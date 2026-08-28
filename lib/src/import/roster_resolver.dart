/// Turns a [ParsedList] into a [Roster] against a catalogue (DESIGN.md §6.1).
///
/// All catalogue knowledge lives here, so parsers stay purely syntactic. The
/// central job is the classification the text format cannot express: deciding
/// whether a depth-1 node is a **model** or a **weapon**, which only the
/// datasheet knows (§6.7).
///
/// Matching is always **scoped to one datasheet's own vocabulary** — its model
/// profiles and its weapons — never the whole faction. That is what turns a
/// guessing game into a decision between a handful of candidates.
library;

import '../roster/roster.dart';
import '../rules/battle_size.dart';
import '../rules/catalogue.dart';
import '../source/source_models.dart';
import 'name_match.dart';
import 'parsed_list.dart';

enum IssueSeverity { error, warning, info }

class ResolutionIssue {
  final IssueSeverity severity;
  final String message;

  /// Source line, so the review screen can point at the offending text.
  final int line;

  const ResolutionIssue({
    required this.severity,
    required this.message,
    this.line = 0,
  });

  @override
  String toString() =>
      '[${severity.name}]${line > 0 ? ' line $line:' : ''} $message';
}

class ImportResult {
  final Roster roster;
  final List<ResolutionIssue> issues;

  /// Points as printed in the source, for cross-checking against the computed
  /// total. A mismatch means the importer or the dataset disagrees with the
  /// tool that produced the list, and the user should be told.
  final int? printedPoints;

  const ImportResult({
    required this.roster,
    required this.issues,
    this.printedPoints,
  });

  List<ResolutionIssue> get errors =>
      issues.where((i) => i.severity == IssueSeverity.error).toList();

  bool get isClean => errors.isEmpty;
}

class RosterResolver {
  final Catalogue catalogue;

  /// Optional ability lookup. Used only to recognise entries that are wargear
  /// in the printed list but abilities in the data — drones, mostly — so they
  /// are accepted rather than reported as unresolved.
  final SourceAbility? Function(String abilityId)? abilityLookup;

  /// Every ability in the faction. Used to tell a dataset *attachment gap*
  /// apart from a genuine miss: `Marker Drone` is a real ability that simply
  /// is not listed on Stealth Battlesuits, which is worth an info line, not a
  /// warning that something went wrong.
  final Iterable<SourceAbility> knownAbilities;

  const RosterResolver(
    this.catalogue, {
    this.abilityLookup,
    this.knownAbilities = const [],
  });

