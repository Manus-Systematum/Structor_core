import 'dart:io';

import 'package:test/test.dart';
import 'package:wh40k_core/wh40k_core.dart';

import 'support.dart';

void main() {
  final root = Directory(snapshotDir.path);
  final skip = root.existsSync() ? null : 'no snapshot';
  final loader = DatasetLoader(snapshotDir.path,
      corrections: DatasetLoader.correctionsAt(correctionsPath));

  group('Combat Patrol datasheets are not matched-play datasheets', () {
    test('they are the zero-cost ones, and there are a lot of them', () {
      // 98 across 21 factions. Every one was offered in the builder, free, in
      // a points-limited army — and the points are not wrong, the mode is.
      var free = 0;
      var offered = 0;
      for (final factionId in loader.availableFactions()) {
        for (final unit in loader.loadFaction(factionId).units) {
          if (unit.isMatchedPlay) {
            offered++;
          } else {
            free++;
            expect(unit.points.every((p) => p.cost == 0), isTrue,
                reason: unit.id);
          }
        }
      }
      expect(free, greaterThan(90));
      expect(offered, greaterThan(1000));
    }, skip: skip);

    test('absence of game_modes means matched play, per game-modes.json', () {
      final sororitas = loader.loadFaction('adepta-sororitas');
      final canoness = sororitas.units.firstWhere((u) => u.id == 'canoness');
      expect(canoness.gameModes, isEmpty);
      expect(canoness.isMatchedPlay, isTrue);
    }, skip: skip);

    test('a Combat Patrol sheet shadows a real one by name', () {
      // The reason this is worth filtering rather than tolerating: the picker
      // showed both, and choosing the wrong Sacresants gives a unit the
      // Hospitaller cannot join, because the attachment rules name the
      // matched-play sheet.
      final sororitas = loader.loadFaction('adepta-sororitas');
      final real =
          sororitas.units.firstWhere((u) => u.id == 'celestian-sacresants');
      final patrol = sororitas.units.firstWhere(
          (u) => u.id == 'sanctuary-guardians-celestian-sacresants');

      expect(real.isMatchedPlay, isTrue);
      expect(patrol.isMatchedPlay, isFalse);
      expect(patrol.name, contains('Celestian Sacresants'));

      final attachments = {
        for (final a in sororitas.leaderAttachments)
          a.leaderId: a.eligibleBodyguardIds,
      };
      expect(attachments['hospitaller'], contains('celestian-sacresants'));
      expect(attachments['hospitaller'],
          isNot(contains('sanctuary-guardians-celestian-sacresants')));
    }, skip: skip);

    test('a Vehicle cannot be the Warlord, and Paragons are a Vehicle', () {
      final paragons = loader
          .loadFaction('adepta-sororitas')
          .units
          .firstWhere((u) => u.id == 'paragon-warsuits');
      expect(paragons.isCharacter, isFalse);
      expect(paragons.hasKeyword('Vehicle'), isTrue);
    }, skip: skip);
  });

  test('budgeted kit with no gun is not an unresolved miss', () {
    // A Dominion Squad's Simulacrum Imperialis is in the datasheet's own
    // wargear budget and is not a weapon. It used to report as unresolved
    // wargear, which reads as "the app could not find this" when the truth
    // was "there is nothing to show for it".
    //
    // There is something to show for it now: BSData carries the rule as
    // printed, so it is an ability as well as a budget line (§3.10). What
    // still must not happen is the aggregator calling it a miss.
    final sororitas = loader.loadFaction('adepta-sororitas');
    final dominions =
        sororitas.units.firstWhere((u) => u.id == 'dominion-squad');
    expect(dominions.wargearVocabulary, contains('simulacrum-imperialis'));
    final simulacrum = sororitas.abilities
        .where((a) => a.abilityId == 'simulacrum-imperialis')
        .firstOrNull;
    expect(simulacrum?.description, isNotNull,
        reason: 'it is an ability now because it has something to say');

    final catalogue = MapCatalogue.ofFaction(sororitas);
    final result = WeaponAggregator(catalogue).aggregate([
      RosterUnit(
        instanceId: 'u1',
        datasheetId: 'dominion-squad',
        models: 5,
        wargear: const [
          WargearSelection(itemId: 'simulacrum-imperialis', count: 1),
        ],
      ),
    ]);
    expect(result.unresolved, isEmpty);

    // An id the datasheet never mentions is still a genuine miss.
    final bogus = WeaponAggregator(catalogue).aggregate([
      RosterUnit(
        instanceId: 'u1',
        datasheetId: 'dominion-squad',
        models: 5,
        wargear: const [WargearSelection(itemId: 'not-a-thing', count: 1)],
      ),
    ]);
    expect(bogus.unresolved, hasLength(1));
  }, skip: skip);

  test('Epic Heroes file apart from the rest of the Characters', () {
    // They are Characters by keyword, but they are the *named* ones — one to
    // an army, chosen by name rather than picked off a list. A player looking
    // for Shadowsun is not looking through Commanders.
    final tau = loader.loadFaction('tau-empire');
    final shadowsun =
        tau.units.firstWhere((u) => u.id == 'commander-shadowsun');
    final commander =
        tau.units.firstWhere((u) => u.id == 'commander-in-enforcer-battlesuit');

    expect(shadowsun.isEpicHero, isTrue);
    expect(shadowsun.battlefieldRole, 'Epic Heroes');
    expect(commander.battlefieldRole, 'Characters');
    expect(SourceUnit.roleOrder, contains('Epic Heroes'));
  }, skip: skip);
}
