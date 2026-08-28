/// Data-transfer objects mirroring the 40kdc-data source format.
///
/// These are deliberately *source-shaped*, not domain-shaped. The normalised
/// domain model (DESIGN.md §2.1) is derived from these in a later stage; keeping
/// the two apart means upstream schema drift lands in one place.
library;

import 'json.dart';

class GameVersion {
  final String edition;
  final String dataslate;

  const GameVersion({required this.edition, required this.dataslate});

  factory GameVersion.fromJson(Object? v) {
    final j = asMap(v);
    return GameVersion(
      edition: strOr(j['edition'], 'unknown'),
      dataslate: strOr(j['dataslate'], 'unknown'),
    );
  }

  /// True for content still carried over from the 10e archive. DESIGN.md §3.0
  /// requires this be surfaced, never silently presented as current.
  bool get isProvisional => dataslate.contains('provisional');

  @override
  String toString() => '$edition/$dataslate';
}

class ModelProfile {
  final String name;
  final String? m, t, w, sv, invulnSv, ld, oc;

  /// A distance with its unit, or the value untouched when it is not one.
  ///
  /// `-` means the model does not move and stays as it is. A trailing `+` is
  /// a minimum rather than a fixed distance — a Heldrake reads `12+"` — so
  /// the mark goes after it, not before.
  static String? _inches(String? raw) {
    final value = raw?.trim();
    if (value == null || value.isEmpty) return raw;
    return RegExp(r'^\d+(\.\d+)?\+?$').hasMatch(value) ? '$value"' : value;
  }

  const ModelProfile({
    required this.name,
    this.m,
    this.t,
    this.w,
    this.sv,
    this.invulnSv,
    this.ld,
    this.oc,
  });

  factory ModelProfile.fromJson(Object? v) {
    final j = asMap(v);
    return ModelProfile(
      name: strOr(j['name'], '(unnamed)'),
      // **Movement always carries its inch mark.** Upstream writes it both
      // ways — `'7"'` on most datasheets and a bare `10` on a handful — so
      // the same screen showed `5"` on a statline and `10` in the move list,
      // which reads as two different kinds of number.
      m: _inches(str(j['M'])),
      t: str(j['T']),
      w: str(j['W']),
      sv: str(j['Sv']),
      invulnSv: str(j['invuln_sv']),
      ld: str(j['Ld']),
      oc: str(j['OC']),
    );
  }

  /// Statline identity, used to detect genuinely divergent per-model profiles
  /// within one attached unit (DESIGN.md §7.3.6).
  String get statKey => '$m|$t|$w|$sv|$invulnSv|$ld|$oc';

  ModelProfile withInvulnerableSave(String? save) => ModelProfile(
        name: name,
        m: m,
        t: t,
        w: w,
        sv: sv,
        invulnSv: save,
        ld: ld,
        oc: oc,
      );
}

/// Points bracket. Carries `unitCountMin`/`unitCountMax` because 11e prices
/// some units by *copy index* as well as model count — see DESIGN.md §2.1.
class PointsBracket {
  final int models;
  final int? modelsMax;
  final int cost;
  final int? unitCountMin;
  final int? unitCountMax;

  const PointsBracket({
    required this.models,
    required this.cost,
    this.modelsMax,
    this.unitCountMin,
    this.unitCountMax,
  });

  factory PointsBracket.fromJson(Object? v) {
    final j = asMap(v);
    return PointsBracket(
      models: intOr(j['models'], 0),
      modelsMax: asInt(j['models_max']),
      cost: intOr(j['cost'], 0),
      unitCountMin: asInt(j['unit_count_min']),
      unitCountMax: asInt(j['unit_count_max']),
    );
  }

  /// True when this bracket's price depends on how many copies of the datasheet
  /// the roster already holds.
  bool get isCopyScaled => (unitCountMin ?? 1) > 1 || unitCountMax != null;
}

/// Wargear that costs points per instance, e.g. a missile pod at 5 pts.
class WargearCost {
  final String itemId;
  final int cost;

  const WargearCost({required this.itemId, required this.cost});

  factory WargearCost.fromJson(Object? v) {
    final j = asMap(v);
    return WargearCost(
      itemId: strOr(j['item_id'], ''),
      cost: intOr(j['cost'], 0),
    );
  }
}

/// A free-but-capped wargear allowance, e.g. up to 3 shield drones per 3
/// models. Contributes no points, only a legality bound.
class WargearBudget {
  final List<String> items;
  final int count;
  final int? perModels;

  const WargearBudget({
    required this.items,
    required this.count,
    required this.perModels,
  });

  factory WargearBudget.fromJson(Object? v) {
    final j = asMap(v);
    return WargearBudget(
      items: strList(j['items']),
      count: intOr(j['count'], 0),
      perModels: asInt(j['per_models']),
    );
  }
}

/// One model entry inside a datasheet's composition.
class CompositionModel {
  final String name;
  final int min;
  final int max;
  final bool isLeaderModel;

  /// What this model carries before the player changes anything.
  final List<String> defaultWeaponIds;

  const CompositionModel({
    required this.name,
    required this.min,
    required this.max,
    required this.isLeaderModel,
    required this.defaultWeaponIds,
  });

  factory CompositionModel.fromJson(Object? v) {
    final j = asMap(v);
    final min = intOr(j['min'], 1);
    return CompositionModel(
      name: strOr(j['name'], '(unnamed)'),
      min: min,
      max: intOr(j['max'], min),
      isLeaderModel: j['is_leader_model'] == true,
      defaultWeaponIds: strList(j['default_weapon_ids']),
    );
  }
}

/// How a datasheet is made up, and what it carries out of the box.
///
/// The builder needs this and nothing else does: adding a unit has to produce
/// a legal starting loadout, and "every weapon on the datasheet" is not that
/// — a Crisis suit lists nine and carries three.
class UnitComposition {
  final String unitId;
  final List<CompositionModel> models;

  const UnitComposition({required this.unitId, required this.models});

