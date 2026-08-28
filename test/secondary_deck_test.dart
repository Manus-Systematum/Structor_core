import 'dart:convert';
import 'dart:io';
import 'dart:math';

import 'package:test/test.dart';
import 'package:wh40k_core/wh40k_core.dart';

import 'support.dart';

MissionCard _card(String id, {List<Object?> awards = const [], Object? drawn}) =>
    MissionCard.fromJson({
      'id': id,
      'name': id,
      'card_type': 'secondary',
      'text': '',
      'awards': awards,
      if (drawn != null) 'when_drawn': drawn,
    });

BattleState _after(List<BattleEvent> events) => BattleLog(events: events).state;

void main() {
  group('drawing', () {
    final deck = SecondaryDeck([_card('a'), _card('b'), _card('c')]);

    test('a drawn card cannot come up again', () {
      // The decks are identical, so there are only 18 choices and each is
      // taken once (§7.3.2).
      final state = _after([const DrawSecondary('a')]);
      expect(deck.remaining(state.secondaries).map((c) => c.id), ['b', 'c']);
      expect(deck.hand(state.secondaries).map((c) => c.id), ['a']);
    });

    test('a discarded card stays out of the deck', () {
      // Discarding is a player decision, not a shuffle-back — otherwise the
      // same unwanted card comes round again.
      final state = _after([
        const DrawSecondary('a'),
        const DiscardSecondary('a'),
      ]);
      expect(deck.hand(state.secondaries), isEmpty);
      expect(deck.remaining(state.secondaries).map((c) => c.id), ['b', 'c']);
      expect(state.secondaries.discarded, ['a']);
    });

    test('a spent deck draws nothing rather than throwing', () {
      final state = _after(const [
        DrawSecondary('a'),
        DrawSecondary('b'),
        DrawSecondary('c'),
      ]);
      expect(deck.remaining(state.secondaries), isEmpty);
      expect(deck.draw(state.secondaries), isNull);
    });

    test('the draw is random but the log is not', () {
      // Randomness at the call site, never in the state: the chosen id is the
      // event, so a replay deals the same hand and undo puts the card back.
      final seen = <String>{};
      for (var seed = 0; seed < 30; seed++) {
        final drawn = deck.draw(const SecondaryState(), random: Random(seed));
        seen.add(drawn!.id);
      }
      expect(seen, hasLength(3), reason: 'all three come up across seeds');

      final replayed = _after([const DrawSecondary('b')]);
      expect(deck.hand(replayed.secondaries).single.id, 'b');
    });
  });

  group('payouts', () {
    test('the tiers a card names become its scoring buttons', () {
      // Outflank pays 3 or 5 depending on how well it went.
      final outflank = _card('outflank', awards: [
        {'vp': 3},
        {'vp': 5},
      ]);
      expect(SecondaryDeck.payouts(outflank), [3, 5]);
    });

    test('a per-something award names no total, so it offers none', () {
      // 2 VP per objective is a number only the player can see. Guessing it
      // would be the invention §7.6 forbids.
      final perObjective = _card('per', awards: [
        {'vp_per': 2, 'per': 'controlled-objective'},
      ]);
      expect(SecondaryDeck.payouts(perObjective), isEmpty);
    });

    test('duplicate tiers collapse', () {
      final card = _card('dup', awards: [
        {'vp': 4},
        {'vp': 4},
      ]);
      expect(SecondaryDeck.payouts(card), [4]);
    });
  });

  group('draw rules', () {
    final deck = SecondaryDeck([
      _card('forward-position', drawn: {
        'operation': 'redraw',
        'battle_round': {'max': 1},
      }),
      _card('plunder', drawn: {
        'operation': 'redraw',
        'card_ids': ['cleanse'],
      }),
      _card('cleanse'),
      _card('bring-it-down', drawn: {
        'operation': 'replace',
        'condition': {
          'subject': 'opponent',
          'quantifier': 'none',
          'unit_filter': {'wounds_min': 10},
        },
      }),
      _card('plain'),
    ]);

    MissionCard card(String id) => deck.card(id)!;

    test('a first-round redraw is flagged, not performed', () {
      // The card goes back into a physical deck the app cannot see, so it
      // says so and leaves the card where it is.
      expect(deck.drawNote(card('forward-position'), round: 1),
          contains('goes back in the deck'));
      expect(deck.drawNote(card('forward-position'), round: 2), isNull);
    });

    test('a mutually exclusive pair only complains when both are held', () {
      expect(deck.drawNote(card('plunder'), round: 2), isNull);
      expect(
        deck.drawNote(card('plunder'), round: 2, hand: ['cleanse']),
        contains('Cannot be held alongside cleanse'),
      );
    });

    test('a replace rule states the condition the app cannot check', () {
      // Whether the opponent fields anything with 10+ wounds is not something
      // the app can see, so it asks rather than deciding.
      expect(
        deck.drawNote(card('bring-it-down'), round: 3),
        'Replace this if your opponent has no unit with 10+ wounds.',
      );
    });

    test('a card with no rule is simply kept', () {
      expect(deck.drawNote(card('plain'), round: 1), isNull);
    });
  });

  group('scoring', () {
    final deck = SecondaryDeck([_card('a'), _card('b')]);

    test('scoring a card banks the VP and clears it from hand', () {
      final state = _after(const [
        DrawSecondary('a'),
        ScoreSecondaryCard(cardId: 'a', round: 2, vp: 5),
      ]);
      expect(deck.hand(state.secondaries), isEmpty);
      expect(state.secondaries.scored, {'a': 5});
      expect(state.me.secondaryTotal, 5);
      expect(state.opponent.total, 0, reason: 'cards are mine, not theirs');
    });

    test('both sides are tracked, and the caps bite per round then per game',
        () {
      // Knowing you are on 42 is useless without knowing they are on 47.
      final state = _after(const [
        ScoreVp(side: Player.me, kind: ScoreKind.primary, round: 1, vp: 10),
        ScoreVp(side: Player.me, kind: ScoreKind.secondary, round: 1, vp: 20),
        ScoreVp(
            side: Player.opponent, kind: ScoreKind.primary, round: 1, vp: 8),
      ]);

      expect(state.me.primaryTotal, 10, reason: 'primary is uncapped here');
      expect(state.me.secondaryTotal, 15, reason: 'trimmed to the round cap');
      expect(state.opponent.total, 8);
    });
  });

  group('the shipped deck', () {
    final available = snapshotAvailable;

    test('is 18 cards, and every one can be drawn', () {
      final loader = correctedLoader();
      final pack = MissionPack.fromJson(
        dispositions: const [],
        missions: const [],
        matchups: const [],
        cards: _readCards(loader),
        deployments: const [],
      );
      final deck = SecondaryDeck.of(pack);

      // "The cards in each deck are identical, so there are only 18 choices."
      expect(deck.cards, hasLength(18));

      var state = const BattleState();
      final drawn = <String>{};
      for (var i = 0; i < 18; i++) {
        final card = deck.draw(state.secondaries, random: Random(i));
        expect(card, isNotNull, reason: 'draw ${i + 1}');
        drawn.add(card!.id);
        state = _after([for (final id in drawn) DrawSecondary(id)]);
      }
      expect(drawn, hasLength(18));
      expect(deck.draw(state.secondaries), isNull, reason: 'the deck is spent');
    }, skip: available ? null : 'no snapshot');

    test('every draw rule in the shipped deck renders a note', () {
      final loader = correctedLoader();
      final pack = MissionPack.fromJson(
        dispositions: const [],
        missions: const [],
        matchups: const [],
        cards: _readCards(loader),
        deployments: const [],
      );
      final deck = SecondaryDeck.of(pack);

      // Seven of the eighteen carry a when_drawn rule, in three shapes. Any
      // that produced no note would be a caveat the player never sees.
      final withRules = [
        for (final card in deck.cards)
          if (card.rawWhenDrawn != null) card.id,
      ];
      expect(withRules, hasLength(7));

      for (final id in withRules) {
        final card = deck.card(id)!;
        final note = deck.drawNote(card, round: 1, hand: withRules);
        expect(note, isNotNull, reason: id);
        expect(note, isNot(contains('null')), reason: id);
      }

      // The three round-gated ones stop complaining once the round moves on.
      final roundGated = [
        for (final id in withRules)
          if (deck.drawNote(deck.card(id)!, round: 1) != null &&
              deck.drawNote(deck.card(id)!, round: 3) == null)
            id,
      ];
      expect(roundGated, hasLength(3));
    }, skip: available ? null : 'no snapshot');
  });
}

List<Object?> _readCards(DatasetLoader loader) {
  final file = '${loader.root.path}/core/secondary-cards.json';
  return _decodeList(file);
}

List<Object?> _decodeList(String path) {
  final content = File(path).readAsStringSync();
  final decoded = jsonDecode(content);
  return decoded is List ? decoded : const [];
}
