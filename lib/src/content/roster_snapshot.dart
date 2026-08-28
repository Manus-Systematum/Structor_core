/// A self-contained copy of the content a roster references (DESIGN.md §2.2).
///
/// Two jobs, both of which the raw dataset cannot do:
///
///   - **Offline play.** The play screen must work with no network and no
///     downloaded faction, which means the roster carries its own datasheets.
///   - **Lists from strangers.** An imported or scanned list has to render even
///     when the receiver lacks the sender's catalogue, or worse, has a
///     different revision of it (§6.4).
///
/// A snapshot is deliberately *not* the whole faction — only what this roster
/// names, which for a 2,000 pt army is a small fraction of it.
library;

import '../play/army_rules.dart';
import '../roster/roster.dart';
import '../source/dataset_loader.dart';
import '../source/json.dart';
import 'dataset.dart';

class RosterSnapshot {
  final DatasetVersion version;

  /// Raw source records keyed by id, as loaded. Kept in source form on purpose:
  /// a snapshot's value is that it can be read by a build of the app whose
  /// domain model has since moved on.
  final Map<String, Object?> units;
  final Map<String, Object?> weapons;
  final Map<String, Object?> detachments;
  final Map<String, Object?> abilities;

  /// Core stratagems plus those of the detachments taken. Part of the snapshot
  /// because the play screen's stratagem list has to survive the trip to
  /// someone else's phone (§7.3), and because which stratagems apply is a
  /// property of *this roster's* detachments, not of the faction.
  final Map<String, Object?> stratagems;

  /// Enhancements and Unit Upgrades the taken detachments offer — not only
  /// the ones bought. The reference page lists what was *available*, because
  /// "what could I have taken" is a question asked mid-game as often as
  /// "what did I take".
  final Map<String, Object?> enhancements;

  /// Which phases each ability is filed under.
  ///
  /// **Carried, because play mode reads only this.** The turn page files a
  /// rule by `phases.contains(phase)`, and for 5,222 of the 8,533 published
  /// mappings the phase is not derivable from the effect — `Righteous
  /// Repugnance` is a bare `add 3 Attacks`, so nothing about its structure
  /// says Shooting or Fight. Without the mapping in the snapshot those rules
  /// appear in no phase section at all.
  final Map<String, Object?> phaseMappings;

  /// The faction's own army rule — For the Greater Good, Oath of Moment. Its
  /// record is in [abilities]; this names which one it is (§7.3.9).
  final String? factionRuleId;

  /// Ability ids more than one datasheet **in the faction** can take.
  ///
  /// Whether a rule is shared is a fact about the catalogue, and a snapshot
  /// holds only the datasheets this roster uses — so counting owners on the
  /// receiving end would answer a narrower question and file the same rule
  /// differently on the sender's phone and the receiver's (§7.3.9).
  final Set<String> sharedAbilities;

  const RosterSnapshot({
    required this.version,
    required this.units,
    required this.weapons,
    required this.detachments,
    required this.abilities,
    this.stratagems = const {},
    this.enhancements = const {},
    this.phaseMappings = const {},
    this.factionRuleId,
    this.sharedAbilities = const {},
  });

  int get entryCount =>
      units.length +
      weapons.length +
      detachments.length +
      abilities.length +
      stratagems.length +
      enhancements.length;

  Map<String, Object?> toJson() => {
        'version': version.toJson(),
        'units': units,
        'weapons': weapons,
        'detachments': detachments,
        'abilities': abilities,
        'stratagems': stratagems,
        'enhancements': enhancements,
        'phaseMappings': phaseMappings,
        if (factionRuleId != null) 'factionRuleId': factionRuleId,
        'sharedAbilities': sharedAbilities.toList(growable: false),
      };

  factory RosterSnapshot.fromJson(Object? v) {
    final j = asMap(v);
    return RosterSnapshot(
      version: DatasetVersion.fromJson(asMap(j['version'])),
      units: asMap(j['units']),
      weapons: asMap(j['weapons']),
      detachments: asMap(j['detachments']),
      abilities: asMap(j['abilities']),
      // Absent in snapshots written before stratagems were captured. An older
      // list opens with an empty stratagem section rather than failing.
      stratagems: asMap(j['stratagems']),
      enhancements: asMap(j['enhancements']),
      // Absent in snapshots written before this was captured, exactly as
      // stratagems were. Such a list opens with its rules unfiled by phase
      // rather than failing — `Update to current data` refills it (§4.6).
      phaseMappings: asMap(j['phaseMappings']),
      factionRuleId: str(j['factionRuleId']),
      // Absent in snapshots written before rules were tiered. An older list
      // falls back to its own datasheets, which files a few more rules under
      // the unit that has them rather than failing to open.
      sharedAbilities: {
        for (final id in asList(j['sharedAbilities'])) '$id',
      },
    );
  }
}

/// Builds the transitive closure of content a roster references: its units,
/// their weapons and abilities, and its detachments.
class SnapshotBuilder {
  final Dataset dataset;

  /// Source records as loaded from disk, needed because [Dataset] holds parsed
  /// DTOs and a snapshot must preserve the original JSON.
  final Map<String, Object?> rawUnits;
  final Map<String, Object?> rawWeapons;
  final Map<String, Object?> rawDetachments;
  final Map<String, Object?> rawAbilities;

  /// Faction stratagems **and** the core ones, keyed by id. Core stratagems
  /// live outside the faction files, so the caller merges them.
  final Map<String, Object?> rawStratagems;
  final Map<String, Object?> rawEnhancements;

