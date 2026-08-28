/// Builds data/merged from data/bsdata over data/40kdc (DESIGN.md §3.10).
///
/// Everything downstream — the bundler, the coverage report, the snapshot
/// writer — reads a 40kdc-shaped tree. This writes one, so the source swap is
/// a change of input directory rather than a rewrite of every consumer.
///
///   dart run bin/merge.dart                 # every faction
///   dart run bin/merge.dart tau-empire      # one
///   dart run bin/merge.dart --report        # conflicts only, write nothing
library;

import 'dart:convert';
import 'dart:io';

import 'package:wh40k_core/src/source/bsdata/bs_document.dart';
import 'package:wh40k_core/src/source/bsdata/bs_mapper.dart';
import 'package:wh40k_core/src/source/bsdata/bs_merge.dart';
import 'package:wh40k_core/src/source/bsdata/bs_slug.dart';
import 'package:wh40k_core/src/import/name_match.dart';
import 'package:wh40k_core/src/source/json.dart';

import 'paths.dart';

// The dataset is in the Structor repository, not this one; `paths.dart` says
// how it is found. Not `const` any more, because where it is is now a
// question answered at run time rather than by this file's own depth.
final _root = projectRoot;
final _bsRoot = '$dataRoot/bsdata';
final _dcRoot = '$dataRoot/40kdc';
final _outRoot = '$dataRoot/merged';
final _conflictsPath = '$_root/data-conflicts.json';

/// Which factions the merged tree already holds merged output for.
///
/// Without this a partial run is destructive: [_copyRemaining] copies raw
/// 40kdc over everything it did not rewrite *this run*, so
/// `merge.dart tau-empire` silently reverted every other faction's abilities
/// to the un-enriched source — 2,723 Space Marine rules lost their printed
/// text because somebody merged a different faction. The tree is derived and
/// gitignored, so nothing caught it; the app only stayed correct because
/// `tools/rebuild-assets.sh` always merges everything.
final _manifestPath = '$_outRoot/.merged.json';

/// Mission card text, fetched by `tools/fetch-gdm.py` (DESIGN.md §3.11).
final _gdmPath = '$dataRoot/gdm/cards.json';

/// Stratagem text, fetched by `tools/fetch-stratagem-text.py` (§3.12).
final _wahapediaPath = '$dataRoot/stratagem-text/wahapedia-stratagems.csv';
final _coreStratagemPath = '$dataRoot/stratagem-text/core-stratagems.json';

/// Enhancements whose printed wording could not be found by name, with
/// suggestions — and the hand-made matches for them.
///
/// **Both a worklist and the answer sheet.** Entries with `ability_id` filled
/// in are applied by the merge and preserved verbatim on the next run; the
/// rest are regenerated. That way a hand-made match is made once and survives
/// every rebuild, which a purely generated report would not.
final _manualPath = '$_root/data-enhancement-text.json';

/// Which BSData-derived list replaces which 40kdc file, and which fields of it
/// are worth diffing when both sources state one.
const _files = {
  'units': (
    path: 'core/%s/units.json',
    idField: 'id',
    compare: {'name', 'points', 'is_legend'},
    fillOnly: false,
  ),
  // Fill-only, and this one is a reversal. BSData declares a weapon entry on
  // every datasheet that can reach the gun, but for T'au almost all of them
  // are BS5+ — the BS3+/BS4+ distinction between a Commander's missile pod,
  // a Crisis suit's and a drone's exists **only in 40kdc**, which curates
  // carrier-scoped records for exactly that. Letting BSData win replaced
  // richer data with poorer and cost the reference list 60 points.
  'weapons': (
    path: 'core/%s/weapons.json',
    idField: 'id',
    compare: {'name', 'type', 'profiles'},
    fillOnly: true,
  ),
  // Fill-only. A 40kdc composition carries `default_weapon_ids` and
  // `base_size_mm`, and BSData has neither — so letting its record win
  // replaced a datasheet's starting loadout with nothing, and every new unit
  // arrived on the builder's table unarmed.
  'compositions': (
    path: 'core/%s/unit-compositions.json',
    idField: 'unit_id',
    compare: <String>{},
    fillOnly: true,
  ),
  'abilities': (
    path: 'enrichment/%s/abilities.json',
    idField: 'ability_id',
    compare: {'name'},
    fillOnly: false,
  ),
};