  factory UnitComposition.fromJson(Object? v) {
    final j = asMap(v);
    return UnitComposition(
      unitId: strOr(j['unit_id'], ''),
      models: asList(j['models'])
          .map(CompositionModel.fromJson)
          .toList(growable: false),
    );
  }

  /// The smallest legal unit, which is what "add this datasheet" should give.
  int get defaultModels => models.fold(0, (sum, m) => sum + m.min);

  /// The largest legal unit, or null when the record does not say.
  ///
  /// Read from the composition rather than the datasheet's `model_count`,
  /// which is derived and demonstrably wrong on eight datasheets — a Loota mob
  /// comes to five and its `model_count.max` says one. The composition is the
  /// curated record: it names each model and how many of it the unit may
  /// field.
  ///
  /// Null rather than a guess where the maxima are absent or add up to less
  /// than the minimum, because a cap below the unit's own smallest legal size
  /// would refuse a list the rules allow — which is the failure §2.3 exists to
  /// avoid.
  int? get maxModels {
    if (models.isEmpty) return null;
    final total = models.fold(0, (sum, m) => sum + m.max);
    return total >= defaultModels && total > 0 ? total : null;
  }

  /// The default loadout as wargear counts, keyed by the **item id** the
  /// roster stores — the weapon id with any `-<unitId>` suffix removed, so
  /// `Catalogue.weaponFor` can re-scope it (§7.3.5).
  Map<String, int> defaultWargear() {
    final tally = <String, int>{};
    for (final model in models) {
      for (final weaponId in model.defaultWeaponIds) {
        final suffix = '-$unitId';
        final itemId = weaponId.endsWith(suffix)
            ? weaponId.substring(0, weaponId.length - suffix.length)
            : weaponId;
        tally[itemId] = (tally[itemId] ?? 0) + model.min;
      }
    }
    return tally;
  }
}

/// One published wargear choice for one datasheet (`wargear-options.json`).
///
/// The file was fetched from the start and never parsed, because §2.3 settled
/// that the builder stays permissive and enforcing this data would refuse
/// legal lists. That is still true of one half of it and not the other, and
/// the difference is worth stating precisely (DESIGN.md §4.5):
///
///   * [choices] **enumerates** the legal selections — Stealth Battlesuits
///     publish `[gun] | [marker, gun] | [marker]`, which is the rulebook's "up
///     to two drones, of different types" written out. An enumeration is a
///     closed list and can be trusted as one.
///   * [maxCount] on its own is a bare number, and the reference list — a
///     validated 2,000 point export — carries four T'au flamers on a Commander
///     whose record says `max_count: 3`. So a bare cap is shown and validated
///     against, never used to refuse the tap.
///
/// A bundle repeating an item (`[heavy-flamer, heavy-flamer]`) means exactly
/// what it says: two of them is one legal choice.
class SourceWargearOption {
  final String id;
  final String unitId;

  /// Items this choice takes away. Empty when the choice only adds.
  final List<String> replaces;

  /// A single fixed replacement, when the choice is not an enumeration.
  final List<String> replacement;

  /// Alternative bundles, each one a complete legal selection.
  final List<List<String>> choices;

  /// Which model in the unit may take it, when the record says.
  final String? modelName;

  /// How many may be taken, when the record says. Advisory — see above.
  final int? maxCount;

  /// One per this many models, when the record says.
  final int? perModels;

  final bool anyNumber;
  final bool isFree;

  const SourceWargearOption({
    required this.id,
    required this.unitId,
    this.replaces = const [],
    this.replacement = const [],
    this.choices = const [],
    this.modelName,
    this.maxCount,
    this.perModels,
    this.anyNumber = false,
    this.isFree = true,
  });

  /// The same record with every item id passed through [rename].
  ///
  /// Used to bring published option ids into the roster's id space, which is
  /// unscoped — see [SourceUnit.unscope].
  SourceWargearOption mapIds(String Function(String) rename) =>
      SourceWargearOption(
        id: id,
        unitId: unitId,
        replaces: [for (final r in replaces) rename(r)],
        replacement: [for (final r in replacement) rename(r)],
        choices: [
          for (final bundle in choices)
            [for (final item in bundle) rename(item)],
        ],
        modelName: modelName,
        maxCount: maxCount,
        perModels: perModels,
        anyNumber: anyNumber,
        isFree: isFree,
      );

  factory SourceWargearOption.fromJson(Object? v) {
    final j = asMap(v);
    final constraint = asMap(j['model_constraint']);
    return SourceWargearOption(
      id: strOr(j['id'], ''),
      unitId: strOr(j['unit_id'], ''),
      replaces: [for (final r in asList(j['replaces'])) '$r'],
      replacement: [for (final r in asList(j['replacement'])) '$r'],
      choices: [
        for (final bundle in asList(j['replacement_choice']))
          [for (final item in asList(bundle)) '$item'],
      ],
      modelName: str(constraint['model_name']),
      maxCount: int.tryParse(strOr(constraint['max_count'], '')),
      perModels: int.tryParse(strOr(constraint['per_n_models'], '')),
      anyNumber: constraint['any_number'] == true,
      isFree: j['is_free'] != false,
    );
  }

  /// Everything this record could put on the unit.
  Set<String> get offered => {
        ...replacement,
        for (final bundle in choices) ...bundle,
      };

  /// True when the bundles spell out whole selections rather than listing
  /// single items under a cap. Only these are worth enforcing.
  bool get isEnumeration => choices.any((bundle) => bundle.length > 1);
}

class SourceUnit {
  final String id;
  final String name;
  final String factionId;
  final List<ModelProfile> profiles;
  final List<PointsBracket> points;

