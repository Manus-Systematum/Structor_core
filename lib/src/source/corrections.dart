/// Corrections applied to upstream data at bundle time (DESIGN.md §3.6).
///
/// The cross-check of §3.5 finds where two sources *disagree*. This is the
/// other half of the same problem: where the data is simply wrong, or — more
/// often — incomplete in a way that makes the app state something stronger
/// than the rule says. Broadside Battlesuits' Advanced Armour is the founding
/// case: upstream encodes `feel-no-pain 4+` with no qualifier, so the play
/// screen promised an unrestricted 4+ against a rule that only applies to
/// mortal wounds.
///
/// The renderer must not paper over this — §7.6 forbids inventing rules text,
/// and a renderer that special-cased one ability would be lying about where
/// its knowledge came from. So the fix belongs to the data, and lives in a
/// file a person can read, with a reason attached.
///
/// Two rules keep this from becoming a private fork:
///
///  * a correction with no reason is not applied, exactly as with an accepted
///    divergence;
///  * a correction that matches nothing is **reported**, so one that upstream
///    has since adopted gets noticed and deleted rather than quietly shadowing
///    data that is now correct.
library;

import 'package:yaml/yaml.dart';

import 'json.dart';

/// Something a person has decided the upstream data gets wrong.
abstract interface class Correction {
  /// A faction id, or `*` for data carried identically by several factions.
  String get faction;

  /// What is being corrected, for logs and staleness reports.
  String get subject;

  String get reason;
}

/// A replacement effect for one ability in one faction.
class AbilityCorrection implements Correction {
  /// A faction id, or `*` for a core ability carried identically by several
  /// factions — Stealth is transcribed once per faction file, and wrong in
  /// each of them.
  @override
  final String faction;

  final String abilityId;

  @override
  final String reason;

  /// Where the problem has been reported upstream, for the record. Free text —
  /// 'not yet reported' is an honest value.
  final String? upstream;

  /// The effect that replaces the upstream one, in the source JSON shape.
  final Map<String, Object?> effect;

  @override
  String get subject => abilityId;

  const AbilityCorrection({
    required this.faction,
    required this.abilityId,
    required this.reason,
    required this.effect,
    this.upstream,
  });
}

/// Wargear a datasheet can carry that upstream does not list.
///
/// Drones are wargear, and what a drone does is an ability (§7.3.7) — so a
/// datasheet that can take one has to name it in both `ability_ids` (what it
/// does) and `wargear_budgets` (that it is a choice, not standard kit). The
/// second half is what lets the app show a drone's rules only on units that
/// actually bought one.
class UnitCorrection implements Correction {
  @override
  final String faction;

  final String unitId;

  @override
  final String reason;

  final String? upstream;

  @override
  String get subject => unitId;

  /// Ability ids the datasheet may take as wargear.
  final List<String> addWargear;

  /// Ability ids that are fitted as standard, not chosen.
  ///
  /// Upstream can say both at once: the Commander in Coldstar Battlesuit
  /// lists `shield-generator` in `ability_ids` *and* in `wargear_budgets`, so
  /// the app cannot tell whether a list that does not mention one has an
  /// invulnerable save. Naming it standard settles that.
  final List<String> standardWargear;

  /// Ability ids the datasheet does not have at all.
  ///
  /// The counterpart to [addWargear], and needed for the same reason: a
  /// wrongly *present* option is as misleading as a missing one. A Commander
  /// in Enforcer Battlesuit is offered a Shield Generator, which belongs to
  /// the Riptide and Stormsurge, and picking it spends points on a rule the
  /// model does not have.
  final List<String> removeWargear;

  const UnitCorrection({
    required this.faction,
    required this.unitId,
    required this.reason,
    this.addWargear = const [],
    this.standardWargear = const [],
    this.removeWargear = const [],
    this.upstream,
  });
}

/// A weapon record upstream is missing, or has wrong.
///
/// Needed because an ability can name a weapon that does not exist: the Recon
/// Drone grants `drone-burst-cannon` and no such record is in the file, so the
/// grant resolves to nothing. Adding the weapon is the only way to make the
/// grant mean anything.
class WeaponCorrection implements Correction {
  @override
  final String faction;

  final String weaponId;

  @override
  final String reason;

  final String? upstream;

  /// The whole record, in the source JSON shape, minus its id. Empty when
  /// [deriveFrom] is set.
  final Map<String, Object?> record;