  ImportResult resolve(ParsedList parsed, {required String factionId}) {
    final issues = <ResolutionIssue>[];

    for (final line in parsed.unparsedLines) {
      issues.add(ResolutionIssue(
        severity: IssueSeverity.warning,
        message: 'Ignored unrecognised line: "${line.trim()}"',
      ));
    }

    final battleSize = _resolveBattleSize(parsed, issues);
    final detachments = _resolveDetachments(parsed, issues);

    final units = <RosterUnit>[];
    final links = <RosterLink>[];
    final chosenEnhancements = <({String id, String instanceId})>[];
    final groups = <String, List<String>>{};
    String? warlord;
    var index = 0;

    for (final parsedUnit in parsed.units) {
      index++;
      final instanceId = 'u${index.toString().padLeft(2, '0')}';

      final match = bestMatch<SourceUnit>(
        parsedUnit.name,
        catalogue.allUnits,
        (u) => u.name,
        threshold: 0.6,
      );

      if (match == null) {
        issues.add(ResolutionIssue(
          severity: IssueSeverity.error,
          message: 'No datasheet matches "${parsedUnit.name}"',
          line: parsedUnit.line,
        ));
        continue;
      }
      if (match.score < 0.99) {
        issues.add(ResolutionIssue(
          severity: IssueSeverity.info,
          message: '"${parsedUnit.name}" matched ${match.value.name}',
          line: parsedUnit.line,
        ));
      }

      final datasheet = match.value;
      final resolved = _resolveUnit(datasheet, parsedUnit, issues);
      for (final enhancementId in resolved.enhancementIds) {
        chosenEnhancements.add((id: enhancementId, instanceId: instanceId));
      }

      // No customName: the attachment group is bookkeeping from the export
      // format, not something the player named the unit. Putting it here made
      // every attached unit show up as "Attached Unit 2" on the play screen
      // instead of the datasheets it is actually made of. The grouping itself
      // is carried by [groups] below.
      units.add(RosterUnit(
        instanceId: instanceId,
        datasheetId: datasheet.id,
        models: resolved.models,
        wargear: resolved.wargear,
      ));

      if (parsedUnit.isWarlord) warlord = instanceId;
      final group = parsedUnit.attachmentGroup;
      if (group != null) {
        groups.putIfAbsent(group, () => []).add(instanceId);
      }
    }

    // A bracketed group is a leader plus what it joined. The leader is the
    // member the data says can lead the other (§6.5).
    for (final entry in groups.entries) {
      final members = entry.value;
      if (members.length < 2) continue;
      if (members.length > 2) {
        issues.add(ResolutionIssue(
          severity: IssueSeverity.warning,
          message: '${entry.key} has ${members.length} units; '
              'only leader/bodyguard pairs are linked automatically',
        ));
        continue;
      }

      final a = units.firstWhere((u) => u.instanceId == members[0]);
      final b = units.firstWhere((u) => u.instanceId == members[1]);
      final aLeads = catalogue
          .eligibleBodyguards(a.datasheetId)
          .contains(b.datasheetId);
      final bLeads = catalogue
          .eligibleBodyguards(b.datasheetId)
          .contains(a.datasheetId);

      if (aLeads || bLeads) {
        final leader = aLeads ? a : b;
        final bodyguard = aLeads ? b : a;
        links.add(RosterLink(
          type: LinkType.leads,
          fromInstanceId: leader.instanceId,
          toInstanceId: bodyguard.instanceId,
        ));
      } else {
        issues.add(ResolutionIssue(
          severity: IssueSeverity.warning,
          message: '${entry.key}: neither unit may lead the other, '
              'so no attachment was created',
        ));
      }
    }

    if (warlord == null && units.isNotEmpty) {
      issues.add(const ResolutionIssue(
        severity: IssueSeverity.warning,
        message: 'No Warlord marked in the source; nominate one',
      ));
    }

    // An Enhancement goes on one Character; a Unit Upgrade may go on several,
    // and the three of them share a slot — so upgrades are grouped by id and
    // enhancements are not (§2.1).
    final enhancementSelections = <EnhancementSelection>[];
    final upgradeTargets = <String, List<String>>{};
    for (final chosen in chosenEnhancements) {
      if (_enhancement(chosen.id)?.isUpgrade ?? false) {
        (upgradeTargets[chosen.id] ??= []).add(chosen.instanceId);
      } else {
        enhancementSelections.add(EnhancementSelection(
          enhancementId: chosen.id,
          targetInstanceId: chosen.instanceId,
        ));
      }
    }

    return ImportResult(
      printedPoints: parsed.printedPoints,
      issues: issues,
      roster: Roster(
        name: parsed.name ?? 'Imported list',
        factionId: factionId,
        battleSizeId: battleSize?.id ?? BattleSize.strikeForce.id,
        detachments: detachments,
        declaredDisposition: _slug(parsed.disposition),
        units: units,
        links: links,
        enhancements: enhancementSelections,
        upgrades: [
          for (final entry in upgradeTargets.entries)
            UpgradeSelection(
              upgradeId: entry.key,
              targetInstanceIds: entry.value,
            ),
        ],
        warlordInstanceId: warlord,
      ),
    );
  }

  BattleSize? _resolveBattleSize(
      ParsedList parsed, List<ResolutionIssue> issues) {
    final name = parsed.battleSizeName;
    if (name != null) {
      final match =
          bestMatch<BattleSize>(name, BattleSize.all, (b) => b.name);
      if (match != null) return match.value;
    }
    issues.add(ResolutionIssue(
      severity: IssueSeverity.warning,
      message: 'Battle size "${name ?? 'unspecified'}" not recognised; '
          'defaulting to Strike Force',
    ));
    return null;
  }

