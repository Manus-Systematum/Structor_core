/// Builds sample armies for every faction and checks what the builder makes
/// of them (DESIGN.md §3.34).
///
///     dart run bin/sample_lists.dart [faction ...] [--data <dir>] [--json out]
///
/// **A test suite asks whether a known list still works. This asks whether an
/// unknown one does.** The reference army is one 2,000 point T'au list, and it
/// is the only army either suite prices end to end — so a faction whose
/// datasheets cannot be assembled at all reads as green. Every regression
/// found in the dataset so far arrived that way: a datasheet with no price, a
/// composition that will not resolve, a detachment whose enhancements no
/// character in the faction can carry.
///
/// Two passes, because they fail differently:
///
///   **every datasheet, alone** — added to a blank army at its own default
///   size. What this catches is a record the builder cannot make a unit out
///   of: no price, no bracket for its own model count, wargear over its own
///   cap. 1,800-odd of them, and none of it depends on choosing a good list.
///
///   **a few whole armies per faction** — one per detachment, up to three,
///   filled towards the points limit the way a person fills one: battleline
///   first, then whatever fits. What this catches is everything that only
///   appears in combination — enhancement slots, Epic Hero duplicates, the
///   detachment budget, allies admitted or not.
///
/// Findings are structural only. A list being under its points limit is not a
/// finding: these are assembled by a greedy loop, not by a player.
library;

import 'dart:convert';
import 'dart:io';

import 'package:wh40k_core/wh40k_core.dart';

import 'paths.dart';

/// Codes that say something about *this* generated list rather than about the
/// data — a greedy fill stops short of 2,000 and takes no enhancements, and
/// neither is a defect in the dataset.
const _ofTheSample = {
  'points.under',
  'slots.unused',
  'detachment.under-budget',
  'warlord.missing',
};

class Finding {
  final String faction;
  final String subject;
  final String code;
  final String message;

  const Finding(this.faction, this.subject, this.code, this.message);

  Map<String, Object?> toJson() => {
        'faction': faction,
        'subject': subject,
        'code': code,
        'message': message,
      };

  @override
  String toString() => '${faction.padRight(22)} ${subject.padRight(38)} '
      '$code — $message';
}

void main(List<String> args) {
  var dataDir = '$dataRoot/merged';
  var correctionsPath = '$projectRoot/data-corrections.yaml';
  String? jsonOut;
  final wanted = <String>[];

  for (var i = 0; i < args.length; i++) {
    switch (args[i]) {
      case '--data':
        if (i + 1 < args.length) dataDir = args[++i];
      case '--corrections':
        if (i + 1 < args.length) correctionsPath = args[++i];
      case '--json':
        if (i + 1 < args.length) jsonOut = args[++i];
      case '-h':
      case '--help':
        stdout.writeln('usage: dart run bin/sample_lists.dart '
            '[faction ...] [--data <dir>] [--json out]');
        return;
      default:
        if (!args[i].startsWith('-')) wanted.add(args[i]);
    }
  }

  final loader = DatasetLoader(dataDir,
      corrections: DatasetLoader.correctionsAt(correctionsPath));
  if (!loader.root.existsSync()) {
    stderr.writeln('no dataset at $dataDir — run tools/rebuild-assets.sh');
    exit(2);
  }

  final factions = wanted.isNotEmpty ? wanted : loader.availableFactions();
  final findings = <Finding>[];
  // A chapter fields its parent's datasheets (§3.10), so `attack-bike-squad`
  // is reached through seven factions and is one datasheet with one problem.
  // Reported once, with the factions that carry it counted.
  final perDatasheet = <String, ({Finding finding, Set<String> factions})>{};
  var datasheets = 0;
  var armies = 0;
  var armyUnits = 0;

  for (final factionId in factions) {
    final catalogue = MapCatalogue.ofFaction(loader.loadFaction(factionId));
    final editor = RosterEditor(catalogue);
    final validator = RosterValidator(catalogue);

    // ---------------------------------------------------- every datasheet
    for (final unit in catalogue.allUnits) {
      if (!unit.isMatchedPlay) continue;
      datasheets++;
      final roster = editor.addUnit(
        RosterEditor.blank(name: 'one of each', factionId: factionId),
        unit.id,
      );
      void report(String code, String message) {
        final key = '${unit.id}|$code|$message';
        final seen = perDatasheet[key];
        if (seen == null) {
          perDatasheet[key] = (
            finding: Finding(factionId, unit.id, code, message),
            factions: {factionId},
          );
        } else {
          seen.factions.add(factionId);
        }
      }

      if (roster.units.isEmpty) {
        report('unit.not-addable',
            'the builder produced no unit for this datasheet');
        continue;
      }
      final result = validator.validate(roster);
      for (final cost in result.cost.unpriced) {
        report('points.unpriced',
            'priced as ${cost.problem?.name} at ${roster.units.single.models} '
            'models');
      }
      for (final finding in result.errors) {
        // A single datasheet in an empty army has no detachment and may be an
        // ally of its own bundle; neither says anything about the datasheet.
        if (_ofTheSample.contains(finding.code)) continue;
        if (finding.code.startsWith('ally.')) continue;
        if (finding.code == 'detachment.none') continue;
        if (finding.code == 'points.unpriced') continue;
        // A datasheet dearer than a Strike Force is not a broken one — the
        // Manta costs 2,100 and belongs in an Onslaught army.
        if (finding.code == 'points.over') continue;
        report(finding.code, finding.message);
      }
    }

    // --------------------------------------------------------- whole armies
    final detachments = catalogue.allDetachments.take(3);
    for (final detachment in detachments) {
      armies++;
      final roster =
          _fill(editor, validator, catalogue, factionId, detachment.id);
      armyUnits += roster.units.length;
      final result = validator.validate(roster);
      final subject = '${detachment.id} (${roster.units.length} units, '
          '${result.cost.total} pts)';
      for (final finding in result.errors) {
        if (_ofTheSample.contains(finding.code)) continue;
        findings.add(
            Finding(factionId, subject, finding.code, finding.message));
      }
    }
  }

  for (final entry in perDatasheet.values) {
    final also = entry.factions.length - 1;
    findings.add(Finding(
      also == 0
          ? entry.finding.faction
          : '${entry.finding.faction} +$also',
      entry.finding.subject,
      entry.finding.code,
      entry.finding.message,
    ));
  }
  findings.sort((a, b) => a.toString().compareTo(b.toString()));

  stdout
    ..writeln('$datasheets datasheets added one at a time')
    ..writeln('$armies armies assembled, $armyUnits units between them')
    ..writeln();

  if (findings.isEmpty) {
    stdout.writeln('no structural findings');
  } else {
    stdout.writeln('${findings.length} findings:');
    for (final finding in findings) {
      stdout.writeln('  $finding');
    }
  }

  if (jsonOut != null) {
    File(jsonOut).writeAsStringSync(
        const JsonEncoder.withIndent(' ').convert({
      'datasheets': datasheets,
      'armies': armies,
      'findings': [for (final f in findings) f.toJson()],
    }));
    stdout.writeln('\nwritten to $jsonOut');
  }

  exit(findings.isEmpty ? 0 : 1);
}

