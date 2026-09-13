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
import 'roster.dart';
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


/// One weapon slot as the editor offers it (DESIGN.md §4.20).
class LoadoutSlot {
  /// `model|slot`, the key a unit records its choices under.
  final String key;
  final String model;
  final String name;

  /// What the model carries with nothing chosen.
  final List<String> defaultItems;

  /// Each alternative, as what choosing it puts on the model.
  final List<List<String>> choices;

  /// How many models the slot is on: one for a leader, up to the model count
  /// for a slot every squad member has.
  final int seats;

  const LoadoutSlot({
    required this.key,
    required this.model,
    required this.name,
    required this.defaultItems,
    required this.choices,
    this.seats = 1,
  });

  Set<String> get items => {...defaultItems, for (final c in choices) ...c};

  /// What choice [index] adds and gives up, net of what the default already
  /// holds. `Bolt Rifle w/ Grenade Launcher` over a bolt rifle adds a grenade
  /// launcher and gives up nothing.
  ({Map<String, int> adds, Map<String, int> removes}) delta(int index) {
    final add = _tally(choices[index]);
    final remove = _tally(defaultItems);
    for (final item in {...add.keys}) {
      final both = add[item]! < (remove[item] ?? 0) ? add[item]! : (remove[item] ?? 0);
      if (both == 0) continue;
      add[item] = add[item]! - both;
      remove[item] = remove[item]! - both;
    }
    add.removeWhere((_, n) => n <= 0);
    remove.removeWhere((_, n) => n <= 0);
    return (adds: add, removes: remove);
  }
}

/// A counted swap: up to [max] models trade [takes] for [gives].
class LoadoutSwap {
  final String model;
  final String name;
  final List<String> gives;
  final List<String> takes;
  final int? max;

  const LoadoutSwap({
    required this.model,
    required this.name,
    required this.gives,
    required this.takes,
    this.max,
  });
}

/// What each slot and swap currently holds, read from a unit.
class SlotReading {
  /// Per slot, the choice index taken by each model that swapped. Empty for a
  /// slot left at its default.
  final List<List<int>> slots;

  /// Per swap, how many models took it.
  final List<int> swaps;

  const SlotReading(this.slots, this.swaps);

  /// How many models in slot [slot] took choice [choice].
  int countOf(int slot, int choice) =>
      slots[slot].where((c) => c == choice).length;
}

Map<String, int> _tally(Iterable<String> items) {
  final out = <String, int>{};
  for (final item in items) {
    out[item] = (out[item] ?? 0) + 1;
  }
  return out;
}

bool _covers(Map<String, int> pool, Map<String, int> wanted) =>
    wanted.entries.every((e) => (pool[e.key] ?? 0) >= e.value);

