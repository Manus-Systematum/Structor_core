/// User-owned roster model (DESIGN.md §2.2).
///
/// Two shapes deserve attention because both were arrived at the hard way:
///
///   - **Detachments are a list**, not a field. 11e buys multiple detachments
///     from a Detachment Points budget.
///   - **Attachments are explicit edges**, not nesting. A Commander leading a
///     Crisis squad is two units plus a `LEADS` link, because the play screen
///     needs them as one combat unit while the builder prices them separately.
library;

import '../source/json.dart';

enum LinkType { leads, embarkedIn }

class RosterLink {
  final LinkType type;
  final String fromInstanceId;
  final String toInstanceId;

  const RosterLink({
    required this.type,
    required this.fromInstanceId,
    required this.toInstanceId,
  });

  factory RosterLink.fromJson(Object? v) {
    final j = asMap(v);
    return RosterLink(
      type: strOr(j['type'], 'LEADS') == 'EMBARKED_IN'
          ? LinkType.embarkedIn
          : LinkType.leads,
      fromInstanceId: strOr(j['from'], ''),
      toInstanceId: strOr(j['to'], ''),
    );
  }

  Map<String, Object?> toJson() => {
        'type': type == LinkType.embarkedIn ? 'EMBARKED_IN' : 'LEADS',
        'from': fromInstanceId,
        'to': toInstanceId,
      };
}

/// A chosen wargear item and how many instances the unit carries.
///
/// Instances are counted rather than individually addressed. DESIGN.md §7.3.6
/// notes that per-weapon-instance modifiers will eventually need addressable
/// instances; that is a deliberate later change, flagged here so it is not a
/// surprise.
class WargearSelection {
  final String itemId;
  final int count;

  const WargearSelection({required this.itemId, required this.count});

  factory WargearSelection.fromJson(Object? v) {
    final j = asMap(v);
    return WargearSelection(
      itemId: strOr(j['itemId'], ''),
      count: intOr(j['count'], 0),
    );
  }

  Map<String, Object?> toJson() => {'itemId': itemId, 'count': count};
}

class RosterUnit {
  final String instanceId;
  final String datasheetId;
  final String? customName;
  final int models;
  final List<WargearSelection> wargear;

  const RosterUnit({
    required this.instanceId,
    required this.datasheetId,
    required this.models,
    this.customName,
    this.wargear = const [],
  });

  factory RosterUnit.fromJson(Object? v) {
    final j = asMap(v);
    return RosterUnit(
      instanceId: strOr(j['instanceId'], ''),
      datasheetId: strOr(j['datasheetId'], ''),
      customName: str(j['customName']),
      models: intOr(j['models'], 1),
      wargear: asList(j['wargear'])
          .map(WargearSelection.fromJson)
          .toList(growable: false),
    );
  }

  Map<String, Object?> toJson() => {
        'instanceId': instanceId,
        'datasheetId': datasheetId,
        if (customName != null) 'customName': customName,
        'models': models,
        if (wargear.isNotEmpty)
          'wargear': wargear.map((w) => w.toJson()).toList(),
      };

  int countOf(String itemId) => wargear
      .where((w) => w.itemId == itemId)
      .fold(0, (sum, w) => sum + w.count);

  RosterUnit copyWith({
    int? models,
    List<WargearSelection>? wargear,
    String? customName,
  }) =>
      RosterUnit(
        instanceId: instanceId,
        datasheetId: datasheetId,
        customName: customName ?? this.customName,
        models: models ?? this.models,
        wargear: wargear ?? this.wargear,
      );
}

/// An Enhancement: one slot, one **Character**, points once.
class EnhancementSelection {
  final String enhancementId;
  final String targetInstanceId;

  const EnhancementSelection({
    required this.enhancementId,
    required this.targetInstanceId,
  });

  factory EnhancementSelection.fromJson(Object? v) {
    final j = asMap(v);
    return EnhancementSelection(
      enhancementId: strOr(j['enhancementId'], ''),
      targetInstanceId: strOr(j['target'], ''),
    );
  }

