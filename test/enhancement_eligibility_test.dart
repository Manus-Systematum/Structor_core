import 'dart:io';

import 'package:test/test.dart';
import 'package:wh40k_core/wh40k_core.dart';

import 'support.dart';

void main() {
  final root = Directory(snapshotDir.path);
  final skip = root.existsSync() ? null : 'no snapshot';
  final loader = DatasetLoader(snapshotDir.path,
      corrections: DatasetLoader.correctionsAt(correctionsPath));

  group('who may carry an enhancement', () {
    late FactionData sororitas;
    late SourceUnit canoness;
    late SourceUnit paragons;
    late SourceUnit sacresants;

    setUpAll(() {
      if (!root.existsSync()) return;
      sororitas = loader.loadFaction('adepta-sororitas');
      SourceUnit unit(String id) =>
          sororitas.units.firstWhere((u) => u.id == id);
      canoness = unit('canoness');
      paragons = unit('paragon-warsuits');
      sacresants = unit('celestian-sacresants');
    });

    SourceEnhancement byName(String name) =>
        sororitas.enhancements.firstWhere((e) => e.name.startsWith(name));

    test('a Character may, a Vehicle may not', () {
      final e = byName('Saintly Example');
      expect(e.isUpgrade, isFalse);
      expect(e.canBeTakenBy(canoness, factionName: 'Adepta Sororitas'), isTrue);
      expect(
          e.canBeTakenBy(paragons, factionName: 'Adepta Sororitas'), isFalse);
    }, skip: skip);

    test('a Unit Upgrade names its target, and is not Character-only', () {
      // Writ of Compunction is restricted to Celestian Sacresants — a squad,
      // not a character — which is why the Character rule cannot apply to
      // upgrades.
      final writ = byName('Writ of Compunction');
      expect(writ.isUpgrade, isTrue);
      expect(writ.canBeTakenBy(sacresants, factionName: 'Adepta Sororitas'),
          isTrue);
      expect(writ.canBeTakenBy(canoness, factionName: 'Adepta Sororitas'),
          isFalse);
    }, skip: skip);

    test('a compound restriction is both halves', () {
      // "Adepta Sororitas Character" is the faction keyword and Character run
      // together — matched as one string it matches nothing.
      final h = byName('Hagiomnifex');
      expect(h.keywordRestrictions, contains('Adepta Sororitas Character'));
      expect(h.canBeTakenBy(canoness, factionName: 'Adepta Sororitas'), isTrue);
      expect(
          h.canBeTakenBy(sacresants, factionName: 'Adepta Sororitas'), isFalse,
          reason: 'a squad is not a Character');
    }, skip: skip);

    test('an Epic Hero takes none at all', () {
      final heroes = sororitas.units.where((u) => u.isEpicHero).toList();
      expect(heroes, isNotEmpty);
      for (final enhancement in sororitas.enhancements) {
        expect(
            enhancement.canBeTakenBy(heroes.first,
                factionName: 'Adepta Sororitas'),
            isFalse,
            reason: enhancement.name);
      }
    }, skip: skip);

    test('the faction keyword is not on the datasheet, and still counts', () {
      // Every restriction is a faction keyword somewhere, and a datasheet
      // carries it in `faction_keywords` rather than `keywords`. Checking
      // only `keywords` refuses every enhancement in the game.
      expect(canoness.keywords, isNot(contains('Adepta Sororitas')));
      expect(canoness.factionKeywords, contains('Adepta Sororitas'));
      expect(byName('Saintly Example').keywordRestrictions,
          contains('Adepta Sororitas'));
    }, skip: skip);
  });

  test('every faction keeps at least one enhancement it can actually take', () {
    // The check that would have caught over-strictness: refusing on an
    // unreadable restriction is worse than allowing it, because it makes a
    // published enhancement impossible rather than merely permissive.
    for (final factionId in loader.availableFactions()) {
      final faction = loader.loadFaction(factionId);
      if (faction.enhancements.isEmpty || faction.units.isEmpty) continue;
      final takeable = faction.enhancements.where((e) => faction.units
          .any((u) => e.canBeTakenBy(u, factionName: faction.factionName)));
      expect(takeable, isNotEmpty, reason: factionId);
    }
  }, skip: skip);
}
