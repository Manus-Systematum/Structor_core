/// Read-only content lookup used by pricing and validation.
///
/// Deliberately narrow. It is backed by source DTOs today; the normalised
/// domain model (DESIGN.md §2.1) can implement the same interface later
/// without touching the calculator or the validator.
library;

import '../roster/roster.dart';
import '../source/dataset_loader.dart';
import '../source/source_models.dart';

abstract interface class Catalogue {
  SourceUnit? unit(String datasheetId);

  /// Every datasheet, for name-based lookup during import (DESIGN.md §6.1).
  Iterable<SourceUnit> get allUnits;

  /// Every detachment, for the same reason.
  Iterable<SourceDetachment> get allDetachments;

  SourceDetachment? detachment(String detachmentId);

  SourceWeapon? weapon(String weaponId);

  /// Abilities, when the backing store has them. Needed because wargear and
  /// abilities are the same thing for a drone: taking one is a wargear
  /// choice, and what it does is an ability (DESIGN.md §7.3.7).
  SourceAbility? ability(String abilityId) => null;

  /// Enhancements and Unit Upgrades the army's detachments offer.
  Iterable<SourceEnhancement> get enhancements => const [];

  /// How a datasheet is made up, when the backing store knows. Only the
  /// builder needs it.
  UnitComposition? composition(String datasheetId) => null;

  /// Published wargear choices for [datasheetId]. Empty for roughly half of
  /// datasheets, which is why the editor treats an empty list as "nothing is
  /// published" rather than "nothing is allowed" (DESIGN.md §4.5).
  List<SourceWargearOption> wargearOptions(String datasheetId) => const [];

  /// Datasheets [leaderDatasheetId] may join. Empty when the datasheet is not
  /// a leader, or when no attachment rule is published for it.
  List<String> eligibleBodyguards(String leaderDatasheetId);

  /// The force disposition ids [detachmentId] lets an army declare.
  ///
  /// A detachment brings its own, and which mission you play is decided from
  /// them (§7.3.1) — so it is part of what choosing a detachment buys and
  /// belongs beside the DP cost rather than only in the pre-game wizard.
  List<String> dispositionsOf(String detachmentId) =>
      detachment(detachmentId)?.forceDispositions ?? const [];

  /// The phases `phase-mappings.json` files [abilityId] under.
  ///
  /// Empty when nothing is published, which is not the same as "no phase":
  /// the renderer derives one from the effect where the effect names one.
  List<String> phasesFor(String abilityId) => const [];

  /// Whether any leader in this catalogue may attach to [datasheetId].
  ///
  /// The reverse of [eligibleBodyguards], and the question the *unit's* side
  /// of the screen asks. Without it the editor offered a `LED BY` heading on
  /// every unit that is not itself a character — Paragon Warsuits, a Rhino —
  /// and then said no character may lead it, which is a section that exists
  /// to report its own emptiness.
  bool canBeLed(String datasheetId);

  /// Resolves a roster wargear item to the weapon record **that unit** uses.
  ///
  /// Weapons are per-carrier: `missile-pod` is BS4+ on a Crisis suit while
  /// `missile-pod-commander-in-enforcer-battlesuit` is BS3+. Both names read
  /// "Missile pod" to the player, so resolution must be scoped to the unit's
  /// own `weapon_ids` or the shooting screen will report the wrong skill
  /// (DESIGN.md §7.3.5).
  SourceWeapon? weaponFor(SourceUnit unit, String itemId) {
    final scoped = '$itemId-${unit.id}';
    if (unit.weaponIds.contains(scoped)) return weapon(scoped);
    if (unit.weaponIds.contains(itemId)) return weapon(itemId);
    return null;
  }
}

class MapCatalogue implements Catalogue {
  final Map<String, SourceUnit> _units;
  final Map<String, SourceDetachment> _detachments;
  final Map<String, SourceWeapon> _weapons;
  final Map<String, List<String>> _attachments;
  final Map<String, SourceAbility> _abilities;
  final Map<String, SourceEnhancement> _enhancements;
  final Map<String, UnitComposition> _compositions;
  final Map<String, List<SourceWargearOption>> _wargearOptions;
  final Map<String, List<String>> _phases;

