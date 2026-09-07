/// The published rules that let an army include units from another faction
/// (DESIGN.md §4.18).
///
/// **Every entry is a transcription of a rule in the dataset, not a memory of
/// the game.** Each names the `abilityId` it comes from, and
/// `test/ally_rules_test.dart` asserts that ability still exists upstream and
/// still reads as an allied-inclusion rule — so if the wording changes or the
/// rule is withdrawn, a test fails rather than the app quietly enforcing
/// something nobody publishes any more (§0).
///
/// **Why a table rather than parsing the text.** The rules state their limits
/// in prose — *"Up to 500 pts"*, *"1 RETINUE, 1 CHARACTER"*, *"You cannot
/// include units with any of the following keywords"* — and a parser for that
/// would be a worse kind of guess than a transcription somebody can check
/// against the quoted original beside it. There are five of them in the whole
/// game.
library;

import '../source/source_models.dart';

/// One rule permitting units the army's Faction keyword does not cover.
class AllyRule {
  /// The published rule this is a transcription of. Traceable, and tested.
  final String abilityId;

  final String name;

  /// Army faction keywords this rule is available to, folded. Empty means any
  /// army that satisfies [hostEveryModelKeyword].
  final Set<String> hostFactionKeywords;

  /// Every model in the army must carry this keyword. Assigned Agents is the
  /// only rule that asks it, and it is what stops an Agent joining an army of
  /// xenos.
  final String? hostEveryModelKeyword;

  /// Faction keywords the rule admits, folded.
  final Set<String> grantedKeywords;

  /// The detachment that unlocks it, when one does. Brood Brothers is the
  /// only rule in the game that is bought with detachment points rather than
  /// being available to the faction outright.
  final String? requiresDetachmentId;

  /// Combined points of allied units allowed, by battle size id.
  final Map<String, int> pointsCap;

  /// Allied units allowed by battle size id, counted per keyword. Assigned
  /// Agents caps three categories separately rather than by points.
  final Map<String, Map<String, int>> unitCap;

  /// The Warlord must be a model the host faction owns.
  final bool warlordMustBeHost;

  /// Allied models may not be given Enhancements.
  final bool alliesTakeNoEnhancements;

  /// Keywords the rule refuses, folded, checked against the allied unit's
  /// own keywords.
  final Set<String> excludedKeywords;

  /// Abilities that take their bearer out of [unitCap] counting.
  ///
  /// Two datasheets carry one: an Inquisitorial Agents unit taken under
  /// *Inquisitorial Henchmen*, and a Voidsmen-at-Arms unit taken under *Navy
  /// Bodyguards*, each of which "does not count towards the number of RETINUE
  /// units your army can include".
  final Set<String> exemptAbilityIds;

  const AllyRule({
    required this.abilityId,
    required this.name,
    required this.grantedKeywords,
    this.hostFactionKeywords = const {},
    this.hostEveryModelKeyword,
    this.requiresDetachmentId,
    this.pointsCap = const {},
    this.unitCap = const {},
    this.warlordMustBeHost = false,
    this.alliesTakeNoEnhancements = false,
    this.excludedKeywords = const {},
    this.exemptAbilityIds = const {},
  });
}

abstract final class AllyRules {
  const AllyRules._();

