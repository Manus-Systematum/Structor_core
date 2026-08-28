/// BattleScribe entries -> records in 40kdc's shape (DESIGN.md §3.10).
///
/// **Raw records, not typed models.** The obvious output was `SourceUnit` and
/// friends, and it is the wrong one: the bundler, the snapshot writer and the
/// corrections layer all work on the JSON the loader read, never on the DTOs.
/// Emitting JSON means the merge is a field-by-field diff of two records that
/// already speak the same language, the conflict log is readable by a person,
/// and every downstream consumer carries on unchanged.
///
/// The mapper is **partial, and honest about it**. BSData is a list-building
/// catalogue: it knows what a datasheet costs, what models it contains, what it
/// may carry and what its rules say. It knows nothing about missions, terrain,
/// stratagems, or the structured ability effects the play surfaces render from.
/// Everything in that second group stays on 40kdc, and this file does not
/// pretend to produce it.
library;

import 'dart:convert';

import '../../play/rule_text.dart';
import '../json.dart';
import 'bs_document.dart';
import 'bs_slug.dart';

/// Stamped on every record this mapper writes, so a merged dataset says which
/// lineage each field came from without anyone having to diff two trees.
const bsGameVersion = {'edition': '11th', 'dataslate': 'bsdata'};

class BsFaction {
  final String factionId;
  final List<Map<String, Object?>> units;
  final List<Map<String, Object?>> weapons;
  final List<Map<String, Object?>> abilities;
  final List<Map<String, Object?>> compositions;

  /// Weapon profiles dropped because the app cannot yet say which of a
  /// datasheet's variants of one weapon it carries. See §3.10.
  final List<String> droppedWeaponVariants;

  /// Names that slugged to the same id.
  ///
  /// Reported rather than resolved. A collision means two datasheets would
  /// share one record, and picking a winner quietly is how a unit disappears
  /// from a faction without anybody noticing.
  final List<String> collisions;

  const BsFaction({
    required this.factionId,
    required this.units,
    required this.weapons,
    required this.abilities,
    required this.compositions,
    required this.collisions,
    this.droppedWeaponVariants = const [],
  });
}

class BsMapper {
  final BsIndex index;

  /// The `pts` cost type id. Every entry lists all eight cost types — Crusade
  /// Points, Blackstone Fragments and the rest, all zero on a normal
  /// datasheet — so the type has to be matched, not the first cost taken.
  late final String _pts = index.costTypes.entries
      .firstWhere((e) => e.value == 'pts', orElse: () => const MapEntry('', ''))
      .key;

  BsMapper(this.index);

