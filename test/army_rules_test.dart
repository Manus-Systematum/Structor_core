import 'dart:convert';
import 'dart:io';

import 'package:test/test.dart';
import 'package:wh40k_core/wh40k_core.dart';

import 'support.dart';

void main() {
  group('sharedAcross', () {
    SourceUnit unit(String id, List<String> abilities) => SourceUnit.fromJson({
          'id': id,
          'name': id,
          'faction_id': 'f',
          'ability_ids': abilities,
        });

    test('a rule two datasheets can take is shared', () {
      final shared = ArmyRules.sharedAcross([
        unit('a', ['deep-strike', 'only-mine']),
        unit('b', ['deep-strike']),
      ]);
      expect(shared, contains('deep-strike'));
      expect(shared, isNot(contains('only-mine')));
    });

    test('one datasheet listing a rule twice does not make it shared', () {
      // Otherwise a transcription slip would promote a unit's own rule into a
      // column nobody else appears in.
      final shared = ArmyRules.sharedAcross([
        unit('a', ['twice', 'twice']),
      ]);
      expect(shared, isEmpty);
    });
  });

  group('the reference army', () {
    final available = snapshotAvailable;

    late ArmyRules rules;
    late RosterSnapshot snapshot;

    setUpAll(() {
      if (!available) return;
      final loader = correctedLoader();
      final faction = loader.loadFaction('tau-empire');
      final dataset = Dataset.of(faction, revision: 'test');
      final roster = Roster.fromJson(jsonDecode(
          File('test/fixtures/tau_strike_force_2000.json').readAsStringSync()));

      snapshot = SnapshotBuilder.fromLoader(loader, dataset).build(roster);
      rules = ArmyRules.forRoster(
        roster,
        catalogue: dataset,
        sharedAbilityIds: snapshot.sharedAbilities,
        factionRuleId: snapshot.factionRuleId,
      );
    });

    test('the army rule leads the whole-army tier', () {
      expect(rules.armyWide.first.title, 'For The Greater Good');
      expect(rules.armyWide.first.source, 'Army rule');
      expect(rules.armyWide.first.body, isNotEmpty);
    }, skip: available ? null : 'no snapshot');

    test('both detachment rules follow it', () {
      expect(
        rules.armyWide.skip(1).map((e) => e.title),
        containsAll(['Expert Fieldcraft', 'Superior Craftsmanship']),
      );
    }, skip: available ? null : 'no snapshot');

    test('a keyword every datasheet has is stated, not columned', () {
      expect(rules.universalKeywords, contains('Battlesuit'));
      expect(rules.keywordColumns, isNot(contains('Battlesuit')));
      // Fly is on most but not all of them, which is the question a column
      // answers.
      expect(rules.keywordColumns, contains('Fly'));
    }, skip: available ? null : 'no snapshot');

    test('columns are widest-held first', () {
      final counts = [for (final c in rules.columns) c.owners.length];
      expect(counts, equals([...counts]..sort((a, b) => b.compareTo(a))));
    }, skip: available ? null : 'no snapshot');

    test('every column has at least one owner in this army', () {
      for (final column in rules.columns) {
        expect(column.owners, isNotEmpty, reason: column.name);
      }
    }, skip: available ? null : 'no snapshot');

    test('a unit-only rule is filed under its unit, not as a column', () {
      expect(rules.columns.map((c) => c.name), isNot(contains('Nova Charge')));
      final riptide = rules.units
          .firstWhere((u) => u.name == 'Riptide Battlesuit');
      expect(riptide.only.map((r) => r.name), contains('Nova Charge'));
    }, skip: available ? null : 'no snapshot');

    test('duplicate datasheets collapse to one counted row', () {
      final crisis = rules.units
          .firstWhere((u) => u.name == 'Crisis Fireknife Battlesuits');
      expect(crisis.count, 2);
      expect(rules.units.map((u) => u.datasheetId).toSet(),
          hasLength(rules.units.length));
    }, skip: available ? null : 'no snapshot');

    test('a row claims only wargear the army actually bought', () {
      // A Crisis suit may take a Marker Drone; this list did not buy one on
      // the Fireknives, so their row must not claim it (§7.3.7).
      final fireknife = rules.units
          .firstWhere((u) => u.name == 'Crisis Fireknife Battlesuits');
      final marker = rules.columns
          .where((c) => c.name == 'Marker Drone')
          .firstOrNull;
      expect(marker, isNotNull);
      expect(marker!.owners, isNot(contains(fireknife.datasheetId)));
    }, skip: available ? null : 'no snapshot');

    test('the plural duplicate is one column, not two rules', () {
      final support = rules.columns
          .where((c) => c.name == 'Battlesuit Support System')
          .toList();
      expect(support, hasLength(1));
      expect(support.single.owners.length, greaterThan(1));
      for (final unit in rules.units) {
        expect(unit.only.map((r) => r.name),
            isNot(contains('Battlesuit Support Systems')));
      }
    }, skip: available ? null : 'no snapshot');

    test('every rule lands in exactly one tier', () {
      final columned = {for (final c in rules.columns) c.name};
      for (final unit in rules.units) {
        for (final rule in unit.only) {
          expect(columned, isNot(contains(rule.name)), reason: rule.name);
        }
      }
    }, skip: available ? null : 'no snapshot');
  });

  group('sharedness is a fact about the faction, not the roster', () {
    final available = snapshotAvailable;

    test('a rule only one unit here has is still a shared column', () {
      final loader = correctedLoader();
      final faction = loader.loadFaction('tau-empire');
      final dataset = Dataset.of(faction, revision: 'test');
      final roster = Roster.fromJson(jsonDecode(
          File('test/fixtures/tau_strike_force_2000.json').readAsStringSync()));
      final snapshot = SnapshotBuilder.fromLoader(loader, dataset).build(roster);

      final rules = ArmyRules.forRoster(
        roster,
        catalogue: dataset,
        sharedAbilityIds: snapshot.sharedAbilities,
      );

      // Lone Operative is carried by four T'au datasheets but only the
      // Ghostkeel is in this list. Deciding sharedness per roster filed it
      // under the unit, so the same rule moved tier depending on what was
      // taken — which reads as a bug.
      final lone = rules.columns
          .where((c) => c.name == 'Lone Operative')
          .toList();
      expect(lone, hasLength(1));
      expect(lone.single.owners, hasLength(1));
    }, skip: available ? null : 'no snapshot');

    test('a snapshot carries the shared set and the army rule', () {
      final loader = correctedLoader();
      final dataset =
          Dataset.of(loader.loadFaction('tau-empire'), revision: 'test');
      final roster = Roster.fromJson(jsonDecode(
          File('test/fixtures/tau_strike_force_2000.json').readAsStringSync()));
      final snapshot = SnapshotBuilder.fromLoader(loader, dataset).build(roster);

      expect(snapshot.factionRuleId, 'for-the-greater-good');
      expect(snapshot.abilities, contains('for-the-greater-good'));
      expect(snapshot.sharedAbilities, contains('lone-operative'));

      // And survives the round trip a shared list makes.
      final reread = RosterSnapshot.fromJson(
          jsonDecode(jsonEncode(snapshot.toJson())));
      expect(reread.factionRuleId, snapshot.factionRuleId);
      expect(reread.sharedAbilities, snapshot.sharedAbilities);
    }, skip: available ? null : 'no snapshot');

    test('a snapshot written before tiering still opens', () {
      // No sharedAbilities key: the fallback is the roster's own datasheets,
      // which files a few more rules under their unit rather than failing.
      final reread = RosterSnapshot.fromJson({
        'version': {'source': '40kdc', 'revision': 'r', 'factionId': 'f'},
        'units': const {},
        'weapons': const {},
        'detachments': const {},
        'abilities': const {},
      });
      expect(reread.sharedAbilities, isEmpty);
      expect(reread.factionRuleId, isNull);
    });
  });
}
