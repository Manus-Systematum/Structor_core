/// Renders every ability of a faction and reports renderer coverage.
///
///     dart run bin/rules.dart <faction-id> [--data <dir>] [--gaps]
///
/// Coverage is the point: it measures how much of the play screen's rules text
/// the renderer can actually produce, and names what it cannot.
library;

import 'dart:io';

import 'package:wh40k_core/wh40k_core.dart';

import 'paths.dart';

void main(List<String> args) {
  var dataDir = '$dataRoot/40kdc';
  var gapsOnly = false;
  var factionId = 'tau-empire';

  for (var i = 0; i < args.length; i++) {
    final arg = args[i];
    if (arg == '--data' && i + 1 < args.length) {
      dataDir = args[++i];
    } else if (arg == '--gaps') {
      gapsOnly = true;
    } else if (arg == '-h' || arg == '--help') {
      stdout.writeln(
          'usage: dart run bin/rules.dart <faction-id> [--data <dir>] [--gaps]');
      return;
    } else {
      factionId = arg;
    }
  }

  final faction = DatasetLoader(dataDir).loadFaction(factionId);
  if (faction.abilities.isEmpty) {
    stderr.writeln('no abilities for $factionId in $dataDir');
    exit(2);
  }

  const renderer = RulesRenderer();
  final rendered = faction.abilities.map(renderer.render).toList()
    ..sort((a, b) => a.name.compareTo(b.name));

  final gaps = <String, int>{};
  for (final rule in rendered) {
    for (final type in rule.unrendered) {
      gaps[type] = (gaps[type] ?? 0) + 1;
    }
  }

  final complete = rendered.where((r) => r.isComplete).length;

  stdout
    ..writeln('rules renderer — $factionId')
    ..writeln('=' * 68)
    ..writeln();

  for (final rule in rendered) {
    if (gapsOnly && rule.isComplete) continue;
    final phases = rule.phases.isEmpty ? '' : '  {${rule.phases.join(', ')}}';
    stdout
      ..writeln('▸ ${rule.name}$phases')
      ..writeln('    ${rule.text}');
  }

  stdout
    ..writeln()
    ..writeln('=' * 68)
    ..writeln('$complete of ${rendered.length} abilities render completely '
        '(${(complete * 100 / rendered.length).round()}%)');

  if (gaps.isEmpty) {
    stdout.writeln('no unrendered shapes');
  } else {
    stdout.writeln('unrendered shapes:');
    final sorted = gaps.entries.toList()
      ..sort((a, b) => b.value.compareTo(a.value));
    for (final gap in sorted) {
      stdout.writeln('  ${gap.value.toString().padLeft(3)}  ${gap.key}');
    }
  }
}
