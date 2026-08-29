import 'dart:io';

import 'package:test/test.dart';
import 'package:wh40k_core/wh40k_core.dart';

import 'support.dart';

/// Taking a Unit Upgrade in the builder.
///
/// A Unit Upgrade and an Enhancement share one record shape and are two
/// mechanics (§2.1): an Enhancement goes on one Character, an Upgrade goes on
/// up to three units that need not be Characters, and three instances of it
/// share one slot. The editor had a door for the first and none for the
/// second, so the only way to record an upgrade was as an enhancement — which
/// the validator then reported as an enhancement on a non-Character, on a
/// list that was legal.
void main() {
  final root = Directory(snapshotDir.path);
  final skip = root.existsSync() ? null : 'no snapshot';
  final loader = DatasetLoader(snapshotDir.path,
      corrections: DatasetLoader.correctionsAt(correctionsPath));

  group('a Unit Upgrade on a unit that is not a Character', () {
    late Catalogue catalogue;
    late SourceEnhancement upgrade;
    late Roster roster;
    late RosterEditor editor;

    setUpAll(() {
      if (!root.existsSync()) return;
      final tau = loader.loadFaction('tau-empire');
      catalogue = MapCatalogue.ofFaction(tau);
      editor = RosterEditor(catalogue);
      upgrade = tau.enhancements
          .firstWhere((e) => e.id == 'unmasking-suite-upgrade-advanced-acquisition-cadre');
      roster = RosterEditor.blank(
        name: 'Stealth',
        factionId: 'tau-empire',
      );
      roster = editor.addDetachment(roster, 'advanced-acquisition-cadre');
      roster = editor.addUnit(roster, 'stealth-battlesuits');
    });

    test('the record is an upgrade, and the target is no Character', () {
      expect(upgrade.isUpgrade, isTrue);
      final sheet = catalogue.unit('stealth-battlesuits')!;
      expect(sheet.isCharacter, isFalse);
      expect(upgrade.canBeTakenBy(sheet, factionName: 'T’au Empire'), isTrue);
    }, skip: skip);

    test('taking it records an upgrade, not an enhancement', () {
      final instanceId = roster.units.single.instanceId;
      final after = editor.setUpgrade(roster, upgrade.id, instanceId, on: true);

      expect(after.enhancements, isEmpty);
      expect(after.upgrades.single.upgradeId, upgrade.id);
      expect(after.upgrades.single.targetInstanceIds, [instanceId]);
    }, skip: skip);

    test('and the list validates clean of it', () {
      final instanceId = roster.units.single.instanceId;
      final after = editor.setUpgrade(roster, upgrade.id, instanceId, on: true);
      final findings = RosterValidator(catalogue).validate(after);

      expect(
        findings.errors.map((f) => f.code),
        isNot(contains('enhancement.non-character')),
      );
      expect(findings.errors.map((f) => f.code), isNot(contains('upgrade.target-count')));
    }, skip: skip);

    test('the old door leads to the same place, so no caller records it wrong',
        () {
      final instanceId = roster.units.single.instanceId;
      final after = editor.setEnhancement(roster, upgrade.id, instanceId);

      expect(after.enhancements, isEmpty);
      expect(after.upgrades.single.targetInstanceIds, [instanceId]);
    }, skip: skip);

    test('a second and third unit join the same selection, sharing its slot',
        () {
      var after = editor.addUnit(roster, 'stealth-battlesuits');
      after = editor.addUnit(after, 'stealth-battlesuits');
      for (final unit in after.units) {
        after = editor.setUpgrade(after, upgrade.id, unit.instanceId, on: true);
      }

      expect(after.upgrades.single.targetInstanceIds, hasLength(3));
      final findings = RosterValidator(catalogue).validate(after);
      expect(findings.errors.map((f) => f.code), isNot(contains('slots.over')));
    }, skip: skip);

    test('taking it off one unit leaves the others', () {
      var after = editor.addUnit(roster, 'stealth-battlesuits');
      final ids = after.units.map((u) => u.instanceId).toList();
      for (final id in ids) {
        after = editor.setUpgrade(after, upgrade.id, id, on: true);
      }
      after = editor.setUpgrade(after, upgrade.id, ids.first, on: false);

      expect(after.upgrades.single.targetInstanceIds, [ids.last]);
    }, skip: skip);

    test('taking it off the last unit drops the selection, not leaves it empty',
        () {
      final instanceId = roster.units.single.instanceId;
      var after = editor.setUpgrade(roster, upgrade.id, instanceId, on: true);
      after = editor.setUpgrade(after, upgrade.id, instanceId, on: false);

      expect(after.upgrades, isEmpty);
      expect(
        RosterValidator(catalogue).validate(after).errors.map((f) => f.code),
        isNot(contains('upgrade.target-count')),
      );
    }, skip: skip);
  });

  group('a list saved before the door existed', () {
    test('has its mis-filed upgrade moved, and nothing else touched', () {
      final root = Directory(snapshotDir.path);
      if (!root.existsSync()) return;
      final tau = loader.loadFaction('tau-empire');
      final catalogue = MapCatalogue.ofFaction(tau);
      final editor = RosterEditor(catalogue);

      var roster = RosterEditor.blank(
        name: 'Stealth',
        factionId: 'tau-empire',
      );
      roster = editor.addDetachment(roster, 'advanced-acquisition-cadre');
      roster = editor.addUnit(roster, 'stealth-battlesuits');
      roster = editor.addUnit(roster, 'commander-in-coldstar-battlesuit');
      final suits = roster.units.first.instanceId;
      final commander = roster.units.last.instanceId;

      // What the builder used to write: both mechanics in the enhancement list.
      roster = roster.copyWith(enhancements: [
        EnhancementSelection(
          enhancementId: 'unmasking-suite-upgrade-advanced-acquisition-cadre',
          targetInstanceId: suits,
        ),
        EnhancementSelection(
          enhancementId: 'puretide-engram-neurochip-retaliation-cadre',
          targetInstanceId: commander,
        ),
      ]);

      final fixed = editor.reclassifyUpgrades(roster);

      expect(fixed.upgrades.single.upgradeId,
          'unmasking-suite-upgrade-advanced-acquisition-cadre');
      expect(fixed.upgrades.single.targetInstanceIds, [suits]);
      expect(fixed.enhancements.single.enhancementId,
          'puretide-engram-neurochip-retaliation-cadre');
    }, skip: skip);
  });
}