  /// Build this weapon from another one instead of writing it out.
  ///
  /// A drone's weapon is its namesake at BS5+ — the Missile Drone fires the
  /// unit's missile pod, just worse. Deriving says that, and keeps the copy
  /// in step when upstream revises the original. Copying the stat block
  /// instead means a points or profile change upstream silently stops
  /// applying to the drone.
  final String? deriveFrom;

  /// Display name for a derived weapon.
  final String? name;

  /// Stat overrides applied to every profile of a derived weapon.
  final Map<String, Object?> overrideStats;

  @override
  String get subject => weaponId;

  const WeaponCorrection({
    required this.faction,
    required this.weaponId,
    required this.reason,
    this.record = const {},
    this.deriveFrom,
    this.name,
    this.overrideStats = const {},
    this.upstream,
  });
}

/// Two ids for one rule, folded into one.
///
/// Upstream transcribes an ability once per datasheet that has it, and the
/// datasheets do not agree on the plural: a Ghostkeel has a Battlesuit Support
/// System, a Crisis Starscythe has Battlesuit Support Systems, and the effect
/// records are identical. Left alone that is only untidy, but §7.3.9 decides
/// whether a rule is shared by counting the datasheets that carry its id — so
/// a stray plural splits one shared rule into two rules nobody shares, and the
/// rules screen files the same sentence in two different places.
///
/// The alias is deliberately not a rename: [canonicalId] must already exist,
/// so this can only ever merge a duplicate into a record upstream also has.
/// A Unit Upgrade limited to named datasheets.
///
/// The restriction is real and upstream does not carry it: both of T'au's
/// upgrades publish `keyword_restrictions: ["T’au Empire"]` and nothing more,
/// so every Character in the army was offered them. Reported by the app's
/// user, who fields the army.
class EnhancementCorrection implements Correction {
  @override
  final String faction;
  final String enhancementId;
  @override
  final String reason;
  final String? upstream;

  /// Datasheet ids it may go on. `Unmasking Suite` takes two, which is why
  /// this is a list and not a keyword: restrictions are all required at once
  /// and Pathfinders are not Stealth Battlesuits.
  final List<String> restrictTo;

  const EnhancementCorrection({
    required this.faction,
    required this.enhancementId,
    required this.reason,
    required this.restrictTo,
    this.upstream,
  });

  @override
  String get subject => enhancementId;
}

/// The phases a rule is actually used in.
///
/// `phase-mappings.json` is community-authored, and where it does not know it
/// files a rule under **all five phases** — which the turn page then honours,
/// putting `Righteous Repugnance` in the Charge section of a list that has
/// Morvenn Vahl in it. All five is sometimes a real claim (`Unholy Vigour` is
/// "at the start of any phase"), so the mapping cannot be blanket-ignored;
/// these are the ones whose printed text names the phases outright.
class PhaseMappingCorrection implements Correction {
  @override
  final String faction;
  final String abilityId;
  @override
  final String reason;
  final String? upstream;
  final List<String> phases;

  const PhaseMappingCorrection({
    required this.faction,
    required this.abilityId,
    required this.reason,
    required this.phases,
    this.upstream,
  });

  @override
  String get subject => abilityId;
}

class AliasCorrection implements Correction {
  @override
  final String faction;

  /// The duplicate, which is dropped.
  final String abilityId;

  /// The record it folds into.
  final String canonicalId;

  @override
  final String reason;

  final String? upstream;

  @override
  String get subject => '$abilityId -> $canonicalId';

  const AliasCorrection({
    required this.faction,
    required this.abilityId,
    required this.canonicalId,
    required this.reason,
    this.upstream,
  });
}

class CorrectionResult {
  final List<Object?> records;

  /// Corrections that found their subject.
  final List<Correction> applied;

  /// Corrections that matched nothing — a stale entry, or a typo in the id.
  final List<Correction> unmatched;

  const CorrectionResult({
    required this.records,
    required this.applied,
    required this.unmatched,
  });
}

class DataCorrections {
  final List<AbilityCorrection> abilities;
  final List<UnitCorrection> units;
  final List<WeaponCorrection> weapons;
  final List<EnhancementCorrection> enhancements;
  final List<PhaseMappingCorrection> phaseMappings;
  final List<AliasCorrection> aliases;

  const DataCorrections({
    this.abilities = const [],
    this.units = const [],
    this.weapons = const [],
    this.enhancements = const [],
    this.phaseMappings = const [],
    this.aliases = const [],
  });

