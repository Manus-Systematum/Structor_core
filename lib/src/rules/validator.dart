/// Roster validation for 11th edition (DESIGN.md §2.3).
///
/// Every result is a [ValidationFinding] with a severity, and **nothing is ever
/// blocked**. People build illegal lists deliberately — narrative games, works
/// in progress, proxies — so the engine reports and the user decides.
///
/// All numeric limits come from [BattleSize] and the catalogue, never from
/// constants inline: 11e scales points, Detachment Points, enhancement slots
/// and duplicate caps with game size, so a hardcoded "rule of three" would be
/// wrong at two of the three battle sizes.
library;

import '../roster/points.dart';
import '../roster/roster.dart';
import 'battle_size.dart';
import 'catalogue.dart';
import '../roster/unit_loadout.dart';

enum Severity { error, warning, info }

class ValidationFinding {
  /// Stable machine-readable identifier, so the UI can attach its own copy and
  /// tests can assert without matching prose.
  final String code;
  final String message;
  final Severity severity;

  /// Roster units the finding concerns, for highlighting in the builder.
  final List<String> instanceIds;

  const ValidationFinding({
    required this.code,
    required this.message,
    required this.severity,
    this.instanceIds = const [],
  });

  @override
  String toString() => '[${severity.name}] $code: $message';
}

class ValidationResult {
  final List<ValidationFinding> findings;
  final RosterCost cost;

  const ValidationResult({required this.findings, required this.cost});

  Iterable<ValidationFinding> of(Severity severity) =>
      findings.where((f) => f.severity == severity);

  List<ValidationFinding> get errors => of(Severity.error).toList();

  /// No error-severity findings. Warnings and info do not make a list illegal.
  bool get isLegal => errors.isEmpty;

  bool has(String code) => findings.any((f) => f.code == code);
}

class RosterValidator {
  final Catalogue catalogue;

  const RosterValidator(this.catalogue);

  ValidationResult validate(Roster roster) {
    final findings = <ValidationFinding>[];
    final cost = PointsCalculator(catalogue).price(roster);
    final battleSize = BattleSize.byId(roster.battleSizeId);

    if (battleSize == null) {
      findings.add(ValidationFinding(
        code: 'battle-size.unknown',
        message: 'Unknown battle size "${roster.battleSizeId}".',
        severity: Severity.error,
      ));
      return ValidationResult(findings: findings, cost: cost);
    }

    _checkPoints(roster, battleSize, cost, findings);
    _checkDetachments(roster, battleSize, findings);
    _checkDuplicateDatasheets(roster, battleSize, findings);
    _checkEpicHeroes(roster, findings);
    _checkWarlord(roster, findings);
    _checkSlots(roster, battleSize, findings);
    _checkAttachments(roster, findings);
    _checkWargearLimits(roster, findings);

    findings.sort((a, b) => a.severity.index.compareTo(b.severity.index));
    return ValidationResult(findings: findings, cost: cost);
  }

  /// Wargear taken past what the datasheet allows.
  ///
  /// **Only where the cap is a whole-unit number** — see
  /// [UnitLoadout.capsAreExact]. On a single-model datasheet BSData states
  /// each hardpoint's limit and there is nothing to interpret: a Commander in
  /// Enforcer Battlesuit takes four T'au flamers and one shield generator,
  /// and the reference export fields exactly that. On a squad the sources do
  /// not say which caps are per model and which per unit, and an error there
  /// would have called a validated 2,000 point list illegal in four places —
  /// which is how this check failed the first time it was written.
  ///
  /// Reported, never refused. §4.5's posture on the control is unchanged: the
  /// `+` still works, and the finding says what the datasheet allows.
  void _checkWargearLimits(Roster roster, List<ValidationFinding> findings) {
    for (final unit in roster.units) {
      final datasheet = catalogue.unit(unit.datasheetId);
      if (datasheet == null) continue;

      final loadout = UnitLoadout.forDatasheet(
        datasheet,
        catalogue: catalogue,
        vocabulary: datasheet.wargearVocabulary,
      );
      if (!loadout.capsAreExact) continue;

      final caps = <String, int>{
        for (final counter in loadout.counters)
          if (counter.statedMax case final max?) counter.itemId: max,
      };

      for (final item in unit.wargear) {
        final id = datasheet.unscope(item.itemId);
        final cap = caps[id];
        if (cap == null || item.count <= cap) continue;
        findings.add(ValidationFinding(
          code: 'wargear.over-limit',
          message: '${datasheet.name} has ${item.count} × '
              '${id.replaceAll('-', ' ')}; the datasheet allows $cap.',
          severity: Severity.error,
        ));
      }
    }
  }