  /// The model's base, as published — `{shape: round, diameter: 32}`,
  /// `{shape: oval, width: 105, length: 70}` or `{shape: hull}`.
  ///
  /// Carried in the data since the first bundle and read by nothing until the
  /// Warhammer Event Companion's base size guide filled in 95 datasheets that
  /// had none and corrected 17 (§3.17). Kept as the published map rather than
  /// a type: three shapes with different fields, and no screen depends on it
  /// yet.
  final Map<String, Object?> baseSizeMm;
  final List<WargearCost> wargearCosts;
  final List<WargearBudget> wargearBudgets;
  final List<String> keywords;
  final List<String> factionKeywords;
  final List<String> abilityIds;
  final List<String> weaponIds;
  final String? attachmentRole;

  /// Which game modes this datasheet belongs to.
  ///
  /// **Empty means every mode**, which `game-modes.json` states outright:
  /// matched play is "the default scope for every entity that omits
  /// game_modes". Only the Combat Patrol datasheets name a mode, and they are
  /// the reason this is read at all — see [isMatchedPlay].
  final List<String> gameModes;

  final GameVersion gameVersion;

  const SourceUnit({
    required this.id,
    required this.name,
    required this.factionId,
    required this.profiles,
    required this.points,
    required this.wargearCosts,
    required this.wargearBudgets,
    required this.keywords,
    required this.factionKeywords,
    required this.abilityIds,
    required this.weaponIds,
    this.wargearCaps = const {},
    this.isLegend = false,
    required this.attachmentRole,
    this.gameModes = const [],
    required this.gameVersion,
    this.baseSizeMm = const {},
  });

  factory SourceUnit.fromJson(Object? v) {
    final j = asMap(v);
    return SourceUnit(
      id: strOr(j['id'], ''),
      name: strOr(j['name'], '(unnamed)'),
      factionId: strOr(j['faction_id'], ''),
      profiles: asList(j['profiles'])
          .map(ModelProfile.fromJson)
          .toList(growable: false),
      baseSizeMm: asMap(j['base_size_mm']),
      points: asList(j['points'])
          .map(PointsBracket.fromJson)
          .toList(growable: false),
      wargearCosts: asList(j['wargear_costs'])
          .map(WargearCost.fromJson)
          .toList(growable: false),
      wargearBudgets: asList(j['wargear_budgets'])
          .map(WargearBudget.fromJson)
          .toList(growable: false),
      keywords: strList(j['keywords']),
      factionKeywords: strList(j['faction_keywords']),
      abilityIds: strList(j['ability_ids']),
      weaponIds: strList(j['weapon_ids']),
      isLegend: j['is_legend'] == true,
      wargearCaps: {
        for (final e in asMap(j['wargear_caps']).entries)
          if (asInt(e.value) case final v? when v > 0) e.key: v,
      },
      attachmentRole: str(j['attachment_role']),
      gameModes: strList(j['game_modes']),
      gameVersion: GameVersion.fromJson(j['game_version']),
    );
  }

  /// The item id the roster stores for [scopedId].
  ///
  /// Weapons are per-carrier, so the same gun is `cyclic-ion-blaster` in one
  /// place and `cyclic-ion-blaster-commander-in-enforcer-battlesuit` in
  /// another, and the two files disagree about which to use: `weapon_ids`
  /// carries the scoped form while `wargear_budgets` sometimes carries it and
  /// sometimes not. A roster keyed by both ends up listing one weapon twice
  /// under one name, so everything that builds a datasheet's vocabulary goes
  /// through here (§7.3.5).
  String unscope(String scopedId) {
    final suffix = '-$id';
    return scopedId.endsWith(suffix)
        ? scopedId.substring(0, scopedId.length - suffix.length)
        : scopedId;
  }

  /// Everything this datasheet can carry, as roster item ids.
  /// Every rule this datasheet can have: printed on it, or brought by wargear
  /// it may buy.
  ///
  /// The two live in different fields and both are rules. 40kdc files a drone
  /// under `wargear_budgets` and BSData reaches one through a `Drones (0-2)`
  /// group, so neither source puts them all in `ability_ids` — and a screen
  /// reading `ability_ids` alone stopped showing a Marker Drone the army had
  /// actually bought. Whether a *particular* unit has one is a separate
  /// question, answered by checking its roster entry against the budget.
  List<String> get ruleVocabulary => [
        ...abilityIds,
        for (final budget in wargearBudgets)
          for (final item in budget.items)
            if (!abilityIds.contains(item)) item,
      ];

  /// The most of each item this datasheet may take, as BSData states it.
  ///
  /// **Per item, and authoritative where it exists.** 40kdc publishes a
  /// single `max_count` over a whole choice list — 3 across ten different
  /// weapons on a Commander — which is a different quantity from "at most
  /// four T'au flamers" and wrong in both directions: it forbids the fourth
  /// flamer a validated list fields and permits three shield generators.
  final Map<String, int> wargearCaps;

  Set<String> get wargearVocabulary => {
        for (final weaponId in weaponIds) unscope(weaponId),
        for (final budget in wargearBudgets)
          for (final item in budget.items) unscope(item),
      };

  /// Shelved out of the tournament pool.
  ///
  /// 485 of 1,857 datasheets — Crusaders, Death Cult Assassins, Celestian
  /// Sacresant Aveline. They are still real datasheets and a Legends game is
  /// a real game, so they are kept and hidden rather than dropped (§3.10).
  final bool isLegend;

  /// Attaches as a **Leader**. 250 datasheets.
  bool get isLeader => attachmentRole == 'leader';

  /// Attaches as **Support**. 37 datasheets, the Hospitaller among them.
  ///
  /// A distinct role, not a second name for Leader: a unit may be joined by
  /// one of each **at the same time**, so they cannot share a slot. Treating
  /// `support` as "not an attaching character" left the Hospitaller with no
  /// way to join anything, even though `leader-attachments.json` publishes
  /// its eligible bodyguards.
  bool get isSupport => attachmentRole == 'support';

  /// Whether this datasheet joins another unit at all, in either role.
  bool get attachesToUnit => isLeader || isSupport;

  bool hasKeyword(String keyword) =>
      keywords.any((k) => k.toLowerCase() == keyword.toLowerCase());

