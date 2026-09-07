/// Which of an army's rules bear on which of its units (DESIGN.md §4.19).
///
/// The faction rule and the detachment rules are filed as army-wide (§7.3.9),
/// which is true of what they *belong* to and often false of what they *do*.
/// *Bonded Heroes* is a Retaliation Cadre rule and it only ever touches
/// **T'AU EMPIRE BATTLESUIT** models; *Righteous Purpose* names three Sororitas
/// datasheets by keyword. Read as army-wide, both are a paragraph the reader
/// has to re-scope by eye every time they look at a unit.
///
/// **Three ways a rule can say who it is for, and they are not equally
/// trustworthy.** Measured over the 246 detachment rules in the dataset:
///
///   * `unit_ids` on the ability — explicit, and published for **1** of them.
///   * A `unit-has-keyword` condition inside the structured effect — **30**.
///   * Keywords in bold in the printed text — **127**, four times the other
///     two together, because the rules are written for people and say
///     *"**Kroot** models from your army"* rather than encoding it.
///
/// So the text is read, and [RuleReach.source] records which of the three
/// answered, because a rule attributed by reading its prose is a weaker claim
/// than one that named its datasheets and the screen should be able to say so.
///
/// **What stops the prose reading over-matching.** A bolded string counts only
/// when some datasheet in the faction carries it as a keyword and not every
/// datasheet does — `**[SUSTAINED HITS 1]**`, `**charge rolls**` and
/// `**Ld**` are bold and are not keywords, and `**T'AU EMPIRE**` is a keyword
/// every unit has, which makes the rule army-wide rather than pointed. The
/// compound forms the rules use — `**ADEPTA SORORITAS CHARACTER**` — are
/// satisfied the same way enhancement restrictions already are (§4.7).
library;

import '../rules/catalogue.dart';
import '../roster/roster.dart';
import '../source/source_models.dart';

/// How a rule was attributed to a unit.
enum ReachSource {
  /// The ability names the datasheet in `unit_ids`.
  named,

  /// A keyword condition inside the structured effect.
  condition,

  /// Keywords in bold in the printed text.
  wording,
}

/// A characteristic a rule changes, where the effect says so plainly.
class StatChange {
  /// `R`, `S`, `AP`, `A`, `D`, `M` — the dataset's own abbreviations.
  final String stat;

  /// `add`, `subtract`, `set`.
  final String operation;
  final int value;

  /// `ranged`, `melee`, or null for both.
  final String? attackType;

  /// Conditions the effect puts on it, rendered as their type names — empty
  /// when the effect states none.
  ///
  /// Carried rather than resolved: `phase-is`, `is-attached` and
  /// `unit-within-range-of` are answered by the table, not by the app, and a
  /// modifier shown without its condition is a lie about a unit's statline.
  final List<String> conditions;

  const StatChange({
    required this.stat,
    required this.operation,
    required this.value,
    this.attackType,
    this.conditions = const [],
  });

  bool get isUnconditional => conditions.isEmpty;

  String get summary {
    final sign = operation == 'subtract' ? '-' : '+';
    return operation == 'set' ? '$stat $value' : '$stat $sign$value';
  }
}

/// One army rule, and the units it bears on.
class RuleReach {
  final String abilityId;
  final String name;
  final ReachSource source;

  /// The keywords or ids that put it here, for a screen that wants to say why.
  final List<String> because;

  /// Datasheet ids in this roster the rule bears on.
  final Set<String> datasheetIds;

  final List<StatChange> changes;

  const RuleReach({
    required this.abilityId,
    required this.name,
    required this.source,
    required this.because,
    required this.datasheetIds,
    this.changes = const [],
  });
}

abstract final class RuleReachIndex {
  const RuleReachIndex._();

  /// The army-level rules that bear on some but not all of [roster]'s units.
  ///
  /// A rule that reaches everything is left alone: it is army-wide, it is
  /// already stated once where army-wide rules are stated, and repeating it on
  /// every unit is the noise §7.3.9 removed.
  static List<RuleReach> of(Catalogue catalogue, Roster roster) {
    final datasheets = <String, SourceUnit>{};
    for (final unit in roster.units) {
      final sheet = catalogue.unit(unit.datasheetId);
      if (sheet != null) datasheets[sheet.id] = sheet;
    }
    if (datasheets.isEmpty) return const [];

    // Each datasheet's own folded vocabulary, which is what decides whether a
    // bolded string names anything — and, counted across the faction, whether
    // it names *some* of it or all of it.
    final all = catalogue.allUnits.toList();
    final vocabularies = [for (final sheet in all) vocabularyOf(sheet)];

    final out = <RuleReach>[];
    for (final abilityId in _armyRuleIds(catalogue, roster)) {
      final ability = catalogue.ability(abilityId);
      if (ability == null) continue;

      final (source, because) = _targets(ability, vocabularies);
      if (because.isEmpty) continue;

      final reached = <String>{};
      for (final sheet in datasheets.values) {
        if (_bears(ability, sheet, source, because)) reached.add(sheet.id);
      }
      // Nothing in this army: nothing to say. **Whether the rule is
      // army-wide is decided against the faction, not against the roster** —
      // measured over the list, a one-unit army makes every rule look
      // universal and a rule written for BATTLESUITS vanishes from the only
      // battlesuit in it.
      if (reached.isEmpty) continue;

      out.add(RuleReach(
        abilityId: abilityId,
        name: ability.name,
        source: source,
        because: because,
        datasheetIds: reached,
        changes: statChanges(ability.effect),
      ));
    }
    return out;
  }

