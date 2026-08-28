/// One army's rules, filed by how widely each one applies (DESIGN.md §7.3.9).
///
/// The reference page of §7.3.8 files every rule the same way — one entry per
/// ability, naming the datasheets that have it. Measured against a real list
/// that turns out to be the wrong shape twice over. In a 2,000 point T'au army
/// 21 of 30 abilities belong to exactly one datasheet, and in a Space Marine
/// one 23 of 26 do: for the large majority, "who has this" is a question with
/// one answer, printed above the rule, and the entry pays for an index nobody
/// needs. Meanwhile the handful that *are* shared — Deep Strike, Leader, the
/// drones — carry a list of owners long enough to bury the sentence they
/// belong to.
///
/// So rules are split three ways:
///
///   * **army** — the faction rule and the detachment rules, true of the whole
///     list, stated once and never repeated;
///   * **shared** — rules more than one datasheet in the faction can have.
///     These become columns: a unit is a row, a rule is a column, and "which
///     of my units can Deep Strike" is read down a column instead of assembled
///     from prose;
///   * **unit** — everything else, printed under the one datasheet that has
///     it, where naming an owner would only repeat the heading.
///
/// Sharedness is a property of the **faction**, not of the roster. A Space
/// Marine list with one Deep Strike unit still files Deep Strike as a shared
/// rule, because the rule is shared by 37 datasheets in the catalogue and a
/// player asking "who can Deep Strike" is asking about a rule they know is
/// common. Deciding it per roster made the same rule move between sections
/// depending on what was taken, which read as a bug.
library;

import '../roster/roster.dart';
import '../rules/catalogue.dart';
import '../source/source_models.dart';
import 'reference_index.dart';
import 'rules_renderer.dart';

/// A rule several datasheets can carry, and who carries it in this army.
class RuleColumn {
  final String abilityId;
  final String name;

  /// Rendered rules text, or empty when the data carries no effect.
  final String text;

  /// Phases the rule names, for the play screen's ordering.
  final List<String> phases;

  /// Datasheet ids in this army that have it. Never empty — a rule no unit
  /// here carries is not a column.
  final Set<String> owners;

  const RuleColumn({
    required this.abilityId,
    required this.name,
    required this.text,
    required this.phases,
    required this.owners,
  });
}

/// One datasheet's row: which shared rules and keywords it has, plus the rules
/// that are its alone.
class UnitRules {
  final String datasheetId;
  final String name;

  /// How many of this datasheet the roster contains. Four Crisis suits are one
  /// row carrying the same rules, not four identical rows.
  final int count;

  /// Ids from [ArmyRules.columns] this datasheet has.
  final Set<String> columnIds;

  /// Keywords from [ArmyRules.keywordColumns] this datasheet has.
  final Set<String> keywords;

  /// Rules no other datasheet in the faction can take.
  final List<RenderedRule> only;

  const UnitRules({
    required this.datasheetId,
    required this.name,
    required this.count,
    required this.columnIds,
    required this.keywords,
    required this.only,
  });
}

class ArmyRules {
  /// The faction rule first, then one entry per detachment rule.
  final List<ReferenceEntry> armyWide;

  /// Keywords every datasheet in the army has. Stated with the army-wide rules
  /// rather than given a column that would be solid down its whole length.
  final List<String> universalKeywords;

  /// Shared rules, most widely held first.
  final List<RuleColumn> columns;

  /// Keywords some but not all datasheets have, most widely held first.
  ///
  /// Roster-scoped, unlike [columns]: the question a keyword answers — "which
  /// of these can Fly" — is about the units on the table, and a faction-wide
  /// keyword column would be a column of one dot on most lists.
  final List<String> keywordColumns;

  /// One row per distinct datasheet, in roster order.
  final List<UnitRules> units;

  const ArmyRules({
    required this.armyWide,
    required this.universalKeywords,
    required this.columns,
    required this.keywordColumns,
    required this.units,
  });

  bool get isEmpty => armyWide.isEmpty && columns.isEmpty && units.isEmpty;

  /// Ability ids more than one datasheet in [units] can take.
  ///
  /// Computed over a whole faction, which is why it is captured at snapshot
  /// time: a roster's own snapshot holds only the datasheets it uses, and
  /// counting owners there would answer a different question.
  static Set<String> sharedAcross(Iterable<SourceUnit> units) {
    final counts = <String, int>{};
    for (final unit in units) {
      for (final id in unit.ruleVocabulary.toSet()) {
        counts[id] = (counts[id] ?? 0) + 1;
      }
    }
    return {
      for (final entry in counts.entries)
        if (entry.value > 1) entry.key,
    };
  }