  bool get isCharacter => hasKeyword('Character');
  bool get isEpicHero => hasKeyword('Epic Hero');

  /// The order [battlefieldRole] headings appear in, so every list that
  /// groups by role reads the same way round.
  static const roleOrder = [
    'Characters',
    'Epic Heroes',
    'Battleline',
    'Infantry',
    'Mounted',
    'Swarms',
    'Vehicles',
    'Monsters',
    'Aircraft',
    'Transports',
    'Fortifications',
    'Other',
  ];

  /// The heading this datasheet files under, for a list long enough to need
  /// headings — a faction is fifty sheets and Adeptus Astartes is 194.
  ///
  /// **Ordered, because the keywords overlap.** A Canoness is Infantry *and*
  /// Character; a Chaos Lord on a bike is Mounted and Character too. Whichever
  /// test runs first decides the heading, so the ones a player navigates by
  /// run first: characters are looked up by who they are, transports by what
  /// they carry, and everything else by what it is made of.
  ///
  /// Epic Heroes sit with characters rather than apart. They are found by
  /// name, and a separate heading would put Marneus Calgar somewhere other
  /// than where you go looking for a Captain.
  String get battlefieldRole {
    // Epic Heroes file apart from the rest. They are Characters by keyword,
    // but they are the named ones — one to an army, chosen by name rather
    // than picked off a list — and a player looking for Shadowsun is not
    // looking through Commanders (§4.1).
    if (isEpicHero) return 'Epic Heroes';
    if (isCharacter) return 'Characters';
    if (hasKeyword('Battleline')) return 'Battleline';
    if (hasKeyword('Dedicated Transport') || hasKeyword('Transport')) {
      return 'Transports';
    }
    if (hasKeyword('Monster')) return 'Monsters';
    if (hasKeyword('Aircraft')) return 'Aircraft';
    if (hasKeyword('Fortification')) return 'Fortifications';
    if (hasKeyword('Vehicle') || hasKeyword('Walker')) return 'Vehicles';
    if (hasKeyword('Mounted') || hasKeyword('Beast') || hasKeyword('Cavalry')) {
      return 'Mounted';
    }
    if (hasKeyword('Swarm')) return 'Swarms';
    if (hasKeyword('Infantry')) return 'Infantry';
    return 'Other';
  }

  /// Whether this datasheet belongs in a matched-play army.
  ///
  /// **Combat Patrol datasheets cost nothing, and that is not an error.** That
  /// mode plays a fixed boxed roster, so its sheets are priced at zero and
  /// scoped with `game_modes: ["combat-patrol"]`. 98 of them exist across 21
  /// factions and the builder was offering every one — free units in a
  /// points-limited army, and worse, near-duplicates of the real datasheets:
  /// *Sanctuary Guardians Celestian Sacresants* sits beside *Celestian
  /// Sacresants* in the picker, and picking the wrong one gives a unit no
  /// character can be attached to, because the attachment rules name the
  /// matched-play sheet.
  ///
  /// Absence means every mode, per `game-modes.json`, so this stays true for
  /// the 33 of 37 Sororitas sheets that say nothing.
  bool get isMatchedPlay =>
      gameModes.isEmpty || gameModes.contains('matched-play');

  /// Battleline and Dedicated Transport share a doubled duplicate cap
  /// (DESIGN.md §4.4), so they are tested together.
  bool get hasDoubledCap =>
      hasKeyword('Battleline') || hasKeyword('Dedicated Transport');

  /// Selects the bracket for [models] models when this is the [copyIndex]-th
  /// unit of this datasheet in the roster (1-based).
  ///
  /// 11e prices some datasheets by copy index as well as model count, so the
  /// full cost of a unit is `bracketFor(...).cost` plus the per-instance
  /// wargear costs — see DESIGN.md §2.1. Verified against a real 2,000 pt list:
  /// Crisis Fireknife is 100 base + 6 missile pods at 5 = 130.
  PointsBracket? bracketFor({required int models, int copyIndex = 1}) {
    for (final b in points) {
      final withinModels =
          models >= b.models && models <= (b.modelsMax ?? b.models);
      final withinCopies = copyIndex >= (b.unitCountMin ?? 1) &&
          copyIndex <= (b.unitCountMax ?? 1 << 30);
      if (withinModels && withinCopies) return b;
    }
    return null;
  }

  int costOfWargear(String itemId) => wargearCosts
      .where((c) => c.itemId == itemId)
      .fold(0, (sum, c) => sum + c.cost);
}

/// A weapon keyword together with the parameters that give it its meaning.
///
/// The parameters are not decoration. `melta` is Melta 2, `anti` is
/// Anti-Infantry 4+, `rapid-fire` is Rapid Fire 1 — **201 of 920 keyword
/// instances in the snapshot carry one**, and dropping them turns a specific
/// rule into a vague one at exactly the moment a player is reading it to
/// decide whether to shoot.
/// A weapon keyword's printed rule.
///
/// Distinct from [WeaponKeyword], which is one weapon's *use* of a keyword and
/// carries the parameters — `[SUSTAINED HITS 1]`. This is the definition, and
/// there is one of it per keyword rather than one per weapon.
class WeaponKeywordText {
  final String id;
  final String name;
  final String text;

  const WeaponKeywordText({
    required this.id,
    required this.name,
    required this.text,
  });
}

class WeaponKeyword {
  final String id;

  /// `{value: 2}` for Melta 2, `{target_keyword: INFANTRY, threshold: 4}` for
  /// Anti-Infantry 4+. Kept raw so a keyword the app has never heard of still
  /// shows its numbers.
  final Map<String, String> parameters;

  const WeaponKeyword(this.id, {this.parameters = const {}});

  factory WeaponKeyword.fromJson(Object? v) {
    final j = asMap(v);
    final params = <String, String>{};
    for (final entry in asMap(j['parameters']).entries) {
      final value = str(entry.value);
      if (value != null && value.isNotEmpty) params[entry.key] = value;
    }
    return WeaponKeyword(strOr(j['keyword_id'], ''), parameters: params);
  }