  /// One faction's records.
  ///
  /// [anchors] are the 40kdc weapon records, when there are any. They decide
  /// only one thing — which of several variants of a weapon keeps the plain
  /// id — and that one thing protects every saved roster and every correction
  /// already keyed to it.
  BsFaction faction(String factionId, {List<Object?> anchors = const []}) {
    final units = <String, Map<String, Object?>>{};

    /// Keyed by `slug|profile-fingerprint` until every datasheet has been
    /// read, because which variant deserves the plain id is not knowable
    /// until they have all been counted.
    final weapons = <String, Map<String, Object?>>{};
    final variantUsers = <String, Set<String>>{};
    final abilities = <String, Map<String, Object?>>{};
    final compositions = <String, Map<String, Object?>>{};
    final collisions = <String>[];

    /// Every keyword seen on any weapon profile in the faction.
    ///
    /// Collected across the whole faction rather than per datasheet: the rule
    /// for `[PRECISION]` is linked from the weapon entry, so a unit whose own
    /// guns do not spell the keyword still picked the rule up and filed it as
    /// wargear it could buy.
    final weaponKeywords = <String>{};
    final pending = <String, _Walk>{};

    for (final root in index.roots) {
      if (!_isDatasheet(root)) continue;
      final id = bsSlug(root.name);
      if (id.isEmpty) continue;
      if (units.containsKey(id)) {
        collisions.add('$id <- ${root.name}');
        continue;
      }

      final walk = _Walk(index, _pts)..visit(root);

      units[id] = {
        'id': id,
        'name': bsDisplayName(root.name),
        'faction_id': factionId,
        'profiles': walk.profiles,
        'points': _points(root, walk),
        if (walk.wargearCosts.isNotEmpty)
          'wargear_costs': walk.wargearCosts.values.toList(),
        'keywords': _keywords(root),
        'faction_keywords': _factionKeywords(root),
        'weapon_ids': walk.weaponIds.toList(),
        // Filled in below, once every datasheet's keywords are known.
        'ability_ids': const <String>[],
        'model_count': {'min': walk.modelCount, 'max': walk.modelCountMax},
        'is_legend': isLegends(root.name),
        'battlefield_role': root.primaryCategory,
        'game_version': bsGameVersion,
      };

      for (final w in walk.weapons.entries) {
        weapons.putIfAbsent(w.key, () => w.value);
        (variantUsers[w.key] ??= <String>{}).add(id);
      }
      for (final a in walk.abilities.entries) {
        abilities.putIfAbsent(a.key, () => a.value);
      }
      weaponKeywords.addAll(walk.weaponKeywordIds);
      pending[id] = walk;
      if (walk.models.isNotEmpty) {
        compositions[id] = {
          'unit_id': id,
          'faction_id': factionId,
          'models': walk.models,
          'game_version': bsGameVersion,
        };
      }
    }

    for (final entry in pending.entries) {
      final walk = entry.value;
      final unit = units[entry.key]!;
      unit['ability_ids'] = [
        for (final id in walk.abilityIds)
          if (!weaponKeywords.contains(id)) id,
      ];
      final budgets = [
        for (final id in walk.wargearAbilityIds)
          if (!weaponKeywords.contains(id) && !walk.abilityIds.contains(id))
            {
              'items': [id],
              // What the entry states, not a flat 1. The cap is per item and
              // BSData publishes it per item.
              'count': walk.wargearMax[id] ?? 1,
            },
      ];
      if (budgets.isNotEmpty) unit['wargear_budgets'] = budgets;

      // **Per item, for weapons as well as wargear.** The budget lines only
      // ever cover the ability-shaped kit — drones, support systems — and a
      // hardpoint cap applies just as much to the gun in it. Written as its
      // own field so neither source has to be bent into the other's shape.
      final caps = {
        for (final entry in walk.wargearMax.entries)
          if (entry.value > 0) entry.key: entry.value,
      };
      if (caps.isNotEmpty) unit['wargear_caps'] = caps;
    }

    // The anchor variant of each slug — the one 40kdc published under the
    // plain name — decides which datasheets keep the plain id.
    final anchorKeys =
        _anchorKeys(weapons, variantUsers, _anchorProfiles(anchors));
    final variantIds = _variantIds(weapons, variantUsers, anchorKeys);

    final byId = <String, Map<String, Object?>>{};
    final discarded = <String>[];

    for (final unit in units.values) {
      final unitId = unit['id']! as String;
      final linked = unit['weapon_ids']! as List;
      final seen = <String>{};
      final resolved = <String>[];

      for (final raw in linked) {
        final key = raw as String;
        final record = weapons[key];
        if (record == null) continue;
        final slug = key.split('|').first;

        // **Per unit, not per entry.** BSData shares one weapon entry across
        // several datasheets, so scoping by the entry named whichever
        // datasheet sorted first — an Enforcer Commander's missile pod came
        // out scoped to the Coldstar. 40kdc scopes by the carrier, and the
        // carrier is the unit being written.
        final id = variantIds['$slug|${jsonEncode(record['profiles'])}'] ??
            '$slug-$unitId';
        if (!seen.add(id)) continue;
        resolved.add(id);

        if (!byId.containsKey(id)) {
          byId[id] = {...record, 'id': id};
        } else if (byId[id]!['profiles'] != record['profiles']) {
          discarded.add('$id <- $key');
        }
      }
      unit['weapon_ids'] = resolved;
    }

    // Detachment rules and enhancements are declared in shared groups rather
    // than on any datasheet, so the unit walk never reaches them. What they
    // carry is their **printed wording**, which 40kdc has for neither: a
    // detachment rule and an enhancement are exactly the two things a player
    // looks up mid-game and the app could only name (§3.10).
    //
    // Only the text is taken. Which enhancements exist stays 40kdc's, because
    // BSData expresses an enhancement's keyword restrictions as modifier
    // condition groups — and an enhancement imported without its restrictions
    // is one the builder will happily offer to a character that cannot take
    // it, which is worse than not offering it at all.
    for (final group in index.sharedGroups) {
      _harvestText(group, abilities, 0);
    }
    // **A detachment rule is a `sharedRule`, not a shared group.** Harvesting
    // only the groups reached the enhancements and missed the rules entirely:
    // `Fervent Purgation` sits at `catalogue/sharedRules`, linked from a
    // detachment entry, so 127 of 239 detachment rules across the game had no
    // printed wording and fell back to a community paraphrase of their
    // structured effect.
    for (final rule in index.ownRules) {
      _harvestText(rule, abilities, 0);
    }
    // And the container the detachments hang off. `Angelic Judgement`,
    // `Holy Quest` and `Hymns of Battle` are `rules` on entries inside one
    // non-datasheet shared entry, which the unit walk skips by definition and
    // the group walk never reaches.
    //
    // Datasheets are excluded rather than harvested: their rules are already
    // collected by the walk above, and recursing one here would file every
    // weapon rule it passes as a faction ability.
    for (final entry in index.ownEntries) {
      if (_isDatasheet(entry)) continue;
      _harvestText(entry, abilities, 0);
    }

    return BsFaction(
      factionId: factionId,
      units: units.values.toList(growable: false),
      weapons: byId.values.toList(growable: false),
      droppedWeaponVariants: discarded,
      abilities: abilities.values.toList(growable: false),
      compositions: compositions.values.toList(growable: false),
      collisions: collisions,
    );
  }

  /// Final ids for weapons that differ only by which datasheet carries them.
  ///
  /// BSData holds **four separate `Missile pod` entries** — BS 3+, 4+ and two
  /// at 5+ — one per datasheet that fields one, which is exactly the
  /// distinction §7.3.5 says must survive: a Commander's missile pod and a
  /// Crisis suit's are the same name and not the same gun. 40kdc collapses
  /// them into a single BS4+ record, so the app has been showing one number
  /// for three weapons.
  ///
  /// Keeping them apart needs ids to tell them apart. The variant the most
  /// datasheets carry takes the plain slug — so the common case keeps the id
  /// 40kdc used, and saved rosters and corrections keep resolving — and the
  /// rest are suffixed with the skill that distinguishes them. Ties break on
  /// the id itself, never on walk order, or a rebuild would silently
  /// renumber every weapon in the faction.
  /// Whether a modifier condition is counting models.
  ///
  /// Both encodings appear and only one is obvious. T'au writes the literal
  /// `childId: "model"`; Space Marines names the id of the model entry itself,
  /// so `set 150 when at least 6 Intercessors` looked like a condition about
  /// wargear and every squad in the codex lost its ten-model price.
  bool _countsModels(String? childId) {
    if (childId == null) return false;
    if (childId == 'model') return true;
    final target = index.byId(childId);
    if (target == null) return false;
    if (target.type == 'model') return true;
    // A composition group has no `type` at all, so testing for `model` alone
    // still missed it: `set 150 when at least 6 Intercessors` names the
    // *group*, and every Space Marine squad stayed at its five-model price.
    for (final raw in target.selectionEntries) {
      if (str(asMap(raw)['type']) == 'model') return true;
    }
    return false;
  }

  /// 40kdc's weapon records, indexed by id, for anchoring.
  Map<String, Map<String, dynamic>> _anchorProfiles(List<Object?> anchors) {
    final out = <String, Map<String, dynamic>>{};
    for (final raw in anchors) {
      final record = asMap(raw);
      if (str(record['id']) case final id?) out[id] = record;
    }
    return out;
  }

