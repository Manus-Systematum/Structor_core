import 'dart:io';

import 'package:test/test.dart';
import 'package:wh40k_core/wh40k_core.dart';

import 'support.dart';

void main() {
  const candidates = [
    FactionCandidate(id: 'tau-empire', name: 'T’au Empire'),
    FactionCandidate(
        id: 'adeptus-astartes',
        name: 'Adeptus Astartes',
        aliases: ['Space Marines']),
    FactionCandidate(id: 'blood-angels', name: 'Blood Angels'),
    FactionCandidate(id: 'orks', name: 'Orks'),
  ];

  group('reading the faction off an export', () {
    test('an apostrophe is not a difference', () {
      // The whole reason this can be exact rather than fuzzy: the export's
      // `Tau Empire` and the data's `T’au Empire` both fold to `tau empire`.
      expect(matchFactionId('Tau Empire', candidates), 'tau-empire');
      expect(matchFactionId('T’au Empire', candidates), 'tau-empire');
      expect(matchFactionId("T'au empire", candidates), 'tau-empire');
    });

    test('the id itself matches, hyphens and all', () {
      expect(matchFactionId('blood-angels', candidates), 'blood-angels');
      expect(matchFactionId('Blood Angels', candidates), 'blood-angels');
    });

    test('an alias matches, which is how a human writes it', () {
      expect(
          matchFactionId('Space Marines', candidates), 'adeptus-astartes');
    });

    test('a chapter is itself, not its parent', () {
      expect(matchFactionId('Blood Angels', candidates), 'blood-angels');
    });

    test('no match returns null rather than the nearest thing', () {
      // Importing against the wrong faction resolves almost nothing, and the
      // wall of misses it produces never says the faction was the problem.
      // Asking beats guessing.
      expect(matchFactionId('Blood Angel', candidates), isNull);
      expect(matchFactionId('Necrons', candidates), isNull);
      expect(matchFactionId('', candidates), isNull);
      expect(matchFactionId(null, candidates), isNull);
    });
  });

  group('against the real exports', () {
    final root = Directory(snapshotDir.path);

    test('the reference export names a faction the data knows', () {
      final file = File('test/fixtures/war_organ_export.txt');
      final parsed = const TextListParser().parse(file.readAsStringSync());
      expect(parsed.factionName, 'Tau Empire');
      expect(matchFactionId(parsed.factionName, candidates), 'tau-empire');
    });

    test('every shipped faction is reachable by its own name', () {
      final loader = DatasetLoader(root.path);
      if (!loader.root.existsSync()) return;

      final all = [
        for (final id in loader.availableFactions())
          FactionCandidate(
            id: id,
            name: loader.loadFaction(id).factionName ?? id,
          ),
      ];
      expect(all, hasLength(35));

      // Nothing is shadowed: matching a faction's own published name always
      // returns that faction and never an earlier one with a similar name.
      for (final faction in all) {
        expect(matchFactionId(faction.name, all), faction.id,
            reason: faction.name);
      }
    }, skip: root.existsSync() ? null : 'no snapshot');
  });

  group('a chapter fields its parent’s datasheets and its own', () {
    final root = Directory(snapshotDir.path);
    final loader = DatasetLoader(snapshotDir.path,
        corrections: DatasetLoader.correctionsAt(correctionsPath));

    test('Blood Angels fields Adeptus Astartes units and Blood Angels ones',
        () {
      // This used to assert the chapter had *exactly* the parent's
      // datasheets, because 40kdc published none of its own and the loader
      // fell through to the parent. BSData publishes twenty-six for Blood
      // Angels, and a fall-through would then have meant a Blood Angels army
      // could field Sanguinary Guard and not an Intercessor Squad (§3.10).
      final chapter = loader.loadFaction('blood-angels');
      final parent = loader.loadFaction('adeptus-astartes');

      expect(chapter.parentFactionId, 'adeptus-astartes');
      expect(chapter.units.length, greaterThan(parent.units.length));

      final ids = {for (final u in chapter.units) u.id};
      expect(ids, contains('intercessor-squad'), reason: 'the parent\'s');
      expect(ids, contains('sanguinary-guard'), reason: 'its own');
    }, skip: root.existsSync() ? null : 'no snapshot');

    test('but keeps its own detachments and army rule', () {
      final chapter = loader.loadFaction('blood-angels');
      final parent = loader.loadFaction('adeptus-astartes');

      expect(chapter.factionRuleId, 'the-red-thirst');
      expect(chapter.detachments.length,
          greaterThan(parent.detachments.length));
    }, skip: root.existsSync() ? null : 'no snapshot');

    test('an inherited datasheet is corrected as the parent owns it', () {
      // Corrections are keyed by the faction that publishes the record. Key
      // them by the chapter and every one of the twelve needs its own copy of
      // every Adeptus Astartes correction.
      final chapter = loader.loadFaction('imperial-fists');
      final parent = loader.loadFaction('adeptus-astartes');

      final chapterStealth =
          chapter.abilities.where((a) => a.abilityId == 'stealth').firstOrNull;
      final parentStealth =
          parent.abilities.where((a) => a.abilityId == 'stealth').firstOrNull;
      expect(chapterStealth, isNotNull);
      expect(chapterStealth!.effectFingerprint,
          parentStealth!.effectFingerprint);
    }, skip: root.existsSync() ? null : 'no snapshot');

    test('a faction with no parent gets no inheritance at all', () {
      final tau = loader.loadFaction('tau-empire');
      expect(tau.parentFactionId, isNull);
      // Not a fixed count any more: what the union must not do is add
      // datasheets to a faction that has nobody to inherit from.
      expect(tau.units.map((u) => u.factionId).toSet(), {'tau-empire'});
      expect(tau.units.length, greaterThan(40));
    }, skip: root.existsSync() ? null : 'no snapshot');
  });
}
