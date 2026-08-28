/// Coverage and referential-integrity report over a 40kdc snapshot.
///
/// DESIGN.md §3.3 requires every ingest build to publish a coverage report so
/// data quality stays visible and regressions are caught. This is that report.
///
/// It also encodes findings from the design audit as standing checks, so they
/// become regressions rather than rediscoveries:
///   - near-duplicate ability records with identical effects (§7.3.6)
///   - same-name weapons whose resolved profiles differ (§7.3.5)
///   - copy-scaled points brackets (§2.1)
///   - provisional dataslates mixed with launch data (§3.0)
library;

import '../source/dataset_loader.dart';
import '../source/source_models.dart';

/// A single problem found in the source data. [count] lets a check collapse
/// many instances into one line while keeping [examples] for diagnosis.
class Finding {
  final String category;
  final String summary;
  final int count;
  final List<String> examples;
  final FindingSeverity severity;

  const Finding({
    required this.category,
    required this.summary,
    required this.count,
    required this.severity,
    this.examples = const [],
  });
}

enum FindingSeverity { error, warning, info }

class CoverageReport {
  final String factionId;
  final Map<String, int> counts;
  final Map<String, int> dataslates;
  final Map<String, int> effectTypes;
  final List<Finding> findings;

  const CoverageReport({
    required this.factionId,
    required this.counts,
    required this.dataslates,
    required this.effectTypes,
    required this.findings,
  });

  bool get hasErrors => findings.any((f) => f.severity == FindingSeverity.error);

  int get errorCount =>
      findings.where((f) => f.severity == FindingSeverity.error).length;
}

class CoverageAnalyzer {
  final CoreData core;
  final FactionData faction;

  const CoverageAnalyzer({required this.core, required this.faction});

  CoverageReport analyze() {
    final findings = <Finding>[];

    findings.addAll(_missingFiles());
    findings.addAll(_danglingReferences());
    findings.addAll(_unknownWeaponKeywords());
    findings.addAll(_incompleteRecords());
    findings.addAll(_duplicateAbilities());
    findings.addAll(_weaponNameCollisions());
    findings.addAll(_copyScaledPoints());
    findings.addAll(_provisionalContent());

    findings.sort((a, b) => a.severity.index.compareTo(b.severity.index));

    return CoverageReport(
      factionId: faction.factionId,
      counts: {
        'units': faction.units.length,
        'weapons': faction.weapons.length,
        'weapon profiles':
            faction.weapons.fold(0, (n, w) => n + w.profiles.length),
        'detachments': faction.detachments.length,
        'stratagems': faction.stratagems.length,
        'core stratagems': core.coreStratagems.length,
        'enhancements': faction.enhancementIds.length,
        'abilities': faction.abilities.length,
        'phase mappings': faction.phaseMappings.length,
        'mission matchups': core.missionMatchups.length,
      },
      dataslates: _dataslateHistogram(),
      effectTypes: _effectTypeHistogram(),
      findings: findings,
    );
  }

  Map<String, int> _dataslateHistogram() {
    final hist = <String, int>{};
    void bump(GameVersion v) =>
        hist[v.dataslate] = (hist[v.dataslate] ?? 0) + 1;
    for (final u in faction.units) {
      bump(u.gameVersion);
    }
    for (final w in faction.weapons) {
      bump(w.gameVersion);
    }
    for (final s in faction.stratagems) {
      bump(s.gameVersion);
    }
    for (final d in faction.detachments) {
      bump(d.gameVersion);
    }
    for (final a in faction.abilities) {
      bump(a.gameVersion);
    }
    return hist;
  }

  Map<String, int> _effectTypeHistogram() {
    final hist = <String, int>{};
    for (final a in faction.abilities) {
      hist[a.effectType] = (hist[a.effectType] ?? 0) + 1;
    }
    return hist;
  }

  List<Finding> _missingFiles() {
    final missing = [...core.missingFiles, ...faction.missingFiles];
    if (missing.isEmpty) return const [];
    return [
      Finding(
        category: 'snapshot',
        summary: 'source files absent from the snapshot',
        count: missing.length,
        severity: FindingSeverity.error,
        examples: missing.take(5).toList(),
      ),
    ];
  }