  /// An id per *distinct profile*, not per carrier.
  ///
  /// BSData declares a weapon entry on every datasheet that can reach the gun,
  /// including through wargear: nineteen `Missile pod` entries exist on T'au,
  /// and eighteen are the **missile drone's** BS5+ pod linked from every unit
  /// that may take a drone. Scoping by carrier turned that into nineteen
  /// near-identical records.
  ///
  /// So variants are grouped by profile. The one matching what 40kdc published
  /// generically keeps the plain slug; each genuinely different profile gets
  /// one id, scoped to the first datasheet that carries it. Two records for a
  /// missile pod, which is what there are.
  Map<String, String> _variantIds(
    Map<String, Map<String, Object?>> weapons,
    Map<String, Set<String>> users,
    Map<String, String> anchorKeys,
  ) {
    final byProfile = <String, List<String>>{};
    for (final entry in weapons.entries) {
      final slug = entry.key.split('|').first;
      final signature = '$slug|${jsonEncode(entry.value['profiles'])}';
      (byProfile[signature] ??= []).add(entry.key);
    }

    final out = <String, String>{};
    final taken = <String>{};
    for (final entry in byProfile.entries) {
      final slug = entry.key.split('|').first;
      final anchor = anchorKeys[slug];
      if (anchor != null && entry.value.contains(anchor)) {
        out[entry.key] = slug;
        taken.add(slug);
      }
    }
    for (final entry in byProfile.entries) {
      if (out.containsKey(entry.key)) continue;
      final slug = entry.key.split('|').first;
      final carriers = <String>{
        for (final key in entry.value) ...?users[key],
      }.toList()
        ..sort();
      var id = carriers.isEmpty ? slug : '$slug-${carriers.first}';
      if (!taken.add(id)) {
        var n = 2;
        while (!taken.add('$id-$n')) {
          n++;
        }
        id = '$id-$n';
      }
      out[entry.key] = id;
    }
    return out;
  }

  /// The variant of each slug that keeps the plain id, by slug.
  Map<String, String> _anchorKeys(
    Map<String, Map<String, Object?>> weapons,
    Map<String, Set<String>> users,
    Map<String, Map<String, dynamic>> anchors,
  ) {
    final bySlug = <String, List<String>>{};
    for (final key in weapons.keys) {
      (bySlug[key.split('|').first] ??= []).add(key);
    }

    final out = <String, String>{};
    for (final entry in bySlug.entries) {
      final slug = entry.key;
      final anchor = anchors[slug];
      final variants = entry.value
        ..sort((a, b) {
          // The variant that matches what 40kdc called by this name keeps the
          // name. Without this the plain id goes to whichever variant the most
          // datasheets carry, and `missile-pod` silently stopped meaning the
          // BS4+ gun every saved roster was built with.
          final byAnchor = _anchorScore(weapons[b], anchor)
              .compareTo(_anchorScore(weapons[a], anchor));
          if (byAnchor != 0) return byAnchor;
          final byUse =
              (users[b]?.length ?? 0).compareTo(users[a]?.length ?? 0);
          return byUse != 0 ? byUse : a.compareTo(b);
        });
      // **40kdc's own convention**: the common variant keeps the plain slug
      // and the rest are scoped to the datasheet that carries them —
      // `missile-pod`, then `missile-pod-commander-in-enforcer-battlesuit`.
      //
      // Inventing a scheme of my own (`missile-pod-bs5`) was the first attempt
      // and it broke everything downstream, because `wargear_costs`, saved
      // rosters and the corrections all name `missile-pod`. Then collapsing
      // every variant onto the plain slug was the second, and it threw away
      // the BS3+/BS5+ distinction 40kdc had *already* encoded this way. The
      // convention was there to be followed.
      out[slug] = variants.first;
    }
    return out;
  }

  /// How well a variant matches the record 40kdc published under that id.
  ///
  /// The skill is the characteristic these variants differ by, so matching it
  /// is the whole test; anything else scores zero and falls through to the
  /// usage count.
  int _anchorScore(Map<String, Object?>? weapon, Map<String, dynamic>? anchor) {
    if (weapon == null || anchor == null) return 0;
    final theirs = asList(anchor['profiles']).map(asMap).firstOrNull;
    if (theirs == null) return 0;
    final theirStats = asMap(theirs['stats']);
    for (final raw in asList(weapon['profiles'])) {
      final stats = asMap(asMap(raw)['stats']);
      for (final key in const ['BS', 'WS']) {
        final mine = asInt(stats[key]);
        final other = asInt(theirStats[key]);
        if (mine != null && other != null && mine == other) return 1;
      }
    }
    return 0;
  }

  /// Collects printed wording from a shared group, and nothing else.
  ///
  /// Deliberately not the datasheet walk: that one skips anything named
  /// "enhancement" — it is not a datasheet's own rule — and reads `profiles`
  /// but not `rules`, which is where a detachment keeps its rule. Reusing it
  /// would mean loosening both, and both exist for good reasons.
  void _harvestText(
      BsEntry entry, Map<String, Map<String, Object?>> out, int depth) {
    if (depth > 6) return;

    void take(String name, String? description) {
      if (description == null || description.trim().isEmpty) return;
      final id = bsSlug(name);
      if (id.isEmpty) return;
      out.putIfAbsent(
        id,
        () => {
          'ability_id': id,
          'name': name,
          'description': normaliseRuleText(description),
          'game_version': bsGameVersion,
        },
      );
    }

    // A shared rule carries its text on the record itself; a nested one
    // carries it under `rules`. Both shapes appear and both are rules.
    take(strOr(entry.json['name'], ''), str(entry.json['description']));
    for (final raw in asList(entry.json['rules'])) {
      final rule = asMap(raw);
      take(strOr(rule['name'], ''), str(rule['description']));
    }
    for (final raw in entry.profiles) {
      final profile = asMap(raw);
      for (final rawChar in asList(profile['characteristics'])) {
        final c = asMap(rawChar);
        if (str(c['name']) != 'Description') continue;
        take(strOr(profile['name'], ''), str(c[r'$text']));
      }
    }
    for (final raw in entry.infoLinks) {
      if (index.resolve(raw) case final target?) {
        _harvestText(target, out, depth + 1);
      }
    }
    for (final key in const ['selectionEntries', 'selectionEntryGroups']) {
      for (final raw in asList(entry.json[key])) {
        _harvestText(BsEntry(asMap(raw), entry.sourceId), out, depth + 1);
      }
    }
    for (final raw in entry.entryLinks) {
      if (index.resolve(raw) case final target?) {
        _harvestText(target, out, depth + 1);
      }
    }
  }

