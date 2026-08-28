/// Imports a text roster export and writes the resulting roster (§6.7).
///
///     dart run bin/import.dart <export.txt> [--faction <id>] [--out <file>]
///
/// The same path the app's import screen takes, run from a terminal. Its
/// purpose beyond debugging is keeping the committed fixtures honest: the
/// reference roster is *derived* from `war_organ_export.txt`, and a fixture
/// hand-edited out of step with the importer stops testing the importer.
library;

import 'dart:convert';
import 'dart:io';

import 'package:wh40k_core/wh40k_core.dart';

import 'paths.dart';

void main(List<String> args) {
  var dataDir = '$dataRoot/40kdc';
  var correctionsPath = '$projectRoot/data-corrections.yaml';
  var factionId = 'tau-empire';
  String? sourcePath;
  String? outPath;

  for (var i = 0; i < args.length; i++) {
    final arg = args[i];
    if (arg == '--data' && i + 1 < args.length) {
      dataDir = args[++i];
    } else if (arg == '--corrections' && i + 1 < args.length) {
      correctionsPath = args[++i];
    } else if (arg == '--faction' && i + 1 < args.length) {
      factionId = args[++i];
    } else if (arg == '--out' && i + 1 < args.length) {
      outPath = args[++i];
    } else if (arg == '-h' || arg == '--help') {
      stdout.writeln('usage: dart run bin/import.dart <export.txt> '
          '[--faction <id>] [--out <file>] [--data <dir>]');
      return;
    } else {
      sourcePath = arg;
    }
  }

  if (sourcePath == null) {
    stderr.writeln('usage: dart run bin/import.dart <export.txt>');
    exit(2);
  }
  final source = File(sourcePath);
  if (!source.existsSync()) {
    stderr.writeln('no export at $sourcePath');
    exit(2);
  }

  final loader = DatasetLoader(
    dataDir,
    corrections: DatasetLoader.correctionsAt(correctionsPath),
  );
  final faction = loader.loadFaction(factionId);
  if (faction.units.isEmpty) {
    stderr.writeln('no data for $factionId in $dataDir');
    exit(2);
  }
  final dataset = Dataset.of(faction, revision: 'local');

  final parsed = const TextListParser().parse(source.readAsStringSync());
  final result = RosterResolver(
    dataset,
    abilityLookup: dataset.ability,
    knownAbilities: faction.abilities,
  ).resolve(parsed, factionId: factionId);

  for (final issue in result.issues) {
    stderr.writeln('  $issue');
  }

  final cost = PointsCalculator(dataset).price(result.roster);
  final printed = result.printedPoints;
  stdout.writeln('${result.roster.units.length} units, ${cost.total} pts'
      '${printed == null ? '' : ' (printed $printed)'}');
  if (printed != null && printed != cost.total) {
    stderr.writeln('WARNING: computed total disagrees with the printed one');
  }

  final json =
      '${const JsonEncoder.withIndent('  ').convert(result.roster.toJson())}\n';
  if (outPath == null) {
    stdout.write(json);
  } else {
    File(outPath).writeAsStringSync(json);
    stdout.writeln('wrote $outPath');
  }

  if (!result.isClean) exit(1);
}
