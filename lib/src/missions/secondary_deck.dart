/// The secondary mission deck (DESIGN.md §7.3.2).
///
/// **Each player has their own copy of the same 18 cards**, so both sides can
/// hold the same objective at once — which is how the game is played, and what
/// the user asked for on 2026-08-24 (§7.3.16). A draw is a pick from the cards
/// *that side* has not yet seen, so every method here takes one player's
/// [SecondaryState] and knows nothing about the other's.
///
/// Superseded, 2026-08-24: this said there was no per-player copy, on the
/// grounds that the decks are identical. Identical is not shared — treating
/// one player's draw as spending the other's card is a different game.
///
/// Randomness lives at the call site and never in the state. Anything else
/// would make undo redeal.
library;

import 'dart:math';

import '../battle/battle_state.dart';
import '../source/json.dart';
import 'mission_pack.dart';

class SecondaryDeck {
  final List<MissionCard> cards;

  const SecondaryDeck(this.cards);

  factory SecondaryDeck.of(MissionPack pack) =>
      SecondaryDeck(pack.secondaryCards);

  bool get isEmpty => cards.isEmpty;

  MissionCard? card(String id) {
    for (final card in cards) {
      if (card.id == id) return card;
    }
    return null;
  }

  /// Cards not yet drawn. A card that was drawn and discarded stays out —
  /// [SecondaryState.used] records everything seen, so a re-draw cannot repeat
  /// one the player already turned down.
  List<MissionCard> remaining(SecondaryState state) =>
      [for (final card in cards) if (!state.used.contains(card.id)) card];

  /// One card at random from what is left, or null when the deck is spent.
  MissionCard? draw(SecondaryState state, {Random? random}) {
    final left = remaining(state);
    if (left.isEmpty) return null;
    return left[(random ?? Random()).nextInt(left.length)];
  }

  /// The cards in the player's hand, in the order they were drawn.
  List<MissionCard> hand(SecondaryState state) => [
        for (final id in state.hand)
          if (card(id) case final found?) found,
      ];

  /// Distinct fixed payouts the card's awards name, ascending.
  ///
  /// Outflank pays 3 or 5 depending on how well it went, so the scoring row
  /// offers both rather than one figure and a stepper. Awards that pay *per*
  /// something — 2 VP per objective — name no total, and are left to the
  /// stepper because the app cannot see the table.
  static List<int> payouts(MissionCard card) {
    final out = <int>{};
    for (final award in card.awards) {
      final vp = asInt(asMap(award)['vp']);
      if (vp != null && vp > 0) out.add(vp);
    }
    final sorted = out.toList()..sort();
    return sorted;
  }

  /// Why this card may not stick, in the player's words — or null when it is
  /// simply theirs to keep.
  ///
  /// Seven of the eighteen carry a `when_drawn` rule, in three shapes:
  ///
  ///   - **too early** — Forward Position, Behind Enemy Lines and Defend
  ///     Stronghold go back if drawn in the first battle round;
  ///   - **mutually exclusive** — Plunder and Cleanse cannot be held together;
  ///   - **no valid target** — Bring It Down is replaced if the opponent has
  ///     nothing big enough to shoot at.
  ///
  /// The app **says so and leaves the card**, rather than redrawing on the
  /// player's behalf. The card goes back in a physical deck the app cannot
  /// see, the last case depends on an army it does not have, and a silent
  /// swap would be the app playing the game (§7.6).
  String? drawNote(
    MissionCard card, {
    required int round,
    Iterable<String> hand = const [],
  }) {
    final rule = asMap(card.rawWhenDrawn);
    final operation = strOr(rule['operation'], '');
    if (operation.isEmpty) return null;

    final rounds = asMap(rule['battle_round']);
    final min = asInt(rounds['min']);
    final max = asInt(rounds['max']);
    if (min != null || max != null) {
      final tooEarly = min != null && round < min;
      final tooLate = max != null && round > max;
      if (tooEarly || tooLate) return null;
      return max == 1
          ? 'Drawn in the first battle round this goes back in the deck — '
              'discard it and draw again.'
          : 'Drawn this battle round this goes back in the deck — discard it '
              'and draw again.';
    }

    final exclusive = strList(rule['card_ids'])
        .where((id) => hand.contains(id))
        .map((id) => this.card(id)?.name ?? id)
        .toList();
    if (exclusive.isNotEmpty) {
      return 'Cannot be held alongside ${exclusive.join(' or ')} — discard '
          'one and draw again.';
    }

    if (operation == 'replace') {
      final condition = _conditionText(asMap(rule['condition']));
      return condition == null
          ? 'Replace this if it cannot be scored against this opponent.'
          : 'Replace this if $condition.';
    }
    return null;
  }

  /// `{subject: opponent, quantifier: none, unit_filter: {wounds_min: 10}}`
  /// becomes `your opponent has no unit with 10+ wounds`.
  static String? _conditionText(Map<String, dynamic> condition) {
    if (condition.isEmpty) return null;
    final subject = strOr(condition['subject'], 'opponent') == 'opponent'
        ? 'your opponent'
        : 'you';
    final quantifier =
        strOr(condition['quantifier'], 'none') == 'none' ? 'no' : 'a';

    final filter = asMap(condition['unit_filter']);
    final wounds = asInt(filter['wounds_min']);
    final models = asInt(filter['model_count_min']);
    final what = switch ((wounds, models)) {
      (final int w, _) => 'unit with $w+ wounds',
      (_, final int m) => 'unit of $m+ models',
      _ => 'eligible unit',
    };
    return '$subject has $quantifier $what';
  }
}