void main(List<String> args) {
  final reportOnly = args.contains('--report');
  final wanted = args.where((a) => !a.startsWith('--')).toList();

  final factions = wanted.isNotEmpty
      ? wanted
      : (Directory(_bsRoot).listSync().whereType<Directory>().toList()
            ..sort((a, b) => a.path.compareTo(b.path)))
          .map((d) => d.path.split('/').last)
          .where((n) => n != 'shared')
          .toList();

  final allConflicts = <Map<String, Object?>>[];

  /// Ability ids harvested from each faction's shared groups — detachment
  /// rules and enhancements — used below to give an enhancement its wording.
  final harvested = <String, Set<String>>{};
  var totalUnits = 0;
  var totalAdded = 0;

  for (final factionId in factions) {
    final index = BsIndex();
    final shared = Directory('$_bsRoot/shared');
    if (shared.existsSync()) {
      for (final f in shared.listSync().whereType<File>()) {
        if (f.path.endsWith('.json')) index.add(f, asRoot: false);
      }
    }
    final dir = Directory('$_bsRoot/$factionId');
    if (!dir.existsSync()) continue;
    for (final f in dir.listSync().whereType<File>()) {
      if (f.path.endsWith('.json')) index.add(f);
    }

    // Catalogues borrow from one another. `Aeldari - Drukhari.json` holds no
    // entries at all — its datasheets are entry links into the Aeldari
    // library, which is filed under a different faction. Without the other
    // factions' files in the index those links resolve to nothing, and
    // Drukhari came through with zero BSData datasheets.
    //
    // Added as targets, never as roots: the Aeldari library holds Craftworlds'
    // datasheets too, and Drukhari fields the ones it links to, not all of
    // them.
    for (final other in Directory(_bsRoot).listSync().whereType<Directory>()) {
      if (other.path.endsWith('/$factionId')) continue;
      for (final f in other.listSync().whereType<File>()) {
        if (f.path.endsWith('.json')) index.add(f, asRoot: false);
      }
    }
    index.resolveRootLinks();

    // 40kdc's weapons decide which variant of a repeated weapon keeps the
    // plain id, so they are read before the mapping rather than at merge time.
    final mapped = BsMapper(index).faction(
      factionId,
      anchors: _readArray('$_dcRoot/core/$factionId/weapons.json'),
    );
    final produced = {
      'units': mapped.units,
      'weapons': mapped.weapons,
      'compositions': mapped.compositions,
      'abilities': mapped.abilities,
    };

    var added = 0;
    for (final entry in _files.entries) {
      final spec = entry.value;
      final relative = spec.path.replaceFirst('%s', factionId);
      final existing = _readArray('$_dcRoot/$relative');

      final result = mergeRecords(
        faction: factionId,
        kind: entry.key,
        idField: spec.idField,
        bsdata: produced[entry.key]!,
        fortykdc: existing,
        compare: spec.compare,
        fillOnly: spec.fillOnly,
        keepFrom40kdc: entry.key == 'units' ? const {'weapon_ids'} : const {},
        union: entry.key == 'units' ? const {'wargear_budgets'} : const {},
      );

      allConflicts.addAll([for (final c in result.conflicts) c.toJson()]);
      if (entry.key == 'units') {
        totalUnits += result.records.length;
        added = result.addedByBsdata.length;
        totalAdded += added;
      }

      if (!reportOnly) _write('$_outRoot/$relative', result.records);
    }

    // An enhancement's wording, now that there is some. 40kdc leaves
    // `ability_id` null on most of them, so the record naming the rule and the
    // record holding its text were never connected — the app could show an
    // enhancement's name and cost and nothing about what it does.
    if (!reportOnly) {
      final enhPath = 'core/$factionId/enhancements.json';
      final abilityIds = {
        for (final raw in produced['abilities']!)
          if (str(asMap(raw)['ability_id']) case final id?) id,
      };
      final enhancements = _readArray('$_outRoot/$enhPath');
      var linked = 0;
      final updated = [
        for (final raw in enhancements)
          if (asMap(raw) case final record)
            if (str(record['ability_id']) == null &&
                abilityIds.contains(bsSlug(strOr(record['name'], ''))))
              () {
                linked++;
                return {
                  ...record,
                  'ability_id': bsSlug(strOr(record['name'], '')),
                };
              }()
            else
              record,
      ];
      if (linked > 0) _write('$_outRoot/$enhPath', updated);
    }

    harvested[factionId] = {
      for (final raw in mapped.abilities)
        if (str(raw['ability_id']) case final abilityId?) abilityId,
    };

    for (final collision in mapped.collisions) {
      stderr.writeln('  COLLISION $factionId: $collision');
    }
    stdout.writeln('  $factionId: ${mapped.units.length} BSData datasheets, '
        '$added new');
  }

  if (!reportOnly) {
    _copyRemaining(factions, _mergedBefore());
    _writeManifest(factions);
    stdout.writeln('\n${_linkEnhancementText(factions, harvested)} '
        'enhancements linked to their printed text');
    stdout.writeln('${_applyMissionText()} mission cards given their '
        'printed text');
    stdout.writeln('${_applyStratagemText(factions)} stratagems given their '
        'printed text');
    stdout.writeln('${_applyKeywordText()} weapon keywords given their '
        'printed text');
    File(_conflictsPath)
        .writeAsStringSync('${const JsonEncoder.withIndent('  ').convert({
          'note': 'BSData over 40kdc; BSData wins every row here. '
              'DESIGN.md §3.10.',
          'conflicts': allConflicts,
        })}\n');
  }

  stdout.writeln('\n$totalUnits datasheets, $totalAdded added by BSData');
  stdout.writeln('${allConflicts.length} conflicts'
      '${reportOnly ? '' : ' -> ${_conflictsPath.replaceFirst('$_root/', '')}'}');
}