  static const empty = DataCorrections();

  bool get isEmpty =>
      abilities.isEmpty &&
      units.isEmpty &&
      weapons.isEmpty &&
      enhancements.isEmpty &&
      phaseMappings.isEmpty &&
      aliases.isEmpty;

  static const _anyFaction = '*';

  /// Duplicate ability id to canonical id, for [factionId].
  Map<String, String> _aliasesFor(String factionId) => {
        for (final c in aliases)
          if (c.faction == factionId || c.faction == _anyFaction)
            c.abilityId: c.canonicalId,
      };

  /// Applies weapon corrections to raw `weapons.json` records.
  ///
  /// A weapon named by a correction is **added** when upstream has no record
  /// for it, and replaced when it does. Both count as applied — an addition
  /// that turns out to exist upstream is reported by the bundler, since that
  /// is the signal the entry has been adopted and should go.
  CorrectionResult applyToWeapons(String factionId, List<Object?> records) {
    final byId = {
      for (final c in weapons)
        if (c.faction == factionId || c.faction == _anyFaction) c.weaponId: c,
    };
    if (byId.isEmpty) {
      return CorrectionResult(
        records: records,
        applied: const [],
        unmatched: const [],
      );
    }

    final source = <String, Object?>{
      for (final record in records)
        if (record is Map && record['id'] != null)
          record['id'].toString(): record,
    };

    Map<String, Object?>? build(WeaponCorrection c) {
      var body = c.record;
      if (c.deriveFrom != null) {
        final original = _plain(source[c.deriveFrom]);
        if (original is! Map<String, Object?>) return null;
        body = {
          for (final e in original.entries)
            if (e.key != 'id' && e.key != 'corrected') e.key: e.value,
        };
        if (c.name != null) body['name'] = c.name;
        body['profiles'] = [
          for (final profile in asList(body['profiles']))
            if (_plain(profile) case final Map<String, Object?> p)
              {
                ...p,
                if (c.name != null) 'name': c.name,
                'stats': {
                  ...asMap(p['stats']),
                  ...c.overrideStats,
                },
              },
        ];
      }
      if (body.isEmpty) return null;
      return {
        'id': c.weaponId,
        ...body,
        'corrected': {
          'reason': c.reason,
          if (c.upstream != null) 'upstream': c.upstream,
        },
      };
    }

    final applied = <Correction>[];
    final unmatched = <Correction>[];
    final out = <Object?>[];

    for (final record in records) {
      if (record is! Map) {
        out.add(record);
        continue;
      }
      final correction = byId.remove(record['id']?.toString());
      final built = correction == null ? null : build(correction);
      if (built == null) {
        out.add(record);
        if (correction != null) unmatched.add(correction);
        continue;
      }
      applied.add(correction!);
      out.add(built);
    }

    // Whatever is left had no upstream record at all, which is the case this
    // exists for. A derivation whose source is missing is reported instead —
    // silently skipping it would leave the grant dangling again.
    for (final correction in byId.values) {
      final built = build(correction);
      if (built == null) {
        unmatched.add(correction);
        continue;
      }
      applied.add(correction);
      out.add(built);
    }

    return CorrectionResult(
      records: out,
      applied: applied,
      unmatched: unmatched,
    );
  }