  /// A datasheet is a selectable unit or single model with a battlefield role.
  ///
  /// The role is what separates a datasheet from the hundreds of `upgrade`
  /// entries, and from configuration entries like `Detachment` — selectable,
  /// but not something you put on the table.
  bool _isDatasheet(BsEntry e) {
    if (e.type != 'unit' && e.type != 'model') return false;
    if (e.hidden) return false;
    final role = e.primaryCategory;
    return role != null && role != 'Configuration';
  }

  /// Keywords, from the categories BattleScribe hangs on the entry — which is
  /// where 11e keywords actually live.
  ///
  /// `Faction: X` is separated out: it is the faction keyword line, printed
  /// apart from the rest on a real datasheet.
  List<String> _keywords(BsEntry e) => [
        for (final name in e.categoryNames)
          if (!name.startsWith('Faction:')) name,
      ];

  List<String> _factionKeywords(BsEntry e) => [
        for (final name in e.categoryNames)
          if (name.startsWith('Faction:')) name.substring(8).trim(),
      ];

  /// Points: the model-count brackets, and the 11e escalating cost for a
  /// third and later copy.
  ///
  /// 40kdc states both outright. BattleScribe expresses them as modifiers on
  /// the points field, and although evaluating BattleScribe modifiers in
  /// general is a project of its own, these two are entirely regular:
  ///
  ///   `set 150 when selections of model == 2`      -> a two-model bracket
  ///   `set 255 when selections of model >= 3`      -> a three-model bracket
  ///   `increment 20 when 2 selected before this`   -> the third copy onward
  ///
  /// Broadsides come out 75/150/255 and 95/170/275, which is what 40kdc says
  /// to the point. Nothing beyond these two shapes is interpreted — a
  /// half-understood modifier yields a number that looks authoritative and is
  /// wrong, which is worse than a flat cost that is visibly simple.
  List<Map<String, Object?>> _points(BsEntry unit, _Walk walk) {
    final base = unit.costFor(_pts);
    if (base == null) return const [];

    final brackets = <({int models, int cost})>[
      (models: walk.modelCount, cost: base),
      ..._modelBrackets(unit),
    ]..sort((a, b) => a.models.compareTo(b.models));

    // Two modifiers can name the same count — the base already covers it.
    final unique = <int, int>{};
    for (final b in brackets) {
      unique[b.models] = b.cost;
    }
    final counts = unique.keys.toList()..sort();

    final escalation = _escalation(unit);
    final out = <Map<String, Object?>>[];

    for (var i = 0; i < counts.length; i++) {
      final models = counts[i];
      final cost = unique[models]!;
      // A bracket runs up to the model count where the next one starts.
      final modelsMax = i + 1 < counts.length
          ? counts[i + 1] - 1
          : (walk.modelCountMax > models ? walk.modelCountMax : null);

      Map<String, Object?> row(int value, int? min, int? max) => {
            'models': models,
            if (modelsMax != null && modelsMax != models)
              'models_max': modelsMax,
            'cost': value,
            if (min != null) 'unit_count_min': min,
            if (max != null) 'unit_count_max': max,
          };

      if (escalation == null) {
        out.add(row(cost, null, null));
      } else {
        out.add(row(cost, 1, escalation.copy - 1));
        out.add(row(cost + escalation.delta, escalation.copy, null));
      }
    }
    return out;
  }

  /// `set <cost> when the unit has N models` modifiers, as brackets.
  List<({int models, int cost})> _modelBrackets(BsEntry unit) {
    final out = <({int models, int cost})>[];
    for (final raw in [
      ...unit.modifiers,
      for (final group in unit.modifierGroups)
        ...asList(asMap(group)['modifiers']),
    ]) {
      final m = asMap(raw);
      if (str(m['field']) != _pts) continue;
      if (str(m['type']) != 'set') continue;
      final cost = asInt(m['value']);
      if (cost == null) continue;

      for (final rawCondition in asList(m['conditions'])) {
        final condition = asMap(rawCondition);
        if (str(condition['field']) != 'selections') continue;
        if (!_countsModels(str(condition['childId']))) continue;
        final value = asInt(condition['value']);
        if (value == null) continue;
        final models = switch (str(condition['type'])) {
          'equalTo' || 'atLeast' => value,
          // `greaterThan 10` is the eleventh model.
          'greaterThan' => value + 1,
          _ => null,
        };
        if (models != null) out.add((models: models, cost: cost));
      }
    }
    return out;
  }

  /// The `increment N points once M copies are already taken` modifier, if
  /// there is one.
  ///
  /// Anything more elaborate is left alone rather than guessed at. A
  /// half-understood modifier produces a points value that looks authoritative
  /// and is wrong, which is worse than a flat cost that is visibly simple.
  ({int copy, int delta})? _escalation(BsEntry unit) {
    for (final raw in unit.modifiers) {
      final m = asMap(raw);
      if (str(m['field']) != _pts) continue;
      if (str(m['type']) != 'increment') continue;
      final delta = asInt(m['value']);
      if (delta == null) continue;
      for (final rawGroup in asList(m['conditionGroups'])) {
        for (final rawLocal
            in asList(asMap(rawGroup)['localConditionGroups'])) {
          final local = asMap(rawLocal);
          if (str(local['type']) != 'atLeast') continue;
          final before = asInt(local['value']);
          // "at least 2 selected before this one" is the third copy onward.
          if (before != null) return (copy: before + 1, delta: delta);
        }
      }
    }
    return null;
  }
}

/// One pass over a datasheet, gathering everything hanging off it.
///
/// A datasheet is a tree — groups of model entries, each linking weapons, each
/// carrying profiles — and the same weapon is reachable by several routes, so
/// collection is into maps by id rather than by appending.
class _Walk {
  final BsIndex index;
  final String pts;