  List<Finding> _danglingReferences() {
    final out = <Finding>[];

    final weaponIds = {for (final w in faction.weapons) w.id};
    final abilityIds = {for (final a in faction.abilities) a.abilityId};
    final unitIds = {for (final u in faction.units) u.id};
    final detachmentIds = {for (final d in faction.detachments) d.id};
    final stratagemIds = {for (final s in faction.stratagems) s.id};

    // Direction matters. A *forward* reference is one the app will follow at
    // render time — a unit naming a weapon it must display. Breaking one of
    // those breaks a screen, so it is an error. A *back* reference is an index
    // pointing at content absent from this snapshot (an ability tagged with a
    // Legends unit we do not carry); nothing downstream follows it, so it is
    // dead weight rather than a fault.
    void check(
      String category,
      String summary,
      Iterable<({String from, String to})> edges,
      Set<String> targets, {
      FindingSeverity severity = FindingSeverity.error,
    }) {
      final broken = edges.where((e) => !targets.contains(e.to)).toList();
      if (broken.isEmpty) return;
      out.add(Finding(
        category: category,
        summary: summary,
        count: broken.length,
        severity: severity,
        examples:
            broken.take(5).map((e) => '${e.from} -> ${e.to}').toList(),
      ));
    }

    check(
      'refs',
      'unit.weapon_ids referencing unknown weapons',
      [
        for (final u in faction.units)
          for (final w in u.weaponIds) (from: u.id, to: w),
      ],
      weaponIds,
    );

    check(
      'refs',
      'unit.ability_ids referencing unknown abilities',
      [
        for (final u in faction.units)
          for (final a in u.abilityIds) (from: u.id, to: a),
      ],
      abilityIds,
    );

    check(
      'refs',
      'detachment.stratagem_ids referencing unknown stratagems',
      [
        for (final d in faction.detachments)
          for (final s in d.stratagemIds) (from: d.id, to: s),
      ],
      stratagemIds,
    );

    check(
      'refs',
      'detachment.enhancement_ids referencing unknown enhancements',
      [
        for (final d in faction.detachments)
          for (final e in d.enhancementIds) (from: d.id, to: e),
      ],
      faction.enhancementIds,
    );

    check(
      'refs',
      'stratagem.detachment_id referencing unknown detachments',
      [
        for (final s in faction.stratagems)
          if (s.detachmentId != null) (from: s.id, to: s.detachmentId!),
      ],
      detachmentIds,
    );

    check(
      'refs',
      'ability.unit_ids referencing units absent from this snapshot '
          '(back-reference: orphaned ability records, nothing downstream '
          'follows them)',
      [
        for (final a in faction.abilities)
          for (final u in a.unitIds) (from: a.abilityId, to: u),
      ],
      unitIds,
      severity: FindingSeverity.warning,
    );

    check(
      'refs',
      'detachment.force_dispositions referencing unknown dispositions',
      [
        for (final d in faction.detachments)
          for (final f in d.forceDispositions) (from: d.id, to: f),
      ],
      core.forceDispositions.keys.toSet(),
    );

    check(
      'refs',
      'mission matchups referencing unknown missions',
      [
        for (final m in core.missionMatchups)
          (from: '${m.disposition}/${m.opponentDisposition}', to: m.missionId),
      ],
      core.missions.keys.toSet(),
    );

    return out;
  }

  List<Finding> _unknownWeaponKeywords() {
    if (core.weaponKeywordIds.isEmpty) return const [];
    final unknown = <String, int>{};
    for (final w in faction.weapons) {
      for (final p in w.profiles) {
        for (final k in p.keywordIds) {
          if (!core.weaponKeywordIds.contains(k)) {
            unknown[k] = (unknown[k] ?? 0) + 1;
          }
        }
      }
    }
    if (unknown.isEmpty) return const [];
    return [
      Finding(
        category: 'keywords',
        summary: 'weapon keywords absent from the core registry',
        count: unknown.values.fold(0, (a, b) => a + b),
        // DESIGN.md §3.3 step 6: fail loudly on unrecognised keywords rather
        // than let the play screen silently degrade.
        severity: FindingSeverity.error,
        examples: unknown.keys.take(8).toList(),
      ),
    ];
  }

  List<Finding> _incompleteRecords() {
    final out = <Finding>[];

    final noProfile = faction.units.where((u) => u.profiles.isEmpty).toList();
    if (noProfile.isNotEmpty) {
      out.add(Finding(
        category: 'completeness',
        summary: 'units with no model profile',
        count: noProfile.length,
        severity: FindingSeverity.error,
        examples: noProfile.take(5).map((u) => u.id).toList(),
      ));
    }

    final noPoints = faction.units.where((u) => u.points.isEmpty).toList();
    if (noPoints.isNotEmpty) {
      out.add(Finding(
        category: 'completeness',
        summary: 'units with no points bracket',
        count: noPoints.length,
        severity: FindingSeverity.warning,
        examples: noPoints.take(5).map((u) => u.id).toList(),
      ));
    }

    final noPhase = faction.stratagems.where((s) => s.phases.isEmpty).toList();
    if (noPhase.isNotEmpty) {
      out.add(Finding(
        category: 'completeness',
        // Without phases a stratagem cannot be filtered into a phase section
        // (DESIGN.md §7.3.7), which is the whole point of the tracker.
        summary: 'stratagems with no phase assignment',
        count: noPhase.length,
        severity: FindingSeverity.error,
        examples: noPhase.take(5).map((s) => s.id).toList(),
      ));
    }

    final noDisposition =
        faction.detachments.where((d) => d.forceDispositions.isEmpty).toList();
    if (noDisposition.isNotEmpty) {
      out.add(Finding(
        category: 'completeness',
        summary: 'detachments with no force disposition',
        count: noDisposition.length,
        severity: FindingSeverity.error,
        examples: noDisposition.take(5).map((d) => d.id).toList(),
      ));
    }

    return out;
  }

