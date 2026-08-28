/// Loads a 40kdc-data snapshot from disk into source DTOs.
///
/// Reads the layout produced by `tools/fetch-40kdc.sh`:
///
///     <root>/core/<file>.json
///     <root>/core/<faction>/<file>.json
///     <root>/enrichment/<faction>/<file>.json
///
/// Missing files are tolerated and recorded in [FactionData.missingFiles]; an
/// incomplete snapshot should produce a partial load plus an honest report,
/// not an exception.
library;

import 'dart:convert';
import 'dart:io';

import 'corrections.dart';
import 'json.dart';
import 'source_models.dart';

class CoreData {
  final List<GameVersion> gameVersions;
  final Map<String, String> forceDispositions; // id -> name
  final Map<String, String> missions; // id -> name
  final List<MissionMatchup> missionMatchups;
  final Set<String> weaponKeywordIds;

  /// What each weapon keyword does, by id, where a source publishes it.
  ///
  /// 40kdc ships names and parameters with `effect: null`; the text comes from
  /// BSData at merge time (§3.14). A keyword with no entry here has no
  /// published wording — 33 of the 34 have one, and the exception is used by
  /// no weapon.
  final Map<String, WeaponKeywordText> weaponKeywords;
  final List<SourceStratagem> coreStratagems;
  final List<String> missingFiles;

  const CoreData({
    required this.gameVersions,
    required this.forceDispositions,
    required this.missions,
    required this.missionMatchups,
    required this.weaponKeywordIds,
    this.weaponKeywords = const {},
    required this.coreStratagems,
    required this.missingFiles,
  });
}

class MissionMatchup {
  final String disposition;
  final String opponentDisposition;
  final String missionId;

  const MissionMatchup({
    required this.disposition,
    required this.opponentDisposition,
    required this.missionId,
  });

  factory MissionMatchup.fromJson(Object? v) {
    final j = asMap(v);
    return MissionMatchup(
      disposition: strOr(j['disposition'], ''),
      opponentDisposition: strOr(j['opponent_disposition'], ''),
      missionId: strOr(j['mission_id'], ''),
    );
  }
}

class FactionData {
  final String factionId;
  final List<SourceUnit> units;
  final List<SourceWeapon> weapons;
  final List<SourceDetachment> detachments;
  final List<SourceStratagem> stratagems;
  final List<SourceAbility> abilities;
  final List<PhaseMapping> phaseMappings;
  final List<LeaderAttachment> leaderAttachments;
  final Set<String> enhancementIds;

  /// Parsed Enhancement and Unit Upgrade records. [enhancementIds] remains the
  /// validator's cheap membership test; this is for anything that has to show
  /// one to a player.
  final List<SourceEnhancement> enhancements;

  /// How each datasheet is made up. Needed only by the builder, to give a new
  /// unit a legal starting loadout.
  final List<UnitComposition> compositions;

  /// Published wargear choices, by datasheet. About half of datasheets have
  /// none, which is why the builder reads these as guidance rather than as
  /// permission (§4.5).
  final List<SourceWargearOption> wargearOptions;

  /// The army rule every unit in the faction has — For the Greater Good, Oath
  /// of Moment. `factions.json` has always carried it; nothing read the file,
  /// so the one rule that is true of the whole army was the one rule the app
  /// never showed (DESIGN.md §7.3.9).
  final String? factionRuleId;

  /// The faction's display name, from the same record.
  final String? factionName;

  /// The faction whose datasheets this one fields, or null when it has its
  /// own. The twelve Space Marine chapters publish detachments, stratagems
  /// and enhancements and no units at all (DESIGN.md §3.9).
  final String? parentFactionId;

  /// Published questions and answers for this faction (§3.16). Empty until
  /// a patch supplies them: no community source publishes FAQs, so they
  /// arrive with the same update as the rules they clarify.
  final List<FactionFaq> faqs;

  final List<String> missingFiles;

  const FactionData({
    required this.factionId,
    required this.units,
    required this.weapons,
    required this.detachments,
    required this.stratagems,
    required this.abilities,
    required this.phaseMappings,
    required this.leaderAttachments,
    required this.enhancementIds,
    this.enhancements = const [],
    this.compositions = const [],
    this.wargearOptions = const [],
    this.factionRuleId,
    this.factionName,
    this.parentFactionId,
    this.faqs = const [],
    required this.missingFiles,
  });
}

class DatasetLoader {
  final Directory root;

  /// Applied to abilities as they are read, so every consumer — the bundler,
  /// the snapshot writer, the coverage report — sees the same corrected data
  /// (DESIGN.md §3.6). A loader built without them reads the snapshot as it
  /// came from upstream, which is what the cross-check wants.
  final DataCorrections corrections;

  DatasetLoader(String rootPath, {this.corrections = DataCorrections.empty})
      : root = Directory(rootPath);

  /// Reads corrections from [path], or none if the file is absent.
  static DataCorrections correctionsAt(String path) {
    final file = File(path);
    if (!file.existsSync()) return DataCorrections.empty;
    return DataCorrections.parse(file.readAsStringSync());
  }

