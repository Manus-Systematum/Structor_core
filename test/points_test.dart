import 'dart:convert';
import 'dart:io';

import 'package:test/test.dart';
import 'package:wh40k_core/wh40k_core.dart';

import 'support.dart';

/// Synthetic datasheet exercising both pricing mechanisms.
SourceUnit _copyScaledUnit() => SourceUnit.fromJson({
      'id': 'squad',
      'name': 'Squad',
      'points': [
        {'models': 3, 'cost': 100, 'unit_count_min': 1, 'unit_count_max': 2},
        {'models': 3, 'cost': 110, 'unit_count_min': 3},
      ],
      'wargear_costs': [
        {'item_id': 'big-gun', 'cost': 5},
      ],
    });

Roster _rosterOf(List<RosterUnit> units) => Roster(
      name: 'test',
      factionId: 'testers',
      battleSizeId: 'strike-force',
      units: units,
    );

RosterUnit _squad(String id, {int guns = 0}) => RosterUnit(
      instanceId: id,
      datasheetId: 'squad',
      models: 3,
      wargear: [
        if (guns > 0) WargearSelection(itemId: 'big-gun', count: guns),
      ],
    );

void main() {
  group('pricing mechanisms', () {
    final calculator = PointsCalculator(MapCatalogue([_copyScaledUnit()]));

    test('wargear is charged per instance', () {
      final cost = calculator.price(_rosterOf([_squad('a', guns: 6)]));
      expect(cost.units.single.base, 100);
      expect(cost.units.single.wargear, 30);
      expect(cost.total, 130);
    });

    test('the third copy is priced from a later bracket', () {
      final cost =
          calculator.price(_rosterOf([_squad('a'), _squad('b'), _squad('c')]));
      expect(cost.units.map((u) => u.base), [100, 100, 110]);
      expect(cost.units.map((u) => u.copyIndex), [1, 2, 3]);
      expect(cost.total, 310);
    });

    test('a per-unit lookup would under-price - the roster is the unit of work',
        () {
      final roster = _rosterOf([
        _squad('a', guns: 6),
        _squad('b', guns: 6),
        _squad('c', guns: 6),
      ]);
      final cost = calculator.price(roster);

      // 100+30, 100+30, 110+30 — copy scaling on the third, wargear on all.
      expect(cost.units.map((u) => u.total), [130, 130, 140]);
      expect(cost.total, 400);

      // What a naive implementation yields: every unit priced from the first
      // bracket with wargear ignored. 100 points adrift on three units, and
      // it reads as comfortably legal.
      const naive = 100 * 3;
      expect(cost.total - naive, 100);
    });
  });

  group('pricing failures are visible, not silent', () {
    final calculator = PointsCalculator(MapCatalogue([_copyScaledUnit()]));

    test('an unknown datasheet is reported rather than costed at zero', () {
      final cost = calculator.price(_rosterOf([
        RosterUnit(instanceId: 'x', datasheetId: 'nope', models: 1),
      ]));
      expect(cost.isComplete, isFalse);
      expect(cost.unpriced.single.problem, PricingProblem.unknownDatasheet);
    });

    test('a model count with no bracket is reported', () {
      final cost = calculator.price(_rosterOf([
        RosterUnit(instanceId: 'x', datasheetId: 'squad', models: 4),
      ]));
      expect(cost.isComplete, isFalse);
      expect(cost.unpriced.single.problem, PricingProblem.noMatchingBracket);
    });

    test('a bracket costing nothing is reported, not charged as free', () {
      // Two datasheets reach a matched-play list priced at zero: a Legends
      // sheet nobody publishes points for, and one BSData carries without a
      // cost. Summed as written, each is a free unit inside a points limit.
      final free = SourceUnit.fromJson({
        'id': 'free-squad',
        'name': 'Free Squad',
        'points': [
          {'models': 1, 'cost': 0}
        ],
      });
      final cost = PointsCalculator(MapCatalogue([free])).price(_rosterOf([
        RosterUnit(instanceId: 'x', datasheetId: 'free-squad', models: 1),
      ]));
      expect(cost.isComplete, isFalse);
      expect(cost.unpriced.single.problem, PricingProblem.noPublishedPrice);
    });

    test('and a Combat Patrol datasheet still costs nothing, correctly', () {
      // That mode plays a fixed boxed roster with no points at all, so zero
      // is what its sheets say and not a gap in the reading.
      final patrol = SourceUnit.fromJson({
        'id': 'patrol-squad',
        'name': 'Patrol Squad',
        'game_modes': ['combat-patrol'],
        'points': [
          {'models': 1, 'cost': 0}
        ],
      });
      final cost = PointsCalculator(MapCatalogue([patrol])).price(_rosterOf([
        RosterUnit(instanceId: 'x', datasheetId: 'patrol-squad', models: 1),
      ]));
      expect(cost.isComplete, isTrue);
      expect(cost.total, 0);
    });
  });

  group('combat units', () {
    test('LEADS edges collapse a leader and its bodyguard into one entry', () {
      final roster = Roster(
        name: 'test',
        factionId: 'testers',
        battleSizeId: 'strike-force',
        units: const [
          RosterUnit(instanceId: 'cmd', datasheetId: 'commander', models: 1),
          RosterUnit(instanceId: 'sqd', datasheetId: 'squad', models: 3),
          RosterUnit(instanceId: 'solo', datasheetId: 'tank', models: 1),
        ],
        links: const [
          RosterLink(
            type: LinkType.leads,
            fromInstanceId: 'cmd',
            toInstanceId: 'sqd',
          ),
        ],
      );

      final groups = roster.combatUnits();
      expect(groups.length, 2, reason: '3 roster units, 2 combat units');
      expect(groups.first.map((u) => u.instanceId), ['cmd', 'sqd']);
      expect(groups.first.first.instanceId, 'cmd',
          reason: 'the leader heads the group');
      expect(groups.last.single.instanceId, 'solo');
    });
  });

  group('roster serialisation', () {
    test('survives a JSON round trip', () {
      final original = Roster(
        name: 'round trip',
        factionId: 'tau-empire',
        battleSizeId: 'strike-force',
        declaredDisposition: 'reconnaissance',
        detachments: const [RosterDetachment(detachmentId: 'aac')],
        units: [_squad('a', guns: 2)],
        upgrades: const [
          UpgradeSelection(upgradeId: 'up', targetInstanceIds: ['a', 'b', 'c']),
        ],
        links: const [
          RosterLink(
            type: LinkType.leads,
            fromInstanceId: 'a',
            toInstanceId: 'b',
          ),
        ],
        warlordInstanceId: 'a',
      );

      final restored =
          Roster.fromJson(jsonDecode(jsonEncode(original.toJson())));

      expect(restored.name, 'round trip');
      expect(restored.declaredDisposition, 'reconnaissance');
      expect(restored.detachments.single.detachmentId, 'aac');
      expect(restored.units.single.countOf('big-gun'), 2);
      expect(restored.upgrades.single.targetInstanceIds.length, 3,
          reason: 'one upgrade, three targets, one slot');
      expect(restored.links.single.type, LinkType.leads);
      expect(restored.warlordInstanceId, 'a');
    });
  });

  group('reference list end to end', () {
    // Needs a fetched snapshot, which is gitignored. Skipped on a fresh clone
    // rather than failing; run tools/fetch-40kdc.sh to enable.
    final snapshot = Directory(snapshotDir.path);
    final available = snapshot.existsSync();

    late Roster roster;
    late PointsCalculator calculator;

    setUp(() {
      roster = Roster.fromJson(jsonDecode(
          File('test/fixtures/tau_strike_force_2000.json').readAsStringSync()));
      final faction = correctedLoader().loadFaction('tau-empire');
      calculator = PointsCalculator(MapCatalogue(faction.units));
    });

    test('a real 2,000 pt list prices to what its units cost today', () {
      final cost = calculator.price(roster);
      expect(cost.unpriced.map((u) => u.datasheetId), isEmpty);
      expect(cost.total, referenceListCost);
    }, skip: available ? null : 'no snapshot; run tools/fetch-40kdc.sh');

    test('Crisis Fireknife reconciles as 100 base + 6 missile pods at 5', () {
      final cost = calculator.price(roster);
      final fireknife = cost.units
          .firstWhere((u) => u.datasheetId == 'crisis-fireknife-battlesuits');
      expect(fireknife.base, 100);
      expect(fireknife.wargear, 30);
      expect(fireknife.total, 130);
    }, skip: available ? null : 'no snapshot; run tools/fetch-40kdc.sh');

    test('16 roster units resolve to 12 combat units', () {
      expect(roster.units.length, 16);
      expect(roster.combatUnits().length, 12);
    }, skip: available ? null : 'no snapshot; run tools/fetch-40kdc.sh');

    test('both copies of each doubled datasheet stay in the cheaper bracket',
        () {
      final cost = calculator.price(roster);
      final riptides =
          cost.units.where((u) => u.datasheetId == 'riptide-battlesuit');
      expect(riptides.map((u) => u.copyIndex), [1, 2]);
      expect(riptides.map((u) => u.total), [215, 215],
          reason: 'a third Riptide would cost 245, not 215');
    }, skip: available ? null : 'no snapshot; run tools/fetch-40kdc.sh');
  });

  // §3.41. A chapter's Munitorum page prices its parent's datasheets at the
  // chapter's own rate, and so do the god legions for Chaos Space Marine and
  // Daemon datasheets. The data carried those prices as `allied_points` and
  // nothing read them, so a Blood Angels army paid the Space Marine price.
  group('a datasheet is priced at the rate of the army that takes it', () {
    SourceUnit veterans() => SourceUnit.fromJson({
          'id': 'veterans',
          'name': 'Veterans',
          'points': [
            {
              'models': 5,
              'cost': 105,
              'unit_count_min': 1,
              'unit_count_max': 2
            },
            {'models': 5, 'cost': 115, 'unit_count_min': 3},
            {
              'models': 6,
              'models_max': 10,
              'cost': 210,
              'unit_count_min': 1,
              'unit_count_max': 2
            },
            {'models': 6, 'models_max': 10, 'cost': 220, 'unit_count_min': 3},
          ],
          'allied_points': [
            {
              'models': 5,
              'cost': 110,
              'unit_count_min': 1,
              'unit_count_max': 2,
              'host_faction': 'blood-angels'
            },
            {
              'models': 10,
              'cost': 220,
              'unit_count_min': 1,
              'unit_count_max': 2,
              'host_faction': 'blood-angels'
            },
            {
              'models': 5,
              'cost': 120,
              'unit_count_min': 3,
              'unit_count_max': null,
              'host_faction': 'blood-angels'
            },
            {
              'models': 10,
              'cost': 230,
              'unit_count_min': 3,
              'unit_count_max': null,
              'host_faction': 'blood-angels'
            },
          ],
        });

    List<int> basesIn(String army, List<int> sizes) => PointsCalculator(
          MapCatalogue([veterans()]),
        )
            .price(Roster(
              name: 'test',
              factionId: army,
              battleSizeId: 'strike-force',
              units: [
                for (final (i, n) in sizes.indexed)
                  RosterUnit(
                      instanceId: 'u$i', datasheetId: 'veterans', models: n),
              ],
            ))
            .units
            .map((u) => u.base)
            .toList();

    test('the host army pays its own page, copy by copy', () {
      expect(basesIn('blood-angels', [5, 10, 5]), [110, 220, 120]);
      expect(basesIn('adeptus-astartes', [5, 10, 5]), [105, 210, 115]);
      expect(basesIn('ultramarines', [5, 10, 5]), [105, 210, 115],
          reason: 'a chapter with no price of its own pays the parent rate');
    });

    test('a host price printed for 10 models covers the bracket 10 falls in',
        () {
      expect(basesIn('blood-angels', [7]), [220]);
    });

    test('a host list with no bracket for a size leaves it unpriced', () {
      final unit = SourceUnit.fromJson({
        'id': 'veterans',
        'points': [
          {'models': 1, 'cost': 50},
        ],
        'allied_points': [
          {'models': 3, 'cost': 150, 'host_faction': 'blood-angels'},
        ],
      });
      expect(unit.bracketFor(models: 1, army: 'blood-angels'), isNull);
      expect(unit.bracketFor(models: 1)?.cost, 50);
    });

    test('through the real data: Blood Angels and Space Marines', () {
      if (!snapshotAvailable) return;
      final loader = correctedLoader();
      int baseIn(String faction) => PointsCalculator(
            Dataset.of(loader.loadFaction(faction), revision: 'test'),
          )
              .price(Roster(
                name: 'test',
                factionId: faction,
                battleSizeId: 'strike-force',
                units: const [
                  RosterUnit(
                    instanceId: 'u1',
                    datasheetId: 'vanguard-veteran-squad-with-jump-packs',
                    models: 5,
                  ),
                ],
              ))
              .units
              .single
              .base;
      // The Munitorum Field Manual's Space Marine and Blood Angels pages.
      expect(baseIn('adeptus-astartes'), 105);
      expect(baseIn('blood-angels'), 110);
    });
  });
}
