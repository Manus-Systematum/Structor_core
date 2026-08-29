import 'dart:io';

import 'package:test/test.dart';
import 'package:wh40k_core/wh40k_core.dart';

import 'support.dart';

void main() {
  final root = Directory(snapshotDir.path);
  final skip = root.existsSync() ? null : 'no snapshot';
  final loader = DatasetLoader(snapshotDir.path,
      corrections: DatasetLoader.correctionsAt(correctionsPath));
  const renderer = RulesRenderer();

  RenderedRule render(String faction, String id) => renderer.render(loader
      .loadFaction(faction)
      .abilities
      .firstWhere((a) => a.abilityId == id));

  group('a rule that only repeats its name is a keyword', () {
    test('a rule with printed wording is never a bare keyword', () {
      // This used to assert the opposite of Deep Strike and Leader: 40kdc
      // encodes them as a grant of themselves, there was nothing to render,
      // and "Deep Strike: Deep Strike" read as a rule the app had failed to
      // explain. BSData publishes both rules in full, so there is now a
      // sentence worth two lines (§3.10) — the compression is for rules with
      // *nothing* to say, and these have something.
      final deepStrike = render('adeptus-astartes', 'deep-strike');
      expect(deepStrike.isPrinted, isTrue);
      expect(deepStrike.isBareKeyword, isFalse);
      // The derivation underneath is still the empty one it always was.
      expect(deepStrike.derived, anyOf('—', contains('Deep Strike')));
    }, skip: skip);

    test('a rule with neither structure nor wording still is one', () {
      const renderer = RulesRenderer();
      final bare = renderer.render(const SourceAbility(
        abilityId: 'some-keyword',
        name: 'Some Keyword',
        gameVersion: GameVersion(edition: '11th', dataslate: 'test'),
      ));
      expect(bare.isBareKeyword, isTrue);
      expect(bare.isPrinted, isFalse);
    });

    test('a grant of an unpublished marker says nothing at all', () {
      // Holy Vanguard's whole effect is a grant of `special-embark-rule`,
      // which upstream never defines. It rendered as "While leading a unit:
      // grants special embark rule" — a sentence that promises a rule and
      // does not give one. 561 of 640 grant targets are unpublished; the
      // seven marker ids are 332 of them.
      final holyVanguard = render('adepta-sororitas', 'holy-vanguard');
      // The derivation is what this is about: the grant target is unpublished,
      // so the structured effect says nothing. Whether a *screen* shows
      // nothing now depends on whether BSData printed the rule.
      expect(holyVanguard.derived, isNot(contains('embark')));
      expect(holyVanguard.derived, isNot(contains('While leading')),
          reason: 'a condition on nothing is nothing');
    }, skip: skip);

    test('a grant naming a real rule still names it', () {
      // The other half of the same data: `benefit-of-cover` appears 99 times
      // and is meaningful even though no record defines it. Suppressing every
      // unpublished grant would have thrown it away too.
      expect(render('adepta-sororitas', 'purge-and-cleanse').derived,
          contains('benefit of cover'));
    }, skip: skip);

    test('a rule with something to say is not', () {
      expect(render('adepta-sororitas', 'cherub').isBareKeyword, isFalse);
      expect(
          render('adepta-sororitas', 'acts-of-faith').isBareKeyword, isFalse);
      expect(render('adepta-sororitas', 'purge-and-cleanse').isBareKeyword,
          isFalse,
          reason: 'it names the rule it grants');
    }, skip: skip);

    test('detected, not listed', () {
      // A hand-kept list of core keywords goes stale the first time upstream
      // adds one, so this is derived from what the renderer produced.
      //
      // 447 of 7,484 (6.0%), up from 166 when this was written. The rise is
      // deliberate and this test caught it: suppressing grants of unpublished
      // marker ids left 281 more abilities with nothing to say, which is the
      // point — they were rendering "grants special embark rule" and telling
      // nobody anything. The bound is a regression guard, not a target.
      var total = 0;
      var bare = 0;
      for (final factionId in loader.availableFactions()) {
        for (final ability in loader.loadFaction(factionId).abilities) {
          total++;
          if (renderer.render(ability).isBareKeyword) bare++;
        }
      }
      // Far fewer than the 447 this once guarded, and for a good reason: a
      // rule BSData printed is never bare, whatever its structure says. What
      // is left are the rules neither source has anything to say about.
      expect(bare / total, lessThan(0.10),
          reason: 'if most rules look empty, the renderer has regressed');
    }, skip: skip);

    test('an empty render counts as one', () {
      const empty = RenderedRule(
          abilityId: 'x',
          name: 'Stealth',
          text: '—',
          phases: [],
          unrendered: []);
      expect(empty.isBareKeyword, isTrue);
    });

    test('punctuation and case do not hide the repetition', () {
      const same = RenderedRule(
          abilityId: 'x',
          name: 'Fights First',
          text: 'Fights First.',
          phases: [],
          unrendered: []);
      expect(same.isBareKeyword, isTrue);

      const granted = RenderedRule(
          abilityId: 'x',
          name: 'Leader',
          text: 'Grants leader.',
          phases: [],
          unrendered: []);
      expect(granted.isBareKeyword, isTrue);
    });
  });
}