  final profiles = <Map<String, Object?>>[];

  /// Model entries, grouped the way the datasheet groups them.
  ///
  /// The grouping is not presentational. BattleScribe puts `4 Stealth Shas'ui`
  /// on the group and `min 2 / max 4` on each loadout inside it: the group is
  /// how many models there are, the entries are which weapons those models may
  /// carry. Summing the entries counts every model once per loadout it could
  /// have taken — Stealth Battlesuits came out as nine models instead of five.
  final modelGroups = <_ModelGroup>[];
  final weaponIds = <String>{};
  final abilityIds = <String>{};

  /// Abilities reached through a wargear choice rather than printed on the
  /// datasheet — a Commander's `Drones (0-2)` group.
  ///
  /// **Wargear a datasheet may take is not wargear it has** (§3.8). Filed as
  /// plain abilities they showed on every unit that *could* buy one: a marker
  /// drone on a Commander that bought a gun drone, which is a rule on the
  /// screen that is not on the table. They become budget lines instead, which
  /// is where 40kdc puts them and what the app's existing filter reads.
  final wargearAbilityIds = <String>{};

  /// The `max` a wargear entry states for itself, keyed by slug.
  ///
  /// **This is where a hardpoint limit actually lives.** A Commander in
  /// Enforcer Battlesuit carries a `Support Systems (1-4)` group whose
  /// entries each state their own cap — four T'au flamers, four missile pods,
  /// one shield generator, one cyclic ion blaster. 40kdc flattens all of that
  /// to a single `max_count: 3` over the whole choice, which is wrong in both
  /// directions: it forbids the fourth flamer a validated 2,000 point list
  /// actually fields, and permits three shield generators.
  final wargearMax = <String, int>{};
  final weapons = <String, Map<String, Object?>>{};
  final abilities = <String, Map<String, Object?>>{};
  final wargearCosts = <String, Map<String, Object?>>{};

  /// Guards the graph's cycles and its diamonds: a shared entry reachable by
  /// two routes would otherwise be walked twice.
  final _seen = <String>{};

  /// Keyword ids seen on this faction's weapon profiles.
  ///
  /// BattleScribe links the rule for `[ASSAULT]` from every weapon that has
  /// it, so a datasheet's rules came out listing ten weapon keywords among its
  /// abilities. They are keywords printed on a gun, not rules the unit has —
  /// and now that BSData supplies their text, leaving them in would render
  /// each one on the rules screen as though it were the datasheet's own.
  ///
  /// The records are still kept: the text is worth having where a player looks
  /// a keyword up. Only the unit's ability list is filtered.
  final weaponKeywordIds = <String>{};

  _Walk(this.index, this.pts);

  /// Models when every minimum is taken — the datasheet's starting size, which
  /// is what the builder needs to put a legal unit on the table.
  /// The datasheet's own name, used when it turns out to have no composition.
  String _rootName = '';

  /// A single-model datasheet — a Commander, a tank — carries its statline on
  /// the root and has no composition group at all, so it is one model.
  ///
  /// This has to be decided *after* the walk, not during it. A multi-model
  /// datasheet also carries the statline on its root, so counting the root as
  /// a model up front added one phantom model to every squad: Vespid
  /// Stingwings came out as six, and its five-model price bracket vanished
  /// under the six-model one.
  List<_ModelGroup> get _groups =>
      modelGroups.isEmpty ? [_ModelGroup(_rootName, 1, 1)] : modelGroups;

  int get modelCount {
    final total = _groups.fold(0, (sum, g) => sum + g.min);
    return total == 0 ? 1 : total;
  }

  int get modelCountMax {
    final total = _groups.fold(0, (sum, g) => sum + g.max);
    return total < modelCount ? modelCount : total;
  }

  /// The composition, one record per distinct model in the datasheet.
  List<Map<String, Object?>> get models => [
        for (final group in _groups)
          {
            'name': group.name,
            'min': group.min,
            'max': group.max,
            'is_leader_model': false,
            'default_weapon_ids': const <String>[],
          },
      ];

  /// Subtrees that hang off a datasheet without belonging to it.
  ///
  /// A BattleScribe datasheet links the whole Crusade apparatus — battle
  /// traits, relics, specialisms, battle scars — and those links reach shared
  /// trees covering the entire game. Walking them gave an Enforcer Commander
  /// 180 abilities, most of them from other factions, and a Dominion Squad the
  /// Sisters' entire hymn list. None of it is on the datasheet.
  /// Subtrees that are not this datasheet's own equipment.
  ///
  /// `weapon modification` is the game system's Crusade upgrade group —
  /// `Armour Piercing (AP+1)`, `Brutal (S+1)`, `Precise` and four others.
  /// Six of the seven carry no ability profile and were dropped by accident;
  /// `Precise` carries one, so it alone became a buyable wargear line on
  /// **1,113 datasheets across 29 factions**, rendered as "Precise" with a
  /// `+` beside it. Filtering the group is the fix rather than filtering the
  /// one entry, because the other six are the same kind of thing and would
  /// arrive the moment upstream gave them a profile.
  static final _notThisDatasheet = RegExp(
    r'crusade|battle\s*trait|battle\s*scar|relic|specialism|'
    r'expanding the empire|white dwarf|warlord|requisition|enhancement|'
    r'weapon\s*modification',
    caseSensitive: false,
  );

  bool _belongs(String name) => !_notThisDatasheet.hasMatch(name);

  /// Whether the entry currently being read hangs off a wargear choice.
  bool _inWargear = false;

  /// Whether the entry currently being read *is* a weapon, or hangs off one.
  ///
  /// **A rule attached to a gun is not a thing you can buy.** BSData models
  /// weapons as `upgrade` entries, which is the same shape a wargear choice
  /// has, so every rule linked from a weapon arrived looking like purchasable
  /// wargear: `Precise` appeared as a buyable line with a `+` beside it on
  /// 1,113 datasheets, `Lethal Hits` on 304. Filtering the weapon *keywords*
  /// was not enough — the keyword is `[PRECISION]` and the rule that grants
  /// it is named `Precise`, so the ids never met.
  bool _inWeapon = false;

