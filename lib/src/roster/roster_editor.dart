/// Editing a roster (DESIGN.md §4, brief item 1).
///
/// Every operation returns a **new** [Roster]; nothing here mutates. That is
/// what makes undo, live validation and "show me the points before I commit"
/// all fall out of the same mechanism, and it matches how battle state already
/// works (§7.4).
///
/// **The editor is permissive and the validator is honest.** It will let you
/// build an illegal list and tell you exactly how it is illegal, rather than
/// refusing the tap. Two reasons, and the second is the real one:
///
///   - §2.3 already settled this for validation — findings with severity,
///     never a hard block.
///   - The wargear-option data is demonstrably incomplete. Six T'au datasheets
///     did not list the drones their units carry (§3.8), and about half of all
///     datasheets publish no options at all. An editor that enforced it would
///     refuse legal lists, and a builder that will not let you enter the army
///     standing on your table is worthless.
///
/// That still holds, but "permissive" is not the same as "shapeless", and it
/// was being read that way: every item was an independent counter, so the
/// editor offered to remove weapons no rule lets you remove and asked for
/// three separate numbers where the datasheet asks one question. [UnitLoadout]
/// sorts the published data by how far it can be trusted, and this class gains
/// the two edits that structure implies — [swapWargear] and
/// [selectLoadoutBundle]. Neither refuses an edit; both stop counts going
/// negative and leave the verdict to the validator (§4.5).
library;

import '../rules/battle_size.dart';
import '../source/source_models.dart';
import '../rules/catalogue.dart';
import 'roster.dart';
import 'unit_loadout.dart';

class RosterEditor {
  final Catalogue catalogue;

  const RosterEditor(this.catalogue);

  /// A new, empty roster. The battle size sets the points limit and the
  /// detachment budget, so it is asked for up front rather than inferred.
  static Roster blank({
    required String name,
    required String factionId,
    BattleSize battleSize = BattleSize.strikeForce,
  }) =>
      Roster(
        name: name,
        factionId: factionId,
        battleSizeId: battleSize.id,
        units: const [],
      );

  // ------------------------------------------------------------------ units

  /// Adds [datasheetId] at its smallest legal size with its default loadout.
  ///
  /// "Every weapon on the datasheet" would be the wrong starting point — a
  /// Crisis suit lists nine and carries three — so this reads the composition
  /// where one exists and adds a bare unit where it does not.
  Roster addUnit(Roster roster, String datasheetId) {
    final composition = catalogue.composition(datasheetId);
    final datasheet = catalogue.unit(datasheetId);

    final models = composition?.defaultModels ??
        datasheet?.points
            .map((b) => b.models)
            .where((m) => m > 0)
            .fold<int?>(null, (a, b) => a == null || b < a ? b : a) ??
        1;

    final wargear = composition?.defaultWargear() ?? const <String, int>{};

    return _withUnits(roster, [
      ...roster.units,
      RosterUnit(
        instanceId: _nextInstanceId(roster),
        datasheetId: datasheetId,
        models: models,
        wargear: [
          for (final entry in wargear.entries)
            WargearSelection(itemId: entry.key, count: entry.value),
        ],
      ),
    ]);
  }

  /// Removes a unit, and anything that only made sense while it was there:
  /// its attachment links, its enhancement, and the Warlord nomination.
  Roster removeUnit(Roster roster, String instanceId) {
    final units = [
      for (final u in roster.units)
        if (u.instanceId != instanceId) u,
    ];
    return roster.copyWith(
      units: units,
      links: [
        for (final link in roster.links)
          if (link.fromInstanceId != instanceId &&
              link.toInstanceId != instanceId)
            link,
      ],
      enhancements: [
        for (final e in roster.enhancements)
          if (e.targetInstanceId != instanceId) e,
      ],
      upgrades: [
        for (final u in roster.upgrades)
          if (u.targetInstanceIds.contains(instanceId))
            UpgradeSelection(
              upgradeId: u.upgradeId,
              targetInstanceIds: [
                for (final id in u.targetInstanceIds)
                  if (id != instanceId) id,
              ],
            )
          else
            u,
      ].where((u) => u.targetInstanceIds.isNotEmpty).toList(),
      clearWarlordIf: roster.warlordInstanceId == instanceId,
    );
  }