  List<RosterDetachment> _resolveDetachments(
      ParsedList parsed, List<ResolutionIssue> issues) {
    final out = <RosterDetachment>[];
    for (final name in parsed.detachmentNames) {
      final match = bestMatch<SourceDetachment>(
        name,
        catalogue.allDetachments,
        (d) => d.name,
        threshold: 0.6,
      );
      if (match == null) {
        issues.add(ResolutionIssue(
          severity: IssueSeverity.error,
          message: 'No detachment matches "$name"',
        ));
        continue;
      }
      out.add(RosterDetachment(detachmentId: match.value.id));
    }
    return out;
  }

  _ResolvedUnit _resolveUnit(
    SourceUnit datasheet,
    ParsedUnit parsedUnit,
    List<ResolutionIssue> issues,
  ) {
    // Scoped vocabularies. Weapons are keyed by the *item id* the roster will
    // store, which is the weapon id with any `-<unitId>` suffix removed so
    // Catalogue.weaponFor can re-scope it (§7.3.5).
    final weaponCandidates = <_Candidate>[];
    for (final weaponId in datasheet.weaponIds) {
      final weapon = catalogue.weapon(weaponId);
      if (weapon == null) continue;
      final suffix = '-${datasheet.id}';
      final itemId =
          weaponId.endsWith(suffix)
              ? weaponId.substring(0, weaponId.length - suffix.length)
              : weaponId;
      weaponCandidates.add(_Candidate(itemId, weapon.name));
    }

    // Everything the datasheet can carry that is not a weapon, keyed by id.
    // A drone is wargear on the printed list and an ability in the data
    // (§7.3.7), so matching one has to yield something the roster can store,
    // not just a yes/no.
    //
    // Budget lines count, not only `ability_ids`. BSData reaches a Commander's
    // drones through a `Drones (0-2)` wargear group, so they are budgeted
    // rather than innate — and matching abilities alone stopped finding them
    // the moment that distinction was recorded properly (§3.10).
    final abilityCandidates = <_Candidate>[
      for (final id in {
        ...datasheet.abilityIds,
        for (final budget in datasheet.wargearBudgets) ...budget.items,
      })
        _Candidate(id, abilityLookup?.call(id)?.name ?? id.replaceAll('-', ' ')),
    ];

    final modelNodes = <ParsedNode>[];
    final wargearNodes = <ParsedNode>[];

    for (final node in parsedUnit.nodes) {
      if (node.name.toLowerCase() == 'warlord') continue;

      // Children settle it: only a model group has weapons beneath it.
      if (node.hasChildren) {
        modelNodes.add(node);
        continue;
      }

      final asModel = datasheet.profiles.isEmpty
          ? 0.0
          : datasheet.profiles
              .map((p) => scoreName(node.name, p.name))
              .reduce((a, b) => a > b ? a : b);
      final asWeapon = weaponCandidates.isEmpty
          ? 0.0
          : weaponCandidates
              .map((c) => scoreName(node.name, c.name))
              .reduce((a, b) => a > b ? a : b);

      if (asModel > asWeapon && asModel >= 0.6) {
        modelNodes.add(node);
      } else {
        wargearNodes.add(node);
      }
    }

    final models = modelNodes.isNotEmpty
        ? modelNodes.fold(0, (sum, n) => sum + n.count)
        : (datasheet.profiles.length == 1
            ? _defaultModels(datasheet)
            : _defaultModels(datasheet));

    // Depth-2 counts are totals for their model group, so they add directly.
    final flat = <ParsedNode>[
      ...wargearNodes,
      for (final group in modelNodes) ...group.children,
    ];

    // `• Enhancement: Negation Emitters` is not wargear — it is a roster-level
    // selection that costs points there. Recognised before tallying, or it
    // fuzzy-matches the ability of the same name and is then discarded.
    final enhancementIds = <String>[];
    final remaining = <ParsedNode>[];
    for (final node in flat) {
      final id = _enhancementFor(node.name, datasheet, issues);
      if (id != null) {
        enhancementIds.add(id);
      } else {
        remaining.add(node);
      }
    }

    final tally = <String, int>{};
    for (final node in remaining) {
      _tallyWargear(
        node: node,
        datasheet: datasheet,
        candidates: weaponCandidates,
        abilityCandidates: abilityCandidates,
        tally: tally,
        issues: issues,
      );
    }

    return _ResolvedUnit(
      models: models,
      wargear: [
        for (final entry in tally.entries)
          WargearSelection(itemId: entry.key, count: entry.value),
      ],
      enhancementIds: enhancementIds,
    );
  }