  /// Reads a JSON array file, returning `null` when absent or unparseable.
  List<Object?>? _readArray(String relativePath) {
    final file = File('${root.path}/$relativePath');
    if (!file.existsSync()) return null;
    try {
      final decoded = jsonDecode(file.readAsStringSync());
      return decoded is List ? decoded : null;
    } on FormatException {
      return null;
    }
  }

  CoreData loadCore() {
    final missing = <String>[];

    List<Object?> read(String path) {
      final data = _readArray(path);
      if (data == null) {
        missing.add(path);
        return const [];
      }
      return data;
    }

    final dispositions = <String, String>{};
    for (final raw in read('core/force-dispositions.json')) {
      final j = asMap(raw);
      final id = str(j['id']);
      if (id != null) dispositions[id] = strOr(j['name'], id);
    }

    final missions = <String, String>{};
    for (final raw in read('core/missions.json')) {
      final j = asMap(raw);
      final id = str(j['id']);
      if (id != null) missions[id] = strOr(j['name'], id);
    }

    final keywordIds = <String>{};
    final keywords = <String, WeaponKeywordText>{};
    for (final raw in read('core/weapon-keywords.json')) {
      final j = asMap(raw);
      final id = str(j['id']);
      if (id == null) continue;
      keywordIds.add(id);
      final text = str(j['text']);
      if (text != null && text.isNotEmpty) {
        keywords[id] = WeaponKeywordText(
          id: id,
          name: strOr(j['name'], id),
          text: text,
        );
      }
    }

    return CoreData(
      gameVersions: read('core/game-versions.json')
          .map(GameVersion.fromJson)
          .toList(growable: false),
      forceDispositions: dispositions,
      missions: missions,
      missionMatchups: read('core/mission-matchups.json')
          .map(MissionMatchup.fromJson)
          .toList(growable: false),
      weaponKeywordIds: keywordIds,
      weaponKeywords: keywords,
      coreStratagems: read('core/stratagems.json')
          .map(SourceStratagem.fromJson)
          .toList(growable: false),
      missingFiles: missing,
    );
  }

  FactionData loadFaction(String factionId) {
    final missing = <String>[];

    List<Object?> read(String path) {
      final data = _readArray(path);
      if (data == null) {
        missing.add(path);
        return const [];
      }
      return data;
    }

    // Corrected on the way in, like units and abilities: a Unit Upgrade
    // usually names its datasheet and the data usually does not.
    final enhancementRecords = corrections
        .applyToEnhancements(
            factionId, read('core/$factionId/enhancements.json'))
        .records;
    final enhancementIds = <String>{};
    for (final raw in enhancementRecords) {
      final id = str(asMap(raw)['id']);
      if (id != null) enhancementIds.add(id);
    }

    // A faction file holds one record for the faction itself. Sub-factions
    // exist upstream, so the one whose id matches is the one wanted.
    final factionRecords = read('core/$factionId/factions.json');
    final self = factionRecords
        .map(asMap)
        .where((j) => str(j['id']) == factionId)
        .firstOrNull;

    // A Space Marine chapter publishes its own detachments, stratagems and
    // enhancements and **no datasheets** — a Blood Angels army fields Adeptus
    // Astartes units. Datasheet files therefore fall through to the parent,
    // while everything the chapter publishes stays its own, since its files
    // already carry the parent's entries alongside its own.
    final parentId = self == null ? null : str(self['parent_faction_id']);

    /// A datasheet file, from the parent when this faction publishes none.
    /// Absent-and-inherited is not a missing file, so it is not reported as
    /// one — otherwise every chapter would list eight.
    /// A datasheet file: the parent's, plus whatever the chapter adds.
    ///
    /// This used to be a fall-through — own file if non-empty, else the
    /// parent's — because a chapter published no datasheets at all and the two
    /// cases could never both apply. BSData changed that: it gives Blood
    /// Angels twenty-six of their own, and a fall-through then meant a Blood
    /// Angels army could field Sanguinary Guard and *not* an Intercessor
    /// Squad. Both are true at once, so both are read (§3.10).
    List<Object?> sheets(String dir, String name) {
      final own = _readArray('$dir/$factionId/$name') ?? const [];
      if (parentId == null) {
        return own.isEmpty ? read('$dir/$factionId/$name') : own;
      }
      final inherited = _readArray('$dir/$parentId/$name') ?? const [];
      if (own.isEmpty) return inherited;

      // The chapter's own record wins where both name the same id: a chapter
      // that republishes a datasheet is saying something about it.
      final ids = {
        for (final raw in own)
          if (str(asMap(raw)['id'] ?? asMap(raw)['ability_id']) case final id?)
            id,
      };
      return [
        ...own,
        for (final raw in inherited)
          if (str(asMap(raw)['id'] ?? asMap(raw)['ability_id']) case final id?)
            if (!ids.contains(id)) raw,
      ];
    }

    // Corrections are keyed by the faction that *owns* the record, so an
    // inherited datasheet is corrected as the parent's — a chapter must not
    // need its own copy of every Astartes correction.
    final sheetOwner = parentId ?? factionId;

    return FactionData(
      factionId: factionId,
      factionRuleId: self == null ? null : str(self['faction_rule_id']),
      factionName: self == null ? null : str(self['name']),
      parentFactionId: parentId,
      units: corrections
          .applyToUnits(sheetOwner, sheets('core', 'units.json'))
          .records
          .map(SourceUnit.fromJson)
          .toList(growable: false),
      weapons: corrections
          .applyToWeapons(sheetOwner, sheets('core', 'weapons.json'))
          .records
          .map(SourceWeapon.fromJson)
          .toList(growable: false),
      detachments: read('core/$factionId/detachments.json')
          .map(SourceDetachment.fromJson)
          .toList(growable: false),
      stratagems: read('core/$factionId/stratagems.json')
          .map(SourceStratagem.fromJson)
          .toList(growable: false),
      abilities: corrections
          .applyToAbilities(
            sheetOwner,
            sheets('enrichment', 'abilities.json'),
          )
          .records
          .map(SourceAbility.fromJson)
          .toList(growable: false),
      // Corrected on the way in. The file is community-authored and files a
      // rule under all five phases where it does not know, which the turn
      // page then honours literally (§7.3.9).
      phaseMappings: corrections
          .applyToPhaseMappings(
            sheetOwner,
            sheets('enrichment', 'phase-mappings.json'),
          )
          .records
          .map(PhaseMapping.fromJson)
          .toList(growable: false),
      leaderAttachments: sheets('core', 'leader-attachments.json')
          .map(LeaderAttachment.fromJson)
          .toList(growable: false),
      enhancementIds: enhancementIds,
      compositions: sheets('core', 'unit-compositions.json')
          .map(UnitComposition.fromJson)
          .where((c) => c.unitId.isNotEmpty)
          .toList(growable: false),
      wargearOptions: sheets('core', 'wargear-options.json')
          .map(SourceWargearOption.fromJson)
          .where((o) => o.unitId.isNotEmpty)
          .toList(growable: false),
      enhancements: enhancementRecords
          .map(SourceEnhancement.fromJson)
          .where((e) => e.id.isNotEmpty)
          .toList(growable: false),
      missingFiles: missing,
    );
  }