/// Gives each enhancement the id of the ability holding its printed wording.
///
/// 40kdc leaves `ability_id` null on most enhancements, so the record naming
/// the rule and the record holding its text were never connected — the app
/// could show an enhancement's name and its cost and nothing about what it
/// does. BSData publishes the wording, and the two meet at the slug.
///
/// Runs **after** `_copyRemaining`, which is what puts the enhancements file
/// in the merged tree at all; doing it inside the per-faction loop read
/// whatever a previous build had left there.
int _linkEnhancementText(
    List<String> factions, Map<String, Set<String>> harvested) {
  final manual = _handMadeMatches();
  final unmatched = <Map<String, Object?>>[];
  var total = 0;
  for (final factionId in factions) {
    final path = '$_outRoot/core/$factionId/enhancements.json';

    // A chapter's enhancements are the parent's, and only the parent's
    // catalogue was harvested — Blood Angels linked 1 of 83 without this.
    final parentId = _parentOf(factionId);
    final ids = {
      ...?harvested[factionId],
      ...?harvested[parentId],
    };
    if (ids.isEmpty) continue;

    final records = _readArray(path);
    if (records.isEmpty) continue;

    // An enhancement already pointing at an ability is not necessarily
    // pointing at one with any text: 40kdc names the rule and publishes no
    // wording for it, which is the whole gap being closed here.
    final described = _describedAbilities(factionId, parentId);
    final named = _namedAbilities(factionId, parentId);

    var linked = 0;
    final updated = [
      for (final raw in records)
        if (asMap(raw) case final record)
          if (manual['$factionId/${str(record['id'])}'] ??
                  _textIdFor(record, ids, described, named)
              case final id?)
            () {
              linked++;
              return {...record, 'ability_id': id};
            }()
          else
            record,
    ];
    if (linked > 0) {
      _write(path, updated);
      total += linked;
    }

    for (final raw in updated) {
      final record = asMap(raw);
      final id = str(record['ability_id']);
      if (id != null && described.contains(id)) continue;
      if (manual.containsKey('$factionId/${str(record['id'])}')) continue;
      unmatched.add(_worklistEntry(factionId, parentId, record));
    }
  }

  _writeWorklist(manual, unmatched);
  return total;
}

/// Matches a person filled in, keyed `faction/enhancement-id`.
Map<String, String> _handMadeMatches() {
  final file = File(_manualPath);
  if (!file.existsSync()) return {};
  final decoded = asMap(jsonDecode(file.readAsStringSync()));
  final out = <String, String>{};
  for (final raw in asList(decoded['unmatched'])) {
    final entry = asMap(raw);
    final abilityId = str(entry['ability_id']);
    if (abilityId == null || abilityId.isEmpty) continue;
    final faction = str(entry['faction']);
    final id = str(entry['id']);
    if (faction != null && id != null) out['$faction/$id'] = abilityId;
  }
  return out;
}

/// One row of the worklist: the enhancement, and the likeliest abilities.
///
/// Suggestions are scored by name against every ability in the faction that
/// actually has text, because a match with nothing to say is not a match. Only
/// the first line of each is shown — enough to recognise the rule without
/// making the file unreadable.
Map<String, Object?> _worklistEntry(
    String factionId, String? parentId, Map<String, dynamic> record) {
  final name = strOr(record['name'], '');
  final candidates = <({String id, String name, String text})>[];
  for (final source in [factionId, if (parentId != null) parentId]) {
    for (final raw
        in _readArray('$_outRoot/enrichment/$source/abilities.json')) {
      final ability = asMap(raw);
      final text = str(ability['description']);
      final id = str(ability['ability_id']);
      if (text == null || text.trim().isEmpty || id == null) continue;
      candidates.add((id: id, name: strOr(ability['name'], id), text: text));
    }
  }

  final scored = [
    for (final candidate in candidates)
      (candidate: candidate, score: _similarity(name, candidate.name)),
  ]..sort((a, b) => b.score.compareTo(a.score));

  return {
    'faction': factionId,
    'id': str(record['id']),
    'name': name,
    'detachment': str(record['detachment_id']),
    'cost': asInt(record['cost']),
    // Fill this in to match by hand. It is read back on the next merge and
    // this entry is then kept verbatim rather than regenerated.
    'ability_id': null,
    'suggestions': [
      for (final entry in scored.take(3))
        {
          'ability_id': entry.candidate.id,
          'name': entry.candidate.name,
          'score': double.parse(entry.score.toStringAsFixed(2)),
          'text': _firstLine(entry.candidate.text),
        },
    ],
  };
}

/// How alike two rule names are, as an overlap of their words.
///
/// Not `scoreName`, which is tuned for choosing among a *scoped* candidate
/// list — the profiles of one datasheet — and rewards a short candidate. Asked
/// to rank one enhancement against every ability in a faction it put `leader`
/// above `master-of-the-machine-war` for "Master of Machine War".
///
/// This measures both directions at once, so an inserted "the" costs a little
/// and an unrelated short name scores nothing.
double _similarity(String a, String b) {
  final mine = _words(a);
  final theirs = _words(b);
  if (mine.isEmpty || theirs.isEmpty) return 0;
  final shared = mine.intersection(theirs).length;
  if (shared == 0) return 0;
  final precision = shared / mine.length;
  final recall = shared / theirs.length;
  return 2 * precision * recall / (precision + recall);
}

/// Words worth comparing: normalised, singularised, and without the joining
/// words every third rule name contains.
const _stopWords = {'of', 'the', 'a', 'and', 'to', 'in'};

Set<String> _words(String value) => {
      for (final token in tokens(value))
        if (!_stopWords.contains(token))
          token.endsWith('s') && token.length > 3
              ? token.substring(0, token.length - 1)
              : token,
    };

String _firstLine(String text) {
  final line = text.split('\n').first.trim();
  return line.length <= 160 ? line : '${line.substring(0, 157)}…';
}

void _writeWorklist(
    Map<String, String> manual, List<Map<String, Object?>> unmatched) {
  // A hand-made match is kept exactly as written, including any note beside
  // it — regenerating over someone's work is how a file like this stops being
  // trusted.
  final existing = File(_manualPath).existsSync()
      ? asList(
          asMap(jsonDecode(File(_manualPath).readAsStringSync()))['unmatched'])
      : const <Object?>[];
  final kept = [
    for (final raw in existing)
      if (str(asMap(raw)['ability_id'])?.isNotEmpty ?? false) asMap(raw),
  ];

  final rows = [...kept, ...unmatched]..sort((a, b) {
      final byFaction =
          strOr(a['faction'], '').compareTo(strOr(b['faction'], ''));
      return byFaction != 0
          ? byFaction
          : strOr(a['name'], '').compareTo(strOr(b['name'], ''));
    });

  File(_manualPath)
      .writeAsStringSync('${const JsonEncoder.withIndent('  ').convert({
        'note': 'Enhancements whose printed wording could not be found by '
            'name. Fill in `ability_id` from `suggestions` — or with any '
            'other id from the faction\'s abilities — and the next merge '
            'applies it and keeps the entry as written. Leave it null and '
            'the entry is regenerated. DESIGN.md §3.10.',
        'matched_by_hand': kept.length,
        'still_unmatched': unmatched.length,
        'unmatched': rows,
      })}\n');
}

