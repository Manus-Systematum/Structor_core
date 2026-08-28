/// Compares the primary dataset against the Munitorum points (DESIGN.md §3.0).
///
///     dart run bin/crosscheck.dart [faction ...] [--data <dir>] [--mfm <dir>]
///
/// Exits non-zero when the two sources disagree, so it can gate a data build.
library;

import 'dart:convert';
import 'dart:io';

import 'package:wh40k_core/wh40k_core.dart';

import 'paths.dart';

void main(List<String> args) {
  var dataDir = '$dataRoot/40kdc';
  var mfmDir = '$dataRoot/mfm';
  var acceptedPath = '$projectRoot/crosscheck-accepted.yaml';
  final factions = <String>[];

  for (var i = 0; i < args.length; i++) {
    switch (args[i]) {
      case '--data':
        if (i + 1 < args.length) dataDir = args[++i];
      case '--mfm':
        if (i + 1 < args.length) mfmDir = args[++i];
      case '--accepted':
        if (i + 1 < args.length) acceptedPath = args[++i];
      case '-h':
      case '--help':
        stdout.writeln('usage: dart run bin/crosscheck.dart [faction ...] '
            '[--data <dir>] [--mfm <dir>]');
        return;
      default:
        factions.add(args[i]);
    }
  }

  final loader = DatasetLoader(dataDir);
  final available = Directory(mfmDir).existsSync()
      ? Directory(mfmDir)
          .listSync()
          .whereType<File>()
          .where((f) => f.path.endsWith('.yaml'))
          .map((f) =>
              factionIdFor(f.uri.pathSegments.last.replaceAll('.yaml', '')))
          .toList()
      : <String>[];

  final targets = factions.isNotEmpty ? factions : available;
  if (targets.isEmpty) {
    stderr.writeln('no MFM data in $mfmDir - run tools/fetch-mfm.sh first');
    exit(2);
  }

  final acceptedFile = File(acceptedPath);
  final accepted = acceptedFile.existsSync()
      ? AcceptedDivergence.parse(acceptedFile.readAsStringSync())
      : <AcceptedDivergence>[];

  var total = 0;
  for (final factionId in targets) {
    final yamlFile = File('$mfmDir/${mfmSlugFor(factionId)}.yaml');
    if (!yamlFile.existsSync()) {
      stderr.writeln('no MFM data for $factionId');
      continue;
    }
    final faction = loader.loadFaction(factionId);
    if (faction.units.isEmpty) {
      stderr.writeln('no primary data for $factionId');
      continue;
    }

    final enhancements = _enhancements(dataDir, factionId);
    final report = CrossChecker(
      units: faction.units,
      detachments: faction.detachments,
      enhancementPoints: enhancements.$1,
      enhancementNames: enhancements.$2,
      accepted: accepted,
    ).compare(MfmFaction.parse(yamlFile.readAsStringSync()),
        factionId: factionId);

    stdout
      ..writeln('cross-check — $factionId (MFM v${report.mfmVersion})')
      ..writeln('=' * 68)
      ..writeln('  ${report.unitsCompared} units, '
          '${report.detachmentsCompared} detachments compared');

    if (report.unmatched.isNotEmpty) {
      stdout.writeln('  ${report.unmatched.length} in the MFM with no '
          'counterpart: ${report.unmatched.take(5).join(', ')}'
          '${report.unmatched.length > 5 ? '…' : ''}');
    }
    stdout.writeln();

    if (report.accepted.isNotEmpty) {
      stdout.writeln('  ${report.accepted.length} previously settled');
    }

    if (report.agrees) {
      stdout.writeln('  no outstanding divergence\n');
    } else {
      for (final divergence in report.divergences) {
        stdout.writeln('  $divergence');
      }
      stdout.writeln('\n  ${report.divergences.length} divergence(s)\n');
    }
    total += report.divergences.length;
  }

  if (total > 0) exit(1);
}

/// Enhancement points and names, read straight from the source file — the
/// loader only keeps their ids.
(Map<String, int>, Map<String, String>) _enhancements(
    String dataDir, String factionId) {
  final file = File('$dataDir/core/$factionId/enhancements.json');
  if (!file.existsSync()) return (const {}, const {});
  final points = <String, int>{};
  final names = <String, String>{};
  final decoded = jsonDecode(file.readAsStringSync());
  for (final raw in decoded is List ? decoded : const []) {
    if (raw is! Map) continue;
    final id = raw['id']?.toString();
    if (id == null) continue;
    final cost = raw['points'] ?? raw['cost'];
    if (cost is num) points[id] = cost.toInt();
    final name = raw['name']?.toString();
    if (name != null) names[id] = name;
  }
  return (points, names);
}
