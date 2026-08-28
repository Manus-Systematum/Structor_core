/// Weapon aggregation for the shooting and fight sections (DESIGN.md §7.3.5).
///
/// The rule that governs everything here: **aggregate on the resolved profile,
/// never on the weapon name.** A Commander's Missile pod is BS3+ where a Crisis
/// suit's is BS4+ — same name, same S/AP/D. Merging them would tell the player
/// to roll twenty attacks at BS3+, which is worse than showing nothing.
///
/// What this produces that no datasheet does: **total attacks for the unit as
/// actually composed.** An attached Commander and Crisis squad field ten
/// missile pods that split eight attacks at BS3+ and twelve at BS4+, and the
/// player currently recomputes that every turn.
library;

import '../roster/roster.dart';
import '../rules/catalogue.dart';
import '../source/source_models.dart';
import 'attacks.dart';

enum WeaponKind { ranged, melee }

/// One row of the aggregated weapon table.
class AggregatedWeapon {
  /// Name as the player reads it, carrier-disambiguated only where two rows
  /// would otherwise be indistinguishable.
  final String displayName;

  final String weaponId;
  final WeaponProfile profile;

  /// How many instances of this exact profile the combat unit fields.
  final int weaponCount;

  /// Total attacks, symbolic where the characteristic is a dice expression.
  final AttackTotal attacks;

  /// Skill as displayed (`3+`), or null when the weapon hits automatically.
  final String? skill;

  /// Roster units contributing instances to this row.
  final List<String> carrierInstanceIds;

  const AggregatedWeapon({
    required this.displayName,
    required this.weaponId,
    required this.profile,
    required this.weaponCount,
    required this.attacks,
    required this.skill,
    required this.carrierInstanceIds,
  });

  /// Torrent and friends: no skill characteristic, so no roll to hit.
  bool get autoHits => skill == null;

  String? get range => profile.range;

  /// Full keywords, parameters included — `MELTA 2`, not `MELTA`.
  List<WeaponKeyword> get keywords => profile.keywords;
}

/// A wargear item that could not be resolved to a weapon for its carrier.
/// Reported rather than dropped — a silently missing weapon is a unit that
/// looks weaker than it is.
class UnresolvedWargear {
  final String instanceId;
  final String itemId;

  const UnresolvedWargear({required this.instanceId, required this.itemId});
}

class AggregationResult {
  final List<AggregatedWeapon> weapons;
  final List<UnresolvedWargear> unresolved;

  const AggregationResult({required this.weapons, required this.unresolved});

  bool get isComplete => unresolved.isEmpty;
}

class WeaponAggregator {
  final Catalogue catalogue;

  const WeaponAggregator(this.catalogue);

  /// Aggregates the weapons of a combat unit — one entry from
  /// [Roster.combatUnits], so an attached leader and its bodyguard aggregate
  /// together, as they fire together.
  ///
  /// [modelsRemaining] maps a roster unit's instance id to its surviving model
  /// count. Where a unit's wargear divides evenly across its models the counts
  /// scale exactly; where it does not, the unit is reported at full strength
  /// rather than guessed at (see [_scaleToSurvivors]).
  AggregationResult aggregate(
    List<RosterUnit> combatUnit, {
    WeaponKind kind = WeaponKind.ranged,
    Map<String, int> modelsRemaining = const {},
  }) {
    final buckets = <String, _Bucket>{};
    final unresolved = <UnresolvedWargear>[];

    for (final rosterUnit in combatUnit) {
      final datasheet = catalogue.unit(rosterUnit.datasheetId);
      if (datasheet == null) {
        for (final selection in rosterUnit.wargear) {
          unresolved.add(UnresolvedWargear(
            instanceId: rosterUnit.instanceId,
            itemId: selection.itemId,
          ));
        }
        continue;
      }

      final survivors = modelsRemaining[rosterUnit.instanceId];

      for (final selection in rosterUnit.wargear) {
        var resolved = catalogue.weaponFor(datasheet, selection.itemId);

        // A drone is wargear that grants the model a rule, and sometimes a
        // weapon with it (§7.3.7). `gun-drone` is not itself a weapon id, so
        // the grant has to be followed before calling it unresolved.
        if (resolved == null &&
            datasheet.abilityIds.contains(selection.itemId)) {
          resolved = _grantedWeapon(datasheet, selection.itemId);
          if (resolved == null) continue; // a rule, not a gun
        }

        final weapon = resolved;
        if (weapon == null) {
          // Kit that carries no gun and no rule. A Dominion Squad's
          // Simulacrum Imperialis is in the datasheet's own wargear budget
          // but is not a weapon and not in `ability_ids`, so it fell through
          // to "unresolved" — which reads as *the app could not find this*
          // when the truth is *there is nothing to show for it*. The
          // datasheet vouching for the id is what separates the two: an id
          // the datasheet never mentions is still a genuine miss.
          if (datasheet.wargearVocabulary
              .contains(datasheet.unscope(selection.itemId))) {
            continue;
          }
          unresolved.add(UnresolvedWargear(
            instanceId: rosterUnit.instanceId,
            itemId: selection.itemId,
          ));
          continue;
        }
        final count = _scaleToSurvivors(
          count: selection.count,
          totalModels: rosterUnit.models,
          survivors: survivors,
        );
        if (count <= 0) continue;

        for (final profile in weapon.profiles) {
          // Filter per profile, not per weapon: a Fusion eliminator is typed
          // `ranged` but carries a Melee profile too, and showing that in the
          // shooting table is exactly the sort of wrong number this app must
          // never put in front of a player.
          final isMelee = profile.isMelee(weaponIsMelee: !weapon.isRanged);
          if (kind == WeaponKind.ranged && isMelee) continue;
          if (kind == WeaponKind.melee && !isMelee) continue;

          final key = '${weapon.id}|${profile.profileKey}';
          buckets
              .putIfAbsent(
                key,
                () => _Bucket(
                  weapon: weapon,
                  profile: profile,
                  carrierName: datasheet.name,
                ),
              )
              .add(count, rosterUnit.instanceId);
        }
      }
    }

    return AggregationResult(
      weapons: _render(buckets.values.toList()),
      unresolved: unresolved,
    );
  }

