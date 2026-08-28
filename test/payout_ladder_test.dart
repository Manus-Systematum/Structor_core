import 'package:test/test.dart';
import 'package:wh40k_core/wh40k_core.dart';

/// §7.3.27. A card that pays per something and caps can only ever be worth a
/// few totals, and the card leaves the arithmetic to the player.
void main() {
  MissionCard card(List<Map<String, Object?>> awards) => MissionCard.fromJson({
        'id': 'c',
        'name': 'C',
        'card_type': 'secondary',
        'text': '',
        'awards': awards,
      });

  test('two a kill, capped at five, is 2, 4 or 5', () {
    // The third kill is worth one point, not two.
    expect(
        card([
          {'vp_per': 2, 'vp_max': 5},
        ]).ladderFor(2),
        [2, 4, 5]);
  });

  test('three a unit, capped at five, is 3 or 5', () {
    expect(
        card([
          {'vp_per': 3, 'vp_max': 5},
        ]).ladderFor(3),
        [3, 5]);
  });

  test('a rate that already reaches the cap is one figure', () {
    expect(
        card([
          {'vp_per': 5, 'vp_max': 5},
        ]).ladderFor(5),
        [5]);
  });

  test('an uncapped rate has no ladder', () {
    // `3 VP each: for each objective you control` runs as far as the board
    // allows, so there is nothing to enumerate and the stepper stays.
    expect(
        card([
          {'vp_per': 3},
        ]).ladderFor(3),
        isEmpty);
  });

  test('it answers for the rate asked about, not the first award', () {
    expect(
      card([
        {'vp_per': 4, 'vp_max': 8},
        {'vp_per': 2, 'vp_max': 5},
      ]).ladderFor(2),
      [2, 4, 5],
    );
  });

  test('a fixed award is not a ladder', () {
    expect(
        card([
          {'vp': 4},
        ]).ladderFor(4),
        isEmpty);
  });
}
