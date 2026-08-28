/// Which faction an export is written for (DESIGN.md §6.7).
///
/// The resolver needs a faction before it can match a single name, because
/// every candidate list it scopes to comes out of one faction's catalogue.
/// Until every faction shipped there was nothing to decide and the app simply
/// assumed T'au; with thirty-five, assuming is worse than asking.
///
/// Fortunately the export says so itself — a War Organ list carries its
/// faction on the third line — so this reads what is already there and only
/// falls back to asking when it cannot.
library;

import 'name_match.dart';

/// A faction the app could import against.
class FactionCandidate {
  final String id;
  final String name;

  /// Other published names — Adeptus Astartes is also *Space Marines*.
  final List<String> aliases;

  const FactionCandidate({
    required this.id,
    required this.name,
    this.aliases = const [],
  });
}

/// The faction [line] names, or null when nothing matches it exactly.
///
/// **Exact on the normalised form, never fuzzy.** Importing against the wrong
/// faction resolves almost nothing, and the wall of misses it produces does
/// not say that the faction was the problem — so a near-miss must ask rather
/// than guess. Normalisation is what makes exactness workable: the export's
/// `Tau Empire` and the data's `T’au Empire` both fold to `tau empire`, and
/// the id `tau-empire` folds there too.
String? matchFactionId(String? line, Iterable<FactionCandidate> candidates) {
  if (line == null) return null;
  final needle = normalise(line);
  if (needle.isEmpty) return null;

  for (final candidate in candidates) {
    for (final label in [
      candidate.name,
      candidate.id,
      ...candidate.aliases,
    ]) {
      if (normalise(label) == needle) return candidate.id;
    }
  }
  return null;
}