  /// Duplicates a unit, loadout and all. Lists are full of second Broadsides.
  Roster duplicateUnit(Roster roster, String instanceId) {
    final source = _unit(roster, instanceId);
    if (source == null) return roster;
    return _withUnits(roster, [
      ...roster.units,
      RosterUnit(
        instanceId: _nextInstanceId(roster),
        datasheetId: source.datasheetId,
        models: source.models,
        wargear: [
          for (final w in source.wargear)
            WargearSelection(itemId: w.itemId, count: w.count),
        ],
      ),
    ]);
  }

  /// The largest unit the published data supports, or null when nothing says.
  ///
  /// **Two sources, and the looser wins.** The composition names each model
  /// and how many the unit may field; the points table prices whole brackets.
  /// They disagree on 35 of 1,961 datasheets — Cadian Shock Troops compose to
  /// twenty and are priced to twenty-seven — and where they do, refusing the
  /// size the points table prices would be the builder telling a player their
  /// legal list is illegal, which is the failure §2.3 exists to avoid.
  ///
  /// Null is a real answer: with no evidence either way nothing is capped,
  /// because a cap invented from silence is the same mistake.
  int? maxModels(String datasheetId) {
    final composition = catalogue.composition(datasheetId);
    final unit = catalogue.unit(datasheetId);

    var cap = composition?.maxModels;
    for (final bracket in unit?.points ?? const <PointsBracket>[]) {
      final priced = bracket.modelsMax ?? bracket.models;
      if (priced > (cap ?? 0)) cap = priced;
    }
    if (cap == null || cap <= 0) return null;

    // Never below the unit's own smallest legal size.
    final floor = composition?.defaultModels ?? 1;
    return cap < floor ? floor : cap;
  }

  /// Resizes a unit, bringing its wargear with it.
  ///
  /// Adding models used to change nothing but the number: six Paragon Warsuits
  /// still carried three heavy bolters, because the guns were only ever set
  /// when the unit was created. Every added model arrives with what the
  /// datasheet gives it by default, and a removed one takes its share away.
  ///
  /// **Only the default kit scales.** Anything swapped in deliberately is left
  /// exactly as it is — a multi-melta bought for one model is one model's
  /// multi-melta, and doubling the unit does not double a choice the player
  /// made. The validator reports a loadout that no longer adds up (§2.3).
  Roster setModels(Roster roster, String instanceId, int models) {
    final unit = _unit(roster, instanceId);
    if (unit == null) return roster;
    // The datasheet's own ceiling, not a flat 30: a unit could be grown past
    // any legal size and then priced at zero, because no bracket covers it.
    final ceiling = maxModels(unit.datasheetId) ?? 30;
    final wanted = models.clamp(1, ceiling);
    final delta = wanted - unit.models;
    if (delta == 0) return roster;

    final composition = catalogue.composition(unit.datasheetId);
    final base = composition?.defaultModels ?? 0;
    if (composition == null || base <= 0) {
      return _mapUnit(roster, instanceId, (u) => u.copyWith(models: wanted));
    }

    // What one model brings, from the smallest legal unit.
    final perModel = <String, int>{};
    for (final entry in composition.defaultWargear().entries) {
      final share = entry.value ~/ base;
      if (share > 0) perModel[entry.key] = share;
    }

    return _mapUnit(roster, instanceId, (u) {
      final counts = {for (final w in u.wargear) w.itemId: w.count};
      for (final entry in perModel.entries) {
        final held = counts[entry.key] ?? 0;
        counts[entry.key] =
            (held + entry.value * delta).clamp(0, 1 << 20).toInt();
      }
      return u.copyWith(
        models: wanted,
        wargear: [
          for (final entry in counts.entries)
            if (entry.value > 0)
              WargearSelection(itemId: entry.key, count: entry.value),
        ],
      );
    });
  }

  /// Sets how many of [itemId] the unit carries. Zero removes it.
  Roster setWargear(
    Roster roster,
    String instanceId,
    String itemId,
    int count,
  ) =>
      _mapUnit(roster, instanceId, (unit) {
        final kept = [
          for (final w in unit.wargear)
            if (w.itemId != itemId) w,
        ];
        return unit.copyWith(wargear: [
          ...kept,
          if (count > 0) WargearSelection(itemId: itemId, count: count),
        ]);
      });