/// `Hagiomnifex (Upgrade)` and `Fear Made Manifest (Aura)`.
///
/// 40kdc appends what kind of enhancement it is to the name; BSData does not.
/// Slugging the whole string missed 42 of them over a parenthesis.
final _nameSuffix = RegExp(r'\s*\([^)]*\)\s*$');

/// The ability id holding this enhancement's wording, or null.
String? _textIdFor(Map<String, dynamic> record, Set<String> ids,
    Set<String> described, List<({String id, String name})> named) {
  final existing = str(record['ability_id']);
  if (existing != null && described.contains(existing)) return null;

  final name = strOr(record['name'], '');
  for (final candidate in [
    bsSlug(name),
    bsSlug(name.replaceAll(_nameSuffix, '')),
  ]) {
    if (candidate.isNotEmpty && ids.contains(candidate)) return candidate;
  }

  // Same words, different joining: `Master of Machine War` against
  // `master-of-the-machine-war`, `Eye of the Hunter` against
  // `eyes-of-the-hunter`. Once "the" and a plural are set aside these are the
  // same name, which is the rule the aliases already work by (§3.6) — not a
  // guess, and it accounted for a sixth of what was left unmatched.
  final wanted = _words(name.replaceAll(_nameSuffix, ''));
  if (wanted.isEmpty) return null;
  for (final candidate in named) {
    if (_words(candidate.name).difference(wanted).isEmpty &&
        wanted.difference(_words(candidate.name)).isEmpty) {
      return candidate.id;
    }
  }
  return null;
}

/// Abilities carrying text, with their names, for word-set matching.
List<({String id, String name})> _namedAbilities(
    String factionId, String? parentId) {
  final out = <({String id, String name})>[];
  for (final id in [factionId, if (parentId != null) parentId]) {
    for (final raw in _readArray('$_outRoot/enrichment/$id/abilities.json')) {
      final record = asMap(raw);
      final text = str(record['description']);
      if (text == null || text.trim().isEmpty) continue;
      if (str(record['ability_id']) case final abilityId?) {
        out.add((id: abilityId, name: strOr(record['name'], abilityId)));
      }
    }
  }
  return out;
}

/// Ability ids that actually carry text, for this faction and its parent.
Set<String> _describedAbilities(String factionId, String? parentId) {
  final out = <String>{};
  for (final id in [factionId, if (parentId != null) parentId]) {
    for (final raw in _readArray('$_outRoot/enrichment/$id/abilities.json')) {
      final record = asMap(raw);
      final text = str(record['description']);
      if (text == null || text.trim().isEmpty) continue;
      if (str(record['ability_id']) case final abilityId?) out.add(abilityId);
    }
  }
  return out;
}

/// The faction whose datasheets and enhancements this one fields, if any.
String? _parentOf(String factionId) {
  for (final raw in _readArray('$_outRoot/core/$factionId/factions.json')) {
    final record = asMap(raw);
    if (str(record['id']) == factionId) return str(record['parent_faction_id']);
  }
  return null;
}

/// Writes the printed wording onto the mission cards.
///
/// 40kdc publishes each card's *structure* — trigger, VP, condition — and a
/// hand-written paraphrase beside it. The paraphrase reads as a summary
/// because it is one: "central-objective control pays at the end of every one
/// of your turns" against "3 VP: You control one or more central objectives."
/// A player checking whether they scored wants the second (§3.11).
///
/// The structure is untouched. Everything that *does* something — the scoring
/// controls, the round caps, the award triggers — still runs off 40kdc's
/// awards, which agree with this source card for card on every one checked.
/// Only the sentence changes.
int _applyMissionText() {
  final file = File(_gdmPath);
  if (!file.existsSync()) return 0;
  final source = asMap(jsonDecode(file.readAsStringSync()));

  // Primary cards are keyed `deck/card`; the card half is the mission id.
  final byId = <String, Map<String, dynamic>>{};
  for (final entry in asMap(source['primary']).entries) {
    byId[entry.key.split('/').last] = asMap(entry.value);
  }
  for (final entry in asMap(source['secondary']).entries) {
    // `secure-no-man-s-land-defender` -> `secure-no-mans-land`.
    final id = entry.key
        .replaceAll(RegExp(r'-(?:defender|attacker)$'), '')
        .replaceAll('-man-s-', '-mans-');
    byId[id] = asMap(entry.value);
  }

  final path = '$_outRoot/core/secondary-cards.json';
  final records = _readArray(path);
  if (records.isEmpty) return 0;

  var written = 0;
  final updated = [
    for (final raw in records)
      if (asMap(raw) case final record)
        () {
          final card = byId[strOr(record['id'], '')];
          final front = card == null ? '' : _cardText(card);
          final action = _actionText(record);
          final text = [
            if (front.isNotEmpty) front else strOr(record['text'], ''),
            if (action.isNotEmpty) action,
          ].where((part) => part.isNotEmpty).join('\n');
          if (text.isEmpty || text == strOr(record['text'], '')) return record;
          written++;
          return {...record, 'text': text};
        }(),
  ];
  if (written > 0) _write(path, updated);
  return written;
}

