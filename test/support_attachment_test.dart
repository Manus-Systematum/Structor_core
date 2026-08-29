import 'dart:io';

import 'package:test/test.dart';
import 'package:wh40k_core/wh40k_core.dart';

import 'support.dart';

void main() {
  final root = Directory(snapshotDir.path);
  final skip = root.existsSync() ? null : 'no snapshot';
  final loader = DatasetLoader(snapshotDir.path,
      corrections: DatasetLoader.correctionsAt(correctionsPath));

  group('Leader and Support are different roles', () {
    test('the Hospitaller attaches, as Support', () {
      // It was neither leading nor listed as able to: `isLeader` accepts only
      // `leader`, so a Support character had no way to join anything even
      // though leader-attachments.json publishes its bodyguards.
      final sororitas = loader.loadFaction('adepta-sororitas');
      final hospitaller =
          sororitas.units.firstWhere((u) => u.id == 'hospitaller');
      expect(hospitaller.isLeader, isFalse);
      expect(hospitaller.isSupport, isTrue);
      expect(hospitaller.attachesToUnit, isTrue);

      final canoness = sororitas.units.firstWhere((u) => u.id == 'canoness');
      expect(canoness.isLeader, isTrue);
      expect(canoness.attachesToUnit, isTrue);
    }, skip: skip);

    test('37 datasheets are Support, and they are not a rounding error', () {
      var support = 0;
      for (final factionId in loader.availableFactions()) {
        support += loader
            .loadFaction(factionId)
            .units
            .where((u) => u.isSupport)
            .length;
      }
      expect(support, greaterThan(30));
    }, skip: skip);
  });

  group('a unit takes one of each', () {
    late RosterEditor editor;
    late Roster roster;

    setUp(() {
      if (!root.existsSync()) return;
      final dataset = Dataset.of(loader.loadFaction('adepta-sororitas'));
      editor = RosterEditor(dataset);
      roster = RosterEditor.blank(name: 'test', factionId: 'adepta-sororitas');
      roster = editor.addUnit(roster, 'canoness');
      roster = editor.addUnit(roster, 'hospitaller');
      roster = editor.addUnit(roster, 'battle-sisters-squad');
    });

    String idOf(Roster r, String datasheetId) =>
        r.units.firstWhere((u) => u.datasheetId == datasheetId).instanceId;

    test('a Support does not evict the Leader already there', () {
      // `attach` dropped every link on the bodyguard, so adding the
      // Hospitaller silently removed the Canoness leading the squad.
      final squad = idOf(roster, 'battle-sisters-squad');
      var out = editor.attach(roster, idOf(roster, 'canoness'), squad);
      out = editor.attach(out, idOf(out, 'hospitaller'), squad);

      final joined = out.links
          .where((l) => l.type == LinkType.leads && l.toInstanceId == squad);
      expect(joined, hasLength(2));
    }, skip: skip);

    test('and the three of them are one combat unit', () {
      // Keyed by bodyguard, the old grouping kept one link and left the other
      // character standing alone — priced and drawn as its own unit.
      final squad = idOf(roster, 'battle-sisters-squad');
      var out = editor.attach(roster, idOf(roster, 'canoness'), squad);
      out = editor.attach(out, idOf(out, 'hospitaller'), squad);

      final groups = out.combatUnits();
      expect(groups, hasLength(1));
      expect(groups.single, hasLength(3));
      // The squad is last, so the label still reads character-first.
      expect(groups.single.last.datasheetId, 'battle-sisters-squad');
    }, skip: skip);

    test('a squad with a Leader is still offered to a Support', () {
      final squad = idOf(roster, 'battle-sisters-squad');
      final withLeader = editor.attach(roster, idOf(roster, 'canoness'), squad);

      final forSupport = editor.eligibleBodyguards(
          withLeader, idOf(withLeader, 'hospitaller'));
      expect(forSupport.map((u) => u.datasheetId),
          contains('battle-sisters-squad'));
    }, skip: skip);

    test('but not to a second Leader', () {
      var out = editor.addUnit(roster, 'palatine');
      final squad = idOf(out, 'battle-sisters-squad');
      out = editor.attach(out, idOf(out, 'canoness'), squad);

      final forSecondLeader =
          editor.eligibleBodyguards(out, idOf(out, 'palatine'));
      expect(forSecondLeader.map((u) => u.datasheetId),
          isNot(contains('battle-sisters-squad')));
    }, skip: skip);
  });
}
