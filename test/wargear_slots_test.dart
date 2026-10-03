import 'dart:convert';
import 'dart:io';

import 'package:test/test.dart';
import 'package:wh40k_core/wh40k_core.dart';

import 'support.dart';

/// Weapon slots and counted swaps from BSData (DESIGN.md §4.20).
///
/// The bug these exist for: an Intercessor Sergeant was offered two selectors
/// for the same model, and a Vanguard Veteran's weapon choice showed up on the
/// Sergeant's row as well — both because 40kdc multiplies independent swaps
/// into combined bundles, and because every row read the same weapon counts.
void main() {
  final root = Directory(snapshotDir.path);
  final skip = root.existsSync() ? null : 'no snapshot';

  late MapCatalogue astartes;
  late MapCatalogue chaos;
  late MapCatalogue sororitas;
  late MapCatalogue votann;
  setUpAll(() {
    if (!root.existsSync()) return;
    final loader = correctedLoader();
    astartes = MapCatalogue.ofFaction(loader.loadFaction('adeptus-astartes'));
    chaos = MapCatalogue.ofFaction(loader.loadFaction('chaos-space-marines'));
    sororitas = MapCatalogue.ofFaction(loader.loadFaction('adepta-sororitas'));
    votann = MapCatalogue.ofFaction(loader.loadFaction('leagues-of-votann'));
  });

  UnitLoadout loadoutOf(Catalogue catalogue, String id) {
    final sheet = catalogue.unit(id)!;
    return UnitLoadout.forDatasheet(sheet,
        catalogue: catalogue, vocabulary: sheet.wargearVocabulary);
  }

  (Roster, RosterEditor, String) armyWith(Catalogue catalogue, String faction, String id) {
    final editor = RosterEditor(catalogue);
    final roster = editor.addUnit(
        RosterEditor.blank(name: 't', factionId: faction), id);
    return (roster, editor, roster.units.single.instanceId);
  }

  int slotNamed(UnitLoadout loadout, String model, String name) => loadout.slots
      .indexWhere((s) => s.model == model && s.name == name);

  group('the Intercessor Sergeant', () {
    test('has one slot per weapon, and no selector built from both', () {
      if (!root.existsSync()) return;
      final loadout = loadoutOf(astartes, 'intercessor-squad');
      final sergeant =
          loadout.slots.where((s) => s.model == 'Intercessor Sergeant').toList();

      expect(sergeant.map((s) => s.name), ['Weapon 1', 'Weapon 2']);
      expect(sergeant[0].defaultItems, ['bolt-rifle']);
      expect(sergeant[1].defaultItems, ['close-combat-weapon']);

      // The fifteen pairings, and any other control over the slots' guns.
      final covered = {for (final s in loadout.slots) ...s.items};
      for (final group in loadout.groups) {
        expect(group.items.intersection(covered), isEmpty,
            reason: 'a group still offers a slot\'s weapon: ${group.optionId}');
      }
      for (final counter in loadout.counters) {
        expect(covered, isNot(contains(counter.itemId)));
      }
    }, skip: skip);

    test('two slots offering the same weapons keep their own choices', () {
      if (!root.existsSync()) return;
      // Both slots offer a power weapon and a chainsword. Read from counts
      // alone, which slot holds which is exactly what could swap over.
      final loadout = loadoutOf(astartes, 'intercessor-squad');
      final w1 = slotNamed(loadout, 'Intercessor Sergeant', 'Weapon 1');
      final w2 = slotNamed(loadout, 'Intercessor Sergeant', 'Weapon 2');
      int choice(int slot, String item) =>
          loadout.slots[slot].choices.indexWhere((c) => c.length == 1 && c.single == item);

      var (roster, editor, id) = armyWith(astartes, 'adeptus-astartes', 'intercessor-squad');
      final before = {for (final w in roster.units.single.wargear) w.itemId: w.count};
      roster = editor.chooseInSlot(roster, id, loadout, w1, [choice(w1, 'power-weapon')]);
      roster = editor.chooseInSlot(roster, id, loadout, w2, [choice(w2, 'astartes-chainsword')]);

      final unit = roster.units.single;
      final reading = loadout.read(unit, astartes.composition('intercessor-squad'));
      expect(loadout.slots[w1].choices[reading.slots[w1].single], ['power-weapon']);
      expect(loadout.slots[w2].choices[reading.slots[w2].single], ['astartes-chainsword']);

      // And the counts moved by exactly the two swaps.
      expect(unit.countOf('bolt-rifle'), before['bolt-rifle']! - 1);
      expect(unit.countOf('close-combat-weapon'), before['close-combat-weapon']! - 1);
      expect(unit.countOf('power-weapon'), 1);
      expect(unit.countOf('astartes-chainsword'), 1);
    }, skip: skip);

    test('a grenade launcher is a counted swap, capped as printed', () {
      if (!root.existsSync()) return;
      final loadout = loadoutOf(astartes, 'intercessor-squad');
      final index = loadout.swaps.indexWhere((s) => s.gives.contains('astartes-grenade-launcher'));
      expect(index, isNot(-1));
      expect(loadout.swaps[index].max, 2);
    }, skip: skip);
  });

  // Both of these were Vanguard Veterans with Jump Packs until the codex
  // (§3.42): BSData's slots for that squad are the index's, so they are no
  // longer read, and the behaviour is tested where BSData is current.
  group('slots shared and undefaulted', () {
    test('a trooper\'s choice stays on the trooper, not the Sergeant', () {
      if (!root.existsSync()) return;
      // The reported bug: a squad whose leader and troopers have a slot of
      // the same name. A Paragon Warsuit squad has three.
      const id = 'paragon-warsuits';
      const name = 'Paragon Melee Weapon';
      final loadout = loadoutOf(sororitas, id);
      final troopers = loadout.slots.indexWhere((s) => s.seats > 1 && s.name == name);
      final leader = loadout.slots.indexWhere((s) => s.seats == 1 && s.name == name);
      expect(troopers, isNot(-1));
      expect(leader, isNot(-1));

      var (roster, editor, unitId) = armyWith(sororitas, 'adepta-sororitas', id);
      roster = editor.chooseInSlot(roster, unitId, loadout, troopers, [0]);

      final reading = loadout.read(roster.units.single, sororitas.composition(id));
      expect(reading.slots[troopers], [0]);
      expect(reading.slots[leader], isEmpty,
          reason: 'the trooper\'s weapon was shown on the leader\'s slot');
    }, skip: skip);

    test('a slot BSData leaves undefaulted takes the weapon the model carries', () {
      if (!root.existsSync()) return;
      final loadout = loadoutOf(votann, 'cthonian-earthshakers');
      final main = loadout.slots.firstWhere((s) => s.name == 'Main weapon');
      expect(main.defaultItems, ['breacher-ordnance']);
      expect(main.choices, isNot(contains(['breacher-ordnance'])),
          reason: 'offered its own weapon in place of itself');
    }, skip: skip);

    test('a codex datasheet does not take the index\'s slots', () {
      if (!root.existsSync()) return;
      // 40kdc's codex Vanguard Veteran carries no bolt pistol; BSData's slots
      // start the squad with one. The slots are dropped at merge (§3.42).
      expect(astartes.wargearSlots('vanguard-veteran-squad-with-jump-packs'),
          isNull);
      // And a datasheet whose slots the codex agrees with keeps them.
      expect(astartes.wargearSlots('intercessor-squad'), isNotNull);
    }, skip: skip);
  });

  group('Raptors', () {
    test('a counted swap moves the counts and stops at its maximum', () {
      if (!root.existsSync()) return;
      final loadout = loadoutOf(chaos, 'raptors');
      final index = loadout.swaps.indexWhere((s) => s.gives.contains('plasma-pistol'));
      var (roster, editor, id) = armyWith(chaos, 'chaos-space-marines', 'raptors');
      roster = editor.setModels(roster, id, 10);
      final pistols = roster.units.single.countOf('bolt-pistol');

      roster = editor.setSwapCount(roster, id, loadout, index, 3);
      expect(roster.units.single.countOf('plasma-pistol'), 3);
      expect(roster.units.single.countOf('bolt-pistol'), pistols - 3);
      expect(loadout.read(roster.units.single, chaos.composition('raptors')).swaps[index], 3);

      roster = editor.setSwapCount(roster, id, loadout, index, 9);
      expect(roster.units.single.countOf('plasma-pistol'), 4, reason: 'printed as up to four');
    }, skip: skip);
  });

  group('reading a unit with no record', () {
    test('an imported list is read from its counts', () {
      if (!root.existsSync()) return;
      // A text import or a list saved before slots existed carries counts and
      // nothing else.
      final loadout = loadoutOf(astartes, 'intercessor-squad');
      final w1 = slotNamed(loadout, 'Intercessor Sergeant', 'Weapon 1');
      var (roster, editor, id) = armyWith(astartes, 'adeptus-astartes', 'intercessor-squad');
      final rifles = roster.units.single.countOf('bolt-rifle');
      roster = editor.setWargear(roster, id, 'bolt-rifle', rifles - 1);
      roster = editor.setWargear(roster, id, 'hand-flamer', 1);

      final reading = loadout.read(roster.units.single, astartes.composition('intercessor-squad'));
      expect(loadout.slots[w1].choices[reading.slots[w1].single], ['hand-flamer']);
    }, skip: skip);

    test('and a record the counts no longer support is ignored', () {
      if (!root.existsSync()) return;
      final loadout = loadoutOf(astartes, 'intercessor-squad');
      final w1 = slotNamed(loadout, 'Intercessor Sergeant', 'Weapon 1');
      final flamer = loadout.slots[w1].choices.indexWhere((c) => c.join() == 'hand-flamer');
      var (roster, editor, id) = armyWith(astartes, 'adeptus-astartes', 'intercessor-squad');
      roster = editor.chooseInSlot(roster, id, loadout, w1, [flamer]);
      // Edited outside the slot: the flamer taken away by hand.
      roster = editor.setWargear(roster, id, 'hand-flamer', 0);

      final reading = loadout.read(roster.units.single, astartes.composition('intercessor-squad'));
      expect(reading.slots[w1], isEmpty);
    }, skip: skip);
  });

  test('the default loadout forgets every choice', () {
    if (!root.existsSync()) return;
    final loadout = loadoutOf(astartes, 'intercessor-squad');
    var (roster, editor, id) = armyWith(astartes, 'adeptus-astartes', 'intercessor-squad');
    roster = editor.chooseInSlot(roster, id, loadout, 0, [0]);
    expect(roster.units.single.slotChoices, isNotEmpty);
    roster = editor.resetWargear(roster, id);
    expect(roster.units.single.slotChoices, isEmpty);
  }, skip: skip);

  test('a recorded choice survives saving', () {
    const unit = RosterUnit(
      instanceId: 'u',
      datasheetId: 'intercessor-squad',
      models: 5,
      slotChoices: {'Intercessor Sergeant|Weapon 1': [2]},
    );
    final back = RosterUnit.fromJson(jsonDecode(jsonEncode(unit.toJson())));
    expect(back.slotChoices, {'Intercessor Sergeant|Weapon 1': [2]});
    // And a unit saved before it existed reads as having no record.
    expect(RosterUnit.fromJson({'instanceId': 'u', 'datasheetId': 'x', 'models': 1}).slotChoices,
        isEmpty);
  });
}