/// The card's actions, rendered as the section the printed card puts on its
/// reverse.
///
/// **The front of the card does not contain them.** Secure Asset's own line is
/// "A friendly unit **secured the asset** this turn (see reverse)", and until
/// this existed the reverse was nowhere in the app — neither gdmissions nor
/// 40kdc publishes the printed wording, and gdmissions' payload does not carry
/// it at all (checked, not assumed).
///
/// So the section is **composed from 40kdc's structure**, which is complete
/// enough to say what the action is, when it can be started, how often, and
/// what it is performed on. It is deliberately thinner than the printed card:
/// 40kdc's own prose knows two things its structure does not — that most of
/// these complete only if the unit still controls the objective, and that Booby
/// Trap completes immediately — and neither is derivable here. §3.13.
String _actionText(Map<String, dynamic> record) {
  final lines = <String>[];
  for (final raw in asList(record['actions'])) {
    final action = asMap(raw);
    final name = _titleCase(strOr(action['action_id'], ''));
    if (name.isEmpty) continue;

    final completes = asMap(asMap(action['completes'])['parameters']);
    final kind = str(completes['target_kind']);
    // Only the objective form is confirmed against a printed card — the user
    // reported this feature as "Secure Asset: Objective Action". The others
    // are left unqualified rather than given a label by analogy.
    final label = kind == 'objective' ? '$name: Objective Action' : name;
    lines.add('ACTION · $label');

    // Labelled lines, because the rest of the card reads that way — "4 VP:
    // You control three or more objectives" — and an action is the same kind
    // of thing: a condition with a payout attached elsewhere.
    final when = <String>[];
    if (str(action['starts']) case final phase? when phase.isNotEmpty) {
      when.add('your ${_titleCase(phase)} phase');
    } else if (str(action['timing']) case final timing?
        when timing.isNotEmpty) {
      when.add(_timing(timing));
    }
    final round = asInt(asMap(action['battle_round'])['min']);
    if (round != null) when.add('from battle round $round');
    final limit = _limit(action);
    if (limit.isNotEmpty) when.add(limit);
    if (when.isNotEmpty) lines.add('When: ${when.join(', ')}.');

    final who = _performer(asMap(action['units']));
    if (who.isNotEmpty) lines.add('Who: $who.');

    if (kind != null) {
      lines.add('Completes: on '
          '${_target(kind, asMap(completes['target_filter']))}, this turn.');
    }

    // Both occurrences are Sensor Sweep, and 40kdc's own prose for those two
    // cards says what the shape means: "cannot start while only one operation
    // marker remains on the battlefield". Any other shape is left unrendered
    // rather than guessed at; a test asserts none exists.
    final restrictions = asMap(action['restrictions']);
    if (strOr(restrictions['type'], '') == 'operation-markers') {
      lines.add('Limit: cannot be started while only one of your '
          '**operation markers** remains on the battlefield.');
    }

    final effect = _effect(asMap(action['effect']));
    if (effect.isNotEmpty) lines.add(effect);
  }
  return lines.join('\n');
}

String _limit(Map<String, dynamic> action) {
  final limit = asInt(action['use_limit']);
  if (limit == null) return '';
  final perGame = strOr(action['use_limit_scope'], '') == 'per-game';
  final scope = perGame ? 'per battle' : 'per turn';
  return limit == 1 ? 'once $scope' : 'up to $limit times $scope';
}

String _timing(String timing) => switch (timing) {
      'start-of-turn' => 'the start of your turn',
      'end-of-turn' => 'the end of your turn',
      'start-of-battle' => 'the start of the battle',
      _ => timing.replaceAll('-', ' '),
    };

String _performer(Map<String, dynamic> units) {
  if (strOr(units['type'], '') != 'within-range-of-objective') return '';
  final role = str(asMap(units['parameters'])['objective_role']);
  return role == null
      ? 'a unit within range of an **objective**'
      : 'a unit within range of a **$role objective**';
}

String _target(String kind, Map<String, dynamic> filter) {
  final noun = switch (kind) {
    'objective' => 'one or more **objectives**',
    'terrain' => 'one or more **terrain areas**',
    'enemy-unit' => 'one or more enemy units',
    _ => kind.replaceAll('-', ' '),
  };
  final role = str(filter['objective_role']);
  final qualifier = strOr(filter['exclude'], '') == 'home'
      ? ', excluding your **home objective**'
      : role != null
          ? ' (**$role** only)'
          : filter['in_enemy_territory'] == true
              ? " in your opponent's territory"
              : '';
  return '$noun$qualifier';
}

String _effect(Map<String, dynamic> effect) {
  final subject = switch (strOr(effect['type'], '')) {
    'unit-tag' => 'the unit',
    'objective-tag' => 'that **objective**',
    'terrain-area-tag' => 'that **terrain area**',
    _ => '',
  };
  if (subject.isEmpty) return '';
  final modifier = asMap(effect['modifier']);
  final tag = strOr(modifier['tag'], '');
  if (tag.isEmpty) return '';
  final until = switch (strOr(modifier['clears_on'], '')) {
    'never' => ' for the rest of the battle',
    'turn-rollover' => ' until the start of your next turn',
    _ => '',
  };
  return 'Effect: marks $subject as **$tag**$until.';
}

String _titleCase(String slug) => slug
    .split(RegExp(r'[-_\s]+'))
    .where((word) => word.isNotEmpty)
    .map((word) => word[0].toUpperCase() + word.substring(1))
    .join(' ');

