/// Compares the primary dataset against the Munitorum points (DESIGN.md §3.0).
///
/// The point is **independence**. `40kdc-data` is community-transcribed;
/// `wh40k-11e-mfm` is parsed from Games Workshop's own published points page.
/// Where two separately derived lineages disagree, one of them is wrong, and
/// the disagreement is a higher-quality signal than either source auditing
/// itself.
///
/// This is exactly how the enhancement-slot discrepancy of §3.2 would have
/// been caught automatically rather than by hand.
///
/// Nothing here decides who is right. It reports the divergence and leaves the
/// judgement to a person — a cross-check that silently picked a winner would
/// just be a second, quieter source of error.
library;

import 'package:yaml/yaml.dart';

import '../import/name_match.dart';
import '../source/source_models.dart';
import 'mfm.dart';

/// The two sources do not always agree on a faction's slug: the primary data
/// calls the Space Marines `adeptus-astartes`, the Munitorum calls them
/// `space-marines`. Only genuine renamings belong here — a chapter with its
/// own file in both sources is not an alias.
const mfmSlugAliases = <String, String>{
  'adeptus-astartes': 'space-marines',
};

/// The Munitorum slug for a primary faction id.
String mfmSlugFor(String factionId) =>
    mfmSlugAliases[factionId] ?? factionId;

/// The primary faction id for a Munitorum slug.
String factionIdFor(String mfmSlug) {
  for (final entry in mfmSlugAliases.entries) {
    if (entry.value == mfmSlug) return entry.key;
  }
  return mfmSlug;
}

enum DivergenceKind {
  unitPoints,
  unitMissing,
  detachmentPoints,
  detachmentDisposition,
  detachmentUniqueTag,
  enhancementPoints,
}

class Divergence {
  final DivergenceKind kind;
  final String subject;
  final String primary;
  final String munitorum;

  const Divergence({
    required this.kind,
    required this.subject,
    required this.primary,
    required this.munitorum,
  });

  @override
  String toString() =>
      '${kind.name.padRight(24)} $subject\n'
      '${' ' * 26}40kdc: $primary\n'
      '${' ' * 26}MFM:   $munitorum';
}

/// A divergence a person has looked at and settled.
///
/// The cross-check will not decide who is right, but once someone has, the
/// disagreement must stop being noise or the tool can never gate a build.
/// Neither source is authoritative: the T'au tag divergence resolved in the
/// primary data's favour, against the Munitorum.
class AcceptedDivergence {
  final String faction;
  final DivergenceKind kind;

  /// Matched as a prefix, so a unit's per-bracket divergences settle together.
  final String subject;

  final String reason;

  const AcceptedDivergence({
    required this.faction,
    required this.kind,
    required this.subject,
    required this.reason,
  });

  bool covers(String factionId, Divergence divergence) =>
      faction == factionId &&
      kind == divergence.kind &&
      divergence.subject.startsWith(subject);

  static List<AcceptedDivergence> parse(String yamlSource) {
    final root = loadYaml(yamlSource);
    if (root is! List) return const [];
    final out = <AcceptedDivergence>[];
    for (final raw in root) {
      if (raw is! Map) continue;
      final kindName = raw['kind']?.toString();
      DivergenceKind? kind;
      for (final k in DivergenceKind.values) {
        if (k.name == kindName) kind = k;
      }
      final reason = raw['reason']?.toString().trim() ?? '';
      // An accepted divergence with no reason is indistinguishable from one
      // nobody looked at, so it is not accepted.
      if (kind == null || reason.isEmpty) continue;
      out.add(AcceptedDivergence(
        faction: raw['faction']?.toString() ?? '',
        kind: kind,
        subject: raw['subject']?.toString() ?? '',
        reason: reason,
      ));
    }
    return out;
  }
}

class CrossCheckReport {
  final String factionId;
  final String mfmVersion;
  final int unitsCompared;
  final int detachmentsCompared;
  final List<Divergence> divergences;

  /// Divergences suppressed by an entry in the accepted list.
  final List<Divergence> accepted;

  /// Units in the Munitorum list with no counterpart in the primary data.
  /// Legends entries are excluded — the app does not carry them.
  final List<String> unmatched;

  const CrossCheckReport({
    required this.factionId,
    required this.mfmVersion,
    required this.unitsCompared,
    required this.detachmentsCompared,
    required this.divergences,
    required this.unmatched,
    this.accepted = const [],
  });

  bool get agrees => divergences.isEmpty;
}

class CrossChecker {
  final Iterable<SourceUnit> units;
  final Iterable<SourceDetachment> detachments;

  /// Enhancement id → points, from the primary data.
  final Map<String, int> enhancementPoints;

  /// Enhancement id → display name, so divergences read sensibly.
  final Map<String, String> enhancementNames;

  /// Divergences already settled by a person, suppressed from the report.
  final List<AcceptedDivergence> accepted;

