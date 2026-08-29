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

    final group = loadout.groups.single;
    expect(group.replaces, ['zealots-vindictor']);
    // Unscoped: `power-weapon-ministorum-priest` is this datasheet's name
    // for the plain `power-weapon` the roster speaks in.
    expect(group.bundles, [
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

    // Two disintegrator cannons replace the splinter cannon — a count a set
    // of offered items could not express at all.
    final group = loadout.groups.firstWhere(
        (g) => g.bundles.any((b) => b.length > 1 && b.toSet().length == 1));
    expect(
        group.bundles.single, ['disintegrator-cannon', 'disintegrator-cannon']);
  }, skip: skip);

  test('a single-item replacement is still a plain counter', () {
    if (!root.existsSync()) return;
    final catalogue = MapCatalogue.ofFaction(loader.loadFaction('tau-empire'));
    final loadout = loadoutOf(catalogue, 'stealth-battlesuits');

    // One fusion blaster for one burst cannon: nothing about it is a bundle.
    expect(loadout.counters.map((c) => c.itemId), contains('fusion-blaster'));
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

    roster = editor.selectLoadoutBundle(
      roster,
      instanceId,
      loadout.groups.single,
      loadout.groups.single.bundles.single,
    );

    final carried = {
      for (final item in roster.units.single.wargear) item.itemId: item.count,
    };
    expect(carried['holy-pistol'], 1);
    expect(carried['power-weapon'], 1);
    expect(carried['zealots-vindictor'] ?? 0, 0);
  }, skip: skip);
}
