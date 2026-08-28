/// Prices, validates and prints the shooting table for a roster file.
///
///     dart run bin/roster.dart <roster.json> [--data <dir>] [--melee]
///
/// A development lens on the core: everything the builder and the shooting
/// section will show, rendered as text.
library;

import 'dart:convert';
import 'dart:io';

import 'package:wh40k_core/wh40k_core.dart';

import 'paths.dart';

void main(List<String> args) {
  var dataDir = '$dataRoot/40kdc';
  var kind = WeaponKind.ranged;
  var correctionsPath = '$projectRoot/data-corrections.yaml';
  String? rosterPath;
  String? snapshotOut;

  for (var i = 0; i < args.length; i++) {
    final arg = args[i];
    if (arg == '--data' && i + 1 < args.length) {
      dataDir = args[++i];
    } else if (arg == '--melee') {
      kind = WeaponKind.melee;
    } else if (arg == '--snapshot' && i + 1 < args.length) {
      snapshotOut = args[++i];
    } else if (arg == '--corrections' && i + 1 < args.length) {
      correctionsPath = args[++i];
    } else if (arg == '-h' || arg == '--help') {
      stdout.writeln(
          'usage: dart run bin/roster.dart <roster.json> [--data <dir>] '
          '[--melee] [--snapshot <out.json>]');
      return;
    } else {
      rosterPath = arg;
    }
  }

  if (rosterPath == null) {
    stderr.writeln('usage: dart run bin/roster.dart <roster.json>');
    exit(2);
  }

  final file = File(rosterPath);
  if (!file.existsSync()) {
    stderr.writeln('no roster at $rosterPath');
    exit(2);
  }

  final roster = Roster.fromJson(jsonDecode(file.readAsStringSync()));
  final loader = DatasetLoader(
    dataDir,
    corrections: DatasetLoader.correctionsAt(correctionsPath),
  );
  final faction = loader.loadFaction(roster.factionId);
  if (faction.units.isEmpty) {
    stderr.writeln(
        'no data for ${roster.factionId} in $dataDir - run tools/fetch-40kdc.sh');
    exit(2);
  }

  final dataset = Dataset.of(faction, revision: 'local');

  if (snapshotOut != null) {
    final snapshot = SnapshotBuilder.fromLoader(loader, dataset).build(roster);
    final json = const JsonEncoder.withIndent('  ').convert(snapshot.toJson());
    File(snapshotOut).writeAsStringSync(json);
    stdout.writeln('wrote $snapshotOut — ${snapshot.entryCount} entries, '
        '${json.length} bytes');
    return;
  }

  final catalogue = dataset;
  final result = RosterValidator(catalogue).validate(roster);
  final battleSize = BattleSize.byId(roster.battleSizeId);

  stdout
    ..writeln(roster.name)
    ..writeln('=' * 64)
    ..writeln('${roster.factionId} · ${battleSize?.name ?? roster.battleSizeId}'
        ' · ${result.cost.total} pts')
    ..writeln('detachments: '
        '${roster.detachments.map((d) => catalogue.detachment(d.detachmentId)?.name ?? d.detachmentId).join(', ')}')
    ..writeln('disposition: ${roster.declaredDisposition ?? '(undeclared)'}')
    ..writeln();

  stdout.writeln('validation');
  if (result.findings.isEmpty) stdout.writeln('  clean');
  for (final finding in result.findings) {
    stdout.writeln('  [${finding.severity.name.toUpperCase().padRight(5)}] '
        '${finding.message}');
  }

  stdout
    ..writeln()
    ..writeln(kind == WeaponKind.ranged ? 'shooting' : 'fight')
    ..writeln('-' * 64);

  final aggregator = WeaponAggregator(catalogue);

  for (final combatUnit in roster.combatUnits()) {
    final head = combatUnit.first;
    final label = head.customName ?? catalogue.labelFor(combatUnit);

    final cost = result.cost.units
        .where((c) => combatUnit.any((u) => u.instanceId == c.instanceId))
        .fold(0, (sum, c) => sum + c.total);

    final table = aggregator.aggregate(combatUnit, kind: kind);
    if (table.weapons.isEmpty && table.isComplete) continue;

    stdout.writeln('$label  ($cost pts)');
    final width = table.weapons.fold<int>(
        0, (w, row) => row.displayName.length > w ? row.displayName.length : w);
    for (final w in table.weapons) {
      stdout.writeln('   ${w.weaponCount.toString().padLeft(2)}× '
          '${w.displayName.padRight(width)}  '
          '${w.attacks.display.padLeft(5)} atk  '
          '${(w.skill ?? 'auto').padLeft(4)}  '
          'S${w.profile.stats['S'] ?? '-'} '
          'AP${w.profile.stats['AP'] ?? '-'} '
          'D${w.profile.stats['D'] ?? '-'}'
          '${w.keywords.isEmpty ? '' : '  [${w.keywords.map((k) => k.label).join(', ')}]'}');
    }
    for (final u in table.unresolved) {
      stdout.writeln('   !! unresolved wargear: ${u.itemId}');
    }
    stdout.writeln();
  }
}