  /// Applies unit corrections to raw `units.json` records.
  CorrectionResult applyToUnits(String factionId, List<Object?> records) {
    final byId = {
      for (final c in units)
        if (c.faction == factionId || c.faction == _anyFaction) c.unitId: c,
    };
    final aliased = _aliasesFor(factionId);
    if (byId.isEmpty && aliased.isEmpty) {
      return CorrectionResult(
        records: records,
        applied: const [],
        unmatched: const [],
      );
    }

    final applied = <Correction>[];
    final out = <Object?>[];

    /// Rewrites ids through [aliased], dropping a duplicate the canonical id
    /// already covers.
    List<String> resolve(Iterable<Object?> ids) {
      final seen = <String>[];
      for (final id in ids) {
        final canonical = aliased['$id'] ?? '$id';
        if (!seen.contains(canonical)) seen.add(canonical);
      }
      return seen;
    }

    /// The same rewrite inside wargear budgets, since a drone or a support
    /// system is offered as wargear and named there by the same id.
    List<Object?> resolveBudgets(List<Object?> budgets) => [
          for (final b in budgets)
            if (b is Map)
              {
                for (final e in b.entries) e.key.toString(): e.value,
                'items': resolve(asList(b['items'])),
              }
            else
              b,
        ];

    for (final record in records) {
      if (record is! Map) {
        out.add(record);
        continue;
      }
      final correction = byId[record['id']?.toString()];
      if (correction == null) {
        // An alias applies to every datasheet, not only the ones a unit
        // correction names, so this pass runs regardless.
        if (aliased.isEmpty) {
          out.add(record);
          continue;
        }
        out.add({
          for (final e in record.entries) e.key.toString(): e.value,
          'ability_ids': resolve(asList(record['ability_ids'])),
          'wargear_budgets': resolveBudgets(asList(record['wargear_budgets'])),
        });
        continue;
      }
      applied.add(correction);

      final abilityIds = resolve(asList(record['ability_ids']));
      var budgets = resolveBudgets(asList(record['wargear_budgets']));

      // Standard kit is not a choice, so it must not appear as a budget item
      // — otherwise the app hides its rule on any list that does not mention
      // buying one.
      for (final item in correction.standardWargear) {
        if (!abilityIds.contains(item)) abilityIds.add(item);
        budgets = [
          for (final b in budgets)
            if (!(b is Map &&
                asList(b['items']).map((i) => '$i').contains(item)))
              b,
        ];
      }

      for (final item in correction.addWargear) {
        if (!abilityIds.contains(item)) abilityIds.add(item);
        final alreadyBudgeted = budgets.any((b) =>
            b is Map && asList(b['items']).map((i) => '$i').contains(item));
        if (!alreadyBudgeted) {
          budgets.add({
            'items': [item],
            'count': 1,
            'per_models': 0
          });
        }
      }

      // Gone from both: an item the datasheet does not have is neither an
      // option nor standard kit. A budget naming only the removed item goes
      // with it, rather than being left as an empty choice.
      for (final item in correction.removeWargear) {
        abilityIds.remove(item);
        budgets = [
          for (final b in budgets)
            if (b is Map)
              if (asList(b['items']).map((i) => '$i').toSet().difference({item})
                  case final kept when kept.isNotEmpty)
                {...b, 'items': kept.toList()}
              else
                null
            else
              b,
        ].whereType<Object>().toList();
      }

      out.add({
        for (final e in record.entries) e.key.toString(): e.value,
        'ability_ids': abilityIds,
        'wargear_budgets': budgets,
        'corrected': {
          'reason': correction.reason,
          if (correction.upstream != null) 'upstream': correction.upstream,
        },
      });
    }

    return CorrectionResult(
      records: out,
      applied: applied,
      unmatched: [
        for (final c in byId.values)
          if (c.faction != _anyFaction && !applied.contains(c)) c,
      ],
    );
  }

  /// Corrections for one faction, applied to its raw `abilities.json` records.
  ///
  /// Returns fresh records; the input is not mutated, so a caller may bundle
  /// corrected data while a cross-check still reads the original.
  /// Stamps `unit_ids` onto the enhancements a correction restricts.
  CorrectionResult applyToEnhancements(
      String factionId, List<Object?> records) {
    final byId = {
      for (final c in enhancements)
        if (c.faction == factionId) c.enhancementId: c,
    };
    if (byId.isEmpty) {
      return CorrectionResult(
          records: records, applied: const [], unmatched: const []);
    }

    final applied = <Correction>[];
    final out = <Object?>[];
    for (final record in records) {
      if (record is! Map) {
        out.add(record);
        continue;
      }
      final correction = byId[record['id']?.toString()];
      if (correction == null) {
        out.add(record);
        continue;
      }
      applied.add(correction);
      out.add({
        for (final e in record.entries) e.key.toString(): e.value,
        'unit_ids': correction.restrictTo,
        'corrected': {
          'reason': correction.reason,
          if (correction.upstream != null) 'upstream': correction.upstream,
        },
      });
    }
    return CorrectionResult(
      records: out,
      applied: applied,
      // Reported, so an entry upstream has since adopted gets noticed.
      unmatched: [
        for (final c in byId.values)
          if (!applied.contains(c)) c,
      ],
    );
  }