  MapCatalogue(
    Iterable<SourceUnit> units, {
    Iterable<SourceDetachment> detachments = const [],
    Iterable<SourceWeapon> weapons = const [],
    Iterable<LeaderAttachment> leaderAttachments = const [],
    Iterable<SourceAbility> abilities = const [],
    Iterable<SourceEnhancement> enhancements = const [],
    Iterable<UnitComposition> compositions = const [],
    Iterable<SourceWargearOption> wargearOptions = const [],
    Iterable<PhaseMapping> phaseMappings = const [],
  })  : _units = {for (final u in units) u.id: u},
        _detachments = {for (final d in detachments) d.id: d},
        _weapons = {for (final w in weapons) w.id: w},
        _abilities = {for (final a in abilities) a.abilityId: a},
        _enhancements = {for (final e in enhancements) e.id: e},
        _compositions = {for (final c in compositions) c.unitId: c},
        _wargearOptions = wargearOptions.fold(
          <String, List<SourceWargearOption>>{},
          (map, option) =>
              map..putIfAbsent(option.unitId, () => []).add(option),
        ),
        _phases = {
          for (final m in phaseMappings)
            if (m.phases.isNotEmpty) m.sourceId: m.phases,
        },
        _attachments = {
          for (final a in leaderAttachments) a.leaderId: a.eligibleBodyguardIds,
        };

  /// Builds a catalogue over a loaded faction snapshot.
  factory MapCatalogue.ofFaction(FactionData faction) => MapCatalogue(
        faction.units,
        detachments: faction.detachments,
        weapons: faction.weapons,
        leaderAttachments: faction.leaderAttachments,
        phaseMappings: faction.phaseMappings,
        abilities: faction.abilities,
        enhancements: faction.enhancements,
        compositions: faction.compositions,
        wargearOptions: faction.wargearOptions,
      );

  @override
  SourceUnit? unit(String datasheetId) => _units[datasheetId];

  @override
  SourceAbility? ability(String abilityId) => _abilities[abilityId];

  @override
  Iterable<SourceEnhancement> get enhancements => _enhancements.values;

  @override
  UnitComposition? composition(String datasheetId) =>
      _compositions[datasheetId];

  @override
  List<SourceWargearOption> wargearOptions(String datasheetId) =>
      _wargearOptions[datasheetId] ?? const [];

  @override
  Iterable<SourceUnit> get allUnits => _units.values;

  @override
  Iterable<SourceDetachment> get allDetachments => _detachments.values;

  @override
  SourceDetachment? detachment(String detachmentId) =>
      _detachments[detachmentId];

  @override
  SourceWeapon? weapon(String weaponId) => _weapons[weaponId];

  @override
  List<String> eligibleBodyguards(String leaderDatasheetId) =>
      _attachments[leaderDatasheetId] ?? const [];

  late final Set<String> _leadable = {
    for (final bodyguards in _attachments.values) ...bodyguards,
  };

  @override
  bool canBeLed(String datasheetId) => _leadable.contains(datasheetId);

  @override
  List<String> phasesFor(String abilityId) => _phases[abilityId] ?? const [];

  @override
  List<String> dispositionsOf(String detachmentId) =>
      detachment(detachmentId)?.forceDispositions ?? const [];

  @override
  SourceWeapon? weaponFor(SourceUnit unit, String itemId) {
    final scoped = '$itemId-${unit.id}';
    if (unit.weaponIds.contains(scoped)) return weapon(scoped);
    if (unit.weaponIds.contains(itemId)) return weapon(itemId);
    return null;
  }
}

extension CombatUnitLabel on Catalogue {
  /// A combat unit as a player names it at the table.
  ///
  /// The character leads, so it is named first and the unit it joined follows:
  /// *Commander in Enforcer Battlesuit with Crisis Fireknife Battlesuits*. An
  /// earlier `A + B` read as two units rather than the one they fight as.
  String labelFor(Iterable<RosterUnit> group) {
    final names = [
      for (final rosterUnit in group)
        unit(rosterUnit.datasheetId)?.name ?? rosterUnit.datasheetId,
    ];
    if (names.isEmpty) return '';
    if (names.length == 1) return names.first;
    return '${names.first} with ${names.skip(1).join(' and ')}';
  }
}
