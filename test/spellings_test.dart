import 'dart:io';

import 'package:test/test.dart';
import 'package:wh40k_core/wh40k_core.dart';

import 'support.dart';

/// Words upstream misspells (DESIGN.md §3.36).
void main() {
  final corrections = DataCorrections.parse(File(correctionsPath).existsSync()
      ? File(correctionsPath).readAsStringSync()
      : '');

  group('the shipped spellings', () {
    test('every entry carries both spellings and a reason', () {
      expect(corrections.spellings, isNotEmpty);
      for (final spelling in corrections.spellings) {
        expect(spelling.wrong, isNotEmpty);
        expect(spelling.right, isNotEmpty);
        expect(spelling.reason, isNotEmpty,
            reason: '${spelling.wrong}: a correction with no reason is a '
                'private edit nobody can audit');
        expect(spelling.wrong.toLowerCase(),
            isNot(equals(spelling.right.toLowerCase())),
            reason: '${spelling.wrong}: replaces itself');
      }
    });

    test('and each one still matches something upstream publishes', () {
      final root = Directory(snapshotDir.path);
      if (!root.existsSync()) return;

      // Read raw, not through the loader: the loader corrects these on the
      // way in, so asking it would always find nothing.
      final unmatched = <String>[];
      final files = root
          .listSync(recursive: true)
          .whereType<File>()
          .where((f) => f.path.endsWith('.json'))
          .toList();
      for (final spelling in corrections.spellings) {
        final pattern =
            RegExp(r'\b' + RegExp.escape(spelling.wrong) + r'\b', caseSensitive: false);
        final found = files.any((f) => pattern.hasMatch(f.readAsStringSync()));
        if (!found) unmatched.add(spelling.wrong);
      }
      expect(unmatched, isEmpty,
          reason: 'upstream has fixed these — delete the entries, because '
              'leaving one means silently rewriting data that has since '
              'become correct');
    }, skip: Directory(snapshotDir.path).existsSync() ? null : 'no snapshot');
  });

  group('what respelling does to a sentence', () {
    final corrections = DataCorrections.parse('''
spellings:
  - wrong: abilty
    right: ability
    reason: Testing.
  - wrong: Feel Not Pain
    right: Feel No Pain
    reason: Testing.
''');

    test('a whole word is replaced and a word containing it is not', () {
      expect(corrections.respell('has the abilty'), 'has the ability');
      // `disabilty` is not a word this file knows anything about, and
      // rewriting the middle of one would invent a spelling nobody published.
      expect(corrections.respell('disabilty'), 'disabilty');
    });

    test('the case it was written in survives', () {
      expect(corrections.respell('Abilty'), 'Ability');
      expect(corrections.respell('ABILTY'), 'ABILITY');
      expect(corrections.respell('abilty'), 'ability');
    });

    test('a phrase is corrected too, not only a word', () {
      expect(corrections.respell('the Feel Not Pain 6+ ability'),
          'the Feel No Pain 6+ ability');
    });

    test('a text with nothing wrong in it comes back identical', () {
      const clean = 'Each time this model makes an attack, add 1 to the Hit '
          'roll. It has the Feel No Pain 5+ ability.';
      expect(corrections.respell(clean), same(clean));
    });

    test('and no spellings at all is not an expensive no-op', () {
      final none = DataCorrections.parse('abilities: []');
      expect(none.spellings, isEmpty);
      expect(none.respell('abilty'), 'abilty');
    });
  });

  group('against the real dataset', () {
    final root = Directory(snapshotDir.path);
    final skip = root.existsSync() ? null : 'no snapshot';

    test('the misspellings are gone from what the loader hands out', () {
      if (!root.existsSync()) return;
      final loader = DatasetLoader(snapshotDir.path,
          corrections: DatasetLoader.correctionsAt(correctionsPath));

      final offenders = <String>[];
      for (final factionId in loader.availableFactions()) {
        final faction = loader.loadFaction(factionId);
        for (final ability in faction.abilities) {
          final text = '${ability.name} ${ability.description ?? ''}';
          for (final spelling in loader.corrections.spellings) {
            final pattern = RegExp(
                r'\b' + RegExp.escape(spelling.wrong) + r'\b',
                caseSensitive: false);
            if (pattern.hasMatch(text)) {
              offenders.add('$factionId/${ability.abilityId}: ${spelling.wrong}');
            }
          }
        }
      }
      expect(offenders, isEmpty);
    }, skip: skip);

    test('and the rule that reads worst now reads right', () {
      if (!root.existsSync()) return;
      final loader = DatasetLoader(snapshotDir.path,
          corrections: DatasetLoader.correctionsAt(correctionsPath));
      final astartes = loader.loadFaction('adeptus-astartes');
      final rule = astartes.abilities
          .firstWhere((a) => a.abilityId == 'remorseless-persecution');

      // "eligible to declare a chare" — 32 of the 33 copies said it.
      expect(rule.description, contains('declare a charge'));
      expect(rule.description, isNot(contains('chare')));
    }, skip: skip);
  });
}
