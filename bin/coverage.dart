/// Prints a coverage and referential-integrity report for a 40kdc snapshot.
///
///     dart run bin/coverage.dart [--data <dir>] [faction-id ...]
///
/// Exits non-zero if any error-severity finding is present, so it can gate CI.
library;

import 'dart:io';

import 'package:wh40k_core/wh40k_core.dart';

import 'paths.dart';

void main(List<String> args) {
  var dataDir = '$dataRoot/40kdc';
  final factions = <String>[];

  for (var i = 0; i < args.length; i++) {
    final arg = args[i];
    if (arg == '--data' && i + 1 < args.length) {
      dataDir = args[++i];
    } else if (arg == '-h' || arg == '--help') {
      stdout.writeln(
          'usage: dart run bin/coverage.dart [--data <dir>] [faction-id ...]');
      return;
    } else {
      factions.add(arg);
    }
  }

  final loader = DatasetLoader(dataDir);
  if (!loader.root.existsSync()) {
    stderr.writeln('no snapshot at $dataDir - run tools/fetch-40kdc.sh first');
    exit(2);
  }

  final targets = factions.isNotEmpty ? factions : loader.availableFactions();
  if (targets.isEmpty) {
    stderr.writeln('no factions found under $dataDir/core');
    exit(2);
  }

  final core = loader.loadCore();
  var errors = 0;

  for (final factionId in targets) {
    final report = CoverageAnalyzer(
      core: core,
      faction: loader.loadFaction(factionId),
    ).analyze();

    stdout.writeln(formatReport(report));
    errors += report.errorCount;
  }

  if (errors > 0) exit(1);
}
