import 'package:test/test.dart';
import 'package:wh40k_core/wh40k_core.dart';

import 'support.dart';

/// Wargear whose name contains the word "relic".
///
/// A Captain may take a relic shield — his own datasheet's option says so —
/// and selecting it left the unit reporting `unresolved wargear: relic
/// shield`: the item reached the roster from the published option and matched
/// nothing the datasheet was known to carry, because the BSData walk threw
/// every "relic" subtree away with the Crusade relics.
void main() {
  final skip = snapshotAvailable ? null : 'no snapshot; run tools/fetch-all.sh';

  group('a Captain who takes the relic shield his datasheet offers', () {
    late Catalogue catalogue;
    late SourceUnit captain;
    late LoadoutGroup group;
    late List<String> bundle;

    setUpAll(() {
      if (!snapshotAvailable) return;
      catalogue = MapCatalogue.ofFaction(
          correctedLoader().loadFaction('adeptus-astartes'));
      captain = catalogue.unit('captain')!;
      final loadout = UnitLoadout.forDatasheet(
        captain,
        catalogue: catalogue,
        vocabulary: captain.wargearVocabulary,
      );
      group = loadout.groups.firstWhere((g) => g.items.contains('relic-shield'),
          orElse: () =>
              throw StateError('no published option offers him a shield'));
      bundle = group.bundles.firstWhere((b) => b.contains('relic-shield'));
    });

    test('the shield is a rule the datasheet can have', () {
      // Never a weapon: BSData publishes it as an upgrade carrying one
      // Abilities profile, and 40kdc has the same rule as a +1 to Wounds.
      expect(captain.ruleVocabulary, contains('relic-shield'));
      expect(catalogue.ability('relic-shield')?.description,
          contains('Wounds characteristic'));
    }, skip: skip);

    test('and taking it leaves nothing unresolved', () {
      final editor = RosterEditor(catalogue);
      var roster = RosterEditor.blank(
          name: 'Strike Force', factionId: 'adeptus-astartes');
      roster = editor.addUnit(roster, 'captain');
      final instanceId = roster.units.single.instanceId;
      roster = editor.selectLoadoutBundle(roster, instanceId, group, bundle);
      expect(roster.units.single.countOf('relic-shield'), 1);

      for (final kind in WeaponKind.values) {
        final result =
            WeaponAggregator(catalogue).aggregate(roster.units, kind: kind);
        expect(result.unresolved.map((u) => u.itemId), isEmpty,
            reason: 'the datasheet offers every item the roster holds');
      }
    }, skip: skip);

    test('and so does every other datasheet the shield is offered to', () {
      // Three datasheets in the Space Marine catalogue, and a chapter fields
      // its parent's: the shape was wrong on all of them at once.
      final faction = correctedLoader().loadFaction('adeptus-astartes');
      final offered = [
        for (final unit in faction.units)
          if (faction.wargearOptions
              .where((o) => o.unitId == unit.id)
              .expand((o) => o.mapIds(unit.unscope).offered)
              .contains('relic-shield'))
            unit,
      ];
      expect(offered, isNotEmpty);
      for (final unit in offered) {
        expect(unit.ruleVocabulary, contains('relic-shield'),
            reason: '${unit.name} is offered a shield it cannot hold');
      }
    }, skip: skip);
  });
}