  /// Every allied-inclusion rule the dataset publishes, as of 2026-09-07.
  ///
  /// Found by reading every ability whose text says *"you can include"* and
  /// *"even though they do not have"* — 245 abilities match the first phrase
  /// and five match both, which is the whole set.
  static const all = <AllyRule>[
    // "If your army Faction is not AGENTS OF THE IMPERIUM, but every model in
    //  your army has the IMPERIUM keyword, you can include AGENTS OF THE
    //  IMPERIUM units in your army even if they do not have the Faction
    //  keyword you selected in the Select Army Faction step. In this case, the
    //  maximum number of AGENTS OF THE IMPERIUM units you can include in your
    //  army depends on the battle size, as shown below.
    //  Incursion: 1 RETINUE, 1 CHARACTER, 1 REQUISITIONED
    //  Strike Force: 2 RETINUE, 2 CHARACTER, 1 REQUISITIONED
    //  Onslaught: 3 RETINUE, 3 CHARACTER, 2 REQUISITIONED"
    //
    // Dedicated Transports are exempt from the count and are not modelled as
    // a category: the rule admits them "as normal", with a condition about
    // what starts embarked that belongs to deployment rather than mustering.
    AllyRule(
      abilityId: 'assigned-agents',
      name: 'Assigned Agents',
      hostEveryModelKeyword: 'imperium',
      grantedKeywords: {'agents of the imperium'},
      // "you can include one INQUISITORIAL AGENTS unit in your army that does
      //  not count towards the number of RETINUE units your army can
      //  include" — Inquisitorial Henchmen, and Navy Bodyguards says the same
      //  of a Voidsmen-at-Arms unit. Both are abilities on the datasheet
      //  itself, so they are checkable rather than assumed.
      //
      // *Secret Forces* raises all three caps by 1 and is **not** implemented:
      // nothing in the data references it, so there is no way to tell whether
      // an army has it. It is why a count over the cap is worth reporting and
      // not worth refusing.
      exemptAbilityIds: {'inquisitorial-henchmen', 'navy-bodyguards'},
      unitCap: {
        'incursion': {'retinue': 1, 'character': 1, 'requisitioned': 1},
        'strike-force': {'retinue': 2, 'character': 2, 'requisitioned': 1},
        'onslaught': {'retinue': 3, 'character': 3, 'requisitioned': 2},
      },
    ),

    // "You can include Astra Militarum units in your army, even though they do
    //  not have the Genestealer Cult Faction keyword. The combined points cost
    //  of such units you can include in your army is:
    //  Incursion: Up to 500 pts / Strike Force: Up to 1000 pts /
    //  Onslaught: Up to 1500 pts.
    //  A GENESTEALER CULTS model must be your WARLORD, and ASTRA MILITARUM
    //  models from your army lose the Voice of Command ability if they have
    //  it. You cannot include units with any of the following keywords in your
    //  army using this rule: AIRCRAFT; COMMISSAR; EPIC HERO; MILITARUM
    //  TEMPESTUS; OGRYN; RATLING; TECH-PRIEST ENGINSEER; MINISTORUM PRIEST."
    //
    // Losing Voice of Command is a change to a datasheet in play, not a
    // mustering limit, so it is not checked here.
    AllyRule(
      abilityId: 'brood-brothers',
      name: 'Brood Brothers',
      hostFactionKeywords: {'genestealer cults'},
      grantedKeywords: {'astra militarum'},
      requiresDetachmentId: 'brood-brothers-auxilia',
      pointsCap: {
        'incursion': 500,
        'strike-force': 1000,
        'onslaught': 1500,
      },
      warlordMustBeHost: true,
      excludedKeywords: {
        'aircraft',
        'commissar',
        'epic hero',
        'militarum tempestus',
        'ogryn',
        'ratling',
        'tech-priest enginseer',
        'ministorum priest',
      },
    ),

    // "If your Army Faction is DRUKHARI, you can include HARLEQUINS and
    //  ANHRATHE units in your army, even though they do not have the DRUKHARI
    //  Faction keyword. The combined points value ... depends on the battle
    //  size, as follows: Incursion: Up to 250 pts / Strike Force: Up to 500
    //  pts / Onslaught: Up to 750 pts. No HARLEQUINS or ANHRATHE models
    //  included in your army in this way can be your WARLORD, and they cannot
    //  be given Enhancements."
    AllyRule(
      abilityId: 'corsairs-and-travelling-players',
      name: 'Corsairs and Travelling Players',
      hostFactionKeywords: {'drukhari'},
      grantedKeywords: {'harlequins', 'anhrathe'},
      pointsCap: {
        'incursion': 250,
        'strike-force': 500,
        'onslaught': 750,
      },
      warlordMustBeHost: true,
      alliesTakeNoEnhancements: true,
    ),

    // "When mustering you army, you can include Harlequins units in your army,
    //  even though they do not have the Asuryani Faction keyword. Unless
    //  otherwise stated, you cannot select Harlequins or Ynnari as your Army
    //  Faction."
    //
    // No cap is published, so none is invented. An army taking more Harlequins
    // than seems right is not something this can report without a number to
    // report it against.
    AllyRule(
      abilityId: 'disparate-paths',
      name: 'Disparate Paths',
      hostFactionKeywords: {'asuryani'},
      grantedKeywords: {'harlequins'},
    ),

    // "You can include TYRANIDS VANGUARD INVADER units (excluding AIRCRAFT,
    //  BROODLORD and GENESTEALERS units) in your army. The combined points
    //  cost of such units depends on your battle size: Incursion: Up to 500
    //  pts / Strike Force: Up to 1000 pts / Onslaught: Up to 1500 pts. No
    //  TYRANIDS models from your army can be your WARLORD."
    //
    // **The host is inferred, which nothing else here is.** No detachment and
    // no datasheet references this ability, so the data does not say whose
    // rule it is. Two things put it with the Cult: the name — the Star
    // Children are a Genestealer Cults idea — and that the Cult bundle is the
    // one shipping 18 Tyranids datasheets. Said plainly here because it is
    // the one entry a reader should check rather than trust.
    AllyRule(
      abilityId: 'the-star-childrens-blessings',
      name: "The Star Children's Blessings",
      hostFactionKeywords: {'genestealer cults'},
      grantedKeywords: {'tyranids'},
      pointsCap: {
        'incursion': 500,
        'strike-force': 1000,
        'onslaught': 1500,
      },
      warlordMustBeHost: true,
      excludedKeywords: {'aircraft', 'broodlord', 'genestealers'},
    ),

    // "You can include DAMNED units in your army (see Codex: Chaos Space
    //  Marines)."
    //
    // DAMNED is a plain keyword on datasheets whose faction is Heretic
    // Astartes, which is why the Daemons and Chaos Knights bundles ship them.
    // The host is every Chaos army: the rule names no faction and points at
    // the Chaos Space Marines codex, and `Chaos` is a faction keyword every
    // one of those armies carries.
    AllyRule(
      abilityId: 'wretched-thralls',
      name: 'Wretched Thralls',
      hostFactionKeywords: {'chaos'},
      grantedKeywords: {'damned'},
    ),

    // "You can include Ynnari units in your army, even though they do not have
    //  the Asuryani Faction keyword. Asuryani units (excluding Epic Heroes)
    //  from your army gain the Ynnari keyword. You must include Yvraine and/or
    //  The Yncarne in your army, and one of those models must be your
    //  Warlord."
    //
    // The Yvraine/Yncarne requirement is a condition on the army rather than
    // on the allied unit, and is checked separately in the validator.
    AllyRule(
      abilityId: 'servants-of-the-whispering-god',
      name: 'Servants of the Whispering God',
      hostFactionKeywords: {'asuryani'},
      grantedKeywords: {'ynnari'},
    ),
  ];

