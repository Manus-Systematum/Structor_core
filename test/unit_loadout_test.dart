import 'package:test/test.dart';
import 'package:wh40k_core/wh40k_core.dart';

import 'support.dart';

void main() {
  final available = snapshotAvailable;

  Dataset load(String faction) =>
      Dataset.of(correctedLoader().loadFaction(faction), revision: 'test');

  UnitLoadout loadoutFor(Dataset dataset, String datasheetId) {
    final datasheet = dataset.unit(datasheetId)!;
    final vocabulary = <String>{
      for (final weaponId in datasheet.weaponIds)
        weaponId.endsWith('-$datasheetId')
            ? weaponId.substring(0, weaponId.length - datasheetId.length - 1)
            : weaponId,
      for (final budget in datasheet.wargearBudgets) ...budget.items,
    };
    return UnitLoadout.forDatasheet(
      datasheet,
      catalogue: dataset,
      vocabulary: vocabulary,
    );
  }

  group('wargear options are read at all', () {
    test('the file is parsed and reaches the catalogue', () {
      // It shipped from the first fetch and nothing ever looked at it.
      final dataset = load('tau-empire');
      expect(
          dataset.wargearOptions('crisis-fireknife-battlesuits'), isNotEmpty);
      expect(dataset.faction.wargearOptions, isNotEmpty);
    }, skip: available ? null : 'no snapshot');
  });

  group('fixed kit', () {
    test('a default weapon no option can replace is fixed', () {
      // Battlesuit Fists are in every Crisis model's default loadout and no
      // published option takes them away, so there is no legal list without
      // them and the editor should not offer to remove them.
      final loadout =
          loadoutFor(load('tau-empire'), 'crisis-fireknife-battlesuits');
      expect(loadout.fixed.keys, contains('battlesuit-fists'));
      expect(loadout.isFixed('battlesuit-fists'), isTrue);
    }, skip: available ? null : 'no snapshot');

    test('a weapon an option can replace is not fixed', () {
      final loadout =
          loadoutFor(load('tau-empire'), 'crisis-fireknife-battlesuits');
      expect(loadout.fixed.keys, isNot(contains('plasma-rifle')));
      expect(loadout.fixed.keys, isNot(contains('missile-pod')));
    }, skip: available ? null : 'no snapshot');

    test('a datasheet publishing no options is fixed, not open', () {
      // **Reversed** (§4.5). The old rule left everything open, reasoning
      // that absence of data is not evidence of a restriction. That is true
      // and it still produced the worse wrong: the editor put a `+` beside
      // every weapon of a character who has no choices at all, which asserts
      // a rule the data never had just as much as locking does — and asserts
      // one that does not exist in the game either.
      final loadout =
          loadoutFor(load('adeptus-astartes'), 'ballistus-dreadnought');
      expect(load('adeptus-astartes').wargearOptions('ballistus-dreadnought'),
          isEmpty);
      expect(loadout.fixed, isNotEmpty);
      for (final weapon in const [
        'ballistus-lascannon',
        'ballistus-missile-launcher',
        'twin-storm-bolter',
      ]) {
        expect(loadout.fixed.keys, contains(weapon));
        expect(loadout.counters.map((c) => c.itemId), isNot(contains(weapon)),
            reason: 'no + beside a weapon nothing offers to change');
      }
      expect(loadout.isUnpublished, isTrue,
          reason: 'the screen still says why the numbers do not move');
    }, skip: available ? null : 'no snapshot');

    test('a character with no options cannot be given a second relic', () {
      // The bug this fixes: Morvenn Vahl publishes no wargear options and
      // carries three weapons she always has. Every one had a `+`.
      final sisters = load('adepta-sororitas');
      final loadout = loadoutFor(sisters, 'morvenn-vahl');
      expect(sisters.wargearOptions('morvenn-vahl'), isEmpty);
      expect(loadout.counters, isEmpty);
      expect(loadout.fixed.keys, contains('lance-of-illumination'));
    }, skip: available ? null : 'no snapshot');
  });

  group('groups are the datasheet spelling out whole selections', () {
    test("the Stealth team's drones are one choice, not three counters", () {
      final loadout = loadoutFor(load('tau-empire'), 'stealth-battlesuits');
      final group =
          loadout.groups.singleWhere((g) => g.items.contains('gun-drone'));

      // Up to two drones, of different kinds: one gun, one marker, or one of
      // each. Never two of the same.
      expect(
        group.bundles.map((b) => b.toSet()),
        containsAll([
          {'gun-drone'},
          {'marker-drone'},
          {'marker-drone', 'gun-drone'},
        ]),
      );
      for (final bundle in group.bundles) {
        expect(bundle.length, bundle.toSet().length,
            reason: 'no drone bundle doubles up');
      }
    }, skip: available ? null : 'no snapshot');

    test('items in a group are not also offered as loose counters', () {
      final loadout = loadoutFor(load('tau-empire'), 'stealth-battlesuits');
      final grouped = {for (final g in loadout.groups) ...g.items};
      expect(grouped, isNotEmpty);
      for (final counter in loadout.counters) {
        expect(grouped, isNot(contains(counter.itemId)));
      }
    }, skip: available ? null : 'no snapshot');

    test('the carried selection is matched back to its bundle', () {
      final loadout = loadoutFor(load('tau-empire'), 'stealth-battlesuits');
      final group =
          loadout.groups.singleWhere((g) => g.items.contains('gun-drone'));
      final both = group.bundles.indexWhere((b) => b.length == 2);

      expect(group.selectedIndex({'gun-drone': 1, 'marker-drone': 1}), both);
      expect(group.selectedIndex(const {}), isNull);

      // Two of one bundle is two models taking it, not an off-menu
      // combination — several models may make the same swap (§4.5).
      final single = group.bundles
          .indexWhere((b) => b.length == 1 && b.single == 'gun-drone');
      expect(group.selection({'gun-drone': 2}), (index: single, copies: 2));

      // A combination that is not a whole number of any one bundle still
      // reads as off-menu rather than being matched to the nearest thing.
      expect(group.selection({'gun-drone': 2, 'marker-drone': 1}), isNull);
    }, skip: available ? null : 'no snapshot');

    test('a bare cap on single items is not treated as an enumeration', () {
      // The Coldstar's ten weapons under `max_count: 3` are ten independent
      // items, not ten alternatives.
      final loadout =
          loadoutFor(load('tau-empire'), 'commander-in-coldstar-battlesuit');
      for (final group in loadout.groups) {
        expect(group.bundles.any((b) => b.length > 1), isTrue);
      }
    }, skip: available ? null : 'no snapshot');
  });

  group('a stated cap is information, not a gate', () {
    test('the reference list itself exceeds one', () {
      // Four T'au flamers on a Commander whose record caps them at three, in a
      // validated 2,000 point export. A cap that refused the tap would refuse
      // this army.
      final dataset = load('tau-empire');
      final capped = dataset
          .wargearOptions('commander-in-coldstar-battlesuit')
          .where((o) => o.maxCount != null);
      expect(capped, isNotEmpty);
      expect(capped.map((o) => o.maxCount), everyElement(lessThan(4)));
    }, skip: available ? null : 'no snapshot');

    test('the cap is carried on the counter for the editor to show', () {
      final loadout = loadoutFor(load('tau-empire'), 'stealth-battlesuits');
      final fusion =
          loadout.counters.singleWhere((c) => c.itemId == 'fusion-blaster');
      expect(fusion.statedMax, 2);
      expect(fusion.replaces, contains('burst-cannon'));
    }, skip: available ? null : 'no snapshot');
  });
  group('what the builder offers is equipment, not rules', () {
    test('a weapon rule never becomes a wargear line', () {
      // `Precise` is one of seven entries in the game system's Crusade
      // "Weapon Modifications" group. Six carry no ability profile and were
      // dropped by accident; `Precise` carries one, so it alone arrived as a
      // buyable line with a `+` beside it on 1,113 datasheets across 29
      // factions — rendered as "Precise" because an unresolved id falls back
      // to its own slug and reads like a plausible piece of kit.
      //
      // `Lethal Hits` came the other way, as a rule hanging off a weapon
      // entry: BSData models weapons as `upgrade` entries, the same shape a
      // wargear choice has. 304 of those.
      final loader = correctedLoader();
      final offenders = <String>[];
      for (final factionId in loader.availableFactions()) {
        for (final unit in loader.loadFaction(factionId).units) {
          for (final budget in unit.wargearBudgets) {
            for (final item in budget.items) {
              final id = unit.unscope(item);
              if (id == 'precise' || id == 'lethal-hits') {
                offenders.add('$factionId/${unit.id}: $id');
              }
            }
          }
        }
      }
      expect(offenders, isEmpty,
          reason: '${offenders.length} datasheets still offer a weapon rule '
              'as equipment');
    }, skip: available ? null : 'no snapshot');

    test('the drones a Broadside may take are still offered', () {
      // The other half of the fix: filtering rules must not take real wargear
      // with it. Marker, shield and guardian drones are genuine choices.
      final loadout = loadoutFor(load('tau-empire'), 'broadside-battlesuits');
      final offered = loadout.counters.map((c) => c.itemId).toSet();
      expect(offered,
          containsAll(['marker-drone', 'shield-drone', 'guardian-drone']));
      expect(offered, isNot(contains('precise')));
    }, skip: available ? null : 'no snapshot');
  });
  group('an option is not a thing the unit has', () {
    test('a Coldstar does not start with a Shield Generator', () {
      // A correction written against 40kdc forced this on: that source listed
      // the Shield Generator both as a standard ability and as a wargear
      // option, so the app could not tell whether a list that never bought
      // one had a 4+ invulnerable save, and the entry picked "standard".
      // BSData settles it — an option on this datasheet and on the Enforcer,
      // standard on neither — so the correction was making the unit card
      // print a rule the model does not have.
      final loadout =
          loadoutFor(load('tau-empire'), 'commander-in-coldstar-battlesuit');
      expect(loadout.fixed.keys, isNot(contains('shield-generator')));
      expect(
          loadout.counters.map((c) => c.itemId), contains('shield-generator'),
          reason: 'still offered — the Commander may buy one');
    });

    test('the invulnerable save follows the purchase', () {
      // The statline and the rules list read the same ability, so if one says
      // a Shield Generator was bought the other has to agree.
      final dataset = load('tau-empire');
      final sheet = dataset.unit('commander-in-coldstar-battlesuit')!;
      expect(sheet.abilityIds, isNot(contains('shield-generator')));
      final granted = dataset.ability('shield-generator');
      expect(granted?.unconditionalInvulnerableSave, 4,
          reason: 'the ability still grants it once taken');
    });
  }, skip: available ? null : 'no snapshot');
  group('the cap is the one stated per item', () {
    test('a Novitiate Squad takes one banner, not four', () {
      // 40kdc writes the option as `max_count: 4` over a choice of
      // `[flamer] | [banner] | [simulacrum]` — the number of *models* that
      // may swap, with which item each limit belongs to thrown away. Read per
      // item that is 0-4 of each, and the editor offered four Sacred Banners
      // on a squad allowed one. The budget lines carry what was lost.
      final loadout =
          loadoutFor(load('adepta-sororitas'), 'sisters-novitiate-squad');
      int? capOf(String item) =>
          loadout.counters.firstWhere((c) => c.itemId == item).statedMax;

      expect(capOf('sacred-banner'), 1);
      expect(capOf('simulacrum-imperialis'), 1);
    }, skip: available ? null : 'no snapshot');

    test('a hardpoint cap comes from the hardpoint, not an aggregate', () {
      // 40kdc gives a Commander one `max_count: 3` across ten different
      // weapons — a count of *selections*, not of any one gun — and it is
      // wrong in both directions. BSData carries the real thing: a
      // `Support Systems (1-4)` group whose entries each state their own,
      // four T'au flamers and one shield generator.
      //
      // The reference export is the evidence: a validated 2,000 point list
      // that prices to its printed total fields four flamers on a Commander
      // that 40kdc caps at three.
      final loadout =
          loadoutFor(load('tau-empire'), 'commander-in-enforcer-battlesuit');
      int? capOf(String item) =>
          loadout.counters.firstWhere((c) => c.itemId == item).statedMax;

      expect(capOf('tau-flamer'), 4);
      expect(capOf('missile-pod'), 4);
      // …and the same aggregate would have permitted three of these.
      expect(capOf('shield-generator'), 1);
      expect(capOf('cyclic-ion-blaster'), 1);
    }, skip: available ? null : 'no snapshot');
  });
  test('a missing composition is not read as a single-model unit', () {
    // The snapshot carries no compositions — only the builder needs them — so
    // defaulting to one model made every cap in play mode look exact, and a
    // Crisis team of three was reported for having three sets of battlesuit
    // fists. Absence of data does not license an error (§2.3).
    final dataset = load('tau-empire');
    final sheet = dataset.unit('crisis-fireknife-battlesuits')!;
    final bare = MapCatalogue([sheet], weapons: dataset.faction.weapons);
    final loadout = UnitLoadout.forDatasheet(
      sheet,
      catalogue: bare,
      vocabulary: sheet.wargearVocabulary,
    );
    expect(bare.composition(sheet.id), isNull);
    expect(loadout.capsAreExact, isFalse);
  }, skip: available ? null : 'no snapshot');
}
