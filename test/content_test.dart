import 'dart:convert';
import 'dart:io';

import 'package:test/test.dart';
import 'package:wh40k_core/wh40k_core.dart';

import 'support.dart';

void main() {
  group('content hashing', () {
    test('is deterministic and fits in three bytes', () {
      const id = 'crisis-fireknife-battlesuits';
      expect(contentHash24(id), contentHash24(id));
      expect(contentHash24(id), lessThan(1 << 24));
      expect(contentHashBytes(id), hasLength(3));
      expect(contentHashHex(id), hasLength(6));
    });

    test('bytes round trip to the hash', () {
      final bytes = contentHashBytes('riptide-battlesuit');
      final rebuilt = (bytes[0] << 16) | (bytes[1] << 8) | bytes[2];
      expect(rebuilt, contentHash24('riptide-battlesuit'));
    });

    test('distinguishes ids that differ only in their suffix', () {
      // The scoped-weapon case: these two must never collapse (§7.3.5).
      expect(
        contentHash24('missile-pod'),
        isNot(contentHash24('missile-pod-commander-in-enforcer-battlesuit')),
      );
    });

    test('a hasher resolves back to its id', () {
      final hasher = ContentHasher(['alpha', 'beta', 'gamma']);
      expect(hasher.resolve(hasher.hashOf('beta')), 'beta');
      expect(hasher.resolve(0x000000), isNull);
      expect(hasher.size, 3);
    });

    test('collisions are reported rather than tolerated', () {
      final clean = ContentHasher(['alpha', 'beta']);
      expect(clean.collisions, isEmpty);

      // A real pair, found rather than assumed: 24 bits over a few thousand
      // short ids is well past the birthday bound, so one always exists.
      final seen = <int, String>{};
      List<String>? pair;
      for (var i = 0; pair == null && i < 100000; i++) {
        final id = 'id-$i';
        final hash = contentHash24(id);
        if (seen[hash] case final other?) {
          pair = [other, id];
        } else {
          seen[hash] = id;
        }
      }
      expect(pair, isNotNull, reason: 'no colliding pair in 100k ids');
      expect(ContentHasher(pair!).collisions.single, pair);
    });

    test('the same id twice is not a collision', () {
      // A Thunderfire Cannon is a datasheet *and* the gun on it, so the id
      // arrives from two tables. Reported as a collision it said the QR
      // namespace needed widening to four bytes, when nothing was ambiguous.
      final hasher = ContentHasher(['alpha', 'alpha']);
      expect(hasher.collisions, isEmpty);
      expect(hasher.resolve(contentHash24('alpha')), 'alpha');
    });
  });

  group('dataset', () {
    final snapshot = Directory(snapshotDir.path);
    final available = snapshot.existsSync();

    Dataset load(String faction) => Dataset.of(
          correctedLoader().loadFaction(faction),
          revision: 'test',
        );

    test('carries the faction its own army rule', () {
      // factions.json shipped from the start and nothing read it, so the one
      // rule true of every unit was the one rule the app never had (§7.3.9).
      expect(load('tau-empire').faction.factionRuleId, 'for-the-greater-good');
      expect(load('tau-empire').faction.factionName, 'T’au Empire');
      expect(
        load('adeptus-astartes').faction.factionRuleId,
        'oath-of-moment',
      );
    }, skip: available ? null : 'no snapshot');

    test('the army rule resolves to an ability that renders', () {
      final dataset = load('tau-empire');
      final rule = dataset.ability(dataset.faction.factionRuleId!);
      expect(rule, isNotNull);
      expect(const RulesRenderer().render(rule!).text, isNotEmpty);
    }, skip: available ? null : 'no snapshot');

    test('pins a version', () {
      final dataset = load('tau-empire');
      expect(dataset.version.source, '40kdc');
      expect(dataset.version.revision, 'test');
      expect(dataset.version.factionId, 'tau-empire');
      expect(dataset.version.toString(), '40kdc@test/tau-empire');
    }, skip: available ? null : 'no snapshot');

    test('serves as a Catalogue', () {
      final dataset = load('tau-empire');
      final fireknife = dataset.unit('crisis-fireknife-battlesuits');
      expect(fireknife, isNotNull);
      expect(dataset.weaponFor(fireknife!, 'missile-pod')?.id, 'missile-pod');
      expect(
        dataset
            .weaponFor(dataset.unit('commander-in-enforcer-battlesuit')!,
                'missile-pod')
            ?.id,
        'missile-pod-commander-in-enforcer-battlesuit',
        reason: 'resolution stays scoped to the carrier',
      );
      expect(dataset.eligibleBodyguards('commander-in-enforcer-battlesuit'),
          contains('crisis-fireknife-battlesuits'));
    }, skip: available ? null : 'no snapshot');

    test('resolves duplicate caps per battle size', () {
      final dataset = load('tau-empire');
      expect(
          dataset.maxCopies('riptide-battlesuit', BattleSize.strikeForce), 3);
      expect(dataset.maxCopies('riptide-battlesuit', BattleSize.incursion), 2);
      expect(dataset.maxCopies('the-twin-lance', BattleSize.strikeForce), 1,
          reason: 'Epic Heroes are capped at one regardless of battle size');
    }, skip: available ? null : 'no snapshot');

    test('the addressable namespace is collision-free', () {
      for (final faction in ['tau-empire', 'necrons', 'adeptus-astartes']) {
        if (!Directory('${snapshot.path}/core/$faction').existsSync()) continue;
        final dataset = load(faction);
        expect(dataset.hashCollisions, isEmpty,
            reason: '$faction: ${dataset.hashCollisions}');
        expect(dataset.addressableIds, greaterThan(50));
      }
    }, skip: available ? null : 'no snapshot');

    test('provisional content is detectable', () {
      expect(load('tau-empire').hasProvisionalContent, isTrue,
          reason: 'T\'au stratagems are still pre-launch');
    }, skip: available ? null : 'no snapshot');
  });

  group('roster snapshot', () {
    final dir = Directory(snapshotDir.path);
    final available = dir.existsSync();

    RosterSnapshot buildSnapshot() {
      final loader = correctedLoader();
      final dataset =
          Dataset.of(loader.loadFaction('tau-empire'), revision: 'test');
      final roster = Roster.fromJson(jsonDecode(
          File('test/fixtures/tau_strike_force_2000.json').readAsStringSync()));
      return SnapshotBuilder.fromLoader(loader, dataset).build(roster);
    }

    test('captures every datasheet the roster names', () {
      final snapshot = buildSnapshot();
      expect(snapshot.units.keys, contains('crisis-fireknife-battlesuits'));
      expect(snapshot.units.keys, contains('the-twin-lance'));
      expect(snapshot.units, hasLength(9),
          reason: '16 roster units across 9 distinct datasheets');
    }, skip: available ? null : 'no snapshot');

    test('captures carrier-scoped weapons, not just the generic ones', () {
      final snapshot = buildSnapshot();
      expect(snapshot.weapons.keys, contains('missile-pod'));
      expect(snapshot.weapons.keys,
          contains('missile-pod-commander-in-enforcer-battlesuit'));
    }, skip: available ? null : 'no snapshot');

    test('is far smaller than the faction it came from', () {
      final loader = correctedLoader();
      final faction = loader.loadFaction('tau-empire');
      final snapshot = buildSnapshot();
      expect(snapshot.units.length, lessThan(faction.units.length / 3),
          reason: 'a snapshot carries what the roster names, not the codex');
    }, skip: available ? null : 'no snapshot');

    test('survives a JSON round trip with its version intact', () {
      final original = buildSnapshot();
      final restored =
          RosterSnapshot.fromJson(jsonDecode(jsonEncode(original.toJson())));
      expect(restored.version.factionId, 'tau-empire');
      expect(restored.entryCount, original.entryCount);
      expect(restored.units.keys, containsAll(original.units.keys));
    }, skip: available ? null : 'no snapshot');

    test('a snapshot alone can price and render the roster', () {
      // The stranger's-list case: rebuild a catalogue from nothing but the
      // snapshot and confirm the list still works (§6.4).
      final snapshot = buildSnapshot();
      final catalogue = MapCatalogue(
        snapshot.units.values.map(SourceUnit.fromJson),
        weapons: snapshot.weapons.values.map(SourceWeapon.fromJson),
        detachments: snapshot.detachments.values.map(SourceDetachment.fromJson),
        // Abilities are part of the snapshot because wargear can be one: a
        // Gun Drone resolves to a twin pulse carbine through its ability.
        abilities: snapshot.abilities.values.map(SourceAbility.fromJson),
      );
      final roster = Roster.fromJson(jsonDecode(
          File('test/fixtures/tau_strike_force_2000.json').readAsStringSync()));

      expect(PointsCalculator(catalogue).price(roster).total,
          referenceListCost);

      final attached =
          roster.combatUnits().firstWhere((g) => g.first.instanceId == 'u01');
      final table = WeaponAggregator(catalogue).aggregate(attached);
      expect(table.isComplete, isTrue);
      expect(table.weapons.map((w) => w.attacks.fixed), containsAll([8, 12]));
    }, skip: available ? null : 'no snapshot');
  });
}