  Map<String, Object?> toJson() => {
        'keyword_id': id,
        if (parameters.isNotEmpty) 'parameters': parameters,
      };

  /// As it is printed on a datasheet: `MELTA 2`, `ANTI-INFANTRY 4+`,
  /// `SUSTAINED HITS 1`, `TORRENT`.
  String get label {
    final name = id.replaceAll('-', ' ').toUpperCase();
    final target = parameters['target_keyword'];
    final threshold = parameters['threshold'];
    if (target != null || threshold != null) {
      final subject = target == null ? name : '$name-${target.toUpperCase()}';
      return threshold == null ? subject : '$subject $threshold+';
    }
    final value = parameters['value'];
    if (value != null) return '$name $value';
    // An unrecognised parameter set is shown rather than dropped: a keyword
    // rendered without its numbers reads as though it had none.
    if (parameters.isEmpty) return name;
    return '$name ${parameters.values.join('/')}';
  }

  /// Stable identity for aggregation — Melta 2 and Melta 4 are not the same
  /// profile, and keying on the bare id would merge them.
  String get key {
    if (parameters.isEmpty) return id;
    final keys = parameters.keys.toList()..sort();
    return '$id(${keys.map((k) => '$k=${parameters[k]}').join(',')})';
  }

  @override
  String toString() => label;
}

class WeaponProfile {
  final String name;
  final String? range;
  final Map<String, String> stats;
  final List<WeaponKeyword> keywords;

  const WeaponProfile({
    required this.name,
    required this.range,
    required this.stats,
    required this.keywords,
  });

  /// Bare keyword ids, for callers that only ask whether a keyword is present.
  List<String> get keywordIds => [for (final k in keywords) k.id];

  bool hasKeyword(String id) => keywords.any((k) => k.id == id);

  factory WeaponProfile.fromJson(Object? v) {
    final j = asMap(v);
    final rawStats = asMap(j['stats']);
    final stats = <String, String>{};
    for (final entry in rawStats.entries) {
      final s = str(entry.value);
      if (s != null) stats[entry.key] = s;
    }
    return WeaponProfile(
      name: strOr(j['name'], '(unnamed)'),
      range: str(j['range']),
      stats: stats,
      keywords: asList(j['keywords'])
          .map(WeaponKeyword.fromJson)
          .where((k) => k.id.isNotEmpty)
          .toList(growable: false),
    );
  }

  /// Skill characteristic, or null for Torrent-style auto-hitting weapons.
  String? get skill => stats['BS'] ?? stats['WS'];

  /// Whether this *profile* is a melee profile.
  ///
  /// A weapon's declared `type` is not sufficient: several weapons are typed
  /// `ranged` yet carry both a `Ranged` and a `Melee` profile — the T'au
  /// Fusion eliminator has BS2+ at 18" and WS4+ in combat. The reliable
  /// discriminator is the skill characteristic, `WS` for melee and `BS` for
  /// ranged, with the range string and then the weapon's own type as
  /// fallbacks for auto-hitting profiles that carry neither.
  bool isMelee({required bool weaponIsMelee}) {
    if (stats.containsKey('WS')) return true;
    if (stats.containsKey('BS')) return false;
    if ((range ?? '').toLowerCase() == 'melee') return true;
    return weaponIsMelee;
  }

  /// Identity used for aggregation on the shooting/fight screens.
  ///
  /// DESIGN.md §7.3.5: aggregation keys on the *resolved profile*, never on the
  /// weapon name. A Commander's Missile pod (BS3+) and a Crisis suit's Missile
  /// pod (BS4+) are the same name and must remain separate rows.
  String get profileKey {
    final keys = stats.keys.toList()..sort();
    final body = keys.map((k) => '$k=${stats[k]}').join(',');
    final kw = (keywords.map((k) => k.key).toList()..sort()).join('+');
    return '$range|$body|$kw';
  }
}

class SourceWeapon {
  final String id;
  final String name;
  final String type;
  final List<WeaponProfile> profiles;
  final GameVersion gameVersion;

  const SourceWeapon({
    required this.id,
    required this.name,
    required this.type,
    required this.profiles,
    required this.gameVersion,
  });

  factory SourceWeapon.fromJson(Object? v) {
    final j = asMap(v);
    return SourceWeapon(
      id: strOr(j['id'], ''),
      name: strOr(j['name'], '(unnamed)'),
      type: strOr(j['type'], 'unknown'),
      profiles: asList(j['profiles'])
          .map(WeaponProfile.fromJson)
          .toList(growable: false),
      gameVersion: GameVersion.fromJson(j['game_version']),
    );
  }

  bool get isRanged => type == 'ranged';
}

class SourceStratagem {
  final String id;
  final String name;
  final String? category;
  final String? type;
  final String? detachmentId;
  final String? playerTurn;
  final String? timing;
  final String? abilityId;

  /// `AUTOREACTIVE CAMOUFLAGE` in the data, `Autoreactive Camouflage` on a
  /// screen.
  ///
  /// Upstream shouts inconsistently — some names are upper case and some are
  /// not — and a list that shouts at random reads as a bug. Lives here rather
  /// than in one widget because two surfaces now show these names, and the
  /// second one shouted while the first did not.
  String get displayName {
    if (name != name.toUpperCase()) return name;
    return name
        .split(' ')
        .map((w) => w.isEmpty
            ? w
            : '${w[0].toUpperCase()}${w.substring(1).toLowerCase()}')
        .join(' ');
  }

  /// The stratagem as printed: when it may be used, what it targets, what it
  /// does, and what restricts it.
  ///
  /// 40kdc publishes none — §3.0's position, and the reason this was the last
  /// surface in the app showing a name and a cost and nothing else (§3.12).
  final String? text;

  final int cpCost;
  final List<String> phases;

  /// Keywords a target must have **all** of.
  final List<String> requiredKeywords;