  Map<String, Object?> toJson() =>
      {'enhancementId': enhancementId, 'target': targetInstanceId};
}

/// A Unit Upgrade: **one slot total** for up to three non-Character targets,
/// with points paid per instance. Distinct from [EnhancementSelection] —
/// modelling it as an enhancement variant miscounts every list using one
/// (DESIGN.md §2.1).
class UpgradeSelection {
  final String upgradeId;
  final List<String> targetInstanceIds;

  const UpgradeSelection({
    required this.upgradeId,
    required this.targetInstanceIds,
  });

  factory UpgradeSelection.fromJson(Object? v) {
    final j = asMap(v);
    return UpgradeSelection(
      upgradeId: strOr(j['upgradeId'], ''),
      targetInstanceIds: strList(j['targets']),
    );
  }

  Map<String, Object?> toJson() =>
      {'upgradeId': upgradeId, 'targets': targetInstanceIds};
}

class RosterDetachment {
  final String detachmentId;

  const RosterDetachment({required this.detachmentId});

  factory RosterDetachment.fromJson(Object? v) =>
      RosterDetachment(detachmentId: strOr(asMap(v)['detachmentId'], ''));

  Map<String, Object?> toJson() => {'detachmentId': detachmentId};
}

class Roster {
  final int schemaVersion;
  final String name;
  final String factionId;
  final String battleSizeId;
  final int? pointsLimitOverride;
  final List<RosterDetachment> detachments;

  /// The disposition the army declares. With more than one detachment this is
  /// a *choice* among the detachments' dispositions, and it selects the primary
  /// mission (DESIGN.md §7.3.1).
  final String? declaredDisposition;

  final List<RosterUnit> units;
  final List<EnhancementSelection> enhancements;
  final List<UpgradeSelection> upgrades;
  final List<RosterLink> links;
  final String? warlordInstanceId;

  const Roster({
    required this.name,
    required this.factionId,
    required this.battleSizeId,
    required this.units,
    this.schemaVersion = 1,
    this.pointsLimitOverride,
    this.detachments = const [],
    this.declaredDisposition,
    this.enhancements = const [],
    this.upgrades = const [],
    this.links = const [],
    this.warlordInstanceId,
  });

  factory Roster.fromJson(Object? v) {
    final j = asMap(v);
    return Roster(
      schemaVersion: intOr(j['schemaVersion'], 1),
      name: strOr(j['name'], '(untitled)'),
      factionId: strOr(j['factionId'], ''),
      battleSizeId: strOr(j['battleSizeId'], ''),
      pointsLimitOverride: asInt(j['pointsLimitOverride']),
      detachments: asList(j['detachments'])
          .map(RosterDetachment.fromJson)
          .toList(growable: false),
      declaredDisposition: str(j['declaredDisposition']),
      units:
          asList(j['units']).map(RosterUnit.fromJson).toList(growable: false),
      enhancements: asList(j['enhancements'])
          .map(EnhancementSelection.fromJson)
          .toList(growable: false),
      upgrades: asList(j['upgrades'])
          .map(UpgradeSelection.fromJson)
          .toList(growable: false),
      links:
          asList(j['links']).map(RosterLink.fromJson).toList(growable: false),
      warlordInstanceId: str(j['warlordInstanceId']),
    );
  }

  Map<String, Object?> toJson() => {
        'schemaVersion': schemaVersion,
        'name': name,
        'factionId': factionId,
        'battleSizeId': battleSizeId,
        if (pointsLimitOverride != null)
          'pointsLimitOverride': pointsLimitOverride,
        'detachments': detachments.map((d) => d.toJson()).toList(),
        if (declaredDisposition != null)
          'declaredDisposition': declaredDisposition,
        'units': units.map((u) => u.toJson()).toList(),
        if (enhancements.isNotEmpty)
          'enhancements': enhancements.map((e) => e.toJson()).toList(),
        if (upgrades.isNotEmpty)
          'upgrades': upgrades.map((u) => u.toJson()).toList(),
        if (links.isNotEmpty) 'links': links.map((l) => l.toJson()).toList(),
        if (warlordInstanceId != null) 'warlordInstanceId': warlordInstanceId,
      };