  /// The rules that belong to the army rather than to a datasheet: the faction
  /// rule and the rules of every detachment taken.
  static List<String> _armyRuleIds(Catalogue catalogue, Roster roster) => [
        for (final taken in roster.detachments)
          if (catalogue.detachment(taken.detachmentId) case final detachment?)
            ...detachment.ruleIds,
      ];

  /// The keywords, faction keywords and name a datasheet answers to.
  static Set<String> vocabularyOf(SourceUnit sheet) => {
        for (final k in sheet.keywords) foldKeyword(k),
        for (final k in sheet.factionKeywords) foldKeyword(k),
        foldKeyword(sheet.name),
      }..remove('');

  /// Who a rule says it is for, and which of the three ways it said it.
  static (ReachSource, List<String>) _targets(
    SourceAbility ability,
    List<Set<String>> vocabularies,
  ) {
    if (ability.unitIds.isNotEmpty) {
      return (ReachSource.named, ability.unitIds);
    }

    final fromEffect = _keywordConditions(ability.effect);
    if (fromEffect.isNotEmpty) {
      return (ReachSource.condition, fromEffect.toList()..sort());
    }

    // **Two ways the rules mark a keyword, and only one survives to the
    // app.** The merged dataset writes `**T'AU EMPIRE BATTLESUIT**`; the
    // bundle the app ships carries the same sentence with the markup gone and
    // the keyword still in capitals. Reading only the bold markers worked
    // against `data/merged` and found nothing at all on a phone.
    final marked = <String>{
      for (final match
          in RegExp(r'\*\*([^*]+)\*\*').allMatches(ability.description ?? ''))
        match.group(1)!,
      for (final match
          in RegExp(r"\b[A-Z][A-Z'’\u2019\-]*(?:[ /][A-Z][A-Z'’\u2019\-]*)*\b")
              .allMatches(ability.description ?? ''))
        if (match.group(0)!.length > 2) match.group(0)!,
    };

    final bolded = <String>{};
    for (final candidate in marked) {
      for (final part in candidate.split('/')) {
        final folded = foldKeyword(part);
        if (folded.isEmpty) continue;
        // Counted by *datasheets satisfied*, not by keyword lookup, because
        // the rules name compounds: `T'AU EMPIRE BATTLESUIT` is two keywords
        // run together and is a keyword in its own right nowhere.
        var owners = 0;
        for (final vocabulary in vocabularies) {
          if (satisfiesKeyword(folded, vocabulary)) owners++;
        }
        // Nothing satisfies it: rules vocabulary — `[SUSTAINED HITS 1]`,
        // `charge rolls`. Everything satisfies it: the rule is army-wide.
        if (owners > 0 && owners < vocabularies.length) bolded.add(folded);
      }
    }
    return (ReachSource.wording, bolded.toList()..sort());
  }

  static Set<String> _keywordConditions(Map<String, dynamic> effect) {
    final out = <String>{};
    void walk(Object? node) {
      if (node is Map) {
        if (node['type'] == 'unit-has-keyword') {
          final keyword = (node['parameters'] as Map?)?['keyword'];
          if (keyword is String) out.add(foldKeyword(keyword));
        }
        node.values.forEach(walk);
      } else if (node is List) {
        node.forEach(walk);
      }
    }

    walk(effect);
    return out;
  }

  static bool _bears(
    SourceAbility ability,
    SourceUnit sheet,
    ReachSource source,
    List<String> because,
  ) {
    if (source == ReachSource.named) return because.contains(sheet.id);
    final vocabulary = vocabularyOf(sheet);
    return because.any((k) => satisfiesKeyword(k, vocabulary));
  }

  /// Every characteristic change an effect states, with whatever conditions
  /// guard it.
  static List<StatChange> statChanges(Map<String, dynamic> effect) {
    final out = <StatChange>[];
    void walk(Object? node, List<String> conditions) {
      if (node is Map) {
        if (node['type'] == 'conditional') {
          final condition = node['condition'];
          final named = <String>[
            ...conditions,
            if (condition is Map) ...[
              if (condition['type'] is String) condition['type'] as String,
              if (condition['operator'] is String)
                ...(condition['operands'] as List? ?? const [])
                    .whereType<Map<String, dynamic>>()
                    .map((o) => o['type'])
                    .whereType<String>(),
            ],
          ];
          walk(node['effect'], named);
          return;
        }
        if (node['type'] == 'stat-modifier') {
          final modifier = node['modifier'];
          if (modifier is Map && modifier['stat'] is String) {
            out.add(StatChange(
              stat: modifier['stat'] as String,
              operation: '${modifier['operation'] ?? 'add'}',
              value: (modifier['value'] as num?)?.toInt() ?? 0,
              attackType: modifier['attack_type'] as String?,
              conditions: conditions,
            ));
          }
        }
        for (final value in node.values) {
          walk(value, conditions);
        }
      } else if (node is List) {
        for (final value in node) {
          walk(value, conditions);
        }
      }
    }

    walk(effect, const []);
    return out;
  }
}
