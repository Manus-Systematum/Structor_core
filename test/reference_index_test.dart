import 'dart:convert';
import 'dart:io';

import 'package:test/test.dart';
import 'package:wh40k_core/wh40k_core.dart';

import 'support.dart';

void main() {
  group('matching', () {
    const entry = ReferenceEntry(
      kind: ReferenceKind.stratagem,
      id: 'x',
      title: 'Autoreactive Camouflage',
      source: 'Advanced Acquisition Cadre',
      body: 'Shooting phase: Save improved by 1.',
      detail: '1 CP · battle tactic',
    );

    test('a query matches any field, case-insensitively', () {
      expect(entry.matches('camouflage'), isTrue);
      expect(entry.matches('CADRE'), isTrue);
      expect(entry.matches('save improved'), isTrue);
      expect(entry.matches('battle tactic'), isTrue);
      expect(entry.matches('lasgun'), isFalse);
    });

    test('words match in any order and across fields', () {
      // Mid-game you remember two words, not the phrasing they appeared in.
      expect(entry.matches('cadre camouflage'), isTrue);
      expect(entry.matches('shooting cp'), isTrue);
    });

    test('an empty query matches everything', () {
      expect(entry.matches(''), isTrue);
      expect(entry.matches('   '), isTrue);
    });
  });

  group('the reference army', () {
    final available = snapshotAvailable;

    late ReferenceIndex index;

    setUpAll(() {
      if (!available) return;
      final loader = correctedLoader();
      final faction = loader.loadFaction('tau-empire');
      final core = loader.loadCore();
      final dataset = Dataset.of(faction, revision: 'test');
      final roster = Roster.fromJson(jsonDecode(
          File('test/fixtures/tau_strike_force_2000.json').readAsStringSync()));

      index = ReferenceIndex.forRoster(
        roster,
        catalogue: dataset,
        book: StratagemBook.forRoster(
          roster,
          all: [...core.coreStratagems, ...faction.stratagems],
          catalogue: dataset,
        ),
      );
    });

    test('every kind is populated', () {
      for (final kind in ReferenceKind.values) {
        expect(index.of(kind), isNotEmpty, reason: kind.name);
      }
    }, skip: available ? null : 'no snapshot');

    test('both detachment rules are there, rendered', () {
      final rules = index.of(ReferenceKind.detachmentRule);
      expect(rules, hasLength(2));
      expect(rules.map((r) => r.source),
          containsAll(['Advanced Acquisition Cadre',
              'Experimental Prototype Cadre']));
      expect(rules.every((r) => r.body.isNotEmpty), isTrue);
    }, skip: available ? null : 'no snapshot');

    test('an ability shared by several datasheets is one entry naming them all',
        () {
      // Five battlesuits took a Gun Drone. Five identical rows is five times
      // the scrolling for the same sentence.
      final gunDrone = index
          .of(ReferenceKind.unitAbility)
          .where((e) => e.title == 'Gun Drone')
          .toList();
      expect(gunDrone, hasLength(1));
      expect(gunDrone.single.source, contains('Commander in Enforcer'));
      expect(gunDrone.single.source, contains('Crisis Fireknife'));
    }, skip: available ? null : 'no snapshot');

    test('enhancements are listed whether or not they were taken', () {
      // "What could I have taken" is asked as often as "what did I take".
      final enhancements = index.of(ReferenceKind.enhancement);
      expect(enhancements, hasLength(6),
          reason: 'the two Cadres between them offer six');
      expect(enhancements.every((e) => !e.inPlay), isTrue,
          reason: 'this list bought none — 3 of 3 slots unused');
      expect(
        enhancements.map((e) => e.detail),
        contains(contains('Unit Upgrade')),
        reason: 'Enhancements and Unit Upgrades are distinct mechanics',
      );
    }, skip: available ? null : 'no snapshot');

    test("another detachment's enhancements are not offered", () {
      final sources = index.of(ReferenceKind.enhancement).map((e) => e.source);
      expect(sources, everyElement(anyOf(
        'Advanced Acquisition Cadre',
        'Experimental Prototype Cadre',
        'Faction',
      )));
    }, skip: available ? null : 'no snapshot');

    test('search reaches across every kind at once', () {
      // The point of one index rather than four tabs: you remember the word,
      // not which of the four it lives in.
      final drone = index.search('drone');
      expect(drone.map((e) => e.kind).toSet(), hasLength(greaterThan(1)));

      expect(index.search('overwatch').map((e) => e.title),
          contains('FIRE OVERWATCH'));
      expect(index.search('zzzz'), isEmpty);
    }, skip: available ? null : 'no snapshot');

    test('no entry renders an unresolved placeholder', () {
      // A reference page is the last place a `[some-type]` should surface.
      //
      // "Any brackets" was the old test and it no longer works: GW's printed
      // text spells keywords `[PRECISION]` and `[SUSTAINED HITS 2]`, and
      // BSData supplies that text verbatim (§3.10). The thing being looked
      // for is the renderer's own placeholder, which is a lowercase kebab
      // effect type — a shape the printed notation never takes.
      final placeholder = RegExp(r'\[[a-z][a-z0-9-]*\]');
      final broken = [
        for (final e in index.entries)
          if (placeholder.hasMatch(e.body)) '${e.title}: ${e.body}',
      ];
      expect(broken, isEmpty);
    }, skip: available ? null : 'no snapshot');
  });
}