  void visit(BsEntry entry, {int depth = 0, bool wargear = false}) {
    if (depth > 8) return;
    if (!_seen.add(entry.id.isEmpty ? '${entry.name}@$depth' : entry.id)) {
      return;
    }

    final outer = _inWargear;
    final outerWeapon = _inWeapon;
    _inWargear = wargear || entry.type == 'upgrade';
    // Read first: whether this entry is a weapon is decided by the profiles
    // hanging on it, and its own linked rules are read straight afterwards.
    _inWeapon = outerWeapon | _readProfiles(entry);

    // Recorded for anything reached inside a wargear choice, weapon or not:
    // support systems, drones and guns share one group and one kind of cap.
    if (depth > 0 && _inWargear) {
      final slug = bsSlug(entry.name);
      if (slug.isNotEmpty) {
        if (_constraint(entry, 'max') case final max? when max > 0) {
          final known = wargearMax[slug];
          if (known == null || max > known) wargearMax[slug] = max;
        }
      }
    }

    final cost = entry.costFor(pts);
    if (depth > 0 && cost != null && cost != 0) {
      // Keyed, not appended. A datasheet with two model groups reaches the
      // same upgrade once per group — a Paragon Warsuits multi-melta arrived
      // twice at 10 points and the unit priced it at 20.
      wargearCosts[bsSlug(entry.name)] = {
        'item_id': bsSlug(entry.name),
        'cost': cost,
      };
    }

    for (final raw in entry.infoLinks) {
      final link = asMap(raw);
      final type = str(link['type']);
      if (type != 'rule' && type != 'profile') continue;
      final target = index.resolve(link);
      if (target != null) {
        _readRule(target, linked: true, name: _linkName(link, target.name));
      }
    }

    if (depth == 0) _rootName = entry.name;

    // A model can be a direct child rather than sit in a group — a Breacher
    // Team is one `Breacher Fire Warriors` entry with its count on itself.
    // Reading only groups lost every such datasheet down to a single model.
    for (final raw in entry.selectionEntries) {
      final child = BsEntry(asMap(raw), entry.sourceId);
      if (depth == 0 && _hasUnitProfile(child)) {
        modelGroups.add(_ModelGroup(
          child.name,
          _constraint(child, 'min') ?? 1,
          _constraint(child, 'max') ?? _constraint(child, 'min') ?? 1,
        ));
      }
      _child(child, depth, wargear: _inWargear);
    }
    for (final rawGroup in entry.selectionEntryGroups) {
      final group = BsEntry(asMap(rawGroup), entry.sourceId);
      if (!_belongs(group.name)) continue;
      _group(group, entry, depth);
    }
    for (final raw in entry.entryLinks) {
      if (!_belongs(strOr(asMap(raw)['name'], ''))) continue;
      final target = index.resolve(raw);
      if (target != null && _belongs(target.name)) {
        _child(target, depth, wargear: _inWargear);
      }
    }

    _inWargear = outer;
    _inWeapon = outerWeapon;
  }

  /// One composition group: how many models, and which loadouts they may take.
  void _group(BsEntry group, BsEntry owner, int depth) {
    final children = <BsEntry>[
      for (final raw in group.selectionEntries)
        BsEntry(asMap(raw), owner.sourceId),
      for (final raw in group.entryLinks)
        if (_belongs(strOr(asMap(raw)['name'], '')))
          if (index.resolve(raw) case final target?) target,
    ];

    final modelChildren = children.where(_hasUnitProfile).toList();
    if (modelChildren.isNotEmpty) {
      // The group's own bound is the model count when it states one; without
      // it the loadouts are the only evidence and their minimums are summed.
      final statedMin = _constraint(group, 'min') ??
          _sum(modelChildren, 'min', missing: null);
      final statedMax = _constraint(group, 'max') ??
          _sum(modelChildren, 'max', missing: null);

      // Silence and `max 2` mean different things, and conflating them costs
      // a price bracket. A group stating nothing at all is exactly one model —
      // the Long-quill in a Kroot pack, the Shas'vre in a Stealth team. A
      // group stating only a maximum genuinely starts at zero: Broadsides are
      // 0-2 Shas'ui plus one Shas'vre, so the datasheet's smallest legal size
      // is one model, and reading that minimum as one lost the 75-point row.
      final bare = statedMin == null && statedMax == null;
      modelGroups.add(_ModelGroup(
        _groupName(group, modelChildren),
        bare ? 1 : (statedMin ?? 0),
        bare ? 1 : (statedMax ?? statedMin ?? 1),
      ));
    }

    // A group with no models in it is a wargear group: `Drones (0-2)`,
    // `Wargear`. What hangs off it is bought, not printed on the datasheet.
    final isWargearGroup = modelChildren.isEmpty;
    for (final child in children) {
      visit(child, depth: depth + 1, wargear: _inWargear || isWargearGroup);
    }

    // **Groups nest.** A Riptide's `Wargear` group holds one entry and a
    // sub-group, and the sub-group is where its ion accelerator, heavy burst
    // cannon and smart missile system live. Reading only a group's own
    // entries left the Riptide holding nothing but its fists, and the
    // reference list 110 points short.
    for (final raw in group.selectionEntryGroups) {
      final nested = BsEntry(asMap(raw), owner.sourceId);
      if (_belongs(nested.name)) _group(nested, owner, depth);
    }
  }

  /// Sums a constraint across a group's entries, or null when none states it.
  int? _sum(List<BsEntry> children, String type, {required int? missing}) {
    var total = 0;
    var any = false;
    for (final child in children) {
      final value = _constraint(child, type);
      if (value != null) {
        any = true;
        total += value;
      }
    }
    return any ? total : missing;
  }

  /// `4 Stealth Shas'ui` names the group after its models, which reads better
  /// than the loadout of whichever entry happened to come first. A group with
  /// no name of its own falls back to what is in it.
  String _groupName(BsEntry group, List<BsEntry> children) {
    final name = group.name.replaceFirst(RegExp(r'^\d+\s+'), '').trim();
    return name.isEmpty ? children.first.name : name;
  }