  /// Raw JSON records from [relativePath], keyed by [idKey].
  ///
  /// Snapshots (DESIGN.md §2.2) must preserve the original records rather than
  /// re-serialise parsed DTOs: a snapshot's whole point is that a later build,
  /// whose model has moved on, can still read a list saved today.
  Map<String, Object?> rawIndex(String relativePath, {String idKey = 'id'}) {
    final data = _readArray(relativePath);
    if (data == null) return const {};
    final index = <String, Object?>{};
    for (final record in data) {
      final id = str(asMap(record)[idKey]);
      if (id != null) index[id] = record;
    }
    return index;
  }

  Map<String, Object?> rawUnits(String factionId) {
    final index = <String, Object?>{};
    for (final record in correctedUnits(factionId).records) {
      final id = str(asMap(record)['id']);
      if (id != null) index[id] = record;
    }
    return index;
  }

  Map<String, Object?> rawWeapons(String factionId) {
    final index = <String, Object?>{};
    for (final record in correctedWeapons(factionId).records) {
      final id = str(asMap(record)['id']);
      if (id != null) index[id] = record;
    }
    return index;
  }

  Map<String, Object?> rawDetachments(String factionId) =>
      rawIndex('core/$factionId/detachments.json');

  Map<String, Object?> rawAbilities(String factionId) {
    final index = <String, Object?>{};
    for (final record in correctedAbilities(factionId).records) {
      final id = str(asMap(record)['ability_id']);
      if (id != null) index[id] = record;
    }
    return index;
  }

  /// Raw ability records with [corrections] applied, alongside the bookkeeping
  /// of which corrections fired and which matched nothing.
  CorrectionResult correctedAbilities(String factionId) =>
      corrections.applyToAbilities(
        factionId,
        _readArray('enrichment/$factionId/abilities.json') ?? const [],
      );

  /// Raw weapon records with [corrections] applied, including any the
  /// corrections add outright.
  CorrectionResult correctedWeapons(String factionId) =>
      corrections.applyToWeapons(
        factionId,
        _readArray('core/$factionId/weapons.json') ?? const [],
      );

  /// Raw unit records with [corrections] applied.
  CorrectionResult correctedUnits(String factionId) => corrections.applyToUnits(
        factionId,
        _readArray('core/$factionId/units.json') ?? const [],
      );

  /// Faction ids present under `core/`, i.e. directories rather than files.
  List<String> availableFactions() {
    final dir = Directory('${root.path}/core');
    if (!dir.existsSync()) return const [];
    return dir
        .listSync()
        .whereType<Directory>()
        .map((d) => d.path.split(Platform.pathSeparator).last)
        .where((n) => !n.startsWith('_'))
        .toList()
      ..sort();
  }
}