/// One card's sections, rendered as the lines a player reads.
///
/// The VP label follows the source's own rule: a leading `+` when the tier is
/// cumulative with the one above, `each` when it pays per object, and the cap
/// where there is one. Getting that wrong turns "+2 VP each" into "2 VP",
/// which is a different card.
String _cardText(Map<String, dynamic> card) {
  final lines = <String>[];

  final drawn = _plain(str(card['whenDrawn']));
  if (drawn != null) lines.add(drawn);

  for (final rawSection in asList(card['sections'])) {
    final section = asMap(rawSection);
    final when = _plain(str(section['when']));
    final trigger = _plain(str(section['trigger']));
    final header = [
      if (when != null) when,
      if (trigger != null) trigger,
    ].join(' · ');
    if (header.isNotEmpty) lines.add(header);

    // `tiers` on a primary card, `rows` on a secondary; same shape.
    for (final rawRow in [
      ...asList(section['tiers']),
      ...asList(section['rows']),
    ]) {
      final row = asMap(rawRow);
      final text = _plain(str(row['text']));
      if (text == null) continue;
      final label = _vpLabel(row, asMap(section));
      lines.add(label.isEmpty ? text : '$label: $text');
    }
  }
  return lines.join('\n');
}

String _vpLabel(Map<String, dynamic> row, Map<String, dynamic> section) {
  final dual = asMap(row['dual']);
  if (dual.isNotEmpty) {
    return 'Fixed ${strOr(dual['fixed'], '?')} VP / '
        'Tactical ${strOr(dual['tactical'], '?')} VP';
  }
  final vp = str(row['vp']);
  if (vp == null || vp.isEmpty) return '';
  // A cumulative tier is marked with a leading `+` — unless the source has
  // already written one. Two cards do (`assassination`, `defend-stronghold`),
  // and they were rendering as `++1 VP each`.
  final buffer = StringBuffer()
    ..write(row['cumulative'] == true && !vp.startsWith('+') ? '+' : '')
    ..write(vp)
    ..write(' VP')
    ..write(
        row['perUnit'] == true || section['perEvent'] == true ? ' each' : '');
  if (str(row['cap']) case final cap? when cap.isNotEmpty) {
    buffer.write(', max $cap VP');
  }
  return buffer.toString();
}

/// Source text, with its markup brought to the one convention the app renders.
///
/// The primary cards mark keywords `**like this**` — already what
/// `normaliseRuleText` expects — and the secondary cards use `<b>` tags for
/// the same job. `\$undefined` is the payload's way of writing "no value" and
/// is not text at all.
String? _plain(String? value) {
  if (value == null || value.isEmpty || value == r'$undefined') return null;
  final text = value
      .replaceAll(RegExp(r'</?b>', caseSensitive: false), '**')
      .replaceAll(RegExp(r'</?[a-zA-Z][^>]*>'), '')
      .trim();
  return text.isEmpty ? null : text;
}

/// Copies every 40kdc file the merge did not rewrite.
///
/// Missions, terrain, stratagems, detachments, dispositions, phase mappings,
/// leader attachments, wargear options — BSData has none of them, and the
/// merged tree has to be complete or nothing downstream can read it.
/// Every faction BSData publishes a directory for.
List<String> _factionDirs() {
  final root = Directory(_bsRoot);
  if (!root.existsSync()) return const [];
  return root
      .listSync()
      .whereType<Directory>()
      .map((d) => d.path.split('/').last)
      .where((n) => n != 'shared')
      .toList();
}

/// Factions a previous run already merged, from the manifest.
Set<String> _mergedBefore() {
  final file = File(_manifestPath);
  if (!file.existsSync()) return const {};
  try {
    final j = jsonDecode(file.readAsStringSync());
    if (j is! Map) return const {};
    return {for (final f in (j['factions'] as List? ?? const [])) '$f'};
  } on FormatException {
    return const {};
  }
}

void _writeManifest(List<String> factions) {
  final all = {..._mergedBefore(), ...factions}.toList()..sort();
  File(_manifestPath)
    ..parent.createSync(recursive: true)
    ..writeAsStringSync('${const JsonEncoder.withIndent('  ').convert({
          'note': 'Factions this tree holds merged output for. A partial merge '
              'must not copy raw 40kdc over these. Delete to force a full '
              'rebuild.',
          'factions': all,
        })}\n');
}

/// Fills the tree with the 40kdc files this run did not produce.
///
/// [alreadyMerged] is left alone: those files are a previous run's output and
/// copying the raw source over them is what made partial merges destructive.
void _copyRemaining(List<String> factions, Set<String> alreadyMerged) {
  final source = Directory(_dcRoot);
  // Every path the merge is capable of producing, for any faction. A file
  // at one of these paths that already exists is a previous run's output and
  // is left alone; the manifest records who they belong to but the guard does
  // not depend on it, so a tree merged before the manifest existed is still
  // protected.
  final mergeable = <String>{
    for (final faction in {...factions, ...alreadyMerged, ..._factionDirs()})
      for (final spec in _files.values) spec.path.replaceFirst('%s', faction),
  };

  for (final entity in source.listSync(recursive: true)) {
    if (entity is! File || !entity.path.endsWith('.json')) continue;
    final relative = entity.path.substring(source.path.length + 1);
    // Merged output, either from this run or a previous one, is never
    // overwritten by the raw source. A manifest entry with no file behind it
    // falls through and is copied, so a half-deleted tree still fills in.
    if (mergeable.contains(relative) &&
        File('$_outRoot/$relative').existsSync()) {
      continue;
    }
    final target = File('$_outRoot/$relative');
    target.parent.createSync(recursive: true);
    entity.copySync(target.path);
  }
}

