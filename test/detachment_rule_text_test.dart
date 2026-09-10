import 'dart:io';

import 'package:test/test.dart';
import 'package:wh40k_core/wh40k_core.dart';

import 'support.dart';

/// Detachment rules taking Wahapedia's text where ours is missing or is a
/// different rule (DESIGN.md §3.37).
void main() {
  final root = Directory(snapshotDir.path);
  final skip = root.existsSync() ? null : 'no snapshot';
  final loader = DatasetLoader(snapshotDir.path,
      corrections: DatasetLoader.correctionsAt(correctionsPath));

  SourceAbility? rule(String factionId, String abilityId) {
    for (final ability in loader.loadFaction(factionId).abilities) {
      if (ability.abilityId == abilityId) return ability;
    }
    return null;
  }

  test('the Windrider Host reads its own rule, not the Autarch\'s', () {
    if (!root.existsSync()) return;
    // BSData publishes two rules under one slug — the Windrider Host
    // detachment rule and the Autarch Skyrunner's ability, both named Ride
    // the Wind — and the wrong one wins the merge. Wahapedia keeps detachment
    // rules in a table of their own, so it can say which is which.
    final windriders = rule('aeldari', 'ride-the-wind')!;
    expect(windriders.description, contains('Declare Battle Formations'));
    expect(windriders.description, isNot(contains('leading a unit')),
        reason: 'that is the Autarch Skyrunner ability');
  }, skip: skip);

  test('a rule whose text was simply missing has it now', () {
    if (!root.existsSync()) return;
    // Twelve detachment rules had no text at all. Superior Craftsmanship is
    // the one §4.19 pins a structured effect against, so it is the one worth
    // naming here: it now carries a printed wording to show beside it.
    final craftsmanship = rule('tau-empire', 'superior-craftsmanship')!;
    expect((craftsmanship.description ?? '').trim(), isNotEmpty);
  }, skip: skip);

  test('a rule we already had is left as we had it', () {
    if (!root.existsSync()) return;
    // 180 of 236 already agree with Wahapedia word for word, and 30 more
    // differ only in wording — where ours usually reads better, since the
    // export runs bulleted lists into one line. Overriding those would trade
    // one transcription for another. Cogbound Alliance is the closest call:
    // it summarises what Wahapedia spells out, and it stays ours.
    final cogbound = rule('imperial-knights', 'cogbound-alliance')!;
    expect(cogbound.description, contains('Assisted Targeting'));
    expect(cogbound.description, isNot(contains('the following ability')),
        reason: "that is Wahapedia's phrasing, not ours");
  }, skip: skip);

  test('an imported table keeps its grid', () {
    if (!root.existsSync()) return;
    // Wahapedia writes the Windrider Host's reserve limit as an HTML table.
    // Stripping the tags alone ran the cells together —
    // `**BATTLE SIZE****NUMBER OF UNITS**Incursion**1**` — with neighbouring
    // bold markers colliding into an unreadable run.
    final text = rule('aeldari', 'ride-the-wind')!.description!;
    expect(text, contains('BATTLE SIZE'));
    expect(text, contains('Strike Force'));
    expect(RegExp(r'\*{3,}').hasMatch(text), isFalse,
        reason: 'markers of neighbouring cells have collided');
  }, skip: skip);

  test('and no imported rule carries a corrupted keyword', () {
    if (!root.existsSync()) return;
    // Five Wahapedia rows have a lowercase letter inside a keyword —
    // `ADEPTUS ARbITES`, `INqUISITOR`. Taking their text without repairing
    // that would trade one faction's wrong rule for another's wrong spelling.
    final offenders = <String>[];
    for (final factionId in loader.availableFactions()) {
      for (final ability in loader.loadFaction(factionId).abilities) {
        if (ability.abilityType != 'detachment') continue;
        final text = ability.description ?? '';
        if (RegExp(r'[A-Z]{2}[a-z][A-Z]').hasMatch(text)) {
          offenders.add('$factionId/${ability.abilityId}');
        }
      }
    }
    expect(offenders, isEmpty, reason: offenders.take(5).join(', '));
  }, skip: skip);
}
