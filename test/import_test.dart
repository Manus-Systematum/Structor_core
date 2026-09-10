import 'dart:io';

import 'package:test/test.dart';
import 'package:wh40k_core/wh40k_core.dart';

import 'support.dart';

const _parser = TextListParser();

void main() {
  group('name matching', () {
    test('folds case, typographic apostrophes and punctuation', () {
      expect(normalise('T’au flamer'), 'tau flamer');
      expect(normalise('Missile Pod'), 'missile pod');
      expect(normalise('  Seeker missile  '), 'seeker missile');
      expect(scoreName('T’au flamer', 'tau-flamer'), 1.0);
      expect(normalise('Crisis Shas’vre'), 'crisis shasvre');
    });

    test('containment beats length difference', () {
      // The export writes the long form; the catalogue has the short one.
      final long = scoreName(
          'Gun Drone With Twin Pulse Carbine and Shield Drone', 'Gun Drone');
      expect(long, greaterThan(0.7));
      expect(scoreName('Gun Drone', 'Fusion Blaster'), lessThan(0.3));
    });

    test('plurals match their singular', () {
      // Not 1.0: the strings genuinely differ, so this goes through the
      // containment path. Full coverage and full precision is 0.95, which is
      // well clear of every threshold in the resolver.
      expect(scoreName('Missile drones', 'Missile drone'), greaterThan(0.9));
      expect(scoreName('Missile drones', 'Missile drone'),
          greaterThan(scoreName('Missile drones', 'Shield drone')));
    });

    test('compound entries split only as a fallback', () {
      expect(splitCompound('Gun Drone and Shield Drone'),
          ['Gun Drone', 'Shield Drone']);
      expect(splitCompound('Heavy rail rifle'), ['Heavy rail rifle']);
    });

    test('bestMatch respects its threshold', () {
      final names = ['Missile pod', 'Plasma rifle', 'Battlesuit fists'];
      expect(bestMatch('missile pod', names, (n) => n)?.value, 'Missile pod');
      expect(bestMatch('grot blasta', names, (n) => n), isNull);
    });
  });

  group('text parser', () {
    late ParsedList parsed;

    setUpAll(() {
      parsed = _parser
          .parse(File('test/fixtures/war_organ_export.txt').readAsStringSync());
    });

    test('reads the preamble without mistaking it for units', () {
      expect(parsed.name, '2k ret');
      expect(parsed.printedPoints, 2000);
      expect(parsed.factionName, 'Tau Empire');
      expect(parsed.disposition, 'Reconnaissance');
      expect(parsed.detachmentNames,
          ['Advanced Acquisition Cadre', 'Experimental Prototype Cadre']);
      expect(parsed.detachmentPoints, 2);
      // "Strike Force (2000 Point)" also matches the unit-header pattern; the
      // preamble has to claim it first or it imports as a datasheet.
      expect(parsed.battleSizeName, 'Strike Force');
      expect(parsed.units.any((u) => u.name == 'Strike Force'), isFalse);
    });

    test('parses every unit and leaves nothing unread', () {
      expect(parsed.units, hasLength(16));
      expect(parsed.unparsedLines, isEmpty);
    });

    test('preserves attachment grouping', () {
      final group = parsed.units
          .where((u) => u.attachmentGroup == 'Attached Unit 1')
          .toList();
      expect(group, hasLength(2));
      expect(group.first.name, 'Commander In Enforcer Battlesuit');
      expect(group.last.name, 'Crisis Fireknife Battlesuits');
    });

    test('nests depth-2 nodes under their model group', () {
      final fireknife =
          parsed.units.firstWhere((u) => u.name.contains('Fireknife'));
      expect(fireknife.nodes, hasLength(2), reason: 'two model groups');
      final shasui =
          fireknife.nodes.firstWhere((n) => n.name.contains('Shas’ui'));
      expect(shasui.count, 2);
      expect(shasui.children, hasLength(3));
      expect(
        shasui.children.firstWhere((c) => c.name == 'Missile Pod').count,
        4,
        reason: 'depth-2 counts are group totals, not per-model',
      );
    });

    test('flags the warlord', () {
      final warlords = parsed.units.where((u) => u.isWarlord).toList();
      expect(warlords, hasLength(1));
      expect(warlords.single.name, 'The Twin Lance');
    });

    test('a unit with no bullets still parses', () {
      final bare = _parser.parse('My list (500 points)\n\n'
          'Orks\nStrike Force (2000 Point)\n\n'
          'OTHER DATASHEETS\n\nWarboss (85 points)\n');
      expect(bare.units.single.name, 'Warboss');
      expect(bare.units.single.nodes, isEmpty);
    });
  });

  group('resolution against the catalogue', () {
    final snapshot = Directory(snapshotDir.path);
    final available = snapshot.existsSync();

    late ImportResult result;
    late Dataset dataset;

    setUp(() {
      final faction = correctedLoader().loadFaction('tau-empire');
      dataset = Dataset.of(faction, revision: 'test');
      result = RosterResolver(
        dataset,
        abilityLookup: dataset.ability,
        knownAbilities: faction.abilities,
      ).resolve(
        _parser.parse(
            File('test/fixtures/war_organ_export.txt').readAsStringSync()),
        factionId: 'tau-empire',
      );
    });

    test('a real export imports without errors', () {
      expect(result.errors, isEmpty,
          reason: result.errors.map((e) => e.toString()).join('\n'));
      expect(result.isClean, isTrue);
    }, skip: available ? null : 'no snapshot');

    test('the imported roster prices to what its units cost today', () {
      final cost = PointsCalculator(dataset).price(result.roster);
      expect(cost.isComplete, isTrue);
      expect(cost.total, referenceListCost);
      expect(result.printedPoints, 2000);
      expect(cost.total - result.printedPoints!, referenceListOverrun,
          reason: 'computed and printed differ by more than the two '
              'datasheets that moved — see referenceListCost');
    }, skip: available ? null : 'no snapshot');

    test('attachment groups become LEADS edges', () {
      expect(result.roster.links, hasLength(4));
      expect(result.roster.combatUnits(), hasLength(12),
          reason: '16 roster units, 4 attached pairs');

      // Direction matters: the Commander leads, not the other way round.
      final first = result.roster.links.first;
      expect(
          dataset
              .unit(result.roster
                  .unitByInstance(first.fromInstanceId)!
                  .datasheetId)!
              .isLeader,
          isTrue);
    }, skip: available ? null : 'no snapshot');

    test('the roster validates, but for the points that moved under it', () {
      final validation = RosterValidator(dataset).validate(result.roster);
      // The one error is the list being $referenceListOverrun over a 2,000
      // point cap, which is the validator working: a list built to a limit
      // does not stay under it when two of its datasheets are repriced.
      expect(validation.errors.map((f) => f.code), ['points.over']);
      expect(result.roster.warlordInstanceId, isNotNull);
      expect(result.roster.declaredDisposition, 'reconnaissance');
      expect(result.roster.battleSizeId, 'strike-force');
      expect(result.roster.detachments, hasLength(2));
    }, skip: available ? null : 'no snapshot');

    test('weapons resolve to the carrier-scoped profile', () {
      final attached = result.roster.combatUnits().firstWhere(
          (g) => g.length == 2 && g.first.datasheetId.contains('enforcer'));
      final table = WeaponAggregator(dataset).aggregate(attached);
      expect(table.isComplete, isTrue);
      // The split that only exists if the Commander's pod resolved to its own
      // BS3+ record rather than the generic BS4+ one.
      expect(table.weapons.map((w) => w.attacks.fixed), containsAll([8, 12]));
    }, skip: available ? null : 'no snapshot');

    test('every drone in the printed list is recorded as wargear', () {
      // Drones are wargear, and the model gets the drone's rules (§7.3.7).
      // They used to be recognised as abilities and then thrown away, which
      // cost the list its Gun Drone carbines and showed every drone a
      // datasheet *could* take on units that had bought none.
      final commander =
          result.roster.units.firstWhere((u) => u.instanceId == 'u01');
      final carried = {for (final w in commander.wargear) w.itemId: w.count};
      expect(carried['gun-drone'], 1);
      expect(carried['shield-drone'], 1);

      // The unit corrections exist so nothing in this export is left behind.
      expect(
        result.issues.where((i) => i.message.contains('does not list in the '
            'dataset')),
        isEmpty,
        reason: 'an attachment gap remains; add it to data-corrections.yaml\n'
            '${result.issues.join('\n')}',
      );
      expect(
        result.issues.where((i) => i.severity == IssueSeverity.warning),
        isEmpty,
        reason: result.issues.join('\n'),
      );
    }, skip: available ? null : 'no snapshot');
  });

  group('a 1,000 pt Incursion export with Unit Upgrades', () {
    // A second real export, and everything it exercises was broken when it
    // first went through: the battle size, the `Enhancement:` lines, and the
    // points those lines cost.
    final available = snapshotAvailable;

    late ImportResult result;
    late Dataset dataset;

    setUpAll(() {
      if (!available) return;
      final faction = correctedLoader().loadFaction('tau-empire');
      dataset = Dataset.of(faction, revision: 'test');
      final parsed = const TextListParser().parse(
        File('test/fixtures/war_organ_incursion_1000.txt').readAsStringSync(),
      );
      result = RosterResolver(
        dataset,
        abilityLookup: dataset.ability,
        knownAbilities: faction.abilities,
      ).resolve(parsed, factionId: 'tau-empire');
    });

    test('imports without errors or warnings', () {
      expect(result.errors, isEmpty, reason: result.issues.join('\n'));
      expect(
        result.issues.where((i) => i.severity == IssueSeverity.warning),
        isEmpty,
        reason: result.issues.join('\n'),
      );
    }, skip: available ? null : 'no snapshot');

    test('prices to what its units cost today', () {
      // 995 printed, and it was 965 until Enhancements were priced at all.
      expect(result.printedPoints, 995);
      expect(PointsCalculator(dataset).price(result.roster).total,
          incursionListCost);
    }, skip: available ? null : 'no snapshot');

    test('Incursion is read from the header', () {
      expect(result.roster.battleSizeId, 'incursion');
    }, skip: available ? null : 'no snapshot');

    test('a Unit Upgrade on two units is one selection with two targets', () {
      // Three instances of a Unit Upgrade share one slot (§2.1), which is why
      // targets are a list rather than one selection per bearer.
      expect(result.roster.enhancements, isEmpty);
      final upgrade = result.roster.upgrades.single;
      expect(upgrade.upgradeId,
          'negation-emitters-upgrade-advanced-acquisition-cadre');
      expect(upgrade.targetInstanceIds, hasLength(2));

      final validation = RosterValidator(dataset).validate(result.roster);
      // Legal in every way but the points: this list is over its 1,000 point
      // cap by the same 30 the Strike Force one is over 2,000 (see
      // [incursionListCost]).
      expect(validation.errors.map((f) => f.code), ['points.over'],
          reason: validation.errors.join('\n'));
      // Incursion allows two slots and this list spends one.
      expect(validation.findings.map((f) => f.message).join(' '),
          contains('1 of 2 enhancement slots unused'));
    }, skip: available ? null : 'no snapshot');

    test('each bearer is charged for the upgrade', () {
      final cost = PointsCalculator(dataset).price(result.roster);
      final charged = cost.units.where((u) => u.enhancements > 0).toList();
      expect(charged, hasLength(2), reason: 'both Stealth units bear one');
      expect(charged.every((u) => u.enhancements == 15), isTrue);
    }, skip: available ? null : 'no snapshot');
  });
}
