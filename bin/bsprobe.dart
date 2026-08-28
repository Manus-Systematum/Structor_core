/// Reads a vendored BSData faction and reports what the mapper made of it.
///
/// Exists to be run by a person during the migration, not by the build.
library;

import 'dart:convert';
import 'dart:io';

import 'package:wh40k_core/src/source/bsdata/bs_document.dart';
import 'package:wh40k_core/src/source/bsdata/bs_mapper.dart';

import 'paths.dart';

void main(List<String> args) {
  final factionId = args.isEmpty ? 'tau-empire' : args.first;
  final root = Directory('$dataRoot/bsdata');

  final index = BsIndex();
  for (final f
      in Directory('${root.path}/shared').listSync().whereType<File>()) {
    index.add(f, asRoot: false);
  }
  final dir = Directory('${root.path}/$factionId');
  for (final f in dir.listSync().whereType<File>()) {
    if (f.path.endsWith('.json')) index.add(f);
  }

  final faction = BsMapper(index).faction(factionId);
  stdout.writeln('index entries: ${index.size}   roots: ${index.roots.length}');
  stdout.writeln('units:        ${faction.units.length}');
  stdout.writeln('weapons:      ${faction.weapons.length}');
  stdout.writeln('abilities:    ${faction.abilities.length}');
  stdout.writeln('compositions: ${faction.compositions.length}');
  if (faction.collisions.isNotEmpty) {
    stdout.writeln('collisions:   ${faction.collisions.length}');
    for (final c in faction.collisions.take(10)) {
      stdout.writeln('   $c');
    }
  }

  if (args.length > 1) {
    final wanted = args[1];
    final unit = faction.units.where((u) => u['id'] == wanted).firstOrNull;
    stdout.writeln('\n${const JsonEncoder.withIndent(' ').convert(unit)}');
  }
}
