/// A version-pinned, indexed content set (DESIGN.md §2.1).
///
/// This is the "domain layer" in the form that turned out to matter. The
/// original spec called for a wholesale renormalisation of the source, but that
/// was written when BSData — with its recursive links and modifier evaluation —
/// was the input. `40kdc-data` arrives already normalised, so re-shaping every
/// DTO would be motion without value.
///
/// What the layer does owe, and what this provides, is everything the raw
/// snapshot cannot:
///
///   - a **pinned version**, so a roster records the content it was built
///     against and a points update never silently mutates a saved list;
///   - **content addressing** for the QR payload (§6.4);
///   - **resolved per-battle-size limits**, computed once rather than at every
///     validation.
library;

import '../rules/battle_size.dart';
import '../rules/catalogue.dart';
import '../source/dataset_loader.dart';
import '../source/source_models.dart';
import 'content_hash.dart';

/// Identifies the content a roster was built against.
class DatasetVersion {
  final String source;
  final String revision;
  final String factionId;

  const DatasetVersion({
    required this.source,
    required this.revision,
    required this.factionId,
  });

  factory DatasetVersion.fromJson(Map<String, Object?> json) => DatasetVersion(
        source: json['source']?.toString() ?? '40kdc',
        revision: json['revision']?.toString() ?? 'unknown',
        factionId: json['factionId']?.toString() ?? '',
      );

  Map<String, Object?> toJson() =>
      {'source': source, 'revision': revision, 'factionId': factionId};

  @override
  String toString() => '$source@$revision/$factionId';
}

class Dataset implements Catalogue {
  final DatasetVersion version;
  final FactionData faction;

  final Map<String, SourceUnit> _units;
  final Map<String, SourceWeapon> _weapons;
  final Map<String, SourceDetachment> _detachments;
  final Map<String, SourceAbility> _abilities;
  final Map<String, List<String>> _attachments;
  final ContentHasher _hasher;

  Dataset._({
    required this.version,
    required this.faction,
    required Map<String, SourceUnit> units,
    required Map<String, SourceWeapon> weapons,
    required Map<String, SourceDetachment> detachments,
    required Map<String, SourceAbility> abilities,
    required Map<String, List<String>> attachments,
    required ContentHasher hasher,
  })  : _units = units,
        _weapons = weapons,
        _detachments = detachments,
        _abilities = abilities,
        _attachments = attachments,
        _hasher = hasher;

  factory Dataset.of(FactionData faction, {String revision = 'unknown'}) {
    final units = {for (final u in faction.units) u.id: u};
    final weapons = {for (final w in faction.weapons) w.id: w};
    final detachments = {for (final d in faction.detachments) d.id: d};
    final abilities = {for (final a in faction.abilities) a.abilityId: a};

    return Dataset._(
      version: DatasetVersion(
        source: '40kdc',
        revision: revision,
        factionId: faction.factionId,
      ),
      faction: faction,
      units: units,
      weapons: weapons,
      detachments: detachments,
      abilities: abilities,
      attachments: {
        for (final a in faction.leaderAttachments)
          a.leaderId: a.eligibleBodyguardIds,
      },
      // The addressable namespace: everything a roster can name.
      hasher: ContentHasher([
        ...units.keys,
        ...weapons.keys,
        ...detachments.keys,
        ...faction.enhancementIds,
      ]),
    );
  }

  // ------------------------------------------------------------- Catalogue

  @override
  SourceUnit? unit(String datasheetId) => _units[datasheetId];

  @override
  Iterable<SourceUnit> get allUnits => _units.values;

  /// The datasheets a matched-play army may be built from.
  ///
  /// Separate from [allUnits] rather than a filter over it, because lookup by
  /// id must keep working: a roster saved before this existed, or imported
  /// from somewhere else, still has to resolve every datasheet it names. This
  /// narrows what is *offered*, not what can be read.
  Iterable<SourceUnit> get buildableUnits =>
      _units.values.where((u) => u.isMatchedPlay);

  @override
  Iterable<SourceDetachment> get allDetachments => _detachments.values;

  /// The detachments a matched-play army may be built from.
  ///
  /// Separate from [allDetachments] for the same reason [buildableUnits] is
  /// separate from [allUnits]: a roster that already names a Combat Patrol
  /// detachment must still resolve it. This narrows what is *offered*.
  Iterable<SourceDetachment> get buildableDetachments =>
      _detachments.values.where((d) => d.isMatchedPlay);

  @override
  SourceWeapon? weapon(String weaponId) => _weapons[weaponId];

  @override
  SourceDetachment? detachment(String detachmentId) =>
      _detachments[detachmentId];

  @override
  List<String> eligibleBodyguards(String leaderDatasheetId) =>
      _attachments[leaderDatasheetId] ?? const [];

  late final Set<String> _leadable = {
    for (final bodyguards in _attachments.values) ...bodyguards,
  };

  @override
  bool canBeLed(String datasheetId) => _leadable.contains(datasheetId);

  late final Map<String, List<String>> _phases = {
    for (final m in faction.phaseMappings)
      if (m.phases.isNotEmpty) m.sourceId: m.phases,
  };

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

  @override
  SourceAbility? ability(String abilityId) => _abilities[abilityId];

  @override
  Iterable<SourceEnhancement> get enhancements => faction.enhancements;

  @override
  List<SourceWargearOption> wargearOptions(String datasheetId) => [
        for (final option in faction.wargearOptions)
          if (option.unitId == datasheetId) option,
      ];

  @override
  UnitComposition? composition(String datasheetId) {
    for (final c in faction.compositions) {
      if (c.unitId == datasheetId) return c;
    }
    return null;
  }

  // -------------------------------------------------------- addressing

  int hashOf(String contentId) => _hasher.hashOf(contentId);

  String? resolveHash(int hash) => _hasher.resolve(hash);

  /// Ids sharing a 24-bit hash. Must be empty before the QR format of §6.4 can
  /// rely on three-byte identifiers for this faction.
  List<List<String>> get hashCollisions => _hasher.collisions;

  int get addressableIds => _hasher.size;

  // ------------------------------------------------------------- limits

  /// Copies of [datasheetId] permitted at [battleSize], accounting for the
  /// Battleline / Dedicated Transport doubling and Epic Hero uniqueness.
  /// Resolved here so validation reads a number instead of recomputing rules.
  int maxCopies(String datasheetId, BattleSize battleSize) {
    final datasheet = unit(datasheetId);
    if (datasheet == null) return battleSize.maxCopies;
    if (datasheet.isEpicHero) return 1;
    return battleSize.capFor(isBattlelineOrTransport: datasheet.hasDoubledCap);
  }

  /// True when any content in this dataset is still on a provisional
  /// dataslate. The UI must surface this rather than present it as current
  /// (§3.0).
  bool get hasProvisionalContent =>
      faction.units.any((u) => u.gameVersion.isProvisional) ||
      faction.stratagems.any((s) => s.gameVersion.isProvisional);
}