void _take(Map<String, int> pool, Map<String, int> used) {
  for (final e in used.entries) {
    pool[e.key] = (pool[e.key] ?? 0) - e.value;
  }
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

  /// Weapon slots and counted swaps from BSData, when every item they name is
  /// one this datasheet has (§4.20). Items they cover are in neither [groups]
  /// nor [counters], so no weapon is offered by two controls at once.
  final List<LoadoutSlot> slots;
  final List<LoadoutSwap> swaps;

  const UnitLoadout({
    this.slots = const [],
    this.swaps = const [],
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
    // **BSData's slots, where the datasheet can use them** (§4.20). They are
    // taken only when every item they name is one this datasheet actually
    // has: 662 of 698 datasheets resolve completely, and a slot naming a gun
    // the unit cannot carry would be a worse control than the one it
    // replaces. The rest keep the options below, unchanged.
    final (slots, swaps) = _slotsFor(
      datasheet,
      catalogue: catalogue,
      vocabulary: vocabulary,
      options: options,
      composition: composition,
      defaults: defaults,
    );
    final covered = <String>{
      for (final slot in slots) ...slot.items,
      for (final swap in swaps) ...swap.gives,
      for (final swap in swaps) ...swap.takes,
    };

    final replaceable = <String>{
      for (final option in options) ...option.replaces,
      ...covered,
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
        // **A bundle naming a slot's item is the product 40kdc made of it.**
        // An Intercessor Sergeant's fifteen pairings are every bolt-rifle swap
        // times every close-combat-weapon swap; with the two slots offered,
        // the pairings are the same choices twice, and a second control over
        // the same guns is what made the rows change together.
        final bundles = [
          for (final bundle in option.bundles)
            if (!bundle.any(covered.contains)) bundle,
        ];
        if (bundles.isEmpty) continue;
        groups.add(LoadoutGroup(
          optionId: option.id,
          bundles: bundles,
          replaces: option.replaces,
          modelName: option.modelName,
        ));
        continue;
      }
      if (option.offered.every(covered.contains)) continue;
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
        if (!fixed.containsKey(itemId) &&
            !grouped.contains(itemId) &&
            !covered.contains(itemId))
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
      slots: slots,
      swaps: swaps,
      fixed: fixed,
      groups: groups,
      counters: counters,
      capsAreExact: singleModel,
    );
  }

  static String _fold(String name) => name
      .toLowerCase()
      .replaceAll(RegExp(r'[^a-z0-9 ]'), '')
      .split(RegExp(r'\s+'))
      .map((w) => w.length > 3 && w.endsWith('s') ? w.substring(0, w.length - 1) : w)
      .join(' ');

  static (List<LoadoutSlot>, List<LoadoutSwap>) _slotsFor(
    SourceUnit datasheet, {
    required Catalogue catalogue,
    required Iterable<String> vocabulary,
    required List<SourceWargearOption> options,
    required UnitComposition? composition,
    required Map<String, int> defaults,
  }) {
    final published = catalogue.wargearSlots(datasheet.id);
    if (published == null) return (const [], const []);
    final unscope = datasheet.unscope;

    final known = <String>{
      for (final item in vocabulary) unscope(item),
      ...defaults.keys,
      for (final option in options) ...option.offered,
      for (final option in options) ...option.replaces,
    };
    bool isKnown(String item) =>
        known.contains(item) ||
        catalogue.weapon(item) != null ||
        catalogue.weapon('$item-${datasheet.id}') != null ||
        catalogue.ability(item) != null;

    final raw = [for (final slot in published.slots) slot.mapIds(unscope)];
    final rawSwaps = [for (final swap in published.swaps) swap.mapIds(unscope)];
    final named = {
      for (final slot in raw) ...slot.items,
      for (final swap in rawSwaps) ...swap.gives,
      for (final swap in rawSwaps) ...swap.takes,
    };
    if (!named.every(isKnown)) return (const [], const []);

    // A slot BSData leaves without a default takes the one choice the model
    // already carries. The Vanguard trooper's `Pistol Option` names a default
    // id matching none of its own entries, which put the bolt pistol among
    // the replacements for itself.
    List<String> modelDefaults(String model) {
      final wanted = _fold(model);
      for (final m in composition?.models ?? const <CompositionModel>[]) {
        if (_fold(m.name) == wanted) {
          return [for (final w in m.defaultWeaponIds) unscope(w)];
        }
      }
      return defaults.keys.toList();
    }

    final slots = <LoadoutSlot>[];
    final seenKeys = <String>{};
    for (final slot in raw) {
      var defaultItems = slot.defaultItems;
      var choices = slot.choices;
      if (defaultItems.isEmpty) {
        final carried = modelDefaults(slot.model).toSet();
        final matching = [
          for (final c in choices)
            if (c.isNotEmpty && c.every(carried.contains)) c,
        ];
        if (matching.length == 1) {
          defaultItems = matching.single;
          choices = [
            for (final c in choices)
              if (!identical(c, matching.single)) c,
          ];
        }
      }
      final key = '${slot.model}|${slot.name}';
      if (choices.isEmpty || !seenKeys.add(key)) continue;
      slots.add(LoadoutSlot(
        key: key,
        model: slot.model,
        name: slot.name,
        defaultItems: defaultItems,
        choices: choices,
        seats: slot.perModels < 1 ? 1 : slot.perModels,
      ));
    }
    // A leader's own slots are read before the squad's, since a swap the
    // counts cannot place is far likelier to be the one model's than one of
    // nine.
    final ordered = [
      ...slots.where((s) => s.seats == 1),
      ...slots.where((s) => s.seats > 1),
    ];

    return (
      ordered,
      [
        for (final swap in rawSwaps)
          if (swap.gives.isNotEmpty)
            LoadoutSwap(
              model: swap.model,
              name: swap.name,
              gives: swap.gives,
              takes: swap.takes,
              max: swap.max,
            ),
      ],
    );
  }

  /// The default loadout at [models], scaled the way "Default loadout" scales
  /// it.
  static Map<String, int> defaultsAt(UnitComposition? composition, int models) {
    if (composition == null) return const {};
    final base = composition.defaultModels;
    final factor = base <= 0 ? 1 : models / base;
    return {
      for (final entry in composition.defaultWargear().entries)
        entry.key: (entry.value * factor).round().clamp(1, 1 << 20).toInt(),
    };
  }

  /// What each slot and swap holds on [unit].
  ///
  /// **Read as departures from the default loadout, not from raw counts.** An
  /// Intercessor Sergeant who takes a chainsword in `Weapon 1` still carries
  /// the squad's bolt rifles, so "is a bolt rifle present" says nothing about
  /// his slot. What his choice leaves behind is one bolt rifle *fewer than
  /// the default* and one chainsword more, and that is what is matched.
  ///
  /// The unit's recorded choices are used when they account for the counts,
  /// and derived from the counts when they do not — an imported list, or one
  /// saved before slots existed, has none.
  SlotReading read(RosterUnit unit, UnitComposition? composition) {
    final defaults = defaultsAt(composition, unit.models);
    final carried = {for (final w in unit.wargear) w.itemId: w.count};

    Map<String, int> positive(Map<String, int> a, Map<String, int> b) => {
          for (final item in {...a.keys, ...b.keys})
            if ((a[item] ?? 0) - (b[item] ?? 0) > 0)
              item: (a[item] ?? 0) - (b[item] ?? 0),
        };

    var extra = positive(carried, defaults);
    var missing = positive(defaults, carried);
    var taken = [for (final _ in slots) <int>[]];

    // The record first, all or nothing: a record that explains only part of
    // the counts has been overtaken by an edit outside the slots.
    var recordHolds = true;
    for (final (index, slot) in slots.indexed) {
      for (final choice in unit.slotChoices[slot.key] ?? const <int>[]) {
        if (choice < 0 || choice >= slot.choices.length) {
          recordHolds = false;
          break;
        }
        final d = slot.delta(choice);
        if (!_covers(extra, d.adds) || !_covers(missing, d.removes)) {
          recordHolds = false;
          break;
        }
        _take(extra, d.adds);
        _take(missing, d.removes);
        taken[index].add(choice);
      }
      if (!recordHolds) break;
    }
    if (!recordHolds) {
      extra = positive(carried, defaults);
      missing = positive(defaults, carried);
      taken = [for (final _ in slots) <int>[]];
    }

    // **A record is the whole answer for the slots, or none of it.** Once a
    // unit has been edited through its slots, a slot the record leaves out is
    // at its default — it is not a gap to fill from the counts. Filling it let
    // a Raptor Champion's pistol slot claim one of three plasma pistols the
    // squad took as a counted swap, because the two changes look identical.
    final derive = !recordHolds || unit.slotChoices.isEmpty;
    for (final (index, slot) in slots.indexed) {
      if (!derive) break;
      while (taken[index].length < slot.seats) {
        int? found;
        for (var choice = 0; choice < slot.choices.length; choice++) {
          final d = slot.delta(choice);
          if (d.adds.isEmpty && d.removes.isEmpty) continue;
          if (_covers(extra, d.adds) && _covers(missing, d.removes)) {
            found = choice;
            _take(extra, d.adds);
            _take(missing, d.removes);
            break;
          }
        }
        if (found == null) break;
        taken[index].add(found);
      }
    }

    final swapCounts = <int>[];
    for (final swap in swaps) {
      final adds = _tally(swap.gives);
      final removes = _tally(swap.takes);
      var n = 0;
      while ((swap.max == null || n < swap.max!) &&
          _covers(extra, adds) &&
          _covers(missing, removes)) {
        _take(extra, adds);
        _take(missing, removes);
        n++;
      }
      swapCounts.add(n);
    }
    return SlotReading(taken, swapCounts);
  }
}