  void _checkPoints(
    Roster roster,
    BattleSize battleSize,
    RosterCost cost,
    List<ValidationFinding> findings,
  ) {
    if (cost.unpriced.isNotEmpty) {
      findings.add(ValidationFinding(
        code: 'points.unpriced',
        message:
            '${cost.unpriced.length} unit(s) could not be priced; the total is '
            'a floor, not an answer.',
        severity: Severity.error,
        instanceIds: cost.unpriced.map((u) => u.instanceId).toList(),
      ));
      return;
    }

    final limit = roster.pointsLimitOverride ?? battleSize.points;
    if (cost.total > limit) {
      findings.add(ValidationFinding(
        code: 'points.over',
        message: '${cost.total} points exceeds the $limit limit by '
            '${cost.total - limit}.',
        severity: Severity.error,
      ));
    } else if (cost.total < limit) {
      findings.add(ValidationFinding(
        code: 'points.under',
        message: '${limit - cost.total} points unspent of $limit.',
        severity: Severity.info,
      ));
    }
  }

  void _checkDetachments(
    Roster roster,
    BattleSize battleSize,
    List<ValidationFinding> findings,
  ) {
    if (roster.detachments.isEmpty) {
      findings.add(const ValidationFinding(
        code: 'detachment.none',
        message: 'No detachment selected.',
        severity: Severity.error,
      ));
      return;
    }

    var spent = 0;
    var threeDpCount = 0;
    final seen = <String>{};
    final tagOwners = <String, List<String>>{};

    for (final entry in roster.detachments) {
      final detachment = catalogue.detachment(entry.detachmentId);
      if (detachment == null) {
        findings.add(ValidationFinding(
          code: 'detachment.unknown',
          message: 'Unknown detachment "${entry.detachmentId}".',
          severity: Severity.error,
        ));
        continue;
      }

      if (!seen.add(detachment.id)) {
        findings.add(ValidationFinding(
          code: 'detachment.duplicate',
          message: '${detachment.name} is taken more than once.',
          severity: Severity.error,
        ));
      }

      spent += detachment.detachmentPoints;
      if (detachment.detachmentPoints >= 3) threeDpCount++;

      for (final tag in detachment.uniqueTags) {
        tagOwners.putIfAbsent(tag, () => []).add(detachment.name);
      }
    }

    // At most one 3 DP detachment per force, at any battle size.
    if (threeDpCount > 1) {
      findings.add(ValidationFinding(
        code: 'detachment.multiple-3dp',
        message: '$threeDpCount detachments cost 3 DP; at most one is allowed.',
        severity: Severity.error,
      ));
    }

    // At Incursion the budget rises 2 -> 3 when a 3 DP detachment is taken, so
    // a single large detachment is always legal.
    final budget =
        battleSize.budgetFor(includesThreeDpDetachment: threeDpCount > 0);

    if (spent > budget) {
      findings.add(ValidationFinding(
        code: 'detachment.over-budget',
        message: '$spent Detachment Points spent of $budget available.',
        severity: Severity.error,
      ));
    } else if (spent < budget) {
      findings.add(ValidationFinding(
        code: 'detachment.under-budget',
        message: '${budget - spent} Detachment Point(s) unspent.',
        severity: Severity.info,
      ));
    }

    for (final entry in tagOwners.entries) {
      if (entry.value.length > 1) {
        findings.add(ValidationFinding(
          code: 'detachment.tag-conflict',
          message: '${entry.value.join(' and ')} share the unique tag '
              '"${entry.key}".',
          severity: Severity.error,
        ));
      }
    }
  }