  void _child(BsEntry child, int depth, {bool wargear = false}) {
    visit(child, depth: depth + 1, wargear: wargear);
  }

  /// Whether this entry is one of the datasheet's models.
  ///
  /// BattleScribe says so outright with `type: model`. Testing for a `Unit`
  /// profile instead — the first thing I tried — misses most of them: a
  /// Vespid Strain Leader carries no profile at all, because the statline sits
  /// on the datasheet root and the model entry only says how many there are.
  bool _hasUnitProfile(BsEntry e) {
    if (e.type == 'model') return true;
    for (final raw in e.profiles) {
      if (str(asMap(raw)['typeName']) == 'Unit') return true;
    }
    return false;
  }

  /// A count constraint, preferring the group's over the entry's.
  ///
  /// BattleScribe puts `4 Stealth Shas'ui` on the group and `min 2 / max 4` on
  /// the entry inside it: the group says how many models the datasheet fields,
  /// the entry only bounds which loadouts those models may take. Reading the
  /// entry alone makes a five-model unit look like a three-model one.
  int? _constraint(BsEntry e, String type) {
    for (final raw in e.constraints) {
      final c = asMap(raw);
      if (str(c['type']) != type) continue;
      if (str(c['field']) != 'selections') continue;
      final scope = str(c['scope']);
      if (scope != 'parent' && scope != 'self') continue;
      return asInt(c['value']);
    }
    return null;
  }

  /// Reads [entry]'s profiles, reporting whether any of them made it a weapon.
  bool _readProfiles(BsEntry entry) {
    var weapon = false;
    for (final raw in entry.profiles) {
      final profile = asMap(raw);
      final typeName = strOr(profile['typeName'], '');
      if (typeName == 'Ranged Weapons' || typeName == 'Melee Weapons') {
        weapon = true;
      }
      _readProfile(profile, entry);
    }
    return weapon;
  }

  /// [linked] marks a rule reached through an `infoLink` rather than through
  /// the entry's own profile. The distinction only matters inside a wargear
  /// choice: `Ratling Battlemutt` is an upgrade whose own profile makes it the
  /// wargear, and it links the rule `Lethal Hits`, which is what the mutt
  /// *does* — not a second thing to buy. Filing both as budget lines put
  /// "Lethal Hits" in the builder with a `+` beside it.
  /// The name a link gives its target, which is not always the target's own.
  ///
  /// **This is how BSData writes a rule with a number in it.** `Scouts X"` is
  /// one shared rule, and a datasheet that has `Scouts 6"` links it with
  /// `{type: append, field: name, value: 6"}`. Reading the target's bare name
  /// filed every such datasheet under `scouts` — the rulebook explanation of
  /// the ability, which carries no distance — so a Dominion Squad showed
  /// "Scouts" with no number and never appeared in the Scout moves list.
  ///
  /// A separator is inserted where neither side has one: appending `6"` to
  /// `Scouts` has to give `Scouts 6"`, or the slug is `scouts6` and matches
  /// nothing.
  static String _linkName(Map<String, dynamic> link, String targetName) {
    var name = targetName;
    for (final raw in asList(link['modifiers'])) {
      final modifier = asMap(raw);
      if (str(modifier['field']) != 'name') continue;
      final value = strOr(modifier['value'], '');
      if (value.isEmpty) continue;
      switch (str(modifier['type'])) {
        case 'append':
          final gap = name.endsWith(' ') || value.startsWith(' ') ? '' : ' ';
          name = '$name$gap$value';
        case 'prepend':
          final gap = value.endsWith(' ') || name.startsWith(' ') ? '' : ' ';
          name = '$value$gap$name';
        case 'set':
          name = value;
      }
    }
    return name.trim();
  }

  void _readRule(BsEntry rule, {bool linked = false, String? name}) {
    // A shared rule carries its text on the record itself; a profile carries
    // it in a characteristic. Both shapes appear, and both are rules.
    final description = str(rule.json['description']);
    if (description == null || description.isEmpty) {
      _readProfiles(rule);
      return;
    }
    final displayName = name ?? rule.name;
    final id = bsSlug(displayName);
    if (id.isEmpty) return;
    // The record is still kept below — the text is worth having where a
    // player looks a weapon rule up. It is only kept off the unit's own
    // ability list and out of its wargear budget.
    if (!_inWeapon && !(_inWargear && linked)) {
      (_inWargear ? wargearAbilityIds : abilityIds).add(id);
    }
    abilities.putIfAbsent(
      id,
      () => {
        'ability_id': id,
        'name': displayName,
        'description': normaliseRuleText(description),
        'ability_type': 'core',
        'game_version': bsGameVersion,
      },
    );
  }

  /// `➤ Ion cannon - overcharge` -> `overcharge`.
  ///
  /// BattleScribe names a sub-profile by repeating its weapon; 40kdc names it
  /// by what distinguishes it. Same information, and left alone it reported
  /// every multi-profile weapon in the game as a conflict about nothing.
  static String _profileName(String raw, String ownerName) {
    var name = raw.replaceFirst(RegExp(r'^[➤>\s]+'), '').trim();
    final prefix = RegExp('^${RegExp.escape(ownerName)}\\s*[-–]\\s*');
    name = name.replaceFirst(prefix, '').trim();
    if (name.isEmpty) return raw.trim();
    // `overcharge` -> `Overcharge`. What is left after the weapon's own name
    // is stripped is a bare word, and a datasheet prints it capitalised.
    return name[0].toUpperCase() + name.substring(1);
  }

