import 'dart:convert';
import 'dart:io';

import 'package:test/test.dart';
import 'package:wh40k_core/wh40k_core.dart';

import 'support.dart';

SourceWeapon _weapon(
  String id,
  String name, {
  String type = 'ranged',
  Object? attacks = 2,
  Object? skill = 4,
  String skillKey = 'BS',
  int range = 24,
  List<String> keywords = const [],
}) =>
    SourceWeapon.fromJson({
      'id': id,
      'name': name,
      'type': type,
      'profiles': [
        {
          'name': name,
          'range': range,
          'stats': {'A': attacks, 'S': 5, 'AP': 0, 'D': 1, skillKey: skill},
          'keywords': [
            for (final k in keywords) {'keyword_id': k},
          ],
        },
      ],
    });

SourceUnit _unit(String id, String name, List<String> weaponIds) =>
    SourceUnit.fromJson({
      'id': id,
      'name': name,
      'weapon_ids': weaponIds,
      'points': [
        {'models': 1, 'cost': 10},
      ],
    });

/// Mirrors the real shape: a commander with a scoped, better-skilled copy of a
/// weapon the squad also carries.
Catalogue _catalogue() => MapCatalogue(
      [
        _unit('commander', 'Commander', ['pod-commander', 'fists-commander']),
        _unit('squad', 'Squad', ['pod', 'fists', 'flamer']),
      ],
      weapons: [
        _weapon('pod-commander', 'Missile pod', skill: 3),
        _weapon('pod', 'Missile pod', skill: 4),
        _weapon('flamer', 'Flamer',
            attacks: 'D6', skill: null, keywords: ['torrent']),
        _weapon('fists-commander', 'Fists',
            type: 'melee', skill: 2, skillKey: 'WS', range: 0),
        _weapon('fists', 'Fists',
            type: 'melee', skill: 4, skillKey: 'WS', range: 0),
      ],
    );

RosterUnit _r(
  String instanceId,
  String datasheetId, {
  int models = 1,
  Map<String, int> wargear = const {},
}) =>
    RosterUnit(
      instanceId: instanceId,
      datasheetId: datasheetId,
      models: models,
      wargear: [
        for (final e in wargear.entries)
          WargearSelection(itemId: e.key, count: e.value),
      ],
    );