  /// The weapon a wargear-ability grants its bearer, if it grants one.
  SourceWeapon? _grantedWeapon(SourceUnit datasheet, String abilityId) {
    final weaponId = catalogue.ability(abilityId)?.grantedWeaponId;
    if (weaponId == null) return null;
    return catalogue.weaponFor(datasheet, weaponId) ??
        catalogue.weapon(weaponId);
  }

  /// Scales a unit-level wargear count to its surviving models.
  ///
  /// Roster wargear is recorded per unit, not per model, so exact scaling is
  /// only possible when the count divides evenly — six missile pods across
  /// three models is two each, so two survivors field four. When it does not
  /// divide, the honest answer is full strength: inventing a distribution
  /// would put a wrong number in front of a player mid-game (§7.6).
  int _scaleToSurvivors({
    required int count,
    required int totalModels,
    required int? survivors,
  }) {
    if (survivors == null || survivors >= totalModels) return count;
    if (survivors <= 0) return 0;
    if (totalModels <= 0 || count % totalModels != 0) return count;
    return (count ~/ totalModels) * survivors;
  }

  List<AggregatedWeapon> _render(List<_Bucket> buckets) {
    // Disambiguate only where it is needed. Two rows reading "Missile pod"
    // must be told apart; a lone row should not carry a parenthetical.
    final nameCounts = <String, int>{};
    for (final bucket in buckets) {
      final name = bucket.baseName;
      nameCounts[name] = (nameCounts[name] ?? 0) + 1;
    }

    final rows = <AggregatedWeapon>[];
    for (final bucket in buckets) {
      final ambiguous = (nameCounts[bucket.baseName] ?? 0) > 1;
      rows.add(AggregatedWeapon(
        displayName:
            ambiguous ? '${bucket.baseName} (${bucket.carrierName})' : bucket.baseName,
        weaponId: bucket.weapon.id,
        profile: bucket.profile,
        weaponCount: bucket.count,
        attacks: scaleAttacks(bucket.profile.stats['A'], bucket.count),
        skill: formatSkill(bucket.profile.skill),
        carrierInstanceIds: List.unmodifiable(bucket.carriers),
      ));
    }

    rows.sort((a, b) => a.displayName.compareTo(b.displayName));
    return rows;
  }
}

class _Bucket {
  final SourceWeapon weapon;
  final WeaponProfile profile;

  /// Datasheet name of the unit carrying this profile — taken from the carrier
  /// rather than parsed out of the weapon id, so the label is a fact about the
  /// roster rather than a guess about a naming convention.
  final String carrierName;

  final List<String> carriers = [];
  int count = 0;

  _Bucket({
    required this.weapon,
    required this.profile,
    required this.carrierName,
  });

  void add(int n, String instanceId) {
    count += n;
    if (!carriers.contains(instanceId)) carriers.add(instanceId);
  }

  /// Multi-profile weapons read as "Plasma rifle - Standard".
  String get baseName =>
      weapon.profiles.length > 1 && profile.name != weapon.name
          ? '${weapon.name} - ${profile.name}'
          : profile.name;
}
