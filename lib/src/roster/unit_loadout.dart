/// What one datasheet may carry, arranged the way the editor asks about it
/// (DESIGN.md §4.5).
///
/// §2.3 settled that the builder is permissive and the validator is honest,
/// and that stands. What changed is that "permissive" was being read as
/// "unstructured": every item was a bare counter, so a Crisis suit offered its
/// Battlesuit Fists for removal — which no rule allows and no player wants —
/// and offered its drones as three independent numbers when the datasheet says
/// *up to two, of different kinds*.
///
/// The published data supports three statements, and this separates them by
/// how much they can be trusted:
///
///   * **Fixed.** A default weapon that no published option can replace. The
///     Crisis Fireknife's Battlesuit Fists are in every model's default
///     loadout and appear in no `replaces` list. Locking these takes nothing
///     away, because there was never a legal list without them.
///   * **Groups.** An option record whose bundles spell out whole selections
///     is a closed list, and picking one bundle is the whole interaction.
///   * **Loose.** Everything else stays a counter, including every item on the
///     roughly half of datasheets that publish no options at all. A bare
///     `max_count` rides along as a stated limit rather than a stop, because
///     the reference list — a validated 2,000 point export — carries four
///     T'au flamers on a Commander whose record caps them at three.
library;

import '../rules/catalogue.dart';
import '../source/source_models.dart';

/// One mutually exclusive selection: pick one bundle, or none.
class LoadoutGroup {
  final String optionId;

  /// The alternatives, each a complete legal selection. An item repeated
  /// inside a bundle means two of it, which some genuinely allow.
  final List<List<String>> bundles;

  /// What taking a bundle gives up, when the record says.
  final List<String> replaces;

  /// The model in the unit this applies to, when the record names one.
  final String? modelName;

  const LoadoutGroup({
    required this.optionId,
    required this.bundles,
    this.replaces = const [],
    this.modelName,
  });

  /// Every item any bundle can put on the unit.
  Set<String> get items => {for (final bundle in bundles) ...bundle};

  /// The bundle matching what the unit currently carries, or null when the
  /// selection is off-menu — which a hand-edited or imported list may well be,
  /// and which must be shown rather than silently corrected.
  /// Which bundle is carried and how many models took it, or null when what
  /// the unit holds is not a whole number of any one bundle.
  ///
  /// Several models may take the same swap, so a Seraphim Squad with four
  /// hand flamers is two copies of a two-flamer bundle rather than a
  /// combination the datasheet does not offer (§4.5).
  ({int index, int copies})? selection(Map<String, int> carried) {
    for (final (index, bundle) in bundles.indexed) {
      final wanted = <String, int>{};
      for (final item in bundle) {
        wanted[item] = (wanted[item] ?? 0) + 1;
      }
      if (wanted.isEmpty) continue;

      int? copies;
      var matches = true;
      for (final entry in wanted.entries) {
        final held = carried[entry.key] ?? 0;
        if (held == 0 || held % entry.value != 0) {
          matches = false;
          break;
        }
        final n = held ~/ entry.value;
        if (copies != null && copies != n) {
          matches = false;
          break;
        }
        copies = n;
      }
      // Nothing outside the bundle, or it is a different combination.
      if (matches &&
          items.every((i) => wanted.containsKey(i) || (carried[i] ?? 0) == 0) &&
          copies != null) {
        return (index: index, copies: copies);
      }
    }
    return null;
  }

  int? selectedIndex(Map<String, int> carried) => selection(carried)?.index;
}

/// A counter, with the limit the data states where it states one.
class LoadoutCounter {
  final String itemId;

  /// The most the data says may be taken, or null when it says nothing.
  ///
  /// Advisory. It is surfaced and validated against, never used to disable
  /// the button — see the library comment.
  final int? statedMax;

  /// One per this many models, when the record says so.
  final int? perModels;

  /// Items this one replaces, so taking it can give the other back.
  final List<String> replaces;

  const LoadoutCounter({
    required this.itemId,
    this.statedMax,
    this.perModels,
    this.replaces = const [],
  });
}

/// The stricter of two stated caps, or whichever one exists.
int? _tighter(int? a, int? b) {
  if (a == null) return b;
  if (b == null) return a;
  return a < b ? a : b;
}

class UnitLoadout {
  /// Whether every counter's [LoadoutCounter.statedMax] is a whole-unit
  /// number rather than a per-model one.
  ///
  /// True only for a single-model datasheet, where BSData's per-entry cap is
  /// the unit's — a Commander is one suit with four hardpoints. On a squad
  /// the same entry means one *per model*, and the sources do not say which
  /// of a squad's caps are per model and which per unit: a Stealth team takes
  /// two fusion blasters across five suits, and a Broadside team two missile
  /// drones across two. Both read `1` somewhere. Only where the question
  /// cannot arise is the cap firm enough to call a list illegal (§4.5).
  final bool capsAreExact;

  /// Items the unit always has, in default-loadout quantity. Not removable.
  final Map<String, int> fixed;

  final List<LoadoutGroup> groups;
  final List<LoadoutCounter> counters;

  const UnitLoadout({
    required this.fixed,
    required this.groups,
    required this.counters,
    this.capsAreExact = false,
  });

  bool isFixed(String itemId) => fixed.containsKey(itemId);

  /// True when nothing is published for this datasheet, so the editor should
  /// stay entirely permissive rather than imply a rule it has not got.
  bool get isUnpublished =>
      groups.isEmpty &&
      counters.every((c) =>
          c.statedMax == null && c.perModels == null && c.replaces.isEmpty);