  const CrossChecker({
    required this.units,
    required this.detachments,
    this.enhancementPoints = const {},
    this.enhancementNames = const {},
    this.accepted = const [],
  });

  CrossCheckReport compare(MfmFaction mfm, {required String factionId}) {
    final divergences = <Divergence>[];
    final unmatched = <String>[];
    var unitsCompared = 0;

    for (final mfmUnit in mfm.units) {
      if (mfmUnit.isLegends) continue;

      final match = bestMatch<SourceUnit>(
        mfmUnit.name,
        units,
        (u) => u.name,
        threshold: 0.75,
      );
      if (match == null) {
        unmatched.add(mfmUnit.name);
        continue;
      }
      unitsCompared++;

      // Resolve through bracketFor rather than keying on the model count:
      // a primary bracket may cover a range (4-6 models) where the Munitorum
      // lists the endpoint (6), and exact-matching reports every such bracket
      // as missing.
      for (final entry in mfmUnit.costTable.entries) {
        final (copies, models) = entry.key;
        final mine = match.value
            .bracketFor(models: models, copyIndex: copies)
            ?.cost;
        if (mine == null) {
          divergences.add(Divergence(
            kind: DivergenceKind.unitMissing,
            subject: '${match.value.name} — $models models, copies $copies+',
            primary: 'no such bracket',
            munitorum: '${entry.value} pts',
          ));
        } else if (mine != entry.value) {
          divergences.add(Divergence(
            kind: DivergenceKind.unitPoints,
            subject: '${match.value.name} — $models models, copies $copies+',
            primary: '$mine pts',
            munitorum: '${entry.value} pts',
          ));
        }
      }
    }

    var detachmentsCompared = 0;
    for (final mfmDetachment in mfm.detachments) {
      final match = bestMatch<SourceDetachment>(
        mfmDetachment.name,
        detachments,
        (d) => d.name,
        threshold: 0.75,
      );
      if (match == null) continue;
      detachmentsCompared++;
      final ours = match.value;

      if (ours.detachmentPoints != mfmDetachment.dp) {
        divergences.add(Divergence(
          kind: DivergenceKind.detachmentPoints,
          subject: ours.name,
          primary: '${ours.detachmentPoints} DP',
          munitorum: '${mfmDetachment.dp} DP',
        ));
      }

      final objective = mfmDetachment.objective;
      if (objective != null) {
        final wanted = normalise(objective).replaceAll(' ', '-');
        if (!ours.forceDispositions.contains(wanted)) {
          divergences.add(Divergence(
            kind: DivergenceKind.detachmentDisposition,
            subject: ours.name,
            primary: ours.forceDispositions.join(', '),
            munitorum: wanted,
          ));
        }
      }

      // A unique tag governs which detachments can be combined, so a missing
      // one silently permits an illegal army.
      final unique = mfmDetachment.unique;
      final oursTags = ours.uniqueTags.map(normalise).toSet();
      final tagMatches = unique != null &&
          ours.uniqueTags.any((t) => scoreName(unique, t) >= 0.85);
      if (unique != null && !tagMatches) {
        divergences.add(Divergence(
          kind: DivergenceKind.detachmentUniqueTag,
          subject: ours.name,
          primary: ours.uniqueTags.isEmpty ? 'none' : ours.uniqueTags.join(', '),
          munitorum: unique,
        ));
      } else if (unique == null && oursTags.isNotEmpty) {
        divergences.add(Divergence(
          kind: DivergenceKind.detachmentUniqueTag,
          subject: ours.name,
          primary: ours.uniqueTags.join(', '),
          munitorum: 'none',
        ));
      }

      for (final mfmEnhancement in mfmDetachment.enhancements) {
        final ids = ours.enhancementIds;
        final enhancementMatch = bestMatch<String>(
          mfmEnhancement.name,
          ids,
          (id) => enhancementNames[id] ?? id.replaceAll('-', ' '),
          threshold: 0.7,
        );
        if (enhancementMatch == null) continue;
        final mine = enhancementPoints[enhancementMatch.value];
        if (mine != null && mine != mfmEnhancement.points) {
          divergences.add(Divergence(
            kind: DivergenceKind.enhancementPoints,
            subject: '${ours.name} — ${mfmEnhancement.name}',
            primary: '$mine pts',
            munitorum: '${mfmEnhancement.points} pts',
          ));
        }
      }
    }

    final settled = <Divergence>[];
    final outstanding = <Divergence>[];
    for (final divergence in divergences) {
      if (accepted.any((a) => a.covers(factionId, divergence))) {
        settled.add(divergence);
      } else {
        outstanding.add(divergence);
      }
    }

    return CrossCheckReport(
      factionId: factionId,
      mfmVersion: mfm.version,
      unitsCompared: unitsCompared,
      detachmentsCompared: detachmentsCompared,
      divergences: outstanding,
      accepted: settled,
      unmatched: unmatched,
    );
  }
}