  void _tallyWargear({
    required ParsedNode node,
    required SourceUnit datasheet,
    required List<_Candidate> candidates,
    required List<_Candidate> abilityCandidates,
    required Map<String, int> tally,
    required List<ResolutionIssue> issues,
  }) {
    // `X with Y` names a thing and what it carries, and the thing is the one
    // the roster records: a Gun Drone with a twin pulse carbine is a drone,
    // not a carbine (§3.8). This runs *before* the whole-string match because
    // BSData lists the drone's own gun on the datasheet, so the full string
    // matched `Twin pulse carbine` outright and the split that would have
    // found the drone never ran. Only a leading part that names an ability
    // counts, so a weapon legitimately called "... with ..." is unaffected.
    // `X with Y and Z` is one line naming two things a model carries: the
    // export writes "Gun Drone With Twin Pulse Carbine and Shield Drone" for a
    // suit that has both. Matching the carrier alone recorded the gun drone
    // and silently lost the shield drone.
    if (_carrierOf(node.name, abilityCandidates) != null) {
      var any = false;
      for (final part in splitCompound(node.name)) {
        final id = _carrierOf(part, abilityCandidates) ??
            _abilityFor(part, abilityCandidates) ??
            bestMatch<_Candidate>(part, candidates, (c) => c.name,
                    threshold: 0.7)
                ?.value
                .id;
        if (id == null) continue;
        tally.update(id, (n) => n + node.count, ifAbsent: () => node.count);
        any = true;
      }
      if (any) return;
    }

    final direct = bestMatch<_Candidate>(
      node.name,
      candidates,
      (c) => c.name,
      threshold: 0.7,
    );
    if (direct != null) {
      tally.update(direct.value.id, (n) => n + node.count,
          ifAbsent: () => node.count);
      return;
    }

    // Compound entries such as "Gun Drone With Twin Pulse Carbine and Shield
    // Drone" only get split after the whole string fails, because real weapon
    // names contain "and".
    final parts = splitCompound(node.name);
    if (parts.length > 1) {
      var any = false;
      for (final part in parts) {
        final match = bestMatch<_Candidate>(part, candidates, (c) => c.name,
            threshold: 0.7);
        if (match != null) {
          tally.update(match.value.id, (n) => n + node.count,
              ifAbsent: () => node.count);
          any = true;
        } else if (_abilityFor(part, abilityCandidates) case final id?) {
          tally.update(id, (n) => n + node.count, ifAbsent: () => node.count);
          any = true;
        }
      }
      if (any) return;
    }

    // Drones and support systems are wargear on the printed list but
    // abilities in the data. They are **recorded**, not merely acknowledged:
    // a Gun Drone is a twin pulse carbine the unit actually fires, and a
    // Shield Drone is a wound it actually has. Discarding them left the play
    // screen showing every drone the datasheet *could* take and none of the
    // weapons they bring.
    if (_abilityFor(node.name, abilityCandidates) case final id?) {
      tally.update(id, (n) => n + node.count, ifAbsent: () => node.count);
      return;
    }

    // Known to the faction but not attached to this datasheet: an upstream
    // data gap rather than an import failure. It costs no points and does not
    // affect the weapon table, so it is reported without alarm.
    final elsewhere = bestMatch<SourceAbility>(
      node.name,
      knownAbilities,
      (a) => a.name,
      threshold: 0.7,
    );
    if (elsewhere != null) {
      issues.add(ResolutionIssue(
        severity: IssueSeverity.info,
        message: '${datasheet.name}: "${node.name}" is the '
            '${elsewhere.value.name} ability, which this datasheet does not '
            'list in the dataset',
        line: node.line,
      ));
      return;
    }

    issues.add(ResolutionIssue(
      severity: IssueSeverity.warning,
      message: '${datasheet.name}: could not place "${node.name}"',
      line: node.line,
    ));
  }

