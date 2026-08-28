/// Roster pricing (DESIGN.md §2.1).
///
///     unit cost = bracket(models, copyIndex).cost + Σ wargear instances × cost
///
/// Two mechanisms, both easy to miss, and both verified against a real
/// 2,000 pt list:
///
///   - brackets can scale with **copy index**, so the third Crisis Fireknife
///     costs 110 where the first costs 100;
///   - `wargear_costs` are charged **per instance**, so six missile pods at 5
///     add 30 to that squad.
///
/// Because copy index is a property of the roster and not of the unit, pricing
/// is a **roster-level computation**. A per-unit lookup under-prices the
/// reference list by 60 points and reports it as legal.
library;

import '../rules/catalogue.dart';
import 'roster.dart';

/// Why a unit could not be priced. Surfaced rather than silently treated as
/// zero — a missing price must never read as a cheap unit.
enum PricingProblem { unknownDatasheet, noMatchingBracket }

class UnitCost {
  final String instanceId;
  final String datasheetId;
  final int copyIndex;
  final int base;
  final int wargear;

  /// Enhancements and Unit Upgrades borne by this unit. Charged **per
  /// bearer**: a Unit Upgrade on three units costs three times, even though
  /// the three share one slot (§2.1).
  final int enhancements;

  final PricingProblem? problem;

  const UnitCost({
    required this.instanceId,
    required this.datasheetId,
    required this.copyIndex,
    required this.base,
    required this.wargear,
    this.enhancements = 0,
    this.problem,
  });

  int get total => base + wargear + enhancements;
  bool get isPriced => problem == null;
}

class RosterCost {
  final List<UnitCost> units;

  const RosterCost(this.units);

  int get total => units.fold(0, (sum, u) => sum + u.total);

  /// Units the catalogue could not price. Any non-empty result means [total]
  /// is a floor, not an answer.
  List<UnitCost> get unpriced => units.where((u) => !u.isPriced).toList();

  bool get isComplete => unpriced.isEmpty;
}

class PointsCalculator {
  final Catalogue catalogue;

  const PointsCalculator(this.catalogue);

  RosterCost price(Roster roster) {
    final costs = <UnitCost>[];

    // Enhancements and Unit Upgrades are priced per bearer, so they are
    // gathered by instance before the units are walked. Slots are counted
    // differently — three instances of an Upgrade share one — but that is the
    // validator's arithmetic, not this one's (§2.1).
    final borne = <String, int>{};
    void charge(String instanceId, String enhancementId) {
      for (final enhancement in catalogue.enhancements) {
        if (enhancement.id != enhancementId) continue;
        borne[instanceId] = (borne[instanceId] ?? 0) + enhancement.cost;
        return;
      }
    }

    for (final selection in roster.enhancements) {
      charge(selection.targetInstanceId, selection.enhancementId);
    }
    for (final selection in roster.upgrades) {
      for (final instanceId in selection.targetInstanceIds) {
        charge(instanceId, selection.upgradeId);
      }
    }

    // Copy index is assigned in roster order, so it is tracked as we go rather
    // than recomputed per unit.
    final seen = <String, int>{};

    for (final unit in roster.units) {
      final copyIndex = (seen[unit.datasheetId] ?? 0) + 1;
      seen[unit.datasheetId] = copyIndex;

      final datasheet = catalogue.unit(unit.datasheetId);
      if (datasheet == null) {
        costs.add(UnitCost(
          instanceId: unit.instanceId,
          datasheetId: unit.datasheetId,
          copyIndex: copyIndex,
          base: 0,
          wargear: 0,
          problem: PricingProblem.unknownDatasheet,
        ));
        continue;
      }

      final bracket =
          datasheet.bracketFor(models: unit.models, copyIndex: copyIndex);
      if (bracket == null) {
        costs.add(UnitCost(
          instanceId: unit.instanceId,
          datasheetId: unit.datasheetId,
          copyIndex: copyIndex,
          base: 0,
          wargear: 0,
          problem: PricingProblem.noMatchingBracket,
        ));
        continue;
      }

      var wargear = 0;
      for (final selection in unit.wargear) {
        wargear += selection.count * datasheet.costOfWargear(selection.itemId);
      }

      costs.add(UnitCost(
        instanceId: unit.instanceId,
        datasheetId: unit.datasheetId,
        copyIndex: copyIndex,
        base: bracket.cost,
        wargear: wargear,
        enhancements: borne[unit.instanceId] ?? 0,
      ));
    }

    return RosterCost(costs);
  }
}