  /// Keywords a target must have **at least one** of.
  final List<String> requiredKeywordsAny;

  final GameVersion gameVersion;

  const SourceStratagem({
    required this.id,
    required this.name,
    required this.category,
    required this.type,
    required this.detachmentId,
    required this.playerTurn,
    required this.timing,
    required this.abilityId,
    required this.cpCost,
    required this.phases,
    required this.gameVersion,
    this.text,
    this.requiredKeywords = const [],
    this.requiredKeywordsAny = const [],
  });

  factory SourceStratagem.fromJson(Object? v) {
    final j = asMap(v);
    final restrictions = asMap(j['target_restrictions']);
    return SourceStratagem(
      id: strOr(j['id'], ''),
      name: strOr(j['name'], '(unnamed)'),
      category: str(j['category']),
      type: str(j['type']),
      detachmentId: str(j['detachment_id']),
      playerTurn: str(j['player_turn']),
      timing: str(j['timing']),
      abilityId: str(j['ability_id']),
      text: str(j['text']),
      cpCost: intOr(j['cp_cost'], 0),
      phases: strList(j['phases']),
      requiredKeywords: strList(restrictions['required_keywords']),
      requiredKeywordsAny: strList(restrictions['required_keywords_any']),
      gameVersion: GameVersion.fromJson(j['game_version']),
    );
  }

  /// Whether this stratagem is played on a nominated unit at all.
  ///
  /// The data does not say directly, so it is inferred from the restrictions:
  /// a stratagem that names keywords is targeted, and one that does not may
  /// still be — Command Re-roll targets nothing. Callers treat a target as
  /// optional rather than demanding one, which is the honest reading.
  bool get namesTargetKeywords =>
      requiredKeywords.isNotEmpty || requiredKeywordsAny.isNotEmpty;

  bool permitsTarget(Iterable<String> keywords) {
    final have = keywords.map((k) => k.toLowerCase()).toSet();
    for (final needed in requiredKeywords) {
      if (!have.contains(needed.toLowerCase())) return false;
    }
    if (requiredKeywordsAny.isEmpty) return true;
    return requiredKeywordsAny.any((k) => have.contains(k.toLowerCase()));
  }
}

/// An Enhancement or a Unit Upgrade.
///
/// One record shape, two mechanics (§2.1). `upgrade_tag` is the discriminator:
/// an Enhancement goes on a Character and consumes one of the army's two or
/// three slots, while a Unit Upgrade may go on a non-Character and three
/// instances of the same one count as a single slot. Treating them alike is
/// the miscount the roster model exists to prevent.
class SourceEnhancement {
  final String id;
  final String name;
  final String? detachmentId;
  final int cost;
  final String? abilityId;
  final bool isUpgrade;
  final bool isUnique;
  final int? maxTargets;

  /// Keywords a bearer must have, and must not have.
  final List<String> keywordRestrictions;
  final List<String> exclusionKeywords;

  /// Datasheets this may go on, when it is limited to named ones.
  ///
  /// **A Unit Upgrade usually names its datasheet and the data usually does
  /// not.** `Negation Emitters (Upgrade)` and `Unmasking Suite (Upgrade)`
  /// both publish `keyword_restrictions: ["T’au Empire"]` and nothing else,
  /// so every Character in the army was offered them. A keyword restriction
  /// cannot express it either: `Unmasking Suite` goes on Pathfinders **or**
  /// Stealth Battlesuits, and restrictions are all required at once.
  ///
  /// Empty means unrestricted, which is the common case.
  final List<String> unitIds;

  final GameVersion gameVersion;

  const SourceEnhancement({
    required this.id,
    required this.name,
    required this.detachmentId,
    required this.cost,
    required this.abilityId,
    required this.isUpgrade,
    required this.isUnique,
    required this.maxTargets,
    required this.keywordRestrictions,
    required this.exclusionKeywords,
    this.unitIds = const [],
    required this.gameVersion,
  });

  factory SourceEnhancement.fromJson(Object? v) {
    final j = asMap(v);
    return SourceEnhancement(
      id: strOr(j['id'], ''),
      name: strOr(j['name'], '(unnamed)'),
      detachmentId: str(j['detachment_id']),
      cost: intOr(j['cost'], 0),
      abilityId: str(j['ability_id']),
      isUpgrade: j['upgrade_tag'] == true,
      isUnique: j['is_unique'] == true,
      maxTargets: asInt(j['max_targets']),
      keywordRestrictions: strList(j['keyword_restrictions']),
      exclusionKeywords: strList(j['exclusion_keywords']),
      unitIds: strList(j['unit_ids']),
      gameVersion: GameVersion.fromJson(j['game_version']),
    );
  }

  /// Whether [unit] may carry this, given the faction it belongs to.
  ///
  /// Four rules, in the order they eliminate:
  ///
  /// - **An Epic Hero takes nothing.** They arrive with their own wargear and
  ///   the rulebook says so; upstream encodes it nowhere, so it is stated
  ///   here rather than derived.
  /// - **An Enhancement goes on a Character.** Unit Upgrades are exempt —
  ///   they are a separate mechanic (§2.1) and name their own targets, one of
  ///   which is *Exorcist*, a tank.
  /// - **Every `keyword_restrictions` entry must be satisfied**, and
  /// - **no `exclusion_keywords` entry may be.**
  ///
  /// A restriction is satisfied by a keyword, a faction keyword, the
  /// datasheet's own **name** — *Canoness with Jump Pack* is written as a
  /// restriction — the **faction's** name, since `Chaos Space Marines` is
  /// written against datasheets whose faction keyword is `Heretic Astartes`,
  /// or by a **compound** of those: `Adepta Sororitas Character` is the
  /// faction keyword and `Character` run together. Measured across all 35
  /// factions, that reads 805 of 880 restrictions; without names and faction
  /// names it reads 791, and every enhancement in two whole factions becomes
  /// impossible to take.
  bool canBeTakenBy(SourceUnit unit, {String? factionName}) {
    if (unit.isEpicHero) return false;
    if (!isUpgrade && !unit.isCharacter) return false;
    if (unitIds.isNotEmpty && !unitIds.contains(unit.id)) return false;

    final vocabulary = <String>{
      for (final k in unit.keywords) _fold(k),
      for (final k in unit.factionKeywords) _fold(k),
      _fold(unit.name),
      if (factionName != null) _fold(factionName),
    }..remove('');

    for (final restriction in keywordRestrictions) {
      if (!_satisfies(_fold(restriction), vocabulary)) return false;
    }
    for (final exclusion in exclusionKeywords) {
      if (vocabulary.contains(_fold(exclusion))) return false;
    }
    return true;
  }