  static final _enhancementPrefix =
      RegExp(r'^\s*(enhancement|upgrade)\s*[:\-]\s*', caseSensitive: false);

  SourceEnhancement? _enhancement(String id) {
    for (final enhancement in catalogue.enhancements) {
      if (enhancement.id == id) return enhancement;
    }
    return null;
  }

  /// The Enhancement or Unit Upgrade a `Enhancement: X` line names.
  ///
  /// Only lines carrying the prefix are considered. Matching every wargear
  /// line against the enhancement list would let a weapon named like one slip
  /// through and quietly add points.
  String? _enhancementFor(
    String name,
    SourceUnit datasheet,
    List<ResolutionIssue> issues,
  ) {
    if (!_enhancementPrefix.hasMatch(name)) return null;
    final wanted = name.replaceFirst(_enhancementPrefix, '').trim();
    if (wanted.isEmpty) return null;

    // The data suffixes a Unit Upgrade's name — `Negation Emitters (Upgrade)`
    // — where the export writes it plain, so both forms are tried.
    final match = bestMatch<SourceEnhancement>(
      wanted,
      catalogue.enhancements,
      (e) => e.name,
      threshold: 0.7,
    ) ??
        bestMatch<SourceEnhancement>(
          wanted,
          catalogue.enhancements,
          (e) => e.name.replaceAll(RegExp(r'\s*\([^)]*\)'), '').trim(),
          threshold: 0.7,
        );

    if (match == null) {
      issues.add(ResolutionIssue(
        severity: IssueSeverity.warning,
        message: '${datasheet.name}: no Enhancement matches "$wanted"',
      ));
      // Consumed regardless: it is not wargear, and leaving it to the wargear
      // tally would report it as unresolved kit instead.
      return null;
    }
    return match.value.id;
  }

  /// The id of the datasheet ability [name] refers to, if any.
  /// The ability named before a `with`, when the string is `X with Y`.
  ///
  /// Returns null when there is no `with`, or when what precedes it is not an
  /// ability this datasheet has — which is what keeps a weapon whose printed
  /// name contains "with" resolving as a weapon.
  String? _carrierOf(String name, List<_Candidate> abilityCandidates) {
    final split = RegExp(r'\s+with\s+', caseSensitive: false).firstMatch(name);
    if (split == null) return null;
    final head = name.substring(0, split.start).trim();
    if (head.isEmpty) return null;
    return _abilityFor(head, abilityCandidates);
  }

  String? _abilityFor(String name, List<_Candidate> candidates) =>
      bestMatch<_Candidate>(name, candidates, (c) => c.name, threshold: 0.7)
          ?.value
          .id;

  int _defaultModels(SourceUnit datasheet) {
    for (final bracket in datasheet.points) {
      if (bracket.models > 0) return bracket.models;
    }
    return 1;
  }

  String? _slug(String? value) {
    if (value == null) return null;
    final n = normalise(value);
    return n.isEmpty ? null : n.replaceAll(' ', '-');
  }
}

class _Candidate {
  final String id;
  final String name;

  const _Candidate(this.id, this.name);
}

class _ResolvedUnit {
  final int models;
  final List<WargearSelection> wargear;

  /// Enhancements and Unit Upgrades written on this unit's entry. Kept apart
  /// from wargear because they live at roster level and cost points there.
  final List<String> enhancementIds;

  const _ResolvedUnit({
    required this.models,
    required this.wargear,
    this.enhancementIds = const [],
  });
}
