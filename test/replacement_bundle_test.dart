import 'dart:io';

import 'package:test/test.dart';
import 'package:wh40k_core/wh40k_core.dart';
import 'package:wh40k_core/src/roster/unit_loadout.dart';

import 'support.dart';

/// A replacement naming two items is one swap, not two offers.
///
/// The Ministorum Priest's Zealot's vindictor is replaced with a holy pistol
/// **and** a power weapon. Read as two independent items, the editor offered
/// them as a choice between the two and let a list take one — which no
/// datasheet allows, on 83 datasheets across 20 factions.
void main() {
  final root = Directory(snapshotDir.path);
  final skip = root.existsSync() ? null : 'no snapshot';
  final loader = DatasetLoader(snapshotDir.path,
      corrections: DatasetLoader.correctionsAt(correctionsPath));

  UnitLoadout loadoutOf(Catalogue catalogue, String datasheetId) {
    final sheet = catalogue.unit(datasheetId)!;
    return UnitLoadout.forDatasheet(sheet,
        catalogue: catalogue, vocabulary: sheet.wargearVocabulary);
  }

  test('both weapons arrive together, or neither does', () {
    if (!root.existsSync()) return;
    final catalogue =
        MapCatalogue.ofFaction(loader.loadFaction('adepta-sororitas'));
    final loadout = loadoutOf(catalogue, 'ministorum-priest');

    // A slot since §4.20: BSData's `Wargear` group on the Priest, whose one
    // alternative to the vindictor is both weapons at once.
    final slot = loadout.slots.single;
    expect(slot.defaultItems, ['zealots-vindictor']);
    // Unscoped: `power-weapon-ministorum-priest` is this datasheet's name
    // for the plain `power-weapon` the roster speaks in.
    expect(slot.choices, [
      ['holy-pistol', 'power-weapon'],
    ]);

    // And neither weapon is separately buyable.
    expect(
        loadout.counters.map((c) => c.itemId), isNot(contains('holy-pistol')));
    expect(
        loadout.counters.map((c) => c.itemId), isNot(contains('power-weapon')));
  }, skip: skip);

  test('a bundle repeating an item means two of it', () {
    if (!root.existsSync()) return;
    final catalogue = MapCatalogue.ofFaction(loader.loadFaction('drukhari'));
    final loadout = loadoutOf(catalogue, 'razorwing-jetfighter');

    // Two disintegrator cannons replace the two dark lances — a count a set
    // of offered items could not express at all. As printed; 40kdc had them
    // replacing the splinter cannon, and BSData states the two as the
    // quantity on the weapon inside each choice (§4.20).
    final slot = loadout.slots.firstWhere((s) => s.name == 'Main Weapon');
    expect(slot.defaultItems, ['dark-lance', 'dark-lance']);
    expect(slot.choices.single, ['disintegrator-cannon', 'disintegrator-cannon']);
  }, skip: skip);

  test('a single-item replacement is still a plain counter', () {
    if (!root.existsSync()) return;
    final catalogue = MapCatalogue.ofFaction(loader.loadFaction('tau-empire'));
    final loadout = loadoutOf(catalogue, 'stealth-battlesuits');

    // One fusion blaster for one burst cannon: nothing about it is a bundle.
    // It arrives as a slot on the Shas'vre and a counted swap on the Shas'ui
    // (§4.20), each of which trades exactly one gun for one gun.
    final swap = loadout.swaps
        .singleWhere((w) => w.gives.contains('fusion-blaster'));
    expect(swap.gives, ['fusion-blaster']);
    expect(swap.takes, ['burst-cannon']);
    expect(loadout.groups.expand((g) => g.items), isNot(contains('fusion-blaster')));
  }, skip: skip);

  test('taking the bundle puts both on the unit and takes the old one off', () {
    if (!root.existsSync()) return;
    final catalogue =
        MapCatalogue.ofFaction(loader.loadFaction('adepta-sororitas'));
    final editor = RosterEditor(catalogue);
    var roster = editor.addUnit(
      RosterEditor.blank(name: 'p', factionId: 'adepta-sororitas'),
      'ministorum-priest',
    );
    final instanceId = roster.units.single.instanceId;
    final loadout = loadoutOf(catalogue, 'ministorum-priest');

    roster = editor.chooseInSlot(roster, instanceId, loadout, 0, [0]);

    final carried = {
      for (final item in roster.units.single.wargear) item.itemId: item.count,
    };
    expect(carried['holy-pistol'], 1);
    expect(carried['power-weapon'], 1);
    expect(carried['zealots-vindictor'] ?? 0, 0);
  }, skip: skip);
}