  static String _fold(String value) => value
      .toLowerCase()
      .replaceAll('’', "'")
      .split(RegExp(r'\s+'))
      .join(' ')
      .trim();

  /// Exact, or a compound whose parts are each satisfied.
  static bool _satisfies(String restriction, Set<String> vocabulary) {
    if (vocabulary.contains(restriction)) return true;
    final words = restriction.split(' ');
    for (var i = 1; i < words.length; i++) {
      if (vocabulary.contains(words.take(i).join(' ')) &&
          _satisfies(words.skip(i).join(' '), vocabulary)) {
        return true;
      }
    }
    return false;
  }

  /// `T'AU EMPIRE, not SHAPER` — who may take it, in one line.
  String get restrictionSummary {
    final parts = <String>[
      if (keywordRestrictions.isNotEmpty)
        keywordRestrictions.map((k) => k.toUpperCase()).join(' '),
      if (exclusionKeywords.isNotEmpty)
        'not ${exclusionKeywords.map((k) => k.toUpperCase()).join(' or ')}',
    ];
    return parts.join(', ');
  }
}

class SourceDetachment {
  final String id;
  final String name;
  final String factionId;
  final String? detachmentRuleId;
  final int detachmentPoints;
  final List<String> forceDispositions;
  final List<String> uniqueTags;
  final List<String> stratagemIds;
  final List<String> enhancementIds;

  /// The modes this detachment belongs to; empty means matched play.
  final List<String> gameModes;

  final GameVersion gameVersion;

  const SourceDetachment({
    required this.id,
    required this.name,
    required this.factionId,
    required this.detachmentRuleId,
    required this.detachmentPoints,
    required this.forceDispositions,
    required this.uniqueTags,
    required this.stratagemIds,
    required this.enhancementIds,
    required this.gameVersion,
    this.gameModes = const [],
  });

  factory SourceDetachment.fromJson(Object? v) {
    final j = asMap(v);
    return SourceDetachment(
      id: strOr(j['id'], ''),
      name: strOr(j['name'], '(unnamed)'),
      factionId: strOr(j['faction_id'], ''),
      detachmentRuleId: str(j['detachment_rule_id']),
      detachmentPoints: intOr(j['detachment_points'], 0),
      forceDispositions: strList(j['force_dispositions']),
      uniqueTags: strList(pick(j, ['unique_tags', 'tags'])),
      stratagemIds: strList(j['stratagem_ids']),
      enhancementIds: strList(j['enhancement_ids']),
      gameModes: strList(j['game_modes']),
      gameVersion: GameVersion.fromJson(j['game_version']),
    );
  }

  /// Offerable in a matched-play list.
  ///
  /// The same rule [SourceUnit.isMatchedPlay] applies: an empty list means
  /// matched play, and only the Combat Patrol records name a mode. 24 of them
  /// exist, one per faction — `Sudden Dawn Cadre`, `’Ardmob`, `Maggot Lords`
  /// — and the picker was offering every one of them beside the real
  /// detachments, priced at 1 DP, in a Strike Force.
  bool get isMatchedPlay =>
      gameModes.isEmpty || gameModes.contains('matched-play');
}

class SourceAbility {
  final String abilityId;
  final String name;
  final String? abilityType;
  final String? behavior;
  final Map<String, dynamic> effect;

  /// The rule as printed, when the source carries it.
  ///
  /// 40kdc deliberately publishes no rules text, which is why the renderer
  /// (§7.3.6) exists: it says what a structured effect means in English rather
  /// than quoting anything. BattleScribe does carry the printed wording, and
  /// §3.10 records the decision to keep it — so an ability can now arrive with
  /// prose, structure, or both, and a consumer that has one should not assume
  /// the other.
  ///
  /// Null and empty are the same thing here: no text.
  final String? description;

  /// `{frequency: once-per-turn}` and similar. Kept raw — the renderer reads
  /// it, nothing else needs a typed view yet.
  final Map<String, dynamic> usage;

  /// `{event, subject, optional}` for reactive abilities. Raw for the same
  /// reason as [usage].
  final Map<String, dynamic> trigger;

  final List<String> unitIds;
  final GameVersion gameVersion;

  const SourceAbility({
    required this.abilityId,
    required this.name,
    this.abilityType,
    this.behavior,
    this.effect = const {},
    this.description,
    this.usage = const {},
    this.trigger = const {},
    this.unitIds = const [],
    required this.gameVersion,
  });

  factory SourceAbility.fromJson(Object? v) {
    final j = asMap(v);
    return SourceAbility(
      abilityId: strOr(j['ability_id'], ''),
      name: strOr(j['name'], '(unnamed)'),
      abilityType: str(j['ability_type']),
      behavior: str(j['behavior']),
      effect: asMap(j['effect']),
      description: str(j['description']),
      usage: asMap(j['usage']),
      trigger: asMap(j['trigger']),
      unitIds: strList(j['unit_ids']),
      gameVersion: GameVersion.fromJson(j['game_version']),
    );
  }

  /// Outermost effect discriminator, e.g. `conditional`, `stat-modifier`.
  /// The rules renderer (DESIGN.md §7.3.6) dispatches on this.
  String get effectType => strOr(effect['type'], 'none');