void main() {
  final aggregator = WeaponAggregator(_catalogue());

  group('aggregation keys on the resolved profile, not the name', () {
    final attached = [
      _r('cmd', 'commander', wargear: {'pod': 4}),
      _r('sqd', 'squad', models: 3, wargear: {'pod': 6}),
    ];

    test('same-name weapons with different skill stay separate rows', () {
      final result = aggregator.aggregate(attached);
      expect(result.weapons.length, 2,
          reason: 'ten missile pods, two skills, two rows');
      expect(result.weapons.map((w) => w.skill), ['3+', '4+']);
    });

    test('each row totals its own attacks', () {
      final rows = aggregator.aggregate(attached).weapons;
      final commander = rows.firstWhere((w) => w.skill == '3+');
      final squad = rows.firstWhere((w) => w.skill == '4+');

      expect(commander.weaponCount, 4);
      expect(commander.attacks.fixed, 8);
      expect(squad.weaponCount, 6);
      expect(squad.attacks.fixed, 12);
    });

    test('rows are disambiguated by their carrier', () {
      final rows = aggregator.aggregate(attached).weapons;
      expect(rows.map((w) => w.displayName),
          ['Missile pod (Commander)', 'Missile pod (Squad)']);
    });

    test('a single row carries no parenthetical', () {
      final rows = aggregator.aggregate([
        _r('sqd', 'squad', models: 3, wargear: {'pod': 6})
      ]).weapons;
      expect(rows.single.displayName, 'Missile pod');
    });
  });

  group('dice expressions stay symbolic', () {
    test('eight flamers are 8D6 and hit automatically', () {
      final rows = aggregator.aggregate([
        _r('sqd', 'squad', models: 4, wargear: {'flamer': 8})
      ]).weapons;
      expect(rows.single.attacks.display, '8D6');
      expect(rows.single.attacks.fixed, isNull,
          reason: 'a dice pool has no fixed total');
      expect(rows.single.autoHits, isTrue);
      expect(rows.single.skill, isNull);
      expect(rows.single.keywords.map((k) => k.id), contains('torrent'));
    });

    test('scaling handles multipliers and modifiers', () {
      expect(scaleAttacks('3', 4).display, '12');
      expect(scaleAttacks('D6', 8).display, '8D6');
      expect(scaleAttacks('2D3', 3).display, '6D3');
      expect(scaleAttacks('D6+1', 2).display, '2D6+2');
      expect(scaleAttacks('D3-1', 2).display, '2D3-2');
      expect(scaleAttacks('2', 0).display, '0');
    });

    test('an unrecognised expression is flagged, not guessed at', () {
      final total = scaleAttacks('half the squad', 3);
      expect(total.unparsed, isTrue);
      expect(total.display, contains('3 ×'));
    });
  });

  group('ranged and melee are separate tables', () {
    final attached = [
      _r('cmd', 'commander', wargear: {'pod': 4, 'fists': 1}),
      _r('sqd', 'squad', models: 3, wargear: {'pod': 6, 'fists': 3}),
    ];

    test('shooting excludes melee weapons', () {
      final rows = aggregator.aggregate(attached).weapons;
      expect(
          rows.every((w) => w.displayName.startsWith('Missile pod')), isTrue);
    });

    test('fight shows melee, still split by skill', () {
      final rows =
          aggregator.aggregate(attached, kind: WeaponKind.melee).weapons;
      expect(rows.map((w) => w.skill), ['2+', '4+']);
      expect(rows.map((w) => w.weaponCount), [1, 3]);
    });
  });

  group('dual-profile weapons split across the two tables', () {
    // A Fusion eliminator is typed `ranged` yet carries both a BS profile at
    // 18" and a WS profile in combat. Filtering on the weapon's type would put
    // its melee profile in the shooting table.
    final dual = MapCatalogue(
      [
        _unit('hero', 'Hero', ['eliminator'])
      ],
      weapons: [
        SourceWeapon.fromJson({
          'id': 'eliminator',
          'name': 'Fusion eliminator',
          'type': 'ranged',
          'profiles': [
            {
              'name': 'Ranged',
              'range': 18,
              'stats': {'A': 2, 'S': 10, 'AP': -4, 'D': 'D6', 'BS': 2},
            },
            {
              'name': 'Melee',
              'range': 'Melee',
              'stats': {'A': 1, 'S': 10, 'AP': -4, 'D': 'D6+2', 'WS': 4},
            },
          ],
        }),
      ],
    );
    final split = WeaponAggregator(dual);
    final unit = [
      _r('h', 'hero', wargear: {'eliminator': 1})
    ];

    test('shooting shows only the BS profile', () {
      final rows = split.aggregate(unit).weapons;
      expect(rows.single.displayName, 'Fusion eliminator - Ranged');
      expect(rows.single.skill, '2+');
    });

    test('fight shows only the WS profile', () {
      final rows = split.aggregate(unit, kind: WeaponKind.melee).weapons;
      expect(rows.single.displayName, 'Fusion eliminator - Melee');
      expect(rows.single.skill, '4+');
    });

    test('an auto-hitting profile with neither WS nor BS follows its weapon',
        () {
      final rows = aggregator.aggregate([
        _r('sqd', 'squad', wargear: {'flamer': 1})
      ]).weapons;
      expect(rows.single.autoHits, isTrue);
      expect(rows, isNotEmpty, reason: 'Torrent stays in the shooting table');
    });
  });

  group('casualties make the table live', () {
    test('losing a model reduces weapons and attacks exactly', () {
      final unit = [
        _r('sqd', 'squad', models: 3, wargear: {'pod': 6})
      ];

      final full = aggregator.aggregate(unit).weapons.single;
      expect(full.weaponCount, 6);
      expect(full.attacks.fixed, 12);

      final wounded = aggregator
          .aggregate(unit, modelsRemaining: {'sqd': 2})
          .weapons
          .single;
      expect(wounded.weaponCount, 4, reason: 'two pods per model, two models');
      expect(wounded.attacks.fixed, 8);
    });

    test('a wiped unit contributes nothing', () {
      final rows = aggregator.aggregate(
        [
          _r('sqd', 'squad', models: 3, wargear: {'pod': 6})
        ],
        modelsRemaining: {'sqd': 0},
      ).weapons;
      expect(rows, isEmpty);
    });

    test('an uneven distribution reports full strength rather than guessing',
        () {
      // 5 pods across 3 models has no exact per-model share, so the count is
      // left alone instead of inventing a split.
      final rows = aggregator.aggregate(
        [
          _r('sqd', 'squad', models: 3, wargear: {'pod': 5})
        ],
        modelsRemaining: {'sqd': 2},
      ).weapons;
      expect(rows.single.weaponCount, 5);
    });
  });

  group('unresolvable wargear is reported, not dropped', () {
    test('an item the carrier does not have is surfaced', () {
      final result = aggregator.aggregate([
        _r('sqd', 'squad', wargear: {'nope': 2})
      ]);
      expect(result.isComplete, isFalse);
      expect(result.unresolved.single.itemId, 'nope');
      expect(result.weapons, isEmpty);
    });

    test('a commander does not silently borrow the squad profile', () {
      // 'flamer' is on the squad's weapon list, not the commander's.
      final result = aggregator.aggregate([
        _r('cmd', 'commander', wargear: {'flamer': 2})
      ]);
      expect(result.unresolved.single.itemId, 'flamer');
    });
  });

  group('the reference list', () {
    final snapshot = Directory(snapshotDir.path);
    final available = snapshot.existsSync();

    test('Attached Unit 1 fields ten missile pods across two skills', () {
      final roster = Roster.fromJson(jsonDecode(
          File('test/fixtures/tau_strike_force_2000.json').readAsStringSync()));
      final faction = correctedLoader().loadFaction('tau-empire');
      final catalogue = MapCatalogue.ofFaction(faction);

      final attached =
          roster.combatUnits().firstWhere((g) => g.first.instanceId == 'u01');
      expect(attached.length, 2, reason: 'Commander plus Crisis squad');

      final result = WeaponAggregator(catalogue).aggregate(attached);
      expect(result.isComplete, isTrue,
          reason: result.unresolved.map((u) => u.itemId).join(', '));

      final pods = result.weapons
          .where((w) => w.displayName.startsWith('Missile pod'))
          .toList();
      expect(pods.length, 2);

      final commander = pods.firstWhere((w) => w.skill == '3+');
      final crisis = pods.firstWhere((w) => w.skill == '4+');

      expect(commander.weaponCount, 4);
      expect(commander.attacks.fixed, 8);
      expect(crisis.weaponCount, 6);
      expect(crisis.attacks.fixed, 12);
      expect(commander.weaponCount + crisis.weaponCount, 10);
      expect(commander.range, '30');
    }, skip: available ? null : 'no snapshot; run tools/fetch-40kdc.sh');

    test('Attached Unit 2 is an auto-hitting dice pool', () {
      final roster = Roster.fromJson(jsonDecode(
          File('test/fixtures/tau_strike_force_2000.json').readAsStringSync()));
      final faction = correctedLoader().loadFaction('tau-empire');

      final attached =
          roster.combatUnits().firstWhere((g) => g.first.instanceId == 'u03');
      final result =
          WeaponAggregator(MapCatalogue.ofFaction(faction)).aggregate(attached);

      final flamers = result.weapons
          .where((w) => w.displayName.contains('flamer'))
          .toList();
      expect(flamers, isNotEmpty);
      expect(flamers.every((w) => w.autoHits), isTrue,
          reason: 'Torrent weapons have no BS');
      expect(flamers.map((w) => w.attacks.display).join(' + '), contains('D6'));
      expect(
        flamers.expand((w) => w.keywords).map((k) => k.id),
        contains('torrent'),
      );
    }, skip: available ? null : 'no snapshot; run tools/fetch-40kdc.sh');
  });
}