  /// Sets [itemId] to [count], giving back whatever it replaces.
  ///
  /// The data words most choices as a swap — *replace the plasma rifle with a
  /// missile pod* — and a roster that only ever counted upwards ended up
  /// carrying both, which is a unit with twice the guns it can field. Taking N
  /// of an item removes N of what it replaces, and putting it back restores
  /// them, so the pair behaves like the one decision it is (§4.5).
  ///
  /// The give-back is capped at what the unit actually has, so a swap can
  /// never drive a count negative, and it stops at zero rather than refusing
  /// the tap — the builder stays permissive and the validator reports an
  /// over-full loadout (§2.3).
  ///
  /// **A repeated entry means a quantity, not a second swap.** `replaces:
  /// [storm-bolter, storm-bolter]` is *two* storm bolters given up for one of
  /// this, and iterating the list applied the whole delta once per entry —
  /// taking one item removed two. 44 options across the game word it that way
  /// (§4.5).
  Roster swapWargear(
    Roster roster,
    String instanceId,
    String itemId,
    int count, {
    required Iterable<String> replaces,
  }) {
    final unit = _unit(roster, instanceId);
    if (unit == null) return roster;
    final before = unit.countOf(itemId);
    final delta = count - before;
    var next = setWargear(roster, instanceId, itemId, count);
    if (delta == 0 || replaces.isEmpty) return next;

    for (final entry in _multiplicity(replaces).entries) {
      final held = _unit(next, instanceId)?.countOf(entry.key) ?? 0;
      // Giving one up frees `entry.value` of the other; putting it back takes
      // that many again.
      final adjusted = (held - delta * entry.value).clamp(0, 1 << 30);
      if (adjusted != held) {
        next = setWargear(next, instanceId, entry.key, adjusted);
      }
    }
    return next;
  }

  /// How many of each item a list names, since it names one per copy.
  Map<String, int> _multiplicity(Iterable<String> items) {
    final out = <String, int>{};
    for (final item in items) {
      out[item] = (out[item] ?? 0) + 1;
    }
    return out;
  }

  /// Applies [copies] of one bundle from a [LoadoutGroup], clearing the
  /// group's other items so the selection stays mutually exclusive.
  ///
  /// **A bundle is what one model takes, and several models may take it.** A
  /// Seraphim Squad swaps a model's two bolt pistols for two hand flamers, and
  /// more than one model may do it — the group was yes-or-no, so a squad could
  /// only ever make one swap (§4.5). `copies` is how many models took it.
  ///
  /// Passing a null [bundle] or zero [copies] clears the group. A bundle
  /// listing an item twice means two of it, which is why this counts rather
  /// than sets a flag.
  Roster selectLoadoutBundle(
    Roster roster,
    String instanceId,
    LoadoutGroup group,
    List<String>? bundle, {
    int copies = 1,
  }) {
    var next = roster;
    final taking = bundle == null || bundle.isEmpty ? 0 : copies.clamp(0, 99);
    final wanted = _multiplicity(bundle ?? const <String>[]);

    // How many copies the unit already carries, whichever bundle they came
    // from. The group is mutually exclusive, so at most one bundle matches.
    final heldCopies = _copiesHeld(roster, instanceId, group);

    for (final item in group.items) {
      next = setWargear(next, instanceId, item, (wanted[item] ?? 0) * taking);
    }

    // **Taking a bundle gives up what it replaces.** `setWargear` alone only
    // counted upwards, so choosing a Paragon's multi-melta left the heavy
    // bolter it replaces still on the unit — a model with both guns.
    //
    // The give-up scales with the number of models that took it, and a
    // repeated entry in `replaces` is a quantity: `[bolt-pistol, bolt-pistol]`
    // is two pistols per model, not two separate swaps. Iterating the list
    // applied the whole change once per entry — two flamers arrived and four
    // pistols left.
    final change = taking - heldCopies;
    if (change == 0) return next;
    for (final entry in _multiplicity(group.replaces).entries) {
      if (group.items.contains(entry.key)) continue;
      final carried = _unit(next, instanceId)?.countOf(entry.key) ?? 0;
      final adjusted = (carried - change * entry.value).clamp(0, 1 << 30);
      if (adjusted != carried) {
        next = setWargear(next, instanceId, entry.key, adjusted);
      }
    }
    return next;
  }

