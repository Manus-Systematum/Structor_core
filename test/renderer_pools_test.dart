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

  /// The sentence built from the **structured effect**, which is what these
  /// tests are about.
  ///
  /// Not what a screen shows any more: where BSData supplies the rule as
  /// printed, that is what a player reads, and no paraphrase of ours improves
  /// on it (§3.10). The derivation still has to be right — the phase tags, the
  /// invulnerable save and §3.6's corrections all come off the same walk — so
  /// it is still tested, just not through the display.
  String render(String factionId, String abilityId) => renderer
      .render(loader
          .loadFaction(factionId)
          .abilities
          .firstWhere((a) => a.abilityId == abilityId))
      .derived;

  group('a grant says what it grants', () {
    test('the Immolator names the rule it hands out', () {
      // It rendered as "grants a bonus" while the record said
      // `ability_id: benefit-of-cover` all along. §3.0 calls `ability-grant`
      // lossy, and it is — but only where the record says nothing.
      final text = render('adepta-sororitas', 'purge-and-cleanse');
      expect(text, contains('benefit of cover'));
      expect(text, isNot(contains('a bonus')));
    }, skip: skip);
  });

  group('the Sisters run on Miracle dice, and the renderer now says so', () {
    test('gaining one', () {
      expect(render('adepta-sororitas', 'cherub'), 'Gain 1 Miracle dice.');
    }, skip: skip);

    test('adding a specific die to the pool', () {
      final text = render('adepta-sororitas', 'solemn-procession');
      expect(text, contains('add a 6 to the Miracle dice pool'));
    }, skip: skip);

    test('spending one, and on which rolls', () {
      // The eligible rolls are the rule, not decoration: knowing you may
      // replace a Charge roll is the reason to hold a die.
      final text = render('adepta-sororitas', 'acts-of-faith');
      expect(text, startsWith('Replace a'));
      expect(text, contains('charge'));
      expect(text, contains('with a Miracle dice'));
    }, skip: skip);

    test('a pool is a proper noun, not three lowercase words', () {
      expect(render('adepta-sororitas', 'cherub'),
          isNot(contains('miracle dice pool')));
    }, skip: skip);
  });

  test('a stratagem cost modifier reads as CP', () {
    final text = render('adeptus-astartes', 'unorthodox-strategist');
    expect(text, contains('+1CP'));
  }, skip: skip);

  test('coverage is measured, not assumed', () {
    // 87 of 7,484 abilities still carry an effect type with no case, down
    // from 161. The bound catches a regression in the renderer without
    // failing every time upstream publishes a new effect shape.
    var total = 0;
    var unrendered = 0;
    for (final factionId in loader.availableFactions()) {
      for (final ability in loader.loadFaction(factionId).abilities) {
        total++;
        if (renderer.render(ability).unrendered.isNotEmpty) unrendered++;
      }
    }
    expect(total, greaterThan(7000));
    expect(unrendered / total, lessThan(0.02));
  }, skip: skip);
}