  void _readProfile(Map<String, dynamic> profile, BsEntry owner) {
    final typeName = strOr(profile['typeName'], '');
    final name = strOr(profile['name'], '');
    if (name.isEmpty) return;

    final chars = <String, String>{};
    for (final raw in asList(profile['characteristics'])) {
      final c = asMap(raw);
      final key = str(c['name']);
      final value = str(c[r'$text']);
      if (key != null && value != null && value.isNotEmpty) chars[key] = value;
    }
    if (chars.isEmpty) return;

    switch (typeName) {
      case 'Unit':
        // The same statline arrives once per loadout that shares it. Three
        // identical Shas'ui rows say nothing the first one did not.
        if (profiles.any((p) => p['name'] == name)) return;
        profiles.add({
          'name': name,
          'M': chars['M'],
          'T': chars['T'],
          'W': chars['W'],
          'Sv': chars['Sv'],
          'invuln_sv': chars['InSv'],
          'Ld': chars['LD'],
          'OC': chars['OC'],
        });
      case 'Ranged Weapons':
      case 'Melee Weapons':
        _readWeapon(_profileName(name, owner.name), chars, owner,
            melee: typeName == 'Melee Weapons');
      default:
        final text = chars['Description'];
        if (text == null) return;
        final id = bsSlug(name);
        if (id.isEmpty) return;
        (_inWargear ? wargearAbilityIds : abilityIds).add(id);
        abilities.putIfAbsent(
          id,
          () => {
            'ability_id': id,
            'name': name,
            'description': normaliseRuleText(text),
            if (typeName != 'Abilities') 'ability_type': typeName,
            'game_version': bsGameVersion,
          },
        );
    }
  }

  /// A weapon record, keyed by the entry that owns the profile.
  ///
  /// The owning entry is what a datasheet links to and what the roster records,
  /// so its name is the id — while a *profile* may be one of several under that
  /// entry, which is how a two-profile weapon stays one weapon.
  void _readWeapon(
    String name,
    Map<String, String> chars,
    BsEntry owner, {
    required bool melee,
  }) {
    final slug = bsSlug(owner.name);
    if (slug.isEmpty) return;

    final stats = <String, Object?>{};
    for (final key in const ['A', 'BS', 'WS', 'S', 'AP', 'D']) {
      if (chars[key] case final v?) stats[key] = _statValue(v);
    }
    final profile = <String, Object?>{
      'name': name,
      'range': _rangeValue(chars['Range']),
      'stats': stats,
      'keywords': _weaponKeywords(chars['Keywords']),
    };
    for (final keyword in profile['keywords']! as List) {
      if (str(asMap(keyword)['keyword_id']) case final id?) {
        weaponKeywordIds.add(id);
      }
    }

    // Two profiles of one weapon — an ion rifle's standard and overcharge —
    // belong to the same record, and two datasheets' versions of the same
    // weapon do not. The owning entry's id separates them, since BattleScribe
    // declares one entry per datasheet that carries the gun.
    final key = '$slug|${owner.id}';
    weaponIds.add(key);

    final existing = weapons[key];
    if (existing == null) {
      weapons[key] = {
        'id': slug,
        'name': owner.name,
        'type': melee ? 'melee' : 'ranged',
        'profiles': [profile],
        'game_version': bsGameVersion,
      };
      return;
    }
    // A weapon with both a ranged and a melee profile keeps the type of the
    // first seen; §7.3.5 discriminates per profile on the skill characteristic
    // anyway, so the weapon-level type is only a fallback.
    (existing['profiles']! as List).add(profile);
  }

  /// A characteristic in 40kdc's convention: bare numbers where the value is
  /// one, the string otherwise.
  ///
  /// BattleScribe prints characteristics as they appear on the datasheet —
  /// `2+` for a skill, `-4` for AP, `D6` for variable damage. 40kdc stores the
  /// number. Left unconverted, every weapon in the game reported a conflict
  /// over its own punctuation, and the handful of genuine disagreements
  /// underneath — Battlesuit fists are WS4+ in one source and WS5+ in the
  /// other — were invisible in the noise.
  Object? _statValue(String raw) {
    final text = raw.trim();
    // A Torrent weapon auto-hits and has no skill. BattleScribe prints `N/A`
    // where 40kdc stores null, and shipping the literal would put "N/A" in the
    // BS column as though it were a value.
    if (text == 'N/A' || text == '-') return null;
    final skill = RegExp(r'^(\d+)\+$').firstMatch(text);
    if (skill != null) return int.parse(skill.group(1)!);
    return int.tryParse(text) ?? text;
  }

  /// `24"` -> 24, `Melee` -> `Melee`.
  Object? _rangeValue(String? raw) {
    if (raw == null) return null;
    final text = raw.trim();
    final inches = RegExp(r'^(\d+)\s*"?$').firstMatch(text);
    if (inches != null) return int.parse(inches.group(1)!);
    return text;
  }

  /// `[ASSAULT], [MELTA 2], [ANTI-INFANTRY 4+]` -> structured keywords.
  ///
  /// The parameters are the whole point. §3.7 found 201 of 920 keyword
  /// instances carry one, and a Melta 2 rendered as a bare `MELTA` is a lie
  /// about how much damage the weapon does.
  List<Map<String, Object?>> _weaponKeywords(String? text) {
    if (text == null || text.trim().isEmpty) return const [];
    final out = <Map<String, Object?>>[];
    for (final match in RegExp(r'\[([^\]]+)\]').allMatches(text)) {
      final body = match.group(1)!.trim();
      if (body.isNotEmpty) out.add(_weaponKeyword(body));
    }
    if (out.isEmpty) {
      // Some profiles list them unbracketed and comma separated.
      for (final part in text.split(',')) {
        final body = part.trim();
        if (body.isNotEmpty) out.add(_weaponKeyword(body));
      }
    }
    return out;
  }

  Map<String, Object?> _weaponKeyword(String body) {
    final anti = RegExp(r'^ANTI-(.+?)\s+(\d+)\+$', caseSensitive: false)
        .firstMatch(body);
    if (anti != null) {
      return {
        'keyword_id': 'anti',
        'parameters': {
          'target_keyword': anti.group(1)!.toLowerCase(),
          'threshold': int.parse(anti.group(2)!),
        },
      };
    }
    final valued = RegExp(r'^(.+?)\s+(\d+)\+?$').firstMatch(body);
    if (valued != null) {
      return {
        'keyword_id': bsSlug(valued.group(1)!),
        'parameters': {'value': int.parse(valued.group(2)!)},
      };
    }
    return {'keyword_id': bsSlug(body)};
  }
}

/// How many models of one kind a datasheet fields.
class _ModelGroup {
  final String name;
  final int min;
  final int max;

  const _ModelGroup(this.name, this.min, this.max);
}