  void _checkDuplicateDatasheets(
    Roster roster,
    BattleSize battleSize,
    List<ValidationFinding> findings,
  ) {
    final byDatasheet = <String, List<RosterUnit>>{};
    for (final unit in roster.units) {
      byDatasheet.putIfAbsent(unit.datasheetId, () => []).add(unit);
    }

    // A unit larger than anything the data supports.
    //
    // The builder will not grow one past its cap, but a list can arrive that
    // way — imported, shared, or saved before the data said otherwise — and
    // the symptom is silent: no points bracket covers the size, so the unit
    // prices at **zero** and the army looks cheaper than it is.
    for (final unit in roster.units) {
      final datasheet = catalogue.unit(unit.datasheetId);
      if (datasheet == null) continue;
      final composition = catalogue.composition(unit.datasheetId);
      var cap = composition?.maxModels;
      for (final bracket in datasheet.points) {
        final priced = bracket.modelsMax ?? bracket.models;
        if (priced > (cap ?? 0)) cap = priced;
      }
      if (cap == null || cap <= 0 || unit.models <= cap) continue;
      findings.add(ValidationFinding(
        code: 'unit.over-size',
        message: '${datasheet.name} has ${unit.models} models; the largest '
            'the data supports is $cap, and no points bracket covers it.',
        severity: Severity.error,
        instanceIds: [unit.instanceId],
      ));
    }

    for (final entry in byDatasheet.entries) {
      final datasheet = catalogue.unit(entry.key);
      if (datasheet == null) continue; // reported by pricing

      final cap = datasheet.isEpicHero
          ? 1
          : battleSize.capFor(isBattlelineOrTransport: datasheet.hasDoubledCap);

      if (entry.value.length > cap) {
        findings.add(ValidationFinding(
          code: 'datasheet.over-cap',
          message: '${entry.value.length} × ${datasheet.name}; the limit at '
              '${battleSize.name} is $cap.',
          severity: Severity.error,
          instanceIds: entry.value.map((u) => u.instanceId).toList(),
        ));
      }
    }
  }

  void _checkEpicHeroes(Roster roster, List<ValidationFinding> findings) {
    final counts = <String, int>{};
    for (final unit in roster.units) {
      final datasheet = catalogue.unit(unit.datasheetId);
      if (datasheet != null && datasheet.isEpicHero) {
        counts[datasheet.name] = (counts[datasheet.name] ?? 0) + 1;
      }
    }
    for (final entry in counts.entries) {
      if (entry.value > 1) {
        findings.add(ValidationFinding(
          code: 'epic-hero.duplicate',
          message: '${entry.key} is an Epic Hero and may be taken only once.',
          severity: Severity.error,
        ));
      }
    }
  }

  void _checkWarlord(Roster roster, List<ValidationFinding> findings) {
    final id = roster.warlordInstanceId;
    if (id == null) {
      findings.add(const ValidationFinding(
        code: 'warlord.missing',
        message: 'No Warlord nominated; an army must have exactly one.',
        severity: Severity.error,
      ));
      return;
    }

    final unit = roster.unitByInstance(id);
    if (unit == null) {
      findings.add(ValidationFinding(
        code: 'warlord.unknown',
        message: 'The nominated Warlord is not in the roster.',
        severity: Severity.error,
      ));
      return;
    }

    final datasheet = catalogue.unit(unit.datasheetId);
    if (datasheet != null && !datasheet.isCharacter) {
      findings.add(ValidationFinding(
        code: 'warlord.not-character',
        message: '${datasheet.name} is not a Character and cannot be Warlord.',
        severity: Severity.error,
        instanceIds: [unit.instanceId],
      ));
    }
  }