  const SnapshotBuilder({
    required this.dataset,
    this.rawUnits = const {},
    this.rawWeapons = const {},
    this.rawDetachments = const {},
    this.rawAbilities = const {},
    this.rawStratagems = const {},
    this.rawEnhancements = const {},
  });

  /// Builds against a snapshot on disk, pulling the raw records the parsed
  /// [Dataset] does not retain.
  factory SnapshotBuilder.fromLoader(DatasetLoader loader, Dataset dataset) {
    final factionId = dataset.version.factionId;
    return SnapshotBuilder(
      dataset: dataset,
      rawUnits: loader.rawUnits(factionId),
      rawWeapons: loader.rawWeapons(factionId),
      rawDetachments: loader.rawDetachments(factionId),
      rawAbilities: loader.rawAbilities(factionId),
      rawStratagems: {
        ...loader.rawIndex('core/stratagems.json'),
        ...loader.rawIndex('core/$factionId/stratagems.json'),
      },
      rawEnhancements: loader.rawIndex('core/$factionId/enhancements.json'),
    );
  }

  RosterSnapshot build(Roster roster) {
    final units = <String, Object?>{};
    final weapons = <String, Object?>{};
    final detachments = <String, Object?>{};
    final abilities = <String, Object?>{};
    final stratagems = <String, Object?>{};
    final enhancements = <String, Object?>{};

    void takeAbility(String id) {
      final raw = rawAbilities[id];
      if (raw != null) abilities[id] = raw;
    }

    // Core stratagems apply to every army; a detachment's apply only to the
    // armies that took it (§7.3). Scoping here means a shared list never
    // offers its receiver a stratagem the sender could not play either.
    final taken = {for (final d in roster.detachments) d.detachmentId};
    for (final entry in rawStratagems.entries) {
      final detachmentId = str(asMap(entry.value)['detachment_id']);
      if (detachmentId != null && !taken.contains(detachmentId)) continue;
      stratagems[entry.key] = entry.value;

      // A stratagem's effect, where the data has one, is an ability.
      final abilityId = str(asMap(entry.value)['ability_id']);
      if (abilityId != null) takeAbility(abilityId);
    }

    for (final entry in roster.detachments) {
      final raw = rawDetachments[entry.detachmentId];
      if (raw != null) detachments[entry.detachmentId] = raw;

      // A detachment's rule is an ability, and the play screen needs it.
      final detachment = dataset.detachment(entry.detachmentId);
      final ruleId = detachment?.detachmentRuleId;
      if (ruleId != null) takeAbility(ruleId);

      for (final id in detachment?.enhancementIds ?? const <String>[]) {
        final raw = rawEnhancements[id];
        if (raw == null) continue;
        enhancements[id] = raw;
        final abilityId = str(asMap(raw)['ability_id']);
        if (abilityId != null) takeAbility(abilityId);
      }
    }

    for (final rosterUnit in roster.units) {
      final datasheet = dataset.unit(rosterUnit.datasheetId);
      if (datasheet == null) continue;

      final rawUnit = rawUnits[datasheet.id];
      if (rawUnit != null) units[datasheet.id] = rawUnit;

      // The whole vocabulary, not `ability_ids` alone: a drone is optional
      // wargear and its rule lives behind a budget line, so capturing only
      // the innate ones left a snapshot that could not explain a drone the
      // list had actually bought (§3.10).
      for (final abilityId in datasheet.ruleVocabulary) {
        takeAbility(abilityId);
      }

      // Only the weapons this unit actually carries, resolved through the
      // carrier so the scoped variant is captured rather than the generic one
      // (§7.3.5).
      for (final selection in rosterUnit.wargear) {
        var weapon = dataset.weaponFor(datasheet, selection.itemId);

        // Wargear that is an ability can still bring a gun: a Gun Drone is a
        // twin pulse carbine (§7.3.7). Missing it here leaves the shooting
        // table short a weapon on any list rebuilt from the snapshot alone,
        // which is the case the snapshot exists for.
        if (weapon == null) {
          final grantedId = dataset.ability(selection.itemId)?.grantedWeaponId;
          if (grantedId == null) continue;
          weapon = dataset.weaponFor(datasheet, grantedId) ??
              dataset.weapon(grantedId);
          if (weapon == null) continue;
        }

        final raw = rawWeapons[weapon.id];
        if (raw != null) weapons[weapon.id] = raw;
      }
    }

    // The army rule is not reachable from any datasheet, so nothing above
    // would have pulled it in.
    final factionRuleId = dataset.faction.factionRuleId;
    if (factionRuleId != null) takeAbility(factionRuleId);

    // Only for the abilities this roster actually captured — the mapping file
    // covers the whole faction and a snapshot is meant to be small.
    final phases = <String, Object?>{
      for (final id in abilities.keys)
        if (dataset.phasesFor(id) case final p when p.isNotEmpty) id: p,
    };

    return RosterSnapshot(
      version: dataset.version,
      units: units,
      weapons: weapons,
      detachments: detachments,
      abilities: abilities,
      stratagems: stratagems,
      enhancements: enhancements,
      phaseMappings: phases,
      factionRuleId: factionRuleId,
      // Computed here, over the whole faction, because this is the last point
      // at which the whole faction is in hand.
      sharedAbilities: ArmyRules.sharedAcross(dataset.faction.units),
    );
  }
}