List<Object?> _readArray(String path) {
  final file = File(path);
  if (!file.existsSync()) return const [];
  final decoded = jsonDecode(file.readAsStringSync());
  return decoded is List ? decoded : const [];
}

void _write(String path, List<Object?> records) {
  final file = File(path);
  file.parent.createSync(recursive: true);
  file.writeAsStringSync(
      '${const JsonEncoder.withIndent('  ').convert(records)}\n');
}

/// Writes the printed wording onto the stratagems.
///
/// This was the last surface showing a name and a cost and nothing about what
/// the thing does: 2,236 stratagems, none with text, and only 263 rendering
/// even a derived sentence from a linked ability (§3.12).
///
/// Two sources, and the fuller one wins per stratagem. Wahapedia has all of
/// them; Games Workshop's own free Core Rules PDF — by way of
/// `pguetschow/warhammer-40k-stratagem-card-generator` — has the eleven core
/// ones, and where its transcription says more it is preferred.
/// Weapon keyword rules text, from BSData.
///
/// 40kdc ships all 34 keywords with `effect: null` — the name, the parameters
/// it takes, and nothing that says what `[TORRENT]` does. BSData carries the
/// wording, in the same `**bold**` convention the rest of the app renders, as
/// a shared rule with a description.
///
/// This is the fallback in §3.14 doing its job: 40kdc first, then BSData, then
/// Wahapedia. Nothing here is written from memory (§0).
int _applyKeywordText() {
  final path = '$_outRoot/core/weapon-keywords.json';
  final records = _readArray(path);
  if (records.isEmpty) return 0;

  final text = _bsRuleText();
  if (text.isEmpty) return 0;

  var written = 0;
  final updated = [
    for (final raw in records)
      if (asMap(raw) case final record)
        () {
          final name = strOr(record['name'], '').trim();
          // `[ANTI-X Y+]` ships as `Anti`, and BSData calls the rule `Anti`
          // too; a keyword whose name carries its parameter would not match
          // on the full string, so the first word is the fallback key.
          final found = text[name.toLowerCase()] ??
              text[name.toLowerCase().split(' ').first];
          if (found == null || found.isEmpty) return record;
          written++;
          return {...record, 'text': found};
        }()
  ];
  if (written > 0) _write(path, updated);
  return written;
}

/// Every named rule in BSData that carries a description, by lower-case name.
///
/// The keywords are core rules and appear in every faction's library, so the
/// first file that has one is as good as any other. Longest wins where they
/// differ, on the same reasoning as the stratagem merge: a truncated stub is
/// the failure mode, not a competing wording.
Map<String, String> _bsRuleText() {
  final out = <String, String>{};

  void walk(Object? node) {
    if (node is Map<String, Object?>) {
      final name = str(node['name'])?.trim();
      final description = str(node['description'])?.trim();
      if (name != null &&
          name.isNotEmpty &&
          description != null &&
          description.length > 20) {
        final key = name.toLowerCase();
        final existing = out[key];
        if (existing == null || description.length > existing.length) {
          out[key] = _markup(description);
        }
      }
      for (final value in node.values) {
        walk(value);
      }
    } else if (node is List) {
      for (final value in node) {
        walk(value);
      }
    }
  }

  final root = Directory(_bsRoot);
  if (!root.existsSync()) return out;
  for (final file in root.listSync(recursive: true).whereType<File>()) {
    if (!file.path.endsWith('.json')) continue;
    try {
      walk(jsonDecode(file.readAsStringSync()));
    } on FormatException {
      continue;
    }
  }
  return out;
}

int _applyStratagemText(List<String> factions) {
  final wahapedia = _readWahapedia();
  final core = _readCoreStratagems();
  if (wahapedia.isEmpty && core.isEmpty) return 0;

  // **Every faction in the output, not just the ones BSData ships.** The
  // faction list is built from `data/bsdata`, and a chapter with no
  // catalogue of its own — Crimson Fists — is written by `_copyRemaining`
  // and was never visited here. 66 of its stratagems kept a name and a cost
  // and nothing else, the largest single block of missing text.
  final present = <String>{
    ...factions,
    ...Directory('$_outRoot/core')
        .listSync()
        .whereType<Directory>()
        .map((d) => d.path.split(Platform.pathSeparator).last),
  }.toList()
    ..sort();

  var written = 0;
  for (final factionId in [...present, null]) {
    final path = factionId == null
        ? '$_outRoot/core/stratagems.json'
        : '$_outRoot/core/$factionId/stratagems.json';
    final records = _readArray(path);
    if (records.isEmpty) continue;

    var touched = 0;
    final updated = [
      for (final raw in records)
        if (asMap(raw) case final record)
          () {
            final name = _stratagemKey(strOr(record['name'], ''));
            if (name.isEmpty) return record;

            // The detachment disambiguates a name reused across armies —
            // several factions have a stratagem called BLOOD TITHE.
            final detachment = _stratagemKey(
                strOr(record['detachment_id'], '').replaceAll('-', ' '));
            final candidates = wahapedia[name] ?? const [];
            final fromWahapedia = _bestMatch(candidates, detachment);

            final text = _fullest([fromWahapedia, core[name]]);
            if (text == null) return record;
            touched++;
            return {...record, 'text': text};
          }()
    ];
    if (touched > 0) {
      _write(path, updated);
      written += touched;
    }
  }
  return written;
}