  void _checkSlots(
    Roster roster,
    BattleSize battleSize,
    List<ValidationFinding> findings,
  ) {
    // Enhancements cost one slot each. Unit Upgrades cost **one slot total**
    // however many instances they have — counting instances is the miscount
    // DESIGN.md §2.1 exists to prevent.
    final distinctUpgrades =
        roster.upgrades.map((u) => u.upgradeId).toSet().length;
    final used = roster.enhancements.length + distinctUpgrades;

    if (used > battleSize.enhancementSlots) {
      findings.add(ValidationFinding(
        code: 'slots.over',
        message: '$used enhancement slots used of '
            '${battleSize.enhancementSlots} at '
            '${battleSize.name}.',
        severity: Severity.error,
      ));
    } else if (used < battleSize.enhancementSlots) {
      findings.add(ValidationFinding(
        code: 'slots.unused',
        message: '${battleSize.enhancementSlots - used} of '
            '${battleSize.enhancementSlots} enhancement slots unused.',
        severity: Severity.info,
      ));
    }

    final seenEnhancements = <String>{};
    for (final selection in roster.enhancements) {
      if (!seenEnhancements.add(selection.enhancementId)) {
        findings.add(ValidationFinding(
          code: 'enhancement.duplicate',
          message: '${selection.enhancementId} is taken more than once; '
              'enhancements must all be different.',
          severity: Severity.error,
        ));
      }
      final target = roster.unitByInstance(selection.targetInstanceId);
      final datasheet =
          target == null ? null : catalogue.unit(target.datasheetId);
      if (datasheet != null && !datasheet.isCharacter) {
        findings.add(ValidationFinding(
          code: 'enhancement.non-character',
          message: '${selection.enhancementId} is on ${datasheet.name}, which '
              'is not a Character.',
          severity: Severity.error,
          instanceIds: [selection.targetInstanceId],
        ));
      }
    }

    for (final upgrade in roster.upgrades) {
      final targets = upgrade.targetInstanceIds;
      if (targets.isEmpty || targets.length > 3) {
        findings.add(ValidationFinding(
          code: 'upgrade.target-count',
          message: '${upgrade.upgradeId} has ${targets.length} target(s); '
              'a Unit Upgrade takes one to three.',
          severity: Severity.error,
          instanceIds: targets,
        ));
      }
      if (targets.toSet().length != targets.length) {
        findings.add(ValidationFinding(
          code: 'upgrade.repeated-target',
          message: '${upgrade.upgradeId} targets the same unit twice; at most '
              'one instance per unit.',
          severity: Severity.error,
          instanceIds: targets,
        ));
      }
      for (final instanceId in targets) {
        final target = roster.unitByInstance(instanceId);
        final datasheet =
            target == null ? null : catalogue.unit(target.datasheetId);
        if (datasheet != null && datasheet.isCharacter) {
          findings.add(ValidationFinding(
            code: 'upgrade.character-target',
            message: '${upgrade.upgradeId} targets ${datasheet.name}, a '
                'Character; Unit Upgrades apply to non-Characters.',
            severity: Severity.error,
            instanceIds: [instanceId],
          ));
        }
      }
    }
  }

  void _checkAttachments(Roster roster, List<ValidationFinding> findings) {
    for (final link in roster.links) {
      if (link.type != LinkType.leads) continue;

      final leader = roster.unitByInstance(link.fromInstanceId);
      final bodyguard = roster.unitByInstance(link.toInstanceId);
      if (leader == null || bodyguard == null) {
        findings.add(ValidationFinding(
          code: 'attachment.dangling',
          message: 'An attachment references a unit not in the roster.',
          severity: Severity.error,
          instanceIds: [link.fromInstanceId, link.toInstanceId],
        ));
        continue;
      }

      final eligible = catalogue.eligibleBodyguards(leader.datasheetId);
      if (eligible.isEmpty) continue; // no published rule; do not invent one

      if (!eligible.contains(bodyguard.datasheetId)) {
        final leaderSheet = catalogue.unit(leader.datasheetId);
        final bodyguardSheet = catalogue.unit(bodyguard.datasheetId);
        findings.add(ValidationFinding(
          code: 'attachment.illegal',
          message: '${leaderSheet?.name ?? leader.datasheetId} cannot lead '
              '${bodyguardSheet?.name ?? bodyguard.datasheetId}.',
          severity: Severity.error,
          instanceIds: [leader.instanceId, bodyguard.instanceId],
        ));
      }
    }
  }
}
