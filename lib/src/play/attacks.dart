/// Multiplying an Attacks characteristic by a weapon count.
///
/// Dice expressions stay **symbolic**: eight T'au flamers are `8D6`, not an
/// averaged 28. The player is going to roll the dice; presenting a mean where
/// they expect a pool is both wrong and unhelpful (DESIGN.md §7.3.5).
library;

/// Result of scaling an Attacks characteristic by a count.
class AttackTotal {
  /// What to render, e.g. `12`, `8D6`, `4D3+4`.
  final String display;

  /// Fixed total when the expression is a plain integer, else null.
  final int? fixed;

  /// True when the expression could not be scaled and [display] falls back to
  /// `count × expr`. Surfaced rather than hidden — §7.6 requires the UI say so
  /// instead of implying a number it did not compute.
  final bool unparsed;

  const AttackTotal(this.display, {this.fixed, this.unparsed = false});

  @override
  String toString() => display;

  @override
  bool operator ==(Object other) =>
      other is AttackTotal &&
      other.display == display &&
      other.fixed == fixed &&
      other.unparsed == unparsed;

  @override
  int get hashCode => Object.hash(display, fixed, unparsed);
}

/// Matches `D6`, `2D3`, `D6+1`, `3D6+2` — optional multiplier, die, optional
/// flat modifier.
final _dice = RegExp(r'^(\d*)[dD](\d+)([+-]\d+)?$');

AttackTotal scaleAttacks(String? attacks, int count) {
  final expr = attacks?.trim() ?? '';
  if (expr.isEmpty) return const AttackTotal('?', unparsed: true);
  if (count <= 0) return const AttackTotal('0', fixed: 0);

  final flat = int.tryParse(expr);
  if (flat != null) {
    final total = flat * count;
    return AttackTotal('$total', fixed: total);
  }

  final match = _dice.firstMatch(expr);
  if (match != null) {
    final dice = int.tryParse(match.group(1) ?? '') ?? 1;
    final sides = match.group(2)!;
    final modifier = int.tryParse(match.group(3) ?? '') ?? 0;

    final totalDice = dice * count;
    final totalModifier = modifier * count;
    final buffer = StringBuffer('${totalDice}D$sides');
    if (totalModifier > 0) buffer.write('+$totalModifier');
    if (totalModifier < 0) buffer.write('$totalModifier');
    return AttackTotal(buffer.toString());
  }

  return AttackTotal('$count × $expr', unparsed: true);
}

/// Renders a skill characteristic as the player reads it: `3` becomes `3+`.
/// Torrent-style weapons have no skill and hit automatically.
String? formatSkill(String? skill) {
  if (skill == null || skill.isEmpty) return null;
  if (skill.endsWith('+') || skill.contains('N/A')) return skill;
  return '$skill+';
}