/// The longest of the candidate texts, or null when there are none.
///
/// "Fullest" rather than "first": the two sources word the same stratagem
/// differently, and the one that says more is the one worth reading. On the
/// core eleven that is usually the Core Rules PDF, which spells the roll types
/// out as a list where Wahapedia runs them into a sentence.
String? _fullest(List<String?> options) {
  String? best;
  for (final option in options) {
    if (option == null || option.trim().isEmpty) continue;
    if (best == null || option.length > best.length) best = option;
  }
  return best;
}

/// The Wahapedia row for this detachment, or the most complete row otherwise.
///
/// Wahapedia carries several rows under one core name — a Boarding Actions
/// variant, a legacy 10th edition one, and the current `Core Stratagem`.
/// Taking the first gives the stale one, which is what made the export look
/// out of date on first reading.
String? _bestMatch(List<({String detachment, String type, String text})> rows,
    String detachment) {
  if (rows.isEmpty) return null;
  if (detachment.isNotEmpty) {
    for (final row in rows) {
      if (row.detachment == detachment) return row.text;
    }
  }
  for (final row in rows) {
    if (row.type.toLowerCase() == 'core stratagem') return row.text;
  }
  return _fullest([for (final row in rows) row.text]);
}

/// `A TEMPTING TRAP` and `a-tempting-trap` are the same stratagem.
///
/// **Letters and digits only**, because everything else is where the two
/// sources disagree and none of it is meaning. Keeping apostrophes and spaces
/// cost 79 matches: `FOOL’S FLIGHT` against Wahapedia's `FOOLS’ FLIGHT`,
/// `ARMED TO DA TEEF` against their `ARMED TO DATEEF`, `CUT’ EM DOWN` against
/// `CUT’EM DOWN`, and `THREAT-COGITATION` against a non-breaking hyphen.
///
/// Checked for collisions before loosening: across the whole export exactly
/// one pair of distinct keys collapses together, `COUNTER-OFFENSIVE` and
/// `COUNTEROFFENSIVE`, which is the same stratagem spelled two ways.
String _stratagemKey(String value) =>
    value.toLowerCase().replaceAll(RegExp('[^a-z0-9]+'), '');

Map<String, List<({String detachment, String type, String text})>>
    _readWahapedia() {
  final file = File(_wahapediaPath);
  if (!file.existsSync()) return {};
  final lines = const LineSplitter().convert(file.readAsStringSync());
  if (lines.isEmpty) return {};

  final header = lines.first.replaceFirst('﻿', '').split('|');
  final index = {for (final (i, h) in header.indexed) h.trim(): i};
  String field(List<String> row, String name) {
    final at = index[name];
    return at != null && at < row.length ? row[at] : '';
  }

  final out = <String, List<({String detachment, String type, String text})>>{};
  // A description contains newlines only as `<br>`, so a row is a line.
  for (final line in lines.skip(1)) {
    if (line.trim().isEmpty) continue;
    final row = line.split('|');
    final name = _stratagemKey(field(row, 'name'));
    if (name.isEmpty) continue;
    final text = _markup(field(row, 'description'));
    if (text.isEmpty) continue;
    (out[name] ??= []).add((
      detachment: _stratagemKey(field(row, 'detachment')),
      type: field(row, 'type').trim(),
      text: text,
    ));
  }
  return out;
}

Map<String, String> _readCoreStratagems() {
  final file = File(_coreStratagemPath);
  if (!file.existsSync()) return {};
  final parsed = asMap(jsonDecode(file.readAsStringSync()));
  final out = <String, String>{};
  for (final rawFaction in asMap(parsed['factions']).values) {
    for (final rawList in asMap(asMap(rawFaction)['detachments']).values) {
      for (final rawCard in asList(rawList)) {
        final card = asMap(rawCard);
        final name = _stratagemKey(strOr(card['name'], ''));
        if (name.isEmpty) continue;
        // Assembled into the same shape Wahapedia publishes, so the two are
        // comparable and a reader cannot tell which source a card came from.
        final parts = <String>[
          for (final key in const ['when', 'target', 'effect', 'restrictions'])
            if (_markup(strOr(card[key], '')) case final value
                when value.isNotEmpty)
              '**${key.toUpperCase()}:** $value',
        ];
        if (parts.isNotEmpty) out[name] = parts.join('\n\n');
      }
    }
  }
  return out;
}

/// Source HTML, reduced to the markup the app renders (§3.10).
///
/// **Lists are structure, and stripping them loses the sentence.** Wahapedia
/// writes the roll types of COMMAND RE-ROLL as `<ul><li>`, and a generic
/// tag-strip ran them together into
/// `**Advance roll****Charge roll****Damage roll**` — one unreadable line
/// where the card has eight bullets. The Core Rules transcription uses `▪`
/// for the same job, so both become the same bullet.
String _markup(String value) => value
    .replaceAll(RegExp(r'</li>\s*<li>', caseSensitive: false), '\n• ')
    .replaceAll(RegExp(r'<ul>\s*<li>', caseSensitive: false), '\n• ')
    .replaceAll(RegExp(r'</li>\s*</ul>', caseSensitive: false), '\n')
    .replaceAll(RegExp(r'</?(?:ul|ol|li)>', caseSensitive: false), '\n')
    .replaceAll(RegExp(r'<br\s*/?>', caseSensitive: false), '\n')
    .replaceAll(RegExp(r'</?(?:b|strong)>', caseSensitive: false), '**')
    .replaceAll(RegExp(r'<[^>]+>'), '')
    .replaceAll(RegExp('[▪■]\\s*'), '• ')
    .replaceAll('\u00a0', ' ')
    .replaceAll(RegExp(r'[ \t]+\n'), '\n')
    .replaceAll(RegExp(r'\n{3,}'), '\n\n')
    .trim();