  /// Builds the three tiers for one army.
  ///
  /// [sharedAbilityIds] comes from [sharedAcross] over the faction. Omitting it
  /// falls back to the catalogue's own datasheets, which is right for a
  /// faction-wide catalogue and degrades to roster scope for a snapshot.
  factory ArmyRules.forRoster(
    Roster roster, {
    required Catalogue catalogue,
    Set<String>? sharedAbilityIds,
    String? factionRuleId,
  }) {
    const renderer = RulesRenderer();
    final shared = sharedAbilityIds ?? sharedAcross(catalogue.allUnits);

    final armyWide = <ReferenceEntry>[];
    final rule =
        factionRuleId == null ? null : catalogue.ability(factionRuleId);
    if (rule != null) {
      armyWide.add(ReferenceEntry(
        kind: ReferenceKind.detachmentRule,
        id: factionRuleId!,
        title: rule.name,
        source: 'Army rule',
        body: renderer.render(rule).text,
      ));
    }
    for (final taken in roster.detachments) {
      final detachment = catalogue.detachment(taken.detachmentId);
      if (detachment == null) continue;
      final ruleId = detachment.detachmentRuleId;
      final ability = ruleId == null ? null : catalogue.ability(ruleId);
      armyWide.add(ReferenceEntry(
        kind: ReferenceKind.detachmentRule,
        id: ruleId ?? detachment.id,
        title: ability?.name ?? detachment.name,
        source: detachment.name,
        body: ability == null ? '' : renderer.render(ability).text,
        detail: '${detachment.detachmentPoints} DP',
      ));
    }

    // Whatever the army-wide tier has claimed does not appear again below it.
    //
    // 40kdc named the army rule only on the faction record, so this could not
    // arise. BSData puts For The Greater Good on every T'au datasheet as well,
    // and the rule then showed twice on one screen — once as the army rule and
    // once as a column every unit shares (§7.3.9).
    final claimed = {for (final entry in armyWide) entry.id};

    // Distinct datasheets in roster order, with how many the list has of each
    // and the wargear any copy of it bought.
    final order = <String>[];
    final counts = <String, int>{};
    final sheets = <String, SourceUnit>{};
    final taken = <String, Set<String>>{};
    for (final rosterUnit in roster.units) {
      final datasheet = catalogue.unit(rosterUnit.datasheetId);
      if (datasheet == null) continue;
      if (!counts.containsKey(datasheet.id)) {
        order.add(datasheet.id);
        sheets[datasheet.id] = datasheet;
      }
      counts[datasheet.id] = (counts[datasheet.id] ?? 0) + 1;
      taken
          .putIfAbsent(datasheet.id, () => <String>{})
          .addAll(rosterUnit.wargear.map((item) => item.itemId));
    }

    /// Ability ids in force for a datasheet: its own, minus optional wargear
    /// no copy of it took.
    ///
    /// Wargear a datasheet *could* take is not wargear it has (§7.3.7). Two
    /// squads of the same datasheet share one row, so a drone bought by either
    /// counts — the row says what the army fields, not what one squad does.
    List<String> active(String datasheetId) {
      final datasheet = sheets[datasheetId]!;
      final optional = <String>{
        for (final budget in datasheet.wargearBudgets) ...budget.items,
      };
      final bought = taken[datasheetId] ?? const <String>{};
      return [
        for (final id in datasheet.ruleVocabulary.toSet())
          if (!claimed.contains(id))
            if (!optional.contains(id) || bought.contains(id)) id,
      ];
    }

    final columnOrder = <String>[];
    final owners = <String, Set<String>>{};
    final only = <String, List<RenderedRule>>{};
    for (final datasheetId in order) {
      for (final abilityId in active(datasheetId)) {
        final ability = catalogue.ability(abilityId);
        if (ability == null) continue;
        if (shared.contains(abilityId)) {
          owners.putIfAbsent(abilityId, () {
            columnOrder.add(abilityId);
            return <String>{};
          }).add(datasheetId);
        } else {
          only.putIfAbsent(datasheetId, () => []).add(renderer.render(ability,
              published: catalogue.phasesFor(abilityId)));
        }
      }
    }

    // Widest first: the rules most of the army has are the ones worth reading
    // across, and they anchor the left of the grid where the eye starts. Ties
    // keep the order the datasheets introduced them in.
    final introduced = {
      for (final (index, id) in columnOrder.indexed) id: index,
    };
    columnOrder.sort((a, b) {
      final byOwners = owners[b]!.length.compareTo(owners[a]!.length);
      return byOwners != 0
          ? byOwners
          : introduced[a]!.compareTo(introduced[b]!);
    });

    final columns = [
      for (final abilityId in columnOrder)
        if (catalogue.ability(abilityId) case final ability?)
          () {
            final rendered = renderer.render(ability,
                published: catalogue.phasesFor(abilityId));
            return RuleColumn(
              abilityId: abilityId,
              name: ability.name,
              text: rendered.text,
              phases: rendered.phases,
              owners: owners[abilityId]!,
            );
          }(),
    ];

    // Keywords, counted over the datasheets on the table.
    final keywordCounts = <String, int>{};
    for (final datasheetId in order) {
      for (final keyword in sheets[datasheetId]!.keywords.toSet()) {
        keywordCounts[keyword] = (keywordCounts[keyword] ?? 0) + 1;
      }
    }
    final universal = [
      for (final entry in keywordCounts.entries)
        if (entry.value == order.length) entry.key,
    ]..sort();
    final keywordColumns = [
      for (final entry in keywordCounts.entries)
        if (entry.value > 1 && entry.value < order.length) entry.key,
    ]..sort((a, b) {
        final byCount = keywordCounts[b]!.compareTo(keywordCounts[a]!);
        return byCount != 0 ? byCount : a.compareTo(b);
      });

    return ArmyRules(
      armyWide: armyWide,
      universalKeywords: universal,
      columns: columns,
      keywordColumns: keywordColumns,
      units: [
        for (final datasheetId in order)
          UnitRules(
            datasheetId: datasheetId,
            name: sheets[datasheetId]!.name,
            count: counts[datasheetId]!,
            columnIds: {
              for (final column in columns)
                if (column.owners.contains(datasheetId)) column.abilityId,
            },
            keywords: {
              for (final keyword in keywordColumns)
                if (sheets[datasheetId]!.keywords.contains(keyword)) keyword,
            },
            only: only[datasheetId] ?? const [],
          ),
      ],
    );
  }
}