  /// An invulnerable save this ability grants unconditionally, if any.
  ///
  /// The two encodings coexist upstream: most models carry `invuln_sv` on the
  /// profile, but the Commander in Coldstar Battlesuit's 4+ lives only in its
  /// `shield-generator` ability. A screen that reads the statline alone shows
  /// no invulnerable save on a model that has one.
  ///
  /// Deliberately does not descend into `conditional`. A save that applies
  /// only sometimes is a rule to read, not a number to print in a column that
  /// says the model always has it.
  int? get unconditionalInvulnerableSave => _invulnIn(effect);

  static int? _invulnIn(Map<String, dynamic> node) {
    switch (strOr(node['type'], '')) {
      case 'invulnerable-save':
        return asInt(asMap(node['modifier'])['invuln_sv']);
      case 'sequence':
        for (final step in asList(node['steps'])) {
          final found = _invulnIn(asMap(step));
          if (found != null) return found;
        }
    }
    return null;
  }

  /// The weapon this ability grants its bearer, if it names one.
  ///
  /// Drones are wargear that give the model a rule, and a Gun Drone's rule is
  /// a twin pulse carbine (§7.3.7). Only an explicit `weapon_id` counts:
  /// `{grant_type: ranged-weapon}` with no id names nothing, and guessing
  /// which weapon was meant is the invention §7.6 forbids.
  /// Inches this ability lets the unit move before the first turn, or null
  /// when it is not a Scout move.
  ///
  /// Read from the effect rather than the name. Upstream writes the distance
  /// into both — `Scouts 7"` and `{move_type: scout, distance: 7}` — and the
  /// name is the half that varies: the same rule is spelled `Scouts` and
  /// `Scout` across factions, and a screen keyed on the spelling would quietly
  /// miss units (§7.3.10).
  int? get scoutDistance => _scoutIn(effect);

  static int? _scoutIn(Map<String, dynamic> node) {
    if (strOr(node['type'], '') == 'movement-modifier') {
      final modifier = asMap(node['modifier']);
      if (strOr(modifier['move_type'], '') == 'scout') {
        return asInt(modifier['distance']);
      }
    }
    for (final step in asList(node['steps'])) {
      final found = _scoutIn(asMap(step));
      if (found != null) return found;
    }
    final inner = node['effect'];
    if (inner is Map) return _scoutIn(asMap(inner));
    return null;
  }

  String? get grantedWeaponId => _grantedWeaponIn(effect);

  static String? _grantedWeaponIn(Map<String, dynamic> node) {
    if (strOr(node['type'], '') == 'ability-grant') {
      final id = str(asMap(node['modifier'])['weapon_id']);
      if (id != null) return id;
    }
    for (final step in asList(node['steps'])) {
      final found = _grantedWeaponIn(asMap(step));
      if (found != null) return found;
    }
    return null;
  }

  /// Structural fingerprint used to detect near-duplicate ability records —
  /// upstream carries both `weapon-support-system` and
  /// `weapon-support-systems` with identical effects (DESIGN.md §7.3.6).
  String get effectFingerprint => _fingerprint(effect);

  static String _fingerprint(Object? node) {
    if (node is Map) {
      final keys = node.keys.map((k) => k.toString()).toList()..sort();
      return '{${keys.map((k) => '$k:${_fingerprint(node[k])}').join(',')}}';
    }
    if (node is List) return '[${node.map(_fingerprint).join(',')}]';
    return str(node) ?? 'null';
  }
}

/// Which units a given leader may join. This is the data behind the `LEADS`
/// edge of DESIGN.md §2.2, and the reason leader legality is checkable rather
/// than left to the player.
class LeaderAttachment {
  final String leaderId;
  final List<String> eligibleBodyguardIds;

  const LeaderAttachment({
    required this.leaderId,
    required this.eligibleBodyguardIds,
  });

  factory LeaderAttachment.fromJson(Object? v) {
    final j = asMap(v);
    return LeaderAttachment(
      leaderId: strOr(j['leader_id'], ''),
      eligibleBodyguardIds: strList(j['eligible_bodyguard_ids']),
    );
  }
}

class PhaseMapping {
  final String sourceId;
  final String? sourceType;
  final List<String> phases;

  const PhaseMapping({
    required this.sourceId,
    required this.sourceType,
    required this.phases,
  });

  factory PhaseMapping.fromJson(Object? v) {
    final j = asMap(v);
    return PhaseMapping(
      sourceId: strOr(j['source_id'], ''),
      sourceType: str(j['source_type']),
      phases: strList(j['phases']),
    );
  }
}

/// One published question and its answer (§3.16).
///
/// Carried as text and never interpreted. A FAQ answers how two rules
/// interact — *can I use this ability while embarked?* — and there is no
/// record in the app for that to correct. Deriving one would be the app
/// adjudicating rather than quoting, which §7.6 already refuses.
class FactionFaq {
  final String id;
  final String question;
  final String answer;

  /// Where it was published, so a reader can tell a current answer from one
  /// that came with an older pack.
  final String source;

  /// The mission card this answers a question about, where it names one.
  ///
  /// Five of the mission deck's eight questions are about one card — Plunder,
  /// Beacon, Death Trap, Surveil the Foe, Vital Link — and those belong
  /// beside that card rather than in a list a player has to search. The other
  /// three are about the deck as a whole and carry no id.
  final String cardId;

  const FactionFaq({
    required this.id,
    required this.question,
    required this.answer,
    this.source = '',
    this.cardId = '',
  });

  factory FactionFaq.fromJson(Object? v) {
    final j = asMap(v);
    return FactionFaq(
      id: strOr(j['id'], ''),
      question: strOr(j['question'], ''),
      answer: strOr(j['answer'], ''),
      source: strOr(j['source'], ''),
      cardId: strOr(j['card_id'], ''),
    );
  }

  Map<String, Object?> toJson() => {
        'id': id,
        'question': question,
        'answer': answer,
        if (source.isNotEmpty) 'source': source,
        if (cardId.isNotEmpty) 'card_id': cardId,
      };
}