/// One army, filled the way a person fills one: battleline first, then
/// whatever still fits, stopping at the points limit or when nothing does.
Roster _fill(
  RosterEditor editor,
  RosterValidator validator,
  Catalogue catalogue,
  String factionId,
  String detachmentId,
) {
  final size = BattleSize.strikeForce;
  var roster = editor.addDetachment(
    RosterEditor.blank(name: 'sample', factionId: factionId),
    detachmentId,
  );

  // Deterministic, so a finding can be reproduced by running it again: the
  // order is the catalogue's own, with battleline brought forward.
  // **Mono-faction, deliberately.** A greedy loop that takes allies puts 530
  // points of Corsairs in a Drukhari army and the whole Astra Militarum
  // catalogue in a Cult one, and the ally rules are neither what a sample
  // list is for nor short of coverage of their own (§4.18). Trimming cannot
  // undo it either: an over-the-ally-cap finding names no single unit to
  // blame, because no single unit is to blame.
  final candidates = [
    for (final unit in catalogue.allUnits)
      if (unit.isMatchedPlay &&
          !unit.isLegend &&
          !AllyRules.isAlly(unit, catalogue.factionKeywords))
        unit,
  ]..sort((a, b) {
      final battleline = (b.hasDoubledCap ? 1 : 0) - (a.hasDoubledCap ? 1 : 0);
      return battleline != 0 ? battleline : a.id.compareTo(b.id);
    });

  final calculator = PointsCalculator(catalogue);
  for (final unit in candidates) {
    if (calculator.price(roster).total >= size.points) break;
    final attempt = editor.addUnit(roster, unit.id);
    if (attempt.units.length == roster.units.length) continue;
    final cost = calculator.price(attempt);
    // An over-budget or unpriceable addition is put back rather than left in:
    // the point is a legal army, so that what is reported is the data and not
    // the greed of this loop.
    if (cost.total > size.points || !cost.isComplete) continue;
    roster = attempt;
  }

  // A Warlord is required, and choosing one is not optional for the army to
  // be legal — so the first Character takes it.
  for (final unit in roster.units) {
    if (catalogue.unit(unit.datasheetId)?.isCharacter ?? false) {
      roster = editor.setWarlord(roster, unit.instanceId);
      break;
    }
  }

  // **Then take out whatever makes it illegal, which is what a person does.**
  // Adding blindly puts 530 points of Corsairs in a Drukhari army and 24
  // Astra Militarum datasheets in a Cult one without the detachment that
  // admits them — the loop's greed, not the data's shape, and reported as a
  // finding it drowns everything worth reading. Removing the units a finding
  // names converges in a handful of rounds; what survives it is structural.
  for (var round = 0; round < 12; round++) {
    final blamed = <String>{
      for (final finding in validator.validate(roster).errors)
        if (!_ofTheSample.contains(finding.code)) ...finding.instanceIds,
    };
    if (blamed.isEmpty) break;
    for (final instanceId in blamed) {
      roster = editor.removeUnit(roster, instanceId);
    }
  }
  return roster;
}