  /// The rules available to an army with these faction keywords.
  ///
  /// Detachment-gated rules are included: whether the detachment is taken is a
  /// separate question, and the validator answers it so it can say *which*
  /// detachment would permit the unit rather than only that it is not allowed.
  static List<AllyRule> forFaction(Iterable<String> factionKeywords) {
    final folded = {for (final k in factionKeywords) foldKeyword(k)};
    return [
      for (final rule in all)
        if (rule.hostFactionKeywords.isEmpty ||
            rule.hostFactionKeywords.any(folded.contains))
          rule,
    ];
  }

  /// Whether [unit] is an ally in an army of [factionKeywords] — its faction
  /// keywords and the army's have nothing in common.
  ///
  /// Folded on both sides, which is not fussiness: `factions.json` writes
  /// `T’au Empire` with a typographic apostrophe and 66 of its own datasheets
  /// write `T'au Empire` with a typewriter one, so a raw comparison marks a
  /// whole faction as its own ally.
  static bool isAlly(SourceUnit unit, Iterable<String> factionKeywords) {
    if (unit.factionKeywords.isEmpty) return false;
    final army = {for (final k in factionKeywords) foldKeyword(k)};
    if (army.isEmpty) return false;
    return !unit.factionKeywords.any((k) => army.contains(foldKeyword(k)));
  }

  /// The rule that admits [unit] into an army of [factionKeywords], or null.
  ///
  /// **Matched against every keyword, not only the faction ones.** The rules
  /// are written in the game's own vocabulary — *"HARLEQUINS and ANHRATHE
  /// units"* — and `Anhrathe` is published as a plain keyword on datasheets
  /// whose faction keyword is `Asuryani`. Reading only faction keywords would
  /// refuse every Corsair unit the Drukhari rule exists to admit.
  static AllyRule? admitting(SourceUnit unit, Iterable<String> factionKeywords) {
    final unitKeywords = {
      for (final k in unit.factionKeywords) foldKeyword(k),
      for (final k in unit.keywords) foldKeyword(k),
    };
    for (final rule in forFaction(factionKeywords)) {
      if (rule.grantedKeywords.any(unitKeywords.contains)) return rule;
    }
    return null;
  }
}