  /// A changed copy. Everything here is immutable, so the editor works by
  /// producing new rosters and the caller can hold on to the old one — which
  /// is what makes undo and "points before I commit" the same mechanism.
  ///
  /// [clearWarlordIf] exists because `warlordInstanceId: null` cannot be told
  /// apart from "not passed"; deleting the Warlord's unit has to be able to
  /// clear it.
  Roster copyWith({
    String? name,
    String? factionId,
    String? battleSizeId,
    int? pointsLimitOverride,
    List<RosterDetachment>? detachments,
    String? declaredDisposition,
    List<RosterUnit>? units,
    List<EnhancementSelection>? enhancements,
    List<UpgradeSelection>? upgrades,
    List<RosterLink>? links,
    String? warlordInstanceId,
    bool clearWarlordIf = false,
  }) =>
      Roster(
        schemaVersion: schemaVersion,
        name: name ?? this.name,
        factionId: factionId ?? this.factionId,
        battleSizeId: battleSizeId ?? this.battleSizeId,
        pointsLimitOverride: pointsLimitOverride ?? this.pointsLimitOverride,
        detachments: detachments ?? this.detachments,
        declaredDisposition: declaredDisposition ?? this.declaredDisposition,
        units: units ?? this.units,
        enhancements: enhancements ?? this.enhancements,
        upgrades: upgrades ?? this.upgrades,
        links: links ?? this.links,
        warlordInstanceId: clearWarlordIf
            ? null
            : (warlordInstanceId ?? this.warlordInstanceId),
      );

  RosterUnit? unitByInstance(String instanceId) {
    for (final u in units) {
      if (u.instanceId == instanceId) return u;
    }
    return null;
  }

  /// 1-based index of [unit] among units sharing its datasheet, in roster
  /// order. Pricing depends on this: the third Crisis Fireknife costs more
  /// than the first (DESIGN.md §2.1).
  int copyIndexOf(RosterUnit unit) {
    var index = 0;
    for (final u in units) {
      if (u.datasheetId == unit.datasheetId) {
        index++;
        if (identical(u, unit) || u.instanceId == unit.instanceId) return index;
      }
    }
    return index == 0 ? 1 : index;
  }

  /// Units grouped into combat units by `LEADS` edges: a leader and the unit it
  /// joins are one entry, headed by the leader.
  List<List<RosterUnit>> combatUnits() {
    // **A unit can be joined by a Leader and a Support at once**, so this is
    // one bodyguard to *many* characters. Keyed the other way round it kept
    // only the last link, and a squad with both characters split into two
    // combat units — the squad with one of them, and the other standing
    // alone, priced and drawn as though it were its own unit.
    final joinedBy = <String, List<String>>{};
    for (final link in links) {
      if (link.type == LinkType.leads) {
        (joinedBy[link.toInstanceId] ??= []).add(link.fromInstanceId);
      }
    }
    final characters = {for (final ids in joinedBy.values) ...ids};

    final groups = <List<RosterUnit>>[];
    final consumed = <String>{};

    for (final unit in units) {
      if (consumed.contains(unit.instanceId)) continue;
      // Bodyguards are emitted from the first character that joins them.
      if (joinedBy.containsKey(unit.instanceId)) continue;

      if (characters.contains(unit.instanceId)) {
        final bodyguardId = joinedBy.entries
            .firstWhere((e) => e.value.contains(unit.instanceId))
            .key;
        // Characters in roster order, then the unit they joined, so the
        // label still reads "<character> with <squad>" (§3.7).
        final group = [
          for (final member in units)
            if (joinedBy[bodyguardId]!.contains(member.instanceId) &&
                consumed.add(member.instanceId))
              member,
        ];
        final bodyguard = unitByInstance(bodyguardId);
        if (bodyguard != null && consumed.add(bodyguardId)) {
          group.add(bodyguard);
        }
        groups.add(group);
        continue;
      }

      consumed.add(unit.instanceId);
      groups.add([unit]);
    }
    return groups;
  }
}
