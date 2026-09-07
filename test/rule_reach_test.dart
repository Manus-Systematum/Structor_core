import 'dart:io';

import 'package:test/test.dart';
import 'package:wh40k_core/wh40k_core.dart';

import 'support.dart';

/// Army rules landing on the units they are written for (DESIGN.md §4.19).
void main() {
  final root = Directory(snapshotDir.path);
  final skip = root.existsSync() ? null : 'no snapshot';
  final loader = DatasetLoader(snapshotDir.path,
      corrections: DatasetLoader.correctionsAt(correctionsPath));

  group('a detachment publishes its rules in either of two shapes', () {
    test('and both are read', () {
      if (!root.existsSync()) return;
      final tau = loader.loadFaction('tau-empire');
      final cult = loader.loadFaction('genestealer-cults');

      // The singular form, which 210 detachments use.
      final prototype = tau.detachments
          .firstWhere((d) => d.id == 'experimental-prototype-cadre');
      expect(prototype.detachmentRuleId, 'superior-craftsmanship');
      expect(prototype.ruleIds, ['superior-craftsmanship']);

      // The plural, which ten publish *instead* — read as nothing at all
      // before this, so those detachments had no rules in the app.
      final brood =
          cult.detachments.firstWhere((d) => d.id == 'brood-brothers-auxilia');
      expect(brood.detachmentRuleId, isNull);
      expect(brood.ruleIds, ['integrated-tactics', 'brood-brothers']);
    }, skip: skip);
  });

  group('which units a rule bears on', () {
    late Catalogue tau;
    late RosterEditor editor;

    setUpAll(() {
      if (!root.existsSync()) return;
      tau = MapCatalogue.ofFaction(loader.loadFaction('tau-empire'));
      editor = RosterEditor(tau);
    });

    Roster army(String detachmentId, List<String> datasheetIds) {
      var roster = editor.addDetachment(
        RosterEditor.blank(name: 'p', factionId: 'tau-empire'),
        detachmentId,
      );
      for (final id in datasheetIds) {
        roster = editor.addUnit(roster, id);
      }
      return roster;
    }

    test('a rule written for BATTLESUITS reaches the battlesuits only', () {
      if (!root.existsSync()) return;
      // Bonded Heroes: "Each time a T'AU EMPIRE BATTLESUIT model from your
      // army makes a ranged attack…". Nothing in its structured effect says
      // BATTLESUIT; its printed text does.
      final roster = army('retaliation-cadre',
          ['crisis-sunforge-battlesuits', 'kroot-carnivores']);
      final reach = RuleReachIndex.of(tau, roster);

      final bonded = reach.firstWhere((r) => r.abilityId == 'bonded-heroes');
      expect(bonded.source, ReachSource.wording);
      expect(bonded.datasheetIds, contains('crisis-sunforge-battlesuits'));
      expect(bonded.datasheetIds, isNot(contains('kroot-carnivores')));
    }, skip: skip);

    test('a one-unit army still gets its rule', () {
      if (!root.existsSync()) return;
      // Army-wideness is a property of the faction. Judged against the roster
      // instead, the only battlesuit in a one-unit list satisfies everything
      // the rule names, and the rule disappears from the unit it was written
      // for.
      final roster = army('retaliation-cadre', ['crisis-sunforge-battlesuits']);
      final reach = RuleReachIndex.of(tau, roster);

      expect(reach.map((r) => r.abilityId), contains('bonded-heroes'));
    }, skip: skip);

    test('a rule everything in the army satisfies is left army-wide', () {
      if (!root.existsSync()) return;
      // Killing Blow names T'AU EMPIRE, which every unit in a T'au army has.
      // Repeating it on each is the noise §7.3.9 removed.
      final roster = army(
          'montka', ['crisis-sunforge-battlesuits', 'stealth-battlesuits']);
      final reach = RuleReachIndex.of(tau, roster);

      expect(reach.map((r) => r.abilityId), isNot(contains('killing-blow')));
    }, skip: skip);

    test('a rule reaching nothing in the army is not reported either', () {
      if (!root.existsSync()) return;
      // Hunter's Instincts is written for KROOT, and this army has none.
      final roster =
          army('kroot-hunting-pack', ['crisis-sunforge-battlesuits']);
      final reach = RuleReachIndex.of(tau, roster);

      expect(
          reach.map((r) => r.abilityId), isNot(contains('hunters-instincts')));
    }, skip: skip);

    test('and reaches them when they are there', () {
      if (!root.existsSync()) return;
      final roster = army('kroot-hunting-pack',
          ['kroot-carnivores', 'crisis-sunforge-battlesuits']);
      final reach = RuleReachIndex.of(tau, roster);

      final instincts =
          reach.firstWhere((r) => r.abilityId == 'hunters-instincts');
      expect(instincts.datasheetIds, ['kroot-carnivores']);
    }, skip: skip);
  });

  group('what a rule changes', () {
    test('the range modifier is read, and it is the only one in the game', () {
      if (!root.existsSync()) return;
      final tau = MapCatalogue.ofFaction(loader.loadFaction('tau-empire'));
      final ability = tau.ability('superior-craftsmanship')!;
      final changes = RuleReachIndex.statChanges(ability.effect);

      expect(changes, hasLength(1));
      expect(changes.single.stat, 'R');
      expect(changes.single.operation, 'add');
      expect(changes.single.value, 6);
      expect(changes.single.attackType, 'ranged');
      // **No condition is published.** Superior Craftsmanship reads +6" range
      // on every ranged attack, unconditionally, and its printed text is
      // empty so nothing else states one. Pinned so that a correction adding
      // the condition fails here and is noticed (§4.19).
      expect(changes.single.isUnconditional, isTrue);
    }, skip: skip);

    test('a conditional modifier carries its conditions, unresolved', () {
      if (!root.existsSync()) return;
      final tau = MapCatalogue.ofFaction(loader.loadFaction('tau-empire'));
      final changes =
          RuleReachIndex.statChanges(tau.ability('bonded-heroes')!.effect);

      expect(changes, isNotEmpty);
      expect(changes.first.conditions, contains('unit-within-range-of'));
      expect(changes.first.isUnconditional, isFalse);
    }, skip: skip);
  });
}
