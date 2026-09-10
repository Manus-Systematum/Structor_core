import 'dart:io';

import 'package:test/test.dart';
import 'package:wh40k_core/wh40k_core.dart';

import 'support.dart';

const _yaml = '''
abilities:
  - faction: tau-empire
    id: advanced-armour
    reason: Only applies to mortal wounds.
    upstream: not yet reported
    effect:
      type: conditional
      condition:
        type: damage-is-mortal
      effect:
        type: feel-no-pain
        modifier:
          threshold: 4
''';

List<Object?> get _records => [
      {
        'ability_id': 'advanced-armour',
        'name': 'Advanced Armour',
        'effect': {
          'type': 'feel-no-pain',
          'modifier': {'threshold': 4},
        },
      },
      {
        'ability_id': 'for-the-greater-good',
        'name': 'For the Greater Good',
        'effect': {'type': 'fight-first'},
      },
    ];

void main() {
  group('parsing', () {
    test('an ability correction round-trips its effect and its reason', () {
      final corrections = DataCorrections.parse(_yaml).abilities;
      expect(corrections, hasLength(1));
      final only = corrections.single;
      expect(only.faction, 'tau-empire');
      expect(only.abilityId, 'advanced-armour');
      expect(only.upstream, 'not yet reported');
      expect(only.effect['type'], 'conditional');
      // YAML nodes are not JSON-encodable, so the nested maps must have been
      // copied into plain ones on the way through.
      expect(only.effect, isA<Map<String, Object?>>());
      expect(
        (only.effect['condition']! as Map)['type'],
        'damage-is-mortal',
      );
    });

    test('a correction with no reason is not applied', () {
      // Same rule as an accepted divergence: unexplained is indistinguishable
      // from unexamined.
      const unexplained = '''
abilities:
  - faction: tau-empire
    id: advanced-armour
    effect:
      type: fight-first
''';
      expect(DataCorrections.parse(unexplained).abilities, isEmpty);
    });

    test('an empty or malformed document yields no corrections', () {
      expect(DataCorrections.parse('').isEmpty, isTrue);
      expect(DataCorrections.parse('abilities: []').isEmpty, isTrue);
      expect(DataCorrections.parse('- just: a list').isEmpty, isTrue);
    });
  });

  group('aliases fold a duplicate into the rule it repeats', () {
    const yaml = '''
aliases:
  - faction: tau-empire
    id: weapon-support-systems
    canonical: weapon-support-system
    reason: >
      One rule transcribed twice, singular on one datasheet and plural on
      another.
''';

    List<Object?> abilities() => [
          {
            'ability_id': 'weapon-support-system',
            'name': 'Weapon Support System'
          },
          {
            'ability_id': 'weapon-support-systems',
            'name': 'Weapon Support Systems'
          },
          {'ability_id': 'nova-charge', 'name': 'Nova Charge'},
        ];

    test('the duplicate record is dropped', () {
      final result = DataCorrections.parse(yaml)
          .applyToAbilities('tau-empire', abilities());

      expect(
        result.records.map((r) => (r! as Map)['ability_id']),
        ['weapon-support-system', 'nova-charge'],
      );
      expect(result.applied, hasLength(1));
      expect(result.unmatched, isEmpty);
    });

    test('datasheets referring to it are rewritten to the canonical id', () {
      final result = DataCorrections.parse(yaml).applyToUnits('tau-empire', [
        {
          'id': 'crisis-fireknife-battlesuits',
          'ability_ids': ['weapon-support-systems', 'fireknife'],
          'wargear_budgets': [
            {
              'items': ['weapon-support-systems'],
              'count': 1
            },
          ],
        },
      ]);

      final unit = result.records.single! as Map;
      expect(unit['ability_ids'], ['weapon-support-system', 'fireknife']);
      expect((unit['wargear_budgets']! as List).single,
          containsPair('items', ['weapon-support-system']));
    });

    test('a transcribed price replaces one the sources never wrote', () {
      // The channel exists for a datasheet BSData publishes with no cost:
      // shipped as written it is a free unit inside a points limit, and no
      // other source in the pipeline carries a price to fall back on.
      const priced = '''
units:
  - faction: death-guard
    id: beasts-of-nurgle
    reason: Nobody in the pipeline prices this datasheet.
    upstream: not yet reported
    points:
      - models: 1
        cost: 70
''';
      final result =
          DataCorrections.parse(priced).applyToUnits('death-guard', [
        {
          'id': 'beasts-of-nurgle',
          'points': [
            {'models': 1, 'models_max': 2, 'cost': 0}
          ],
        },
      ]);

      final unit = result.records.single! as Map;
      expect((unit['points']! as List).single, containsPair('cost', 70));
      expect(result.applied, hasLength(1));
    });

    test('and a correction that says nothing is not a correction', () {
      // A reason with no effect is a note, and an effect with no reason is a
      // private fork. Neither is parsed.
      const empty = '''
units:
  - faction: death-guard
    id: beasts-of-nurgle
    reason: A reason on its own changes nothing.
''';
      final result = DataCorrections.parse(empty).applyToUnits('death-guard', [
        {
          'id': 'beasts-of-nurgle',
          'points': [
            {'models': 1, 'cost': 0}
          ],
        },
      ]);
      expect(result.applied, isEmpty);
      expect((result.records.single! as Map)['points'],
          [containsPair('cost', 0)]);
    });

    test('a datasheet holding both ids ends up with one', () {
      final result = DataCorrections.parse(yaml).applyToUnits('tau-empire', [
        {
          'id': 'x',
          'ability_ids': ['weapon-support-system', 'weapon-support-systems'],
        },
      ]);
      expect((result.records.single! as Map)['ability_ids'],
          ['weapon-support-system']);
    });

    test('an alias never deletes a rule whose canonical is missing', () {
      // Otherwise a typo in `canonical` silently removes a rule from the app
      // rather than being reported as stale.
      final result = DataCorrections.parse(yaml).applyToAbilities(
        'tau-empire',
        [
          {
            'ability_id': 'weapon-support-systems',
            'name': 'Weapon Support Systems'
          },
        ],
      );
      expect(result.records, hasLength(1));
      expect(result.applied, isEmpty);
      expect(result.unmatched.map((c) => c.subject),
          ['weapon-support-systems -> weapon-support-system']);
    });

    test('an alias with no reason, or pointing at itself, is ignored', () {
      expect(
        DataCorrections.parse('''
aliases:
  - faction: tau-empire
    id: a
    canonical: b
''').aliases,
        isEmpty,
      );
      expect(
        DataCorrections.parse('''
aliases:
  - faction: tau-empire
    id: a
    canonical: a
    reason: circular
''').aliases,
        isEmpty,
      );
    });
  });

  group('application', () {
    test('the named ability is replaced and the rest left alone', () {
      final result =
          DataCorrections.parse(_yaml).applyToAbilities('tau-empire', _records);

      expect(result.applied, hasLength(1));
      expect(result.unmatched, isEmpty);

      final corrected = result.records
          .cast<Map<String, Object?>>()
          .firstWhere((r) => r['ability_id'] == 'advanced-armour');
      expect((corrected['effect']! as Map)['type'], 'conditional');
      // Provenance travels with the record rather than living in a build log.
      expect((corrected['corrected']! as Map)['reason'], isNotEmpty);

      final untouched = result.records
          .cast<Map<String, Object?>>()
          .firstWhere((r) => r['ability_id'] == 'for-the-greater-good');
      expect((untouched['effect']! as Map)['type'], 'fight-first');
      expect(untouched.containsKey('corrected'), isFalse);
    });

    test("another faction is not touched by a T'au correction", () {
      final records = _records;
      final result =
          DataCorrections.parse(_yaml).applyToAbilities('necrons', records);
      expect(result.applied, isEmpty);
      expect(result.unmatched, isEmpty,
          reason: 'a correction for a faction not being built is not stale');
      expect(result.records, same(records));
    });

    test('the input records are not mutated', () {
      // The cross-check reads upstream data while the bundler writes corrected
      // data; the two must not see each other's view.
      final records = _records;
      DataCorrections.parse(_yaml).applyToAbilities('tau-empire', records);
      expect(
        ((records.first! as Map)['effect']! as Map)['type'],
        'feel-no-pain',
      );
    });

    test('a wildcard faction matches every faction that has the ability', () {
      const wildcard = '''
abilities:
  - faction: "*"
    id: advanced-armour
    reason: Core abilities are transcribed once per faction file.
    effect:
      type: cover-benefit
''';
      final corrections = DataCorrections.parse(wildcard);
      for (final faction in ['tau-empire', 'necrons', 'adeptus-astartes']) {
        final result = corrections.applyToAbilities(faction, _records);
        expect(result.applied, hasLength(1), reason: faction);
      }
    });

    test('a wildcard is stale only when no faction anywhere carries it', () {
      const wildcard = '''
abilities:
  - faction: "*"
    id: nonexistent
    reason: Deliberately matches nothing.
    effect:
      type: cover-benefit
''';
      final corrections = DataCorrections.parse(wildcard);
      final result = corrections.applyToAbilities('necrons', _records);
      // Not reported per-faction — a faction without the ability is normal.
      expect(result.unmatched, isEmpty);
      // Reported once the whole run has been seen.
      expect(corrections.neverApplied(result.applied), hasLength(1));
    });

    test('a correction that matches nothing is reported, not silent', () {
      // Otherwise a correction upstream has since adopted goes on shadowing
      // data that is now correct, and nobody finds out.
      final result = DataCorrections.parse(_yaml)
          .applyToAbilities('tau-empire', [_records.last]);
      expect(result.applied, isEmpty);
      expect(result.unmatched.single.subject, 'advanced-armour');
    });
  });

  group('the shipped corrections file', () {
    final file = File(correctionsPath);

    test('parses, and every entry carries a reason', () {
      expect(file.existsSync(), isTrue,
          reason: 'the bundler defaults to this path');
      final corrections = DataCorrections.parse(file.readAsStringSync());
      expect(corrections.abilities, isNotEmpty);
      for (final correction in corrections.abilities) {
        expect(correction.reason, isNotEmpty);
        expect(correction.faction, isNotEmpty);
        expect(correction.abilityId, isNotEmpty);
        expect(correction.effect, isNotEmpty);
      }
      expect(corrections.aliases, isNotEmpty);
      for (final alias in corrections.aliases) {
        expect(alias.reason, isNotEmpty);
        expect(alias.faction, isNotEmpty);
        expect(alias.abilityId, isNotEmpty);
        expect(alias.canonicalId, isNotEmpty);
      }
    });

    test('no two ids in the shipped data render the same rule twice', () {
      // The check the aliases exist to satisfy: an ability whose name differs
      // only by a plural and whose effect is identical is one rule, and
      // leaving it as two splits it across tiers on the rules screen.
      //
      // **Two ids are only one rule on screen if one army can hold both.**
      // Upstream also publishes *scoped copies*: Armour of Contempt is
      // written once per Dark Angels task force, and the Combat Patrol
      // datasheets carry their own copy of every rule the matched-play sheet
      // has — 24 pairs, against 10 that are genuine splits. A roster has one
      // detachment and cannot take a Combat Patrol sheet at all, so a scoped
      // copy is never rendered beside the rule it copies. Aliasing them would
      // merge rules that were never together, and would need a new entry
      // every time a boxed set is published.
      final loader = DatasetLoader(
        snapshotDir.path,
        corrections: DatasetLoader.correctionsAt(correctionsPath),
      );
      if (!loader.root.existsSync()) return;

      for (final factionId in loader.availableFactions()) {
        final faction = loader.loadFaction(factionId);
        final matchedPlay = {
          for (final unit in faction.units)
            if (unit.isMatchedPlay) unit.id,
        };

        /// Whether any army at all can have this rule in front of it.
        bool reachable(SourceAbility ability) =>
            ability.unitIds.isEmpty ||
            ability.unitIds.any(matchedPlay.contains);

        final seen = <String, SourceAbility>{};
        for (final ability in faction.abilities) {
          if (!reachable(ability)) continue;
          final key =
              '${ability.name.toLowerCase().replaceAll(RegExp(r's$'), '')}'
              '|${ability.effectFingerprint}';
          final previous = seen[key];
          if (previous != null &&
              previous.detachmentId != ability.detachmentId) {
            continue;
          }
          expect(
            previous?.abilityId,
            isNull,
            reason: '$factionId: ${ability.abilityId} and '
                '${previous?.abilityId} are the same rule under two ids, '
                'and one army can hold both — add an alias',
          );
          seen[key] = ability;
        }
      }
    });

    test('every correction still matches an ability in the snapshot', () {
      final loader = DatasetLoader(
        snapshotDir.path,
        corrections: DatasetLoader.correctionsAt(correctionsPath),
      );
      if (!loader.root.existsSync()) return;

      final applied = <Correction>[];
      for (final factionId in loader.availableFactions()) {
        for (final result in [
          loader.correctedAbilities(factionId),
          loader.correctedUnits(factionId),
          loader.correctedWeapons(factionId),
        ]) {
          applied.addAll(result.applied);
          expect(
            result.unmatched.map((c) => c.subject),
            isEmpty,
            reason: 'a correction for $factionId matches nothing — either a '
                'typo, or upstream has fixed it and the entry should go',
          );
        }
      }
      expect(
        loader.corrections.neverApplied(applied).map((c) => c.subject),
        isEmpty,
        reason: 'a wildcard correction fired for no faction at all',
      );
    });

    test('the corrected T\'au abilities read as the rulebook has them', () {
      final loader = DatasetLoader(
        snapshotDir.path,
        corrections: DatasetLoader.correctionsAt(correctionsPath),
      );
      if (!loader.root.existsSync()) return;

      const renderer = RulesRenderer();
      final rendered = {
        for (final a in loader.loadFaction('tau-empire').abilities)
          a.abilityId: renderer.render(a),
      };

      expect(
        rendered['advanced-armour']?.derived,
        'Against mortal wounds: Feel No Pain 4+.',
      );
      // The whole squad's ranged weapons, not just the Commander's — being
      // able to shoot after Advancing is the point of the ability.
      expect(
        rendered['coldstar-commander']?.derived,
        'While leading a unit: Move set to 12; ranged weapons gain ASSAULT.',
      );
      // The exclusion is the rule: -1 AP against everything the Starscythe
      // is not built to kill would be a promise the datasheet does not make.
      expect(
        rendered['starscythe']?.derived,
        'Shooting phase, except vs VEHICLE or MONSTER: -1 AP.',
      );

      for (final id in [
        'advanced-armour',
        'coldstar-commander',
        'starscythe',
        'stealth'
      ]) {
        expect(rendered[id]?.isComplete, isTrue,
            reason: '$id renders a placeholder');
      }
    });

    test('a weapon upstream does not have at all is added', () {
      // The Missile Drone granted `{grant_type: ranged-weapon}` with no
      // weapon named and no record to name — so Broadsides fielded drones
      // that shot nothing.
      final loader = DatasetLoader(
        snapshotDir.path,
        corrections: DatasetLoader.correctionsAt(correctionsPath),
      );
      if (!loader.root.existsSync()) return;

      final faction = loader.loadFaction('tau-empire');
      final pod =
          faction.weapons.where((w) => w.id == 'drone-missile-pod').toList();
      expect(pod, hasLength(1), reason: 'added, not duplicated');

      final profile = pod.single.profiles.single;
      expect(profile.range, '30');
      expect(profile.stats['A'], '2');
      expect(profile.skill, '5');
      expect(profile.stats['S'], '7');
      expect(profile.stats['AP'], '-1');
      expect(profile.stats['D'], '2');

      // Derived, not copied: everything but the skill matches the namesake,
      // so an upstream revision to the missile pod carries over.
      final namesake = faction.weapons.firstWhere((w) => w.id == 'missile-pod');
      final original = namesake.profiles.single;
      expect(original.skill, '4', reason: 'the battlesuit fires it better');
      for (final stat in ['A', 'S', 'AP', 'D']) {
        expect(profile.stats[stat], original.stats[stat], reason: stat);
      }
      expect(profile.range, original.range);
      expect(profile.keywords.map((k) => k.key),
          original.keywords.map((k) => k.key));

      // And the grant now resolves to it.
      final drone =
          faction.abilities.firstWhere((a) => a.abilityId == 'missile-drone');
      expect(drone.grantedWeaponId, 'drone-missile-pod');
    });

    test('every granted weapon resolves to a record', () {
      // A grant naming a weapon that does not exist is silently no weapon at
      // all, which is how three drones came to shoot nothing. Anything not
      // listed below is a new one, and needs a weapons: correction.
      // Empty, and it should stay that way: a drone's gun is its namesake at
      // BS5+, so any new one is a two-line `derive_from` entry.
      const knownDangling = <String>{};

      final loader = DatasetLoader(
        snapshotDir.path,
        corrections: DatasetLoader.correctionsAt(correctionsPath),
      );
      if (!loader.root.existsSync()) return;

      final faction = loader.loadFaction('tau-empire');
      final known = {for (final w in faction.weapons) w.id};
      final dangling = {
        for (final ability in faction.abilities)
          if (ability.grantedWeaponId case final id?)
            if (!known.contains(id)) '${ability.abilityId} -> $id',
      };

      expect(dangling.difference(knownDangling), isEmpty,
          reason: 'a new unresolvable weapon grant');
      expect(knownDangling.difference(dangling), isEmpty,
          reason: 'upstream fixed one — drop it from knownDangling');
    });

    test("a drone fires its own gun, not the battlesuit's", () {
      // Pointing the Gun Drone's grant at the plain twin-pulse-carbine had it
      // shooting at BS4+ — the battlesuit's skill, on the drone's gun.
      final loader = DatasetLoader(
        snapshotDir.path,
        corrections: DatasetLoader.correctionsAt(correctionsPath),
      );
      if (!loader.root.existsSync()) return;

      final faction = loader.loadFaction('tau-empire');
      final byId = {for (final w in faction.weapons) w.id: w};
      for (final id in [
        'drone-missile-pod',
        'drone-burst-cannon',
        'drone-twin-pulse-carbine',
        'twin-pulse-blaster',
      ]) {
        expect(byId[id]?.profiles.single.skill, '5', reason: id);
      }
    });

    test('Stealth is the Benefit of Cover in every faction that has it', () {
      final loader = DatasetLoader(
        snapshotDir.path,
        corrections: DatasetLoader.correctionsAt(correctionsPath),
      );
      if (!loader.root.existsSync()) return;

      var seen = 0;
      for (final factionId in loader.availableFactions()) {
        for (final ability in loader.loadFaction(factionId).abilities) {
          if (ability.abilityId != 'stealth') continue;
          seen++;
          expect(
            const RulesRenderer().render(ability).derived,
            'Has the Benefit of Cover.',
            reason: '$factionId still carries the 10th edition -1 to Hit',
          );
        }
      }
      expect(seen, greaterThan(1), reason: 'Stealth is a core ability');
    });

    test('Advanced Armour renders as a mortal-wounds-only save', () {
      final loader = DatasetLoader(
        snapshotDir.path,
        corrections: DatasetLoader.correctionsAt(correctionsPath),
      );
      if (!loader.root.existsSync()) return;

      final ability = loader
          .loadFaction('tau-empire')
          .abilities
          .where((a) => a.abilityId == 'advanced-armour')
          .toList();
      if (ability.isEmpty) return;

      expect(
        const RulesRenderer().render(ability.single).derived,
        'Against mortal wounds: Feel No Pain 4+.',
      );
    });
  });
  group('a Unit Upgrade is limited to its datasheets', () {
    test('the two T\'au upgrades reach only the units they are for', () {
      // Both publish `keyword_restrictions: ["T’au Empire"]` and nothing
      // else, so the builder offered them on every Character in the list. A
      // keyword cannot express it either: the Unmasking Suite goes on
      // Pathfinders *or* Stealth Battlesuits, and restrictions are all
      // required at once — so the correction names the datasheets.
      final loader = correctedLoader();
      if (!loader.root.existsSync()) return;
      final tau = Dataset.of(loader.loadFaction('tau-empire'), revision: 't');

      List<String> upgradesFor(String id) {
        final sheet = tau.unit(id)!;
        return [
          for (final e in tau.enhancements)
            if (e.isUpgrade &&
                e.canBeTakenBy(sheet, factionName: tau.faction.factionName))
              e.name,
        ];
      }

      expect(upgradesFor('commander-in-enforcer-battlesuit'), isEmpty,
          reason: 'a Commander is neither of the two datasheets');
      expect(
          upgradesFor('stealth-battlesuits'),
          containsAll(
              ['Negation Emitters (Upgrade)', 'Unmasking Suite (Upgrade)']));
      expect(upgradesFor('pathfinder-team'), ['Unmasking Suite (Upgrade)'],
          reason: 'Negation Emitters is Stealth only');
    }, skip: snapshotAvailable ? null : 'no snapshot');

    test('an unrestricted enhancement is left alone', () {
      final loader = correctedLoader();
      if (!loader.root.existsSync()) return;
      final tau = Dataset.of(loader.loadFaction('tau-empire'), revision: 't');
      final plain = tau.enhancements
          .firstWhere((e) => e.name == 'Puretide Engram Neurochip');
      expect(plain.unitIds, isEmpty);
    }, skip: snapshotAvailable ? null : 'no snapshot');
  });
}