  /// Replaces the phases a mapping files an ability under.
  CorrectionResult applyToPhaseMappings(
      String factionId, List<Object?> records) {
    final byId = {
      for (final c in phaseMappings)
        if (c.faction == factionId) c.abilityId: c,
    };
    if (byId.isEmpty) {
      return CorrectionResult(
          records: records, applied: const [], unmatched: const []);
    }

    final applied = <Correction>[];
    final out = <Object?>[];
    for (final record in records) {
      if (record is! Map) {
        out.add(record);
        continue;
      }
      final correction = byId[record['source_id']?.toString()];
      if (correction == null) {
        out.add(record);
        continue;
      }
      applied.add(correction);
      out.add({
        for (final e in record.entries) e.key.toString(): e.value,
        'phases': correction.phases,
        'corrected': {
          'reason': correction.reason,
          if (correction.upstream != null) 'upstream': correction.upstream,
        },
      });
    }
    return CorrectionResult(
      records: out,
      applied: applied,
      unmatched: [
        for (final c in byId.values)
          if (!applied.contains(c)) c,
      ],
    );
  }

  CorrectionResult applyToAbilities(
    String factionId,
    List<Object?> records,
  ) {
    final mine = abilities
        .where((c) => c.faction == factionId || c.faction == _anyFaction)
        .toList();
    final myAliases = aliases
        .where((c) => c.faction == factionId || c.faction == _anyFaction)
        .toList();
    if (mine.isEmpty && myAliases.isEmpty) {
      return CorrectionResult(
        records: records,
        applied: const [],
        unmatched: const [],
      );
    }

    final byId = {for (final c in mine) c.abilityId: c};
    final aliasById = {for (final c in myAliases) c.abilityId: c};
    final present = {
      for (final record in records)
        if (record is Map && record['ability_id'] != null)
          record['ability_id'].toString(),
    };
    final applied = <Correction>[];
    final out = <Object?>[];

    for (final record in records) {
      if (record is! Map) {
        out.add(record);
        continue;
      }
      final id = record['ability_id']?.toString();

      // A duplicate is dropped only once its canonical twin is confirmed
      // present — an alias must never be the reason a rule disappears.
      final alias = aliasById[id];
      if (alias != null && present.contains(alias.canonicalId)) {
        applied.add(alias);
        continue;
      }

      final correction = byId[id];
      if (correction == null) {
        out.add(record);
        continue;
      }
      applied.add(correction);
      out.add({
        for (final e in record.entries) e.key.toString(): e.value,
        'effect': correction.effect,
        // Kept in the shipped record so the provenance travels with the data
        // rather than living only in a build log.
        'corrected': {
          'reason': correction.reason,
          if (correction.upstream != null) 'upstream': correction.upstream,
        },
      });
    }

    return CorrectionResult(
      records: out,
      applied: applied,
      // A wildcard correction is not stale just because *this* faction has no
      // such ability — only if no faction anywhere has it, which only the
      // caller iterating every faction can know.
      unmatched: [
        for (final c in <Correction>[...mine, ...myAliases])
          if (c.faction != _anyFaction && !applied.contains(c)) c,
      ],
    );
  }

  /// Wildcard corrections that fired for no faction at all — the same "stale
  /// entry" check [CorrectionResult.unmatched] does, but across a whole run.
  List<Correction> neverApplied(Iterable<Correction> applied) {
    final fired = applied.toSet();
    return [
      for (final c in <Correction>[
        ...abilities,
        ...units,
        ...weapons,
        ...aliases,
      ])
        if (c.faction == _anyFaction && !fired.contains(c)) c,
    ];
  }