  /// How many copies of any one bundle the unit carries, or zero.
  int _copiesHeld(Roster roster, String instanceId, LoadoutGroup group) {
    final unit = _unit(roster, instanceId);
    if (unit == null) return 0;
    for (final bundle in group.bundles) {
      final want = _multiplicity(bundle);
      if (want.isEmpty) continue;
      int? copies;
      var matches = true;
      for (final entry in want.entries) {
        final held = unit.countOf(entry.key);
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
      if (matches && copies != null && copies > 0) return copies;
    }
    return 0;
  }

  /// Restores the datasheet's default loadout, discarding what was chosen.
  Roster resetWargear(Roster roster, String instanceId) {
    final unit = _unit(roster, instanceId);
    final composition =
        unit == null ? null : catalogue.composition(unit.datasheetId);
    if (composition == null) return roster;
    return _mapUnit(roster, instanceId, (u) {
      // Scaled to the unit's current size, since the composition describes
      // its smallest legal form.
      final base = composition.defaultModels;
      final factor = base <= 0 ? 1 : (u.models / base);
      return u.copyWith(wargear: [
        for (final entry in composition.defaultWargear().entries)
          WargearSelection(
            itemId: entry.key,
            count: (entry.value * factor).round().clamp(1, 1 << 20),
          ),
      ]);
    });
  }

  // ------------------------------------------------------------ attachments

  /// Attaches a leader to a bodyguard, replacing any existing link on either.
  ///
  /// A character can lead one unit and a unit can be led by one character, so
  /// the old links go rather than accumulating into an illegal tangle the
  /// validator would then have to complain about.
  /// The attachment role of whichever character holds [instanceId]'s link, or
  /// null when nothing is attached in that role.
  String? _roleOf(Roster roster, String instanceId) => catalogue
      .unit(_unit(roster, instanceId)?.datasheetId ?? '')
      ?.attachmentRole;

  Roster attach(Roster roster, String leaderId, String bodyguardId) {
    if (leaderId == bodyguardId) return roster;
    // **A unit may take one Leader and one Support at once**, so an existing
    // attachment is only displaced by another in the same role. Dropping
    // every link on the bodyguard meant adding a Hospitaller silently
    // removed the Canoness already leading the squad.
    final role = _roleOf(roster, leaderId);
    return roster.copyWith(links: [
      for (final link in roster.links)
        if (link.type != LinkType.leads ||
            (link.fromInstanceId != leaderId &&
                !(link.toInstanceId == bodyguardId &&
                    _roleOf(roster, link.fromInstanceId) == role)))
          link,
      RosterLink(
        type: LinkType.leads,
        fromInstanceId: leaderId,
        toInstanceId: bodyguardId,
      ),
    ]);
  }

  Roster detach(Roster roster, String instanceId) => roster.copyWith(links: [
        for (final link in roster.links)
          if (link.type != LinkType.leads ||
              (link.fromInstanceId != instanceId &&
                  link.toInstanceId != instanceId))
            link,
      ]);

  /// Units [leaderId] may join: the data's own attachment rule, minus units
  /// already led by someone else.
  List<RosterUnit> eligibleBodyguards(Roster roster, String leaderId) {
    final leader = _unit(roster, leaderId);
    if (leader == null) return const [];
    final allowed = catalogue.eligibleBodyguards(leader.datasheetId).toSet();
    // Taken **in this role**: a squad with a Leader is still open to a
    // Support, and hiding it would make the second attachment impossible.
    final role = _roleOf(roster, leaderId);
    final ledAlready = {
      for (final link in roster.links)
        if (link.type == LinkType.leads &&
            link.fromInstanceId != leaderId &&
            _roleOf(roster, link.fromInstanceId) == role)
          link.toInstanceId,
    };
    return [
      for (final unit in roster.units)
        if (unit.instanceId != leaderId &&
            allowed.contains(unit.datasheetId) &&
            !ledAlready.contains(unit.instanceId))
          unit,
    ];
  }

  /// Characters that may lead [bodyguardId], and what each is doing now.
  ///
  /// The mirror of [eligibleBodyguards], and it deliberately does **not** hide
  /// characters that are busy. Attaching is one decision seen from two sides,
  /// and from this side the useful question is "who could lead this" — an
  /// answer that omitted the character currently leading something else would
  /// be hiding the most likely thing you meant to change. [attach] already
  /// drops a character's previous link, so choosing a busy one moves it.
  List<({RosterUnit leader, String? leadingInstanceId})> eligibleLeaders(
    Roster roster,
    String bodyguardId,
  ) {
    final bodyguard = _unit(roster, bodyguardId);
    if (bodyguard == null) return const [];
    final leadingNow = {
      for (final link in roster.links)
        if (link.type == LinkType.leads) link.fromInstanceId: link.toInstanceId,
    };
    return [
      for (final unit in roster.units)
        if (unit.instanceId != bodyguardId &&
            catalogue
                .eligibleBodyguards(unit.datasheetId)
                .contains(bodyguard.datasheetId))
          (leader: unit, leadingInstanceId: leadingNow[unit.instanceId]),
    ];
  }

  // ------------------------------------------------------------ army-level

  /// Nominates the Warlord, or clears it.
  ///
  /// **Refused for anything that is not a Character** (§4.5.1). The switch in
  /// the editor was already disabled on a Paragon Warsuit, but the rule lived
  /// only in the widget: an imported list, or a scanned one, could name a
  /// Vehicle as its Warlord and nothing on this side would notice. This is
  /// the second place the builder refuses rather than flags, and it qualifies
  /// for the same reason as the first — the keyword is on every datasheet
  /// that has it, so there is no missing data to be permissive about.
  Roster setWarlord(Roster roster, String? instanceId) {
    if (instanceId != null) {
      final unit = roster.unitByInstance(instanceId);
      final datasheet = unit == null ? null : catalogue.unit(unit.datasheetId);
      if (datasheet == null || !datasheet.isCharacter) return roster;
    }
    return roster.copyWith(
      warlordInstanceId: instanceId,
      clearWarlordIf: instanceId == null,
    );
  }

  Roster setName(Roster roster, String name) =>
      roster.copyWith(name: name.trim().isEmpty ? roster.name : name.trim());

  Roster setBattleSize(Roster roster, BattleSize size) =>
      roster.copyWith(battleSizeId: size.id);

  Roster setDisposition(Roster roster, String? disposition) =>
      roster.copyWith(declaredDisposition: disposition);

  Roster addDetachment(Roster roster, String detachmentId) {
    if (roster.detachments.any((d) => d.detachmentId == detachmentId)) {
      return roster;
    }
    return roster.copyWith(detachments: [
      ...roster.detachments,
      RosterDetachment(detachmentId: detachmentId),
    ]);
  }

  /// Removes a detachment, and the enhancements that came with it — an
  /// enhancement outliving its detachment is a points total that quietly
  /// stops adding up.
  Roster removeDetachment(Roster roster, String detachmentId) {
    final gone = catalogue.detachment(detachmentId)?.enhancementIds.toSet() ??
        const <String>{};
    return roster.copyWith(
      detachments: [
        for (final d in roster.detachments)
          if (d.detachmentId != detachmentId) d,
      ],
      enhancements: [
        for (final e in roster.enhancements)
          if (!gone.contains(e.enhancementId)) e,
      ],
      upgrades: [
        for (final u in roster.upgrades)
          if (!gone.contains(u.upgradeId)) u,
      ],
    );
  }

  // ----------------------------------------------------------- enhancements

  /// Puts [enhancementId] on a unit, or removes it when [instanceId] is null.
  /// One bearer per enhancement, so an existing assignment is replaced.
  Roster setEnhancement(
    Roster roster,
    String enhancementId,
    String? instanceId,
  ) =>
      roster.copyWith(enhancements: [
        for (final e in roster.enhancements)
          if (e.enhancementId != enhancementId) e,
        if (instanceId != null)
          EnhancementSelection(
            enhancementId: enhancementId,
            targetInstanceId: instanceId,
          ),
      ]);

  // --------------------------------------------------------------- helpers

  RosterUnit? _unit(Roster roster, String instanceId) {
    for (final unit in roster.units) {
      if (unit.instanceId == instanceId) return unit;
    }
    return null;
  }

  Roster _mapUnit(
    Roster roster,
    String instanceId,
    RosterUnit Function(RosterUnit) change,
  ) =>
      _withUnits(roster, [
        for (final unit in roster.units)
          if (unit.instanceId == instanceId) change(unit) else unit,
      ]);

  Roster _withUnits(Roster roster, List<RosterUnit> units) =>
      roster.copyWith(units: units);

  /// Instance ids are stable and never reused, so a link or an enhancement
  /// cannot silently re-target a different unit after a delete.
  String _nextInstanceId(Roster roster) {
    var highest = 0;
    for (final unit in roster.units) {
      final digits = RegExp(r'\d+').firstMatch(unit.instanceId)?.group(0);
      final n = int.tryParse(digits ?? '') ?? 0;
      if (n > highest) highest = n;
    }
    return 'u${(highest + 1).toString().padLeft(2, '0')}';
  }
}
