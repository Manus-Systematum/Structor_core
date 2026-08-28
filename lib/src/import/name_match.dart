/// Name normalisation and scoring for import (DESIGN.md §6.7).
///
/// The matcher is only ever asked to choose from a **scoped** candidate list —
/// the model profiles and weapons of one datasheet, not the whole faction —
/// which is what makes fuzzy matching tractable here rather than a guessing
/// game.
library;

/// Lowercase, fold typographic punctuation, drop everything that is not a
/// letter, digit or space, and collapse whitespace.
///
/// Handles the real variation in the source: `T'au flamer` against
/// `tau-flamer`, `Missile Pod` against `Missile pod`, and a stray trailing
/// space after `Seeker missile`.
String normalise(String value) {
  // Apostrophes are *deleted* rather than turned into separators, so that
  // T'au folds to "tau" and Shas'vre to "shasvre". Splitting on them instead
  // yields "t au", which no longer matches the catalogue's "tau-flamer".
  final folded = value
      .toLowerCase()
      .replaceAll(RegExp(r"[’‘ʼ']"), '');

  final buffer = StringBuffer();
  for (final rune in folded.runes) {
    final ch = String.fromCharCode(rune);
    if (RegExp(r'[a-z0-9]').hasMatch(ch)) {
      buffer.write(ch);
    } else {
      buffer.write(' ');
    }
  }
  return buffer.toString().trim().replaceAll(RegExp(r'\s+'), ' ');
}

List<String> tokens(String value) =>
    normalise(value).split(' ').where((t) => t.isNotEmpty).toList();

/// Naive singularisation, enough for `Missile drones` against `missile drone`
/// and `auxiliaries` against `Auxiliary`.
String _singular(String token) {
  if (token.length > 4 && token.endsWith('ies')) {
    return '${token.substring(0, token.length - 3)}y';
  }
  if (token.length > 3 && token.endsWith('s') && !token.endsWith('ss')) {
    return token.substring(0, token.length - 1);
  }
  return token;
}

Set<String> _tokenSet(String value) =>
    tokens(value).map(_singular).toSet();

class Match<T> {
  final T value;
  final double score;

  const Match(this.value, this.score);
}

/// Scores [candidate] as an interpretation of [input], in 0..1.
///
/// The important case is not similarity but **containment**: the export writes
/// `Gun Drone With Twin Pulse Carbine and Shield Drone` where the catalogue
/// has `gun drone`. Every candidate token appearing in the input is a strong
/// signal even though the strings differ wildly in length.
double scoreName(String input, String candidate) {
  final a = normalise(input);
  final b = normalise(candidate);
  if (a.isEmpty || b.isEmpty) return 0;
  if (a == b) return 1;

  final inputTokens = _tokenSet(a);
  final candidateTokens = _tokenSet(b);
  if (candidateTokens.isEmpty) return 0;

  final shared = candidateTokens.intersection(inputTokens).length;
  if (shared == 0) return 0;

  final coverage = shared / candidateTokens.length;
  // How much of the input the candidate explains. A candidate that accounts
  // for most of the input beats one that clips a single word out of it.
  final precision = shared / inputTokens.length;

  if (coverage == 1.0) {
    // Whole candidate present: 0.75 when it explains little of the input,
    // rising towards 0.95 when it explains most of it.
    return 0.75 + 0.20 * precision;
  }
  return 0.60 * coverage * precision;
}

/// Best candidate above [threshold], or null.
Match<T>? bestMatch<T>(
  String input,
  Iterable<T> candidates,
  String Function(T) nameOf, {
  double threshold = 0.5,
}) {
  Match<T>? best;
  for (final candidate in candidates) {
    final score = scoreName(input, nameOf(candidate));
    if (score >= threshold && (best == null || score > best.score)) {
      best = Match(candidate, score);
    }
  }
  return best;
}

/// Splits a compound entry such as `Gun Drone With Twin Pulse Carbine and
/// Shield Drone` into its parts.
///
/// Only used as a fallback after the whole string fails to match, because
/// plenty of real weapon names contain "and" (§6.7).
List<String> splitCompound(String input) {
  final parts = input.split(RegExp(r'\s+and\s+', caseSensitive: false));
  return parts.length < 2
      ? [input]
      : parts.map((p) => p.trim()).where((p) => p.isNotEmpty).toList();
}