  static DataCorrections parse(String yamlSource) {
    final root = loadYaml(yamlSource);
    if (root is! Map) return empty;

    final abilities = <AbilityCorrection>[];
    final raw = root['abilities'];
    if (raw is List) {
      for (final node in raw) {
        if (node is! Map) continue;
        final reason = node['reason']?.toString().trim() ?? '';
        final effect = _plain(node['effect']);
        // A correction with no reason is indistinguishable from a private
        // edit, and one with no effect has nothing to say.
        if (reason.isEmpty ||
            effect is! Map<String, Object?> ||
            effect.isEmpty) {
          continue;
        }
        abilities.add(AbilityCorrection(
          faction: node['faction']?.toString() ?? '',
          abilityId: node['id']?.toString() ?? '',
          reason: reason,
          upstream: node['upstream']?.toString(),
          effect: effect,
        ));
      }
    }
    final units = <UnitCorrection>[];
    final rawUnits = root['units'];
    if (rawUnits is List) {
      for (final node in rawUnits) {
        if (node is! Map) continue;
        final reason = node['reason']?.toString().trim() ?? '';
        final wargear = [
          for (final item in asList(_plain(node['add_wargear']))) '$item',
        ];
        final standard = [
          for (final item in asList(_plain(node['standard_wargear']))) '$item',
        ];
        if (reason.isEmpty || (wargear.isEmpty && standard.isEmpty)) continue;
        units.add(UnitCorrection(
          faction: node['faction']?.toString() ?? '',
          unitId: node['id']?.toString() ?? '',
          reason: reason,
          upstream: node['upstream']?.toString(),
          addWargear: wargear,
          standardWargear: standard,
          removeWargear: [
            for (final item in asList(_plain(node['remove_wargear']))) '$item',
          ],
        ));
      }
    }

    final weapons = <WeaponCorrection>[];
    final rawWeapons = root['weapons'];
    if (rawWeapons is List) {
      for (final node in rawWeapons) {
        if (node is! Map) continue;
        final reason = node['reason']?.toString().trim() ?? '';
        final record = _plain(node['weapon']);
        final deriveFrom = node['derive_from']?.toString();
        final overrides = _plain(node['override_stats']);
        final hasRecord = record is Map<String, Object?> && record.isNotEmpty;
        if (reason.isEmpty || (!hasRecord && deriveFrom == null)) continue;
        weapons.add(WeaponCorrection(
          faction: node['faction']?.toString() ?? '',
          weaponId: node['id']?.toString() ?? '',
          reason: reason,
          upstream: node['upstream']?.toString(),
          record: hasRecord ? record : const {},
          deriveFrom: deriveFrom,
          name: node['name']?.toString(),
          overrideStats:
              overrides is Map<String, Object?> ? overrides : const {},
        ));
      }
    }

    final enhancements = <EnhancementCorrection>[];
    final rawEnhancements = root['enhancements'];
    if (rawEnhancements is List) {
      for (final node in rawEnhancements) {
        if (node is! Map) continue;
        final reason = node['reason']?.toString().trim() ?? '';
        final restrict = [
          for (final item in asList(_plain(node['restrict_to']))) '$item',
        ];
        if (reason.isEmpty || restrict.isEmpty) continue;
        enhancements.add(EnhancementCorrection(
          faction: node['faction']?.toString() ?? '',
          enhancementId: node['id']?.toString() ?? '',
          reason: reason,
          upstream: node['upstream']?.toString(),
          restrictTo: restrict,
        ));
      }
    }

    final phaseMappings = <PhaseMappingCorrection>[];
    final rawPhases = root['phase_mappings'];
    if (rawPhases is List) {
      for (final node in rawPhases) {
        if (node is! Map) continue;
        final reason = node['reason']?.toString().trim() ?? '';
        final phases = [
          for (final item in asList(_plain(node['phases']))) '$item',
        ];
        if (reason.isEmpty || phases.isEmpty) continue;
        phaseMappings.add(PhaseMappingCorrection(
          faction: node['faction']?.toString() ?? '',
          abilityId: node['id']?.toString() ?? '',
          reason: reason,
          upstream: node['upstream']?.toString(),
          phases: phases,
        ));
      }
    }

    final aliases = <AliasCorrection>[];
    final rawAliases = root['aliases'];
    if (rawAliases is List) {
      for (final node in rawAliases) {
        if (node is! Map) continue;
        final reason = node['reason']?.toString().trim() ?? '';
        final id = node['id']?.toString() ?? '';
        final canonical = node['canonical']?.toString() ?? '';
        if (reason.isEmpty || id.isEmpty || canonical.isEmpty) continue;
        if (id == canonical) continue;
        aliases.add(AliasCorrection(
          faction: node['faction']?.toString() ?? '',
          abilityId: id,
          canonicalId: canonical,
          reason: reason,
          upstream: node['upstream']?.toString(),
        ));
      }
    }

    return DataCorrections(
      abilities: abilities,
      units: units,
      weapons: weapons,
      enhancements: enhancements,
      phaseMappings: phaseMappings,
      aliases: aliases,
    );
  }

  /// YAML nodes are not JSON-encodable, so they are copied into plain maps and
  /// lists before being written into a bundle.
  static Object? _plain(Object? node) {
    if (node is Map) {
      return <String, Object?>{
        for (final e in node.entries) e.key.toString(): _plain(e.value),
      };
    }
    if (node is List) return [for (final e in node) _plain(e)];
    return node;
  }
}