  List<Finding> _duplicateAbilities() {
    final byFingerprint = <String, List<SourceAbility>>{};
    for (final a in faction.abilities) {
      if (a.effect.isEmpty) continue;
      byFingerprint.putIfAbsent(a.effectFingerprint, () => []).add(a);
    }
    final dupes = byFingerprint.values.where((g) => g.length > 1).toList();
    if (dupes.isEmpty) return const [];
    return [
      Finding(
        category: 'duplicates',
        summary: 'ability records sharing an identical effect structure',
        count: dupes.fold(0, (n, g) => n + g.length),
        severity: FindingSeverity.warning,
        examples: dupes
            .take(5)
            .map((g) => g.map((a) => a.abilityId).join(' == '))
            .toList(),
      ),
    ];
  }

  List<Finding> _weaponNameCollisions() {
    // Group by the name a player actually reads. Multi-profile weapons show as
    // "Plasma rifle - Standard", so grouping on the bare profile name would
    // wrongly collide every weapon's "Standard" row with every other's.
    final byName = <String, Set<String>>{};
    for (final w in faction.weapons) {
      for (final p in w.profiles) {
        final display =
            w.profiles.length > 1 && p.name != w.name ? '${w.name} - ${p.name}' : p.name;
        byName.putIfAbsent(display, () => <String>{}).add(p.profileKey);
      }
    }
    final collisions =
        byName.entries.where((e) => e.value.length > 1).toList();
    if (collisions.isEmpty) return const [];
    return [
      Finding(
        category: 'aggregation',
        // Expected and correct — a Commander's Missile pod is BS3+ where a
        // Crisis suit's is BS4+. Recorded as info because DESIGN.md §7.3.5
        // depends on aggregation keying on profile, not name; if this ever
        // drops to zero the assumption deserves rechecking.
        summary:
            'weapon names carrying more than one distinct profile (expected; '
            'aggregation must key on profile, not name)',
        count: collisions.length,
        severity: FindingSeverity.info,
        examples: collisions
            .take(5)
            .map((e) => '${e.key} x${e.value.length}')
            .toList(),
      ),
    ];
  }

  List<Finding> _copyScaledPoints() {
    final scaled =
        faction.units.where((u) => u.points.any((p) => p.isCopyScaled)).toList();
    if (scaled.isEmpty) return const [];
    return [
      Finding(
        category: 'points',
        // DESIGN.md §2.1: pricing depends on a unit's index among same-datasheet
        // units, so points are a roster-level computation.
        summary: 'units priced by copy count as well as model count',
        count: scaled.length,
        severity: FindingSeverity.info,
        examples: scaled.take(5).map((u) => u.id).toList(),
      ),
    ];
  }

  List<Finding> _provisionalContent() {
    final hist = _dataslateHistogram();
    final provisional = hist.entries
        .where((e) => e.key.contains('provisional'))
        .fold(0, (n, e) => n + e.value);
    if (provisional == 0) return const [];
    final total = hist.values.fold(0, (a, b) => a + b);
    return [
      Finding(
        category: 'dataslate',
        summary:
            'records still on a provisional dataslate ($provisional of $total) '
            '- must be surfaced in the UI, never shown as current',
        count: provisional,
        severity: FindingSeverity.warning,
        examples: hist.keys.toList(),
      ),
    ];
  }
}

/// Renders a report as plain text for CI logs and the terminal.
String formatReport(CoverageReport report) {
  final b = StringBuffer()
    ..writeln('40kdc coverage - ${report.factionId}')
    ..writeln('=' * 60)
    ..writeln();

  b.writeln('counts');
  final widest = report.counts.keys
      .fold<int>(0, (w, k) => k.length > w ? k.length : w);
  for (final e in report.counts.entries) {
    b.writeln('  ${e.key.padRight(widest)}  ${e.value}');
  }

  b
    ..writeln()
    ..writeln('dataslates');
  for (final e in report.dataslates.entries) {
    b.writeln('  ${e.key}: ${e.value}');
  }

  b
    ..writeln()
    ..writeln('ability effect types (rules renderer must cover these)');
  final types = report.effectTypes.entries.toList()
    ..sort((a, b) => b.value.compareTo(a.value));
  for (final e in types) {
    b.writeln('  ${e.value.toString().padLeft(4)}  ${e.key}');
  }

  b
    ..writeln()
    ..writeln('findings');
  if (report.findings.isEmpty) {
    b.writeln('  none');
  }
  for (final f in report.findings) {
    final tag = switch (f.severity) {
      FindingSeverity.error => 'ERROR',
      FindingSeverity.warning => 'WARN ',
      FindingSeverity.info => 'INFO ',
    };
    b.writeln('  [$tag] ${f.category}: ${f.summary} (${f.count})');
    for (final ex in f.examples) {
      b.writeln('           - $ex');
    }
  }

  b
    ..writeln()
    ..writeln('=' * 60)
    ..writeln(report.hasErrors
        ? '${report.errorCount} error finding(s)'
        : 'no error findings');

  return b.toString();
}