  /// Reads the published options for one datasheet.
  factory UnitLoadout.forDatasheet(
    SourceUnit datasheet, {
    required Catalogue catalogue,
    required Iterable<String> vocabulary,
  }) {
    // **Option ids are carrier-scoped; roster ids are not.** A Paragon's
    // multi-melta is published as `multi-melta-paragon-warsuits` and stored on
    // the roster as `multi-melta` (§7.3.5), so an option read raw matches
    // nothing the unit actually carries: the multi-melta showed as a bare
    // counter with no `replaces`, and taking one left the heavy bolter it
    // replaces on the model.
    final options = [
      for (final option in catalogue.wargearOptions(datasheet.id))
        option.mapIds(datasheet.unscope),
    ];
    final composition = catalogue.composition(datasheet.id);
    final defaults = composition?.defaultWargear() ?? const <String, int>{};

    // Anything any published option can take away is, by definition, not
    // fixed.
    //
    // **A datasheet with no options published is all fixed** (§4.5, revised).
    // This used to leave everything open on the reasoning that absence of
    // data is not evidence of a restriction — true, but it produced a worse
    // wrong at the other end: Morvenn Vahl publishes no options and carries
    // three weapons she always has, and the editor offered a `+` on each of
    // them. Nothing in the game lets a named character take a second Lance
    // of Illumination, and a control that offers it is not being permissive,
    // it is inventing a rule the data never had either.
    //
    // The cost is stated rather than hidden: 1,310 of 1,863 datasheets (70%)
    // publish no options, and 1,048 of them carry more than one weapon, so
    // this fixes the loadout on over half the roster. What is lost is the
    // ability to work around a *gap* in the option data by hand. What is
    // gained is that the editor stops asserting choices nobody has.
    final replaceable = <String>{
      for (final option in options) ...option.replaces,
    };
    final fixed = options.isEmpty
        ? defaults
        : {
            for (final entry in defaults.entries)
              if (!replaceable.contains(entry.key)) entry.key: entry.value,
          };

    final groups = <LoadoutGroup>[];
    final constrained = <String, SourceWargearOption>{};
    for (final option in options) {
      if (option.isEnumeration) {
        groups.add(LoadoutGroup(
          optionId: option.id,
          bundles: option.choices,
          replaces: option.replaces,
          modelName: option.modelName,
        ));
        continue;
      }
      for (final item in option.offered) {
        // Where two records mention the same item, the tighter cap wins; a
        // record with no cap never loosens one that has it.
        final existing = constrained[item];
        if (existing == null ||
            (option.maxCount != null &&
                (existing.maxCount == null ||
                    option.maxCount! < existing.maxCount!))) {
          constrained[item] = option;
        }
      }
    }

    // **Two sources state a cap, and the tighter one is the real one.**
    //
    // A Novitiate Squad's option reads `max_count: 4` over a choice of
    // `[flamer] | [banner] | [simulacrum]` — 40kdc collapsing three separate
    // limits into the number of *models* that may swap, and losing which
    // item each applies to. Read per item that becomes 0-4 of each, so the
    // editor offered four Sacred Banners on a squad allowed one.
    //
    // The budget lines carry what was lost: one banner, one simulacrum, two
    // flamers, which is exactly BSData's `max 1`/`max 1`/`max 2` constraints
    // come through the merge. Neither source is wrong — 4 is the aggregate
    // and 1/1/2 are the parts — so the counter takes the smaller, and the
    // aggregate is left to the validator, which can see the whole unit.
    final budgeted = <String, int>{};
    for (final budget in datasheet.wargearBudgets) {
      if (budget.count <= 0) continue;
      for (final item in budget.items) {
        final id = datasheet.unscope(item);
        final known = budgeted[id];
        if (known == null || budget.count > known) budgeted[id] = budget.count;
      }
    }

    // One model, so an entry's own cap is the whole unit's.
    //
    // **A missing composition is not a single-model unit.** The snapshot
    // carries no compositions — only the builder needs them — so defaulting
    // to 1 made every cap in play mode look exact, and a Crisis team of three
    // was reported for having three sets of battlesuit fists. Absence of data
    // does not license an error (§2.3).
    final singleModel =
        composition != null && (composition.maxModels ?? 2) <= 1;

    final grouped = {for (final group in groups) ...group.items};
    final counters = <LoadoutCounter>[
      for (final itemId in vocabulary)
        if (!fixed.containsKey(itemId) && !grouped.contains(itemId))
          LoadoutCounter(
            itemId: itemId,
            // **On a single-model datasheet, BSData's per-item cap is the
            // unit's cap.** A Commander is one suit with four hardpoints, and
            // BSData states them per weapon — four T'au flamers, one shield
            // generator. 40kdc flattens that to `max_count: 3` across ten
            // different guns, a count of *selections*, which forbids the
            // fourth flamer a validated 2,000 point list actually fields and
            // permits three shield generators.
            //
            // On a squad the same entry means one *per model* — a Stealth
            // team's `max 1` fusion blaster is one each, and the unit takes
            // two — so it cannot be read as a unit total and the per-unit
            // statements are used instead.
            statedMax: (singleModel ? datasheet.wargearCaps[itemId] : null) ??
                _tighter(constrained[itemId]?.maxCount, budgeted[itemId]),
            perModels: constrained[itemId]?.perModels,
            replaces: constrained[itemId]?.replaces ?? const [],
          ),
    ];

    return UnitLoadout(
      fixed: fixed,
      groups: groups,
      counters: counters,
      capsAreExact: singleModel,
    );
  }
}
