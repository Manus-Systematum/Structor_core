import 'dart:convert';
import 'dart:io';

import 'package:test/test.dart';
import 'package:wh40k_core/wh40k_core.dart';

import 'support.dart';

SourceUnit _unit(
  String id, {
  int cost = 100,
  int models = 1,
  List<String> keywords = const [],
}) =>
    SourceUnit.fromJson({
      'id': id,
      'name': id,
      'keywords': keywords,
      'points': [
        {'models': models, 'cost': cost},
      ],
    });

SourceDetachment _detachment(String id,
        {int dp = 1, List<String> tags = const []}) =>
    SourceDetachment.fromJson({
      'id': id,
      'name': id,
      'detachment_points': dp,
      'unique_tags': tags,
    });

/// A catalogue with a Character leader, a plain squad, a Battleline squad and
/// an Epic Hero, plus detachments at each DP cost.
Catalogue _catalogue() => MapCatalogue(
      [
        _unit('captain', cost: 80, keywords: ['Character', 'Infantry']),
        _unit('squad', cost: 100, models: 5),
        _unit('troops', cost: 60, models: 5, keywords: ['Battleline']),
        _unit('hero', cost: 120, keywords: ['Character', 'Epic Hero']),
        _unit('tank', cost: 150),
      ],
      detachments: [
        _detachment('one-dp'),
        _detachment('two-dp', dp: 2),
        _detachment('big', dp: 3),
        _detachment('other-big', dp: 3),
        _detachment('tagged-a', tags: ['shared']),
        _detachment('tagged-b', tags: ['shared']),
      ],
      leaderAttachments: [
        LeaderAttachment.fromJson({
          'leader_id': 'captain',
          'eligible_bodyguard_ids': ['squad'],
        }),
      ],
    );

Roster _roster({
  String battleSizeId = 'strike-force',
  List<RosterUnit> units = const [],
  List<String> detachmentIds = const ['two-dp'],
  List<EnhancementSelection> enhancements = const [],
  List<UpgradeSelection> upgrades = const [],
  List<RosterLink> links = const [],
  String? warlord = 'cap',
}) =>
    Roster(
      name: 'test',
      factionId: 'testers',
      battleSizeId: battleSizeId,
      detachments: [
        for (final id in detachmentIds) RosterDetachment(detachmentId: id),
      ],
      units: [
        const RosterUnit(instanceId: 'cap', datasheetId: 'captain', models: 1),
        ...units,
      ],
      enhancements: enhancements,
      upgrades: upgrades,
      links: links,
      warlordInstanceId: warlord,
    );

RosterUnit _r(String id, String datasheetId, {int models = 1}) =>
    RosterUnit(instanceId: id, datasheetId: datasheetId, models: models);

void main() {
  final validator = RosterValidator(_catalogue());

  group('nothing is ever blocked', () {
    test('an over-points list reports an error but still returns a cost', () {
      final result = validator.validate(_roster(units: [
        for (var i = 0; i < 20; i++) _r('t$i', 'tank'),
      ]));
      expect(result.isLegal, isFalse);
      expect(result.has('points.over'), isTrue);
      expect(result.cost.total, greaterThan(2000),
          reason: 'the list is still priced, not rejected');
    });
  });

  group('detachment points', () {
    test('spending within budget leaves an info finding, not an error', () {
      final result = validator.validate(_roster(detachmentIds: ['two-dp']));
      expect(result.has('detachment.over-budget'), isFalse);
      expect(result.has('detachment.under-budget'), isTrue,
          reason: '2 of 3 DP spent at Strike Force');
    });

    test('over-spending the budget is an error', () {
      final result =
          validator.validate(_roster(detachmentIds: ['big', 'two-dp']));
      expect(result.has('detachment.over-budget'), isTrue);
    });

    test('a single 3 DP detachment is legal at Incursion despite a 2 DP budget',
        () {
      // The budget rises 2 -> 3 precisely so one large detachment always fits.
      final result = validator.validate(_roster(
        battleSizeId: 'incursion',
        detachmentIds: ['big'],
      ));
      expect(result.has('detachment.over-budget'), isFalse);
    });

    test('two 3 DP detachments are an error even where the budget allows', () {
      final result = validator.validate(_roster(
        battleSizeId: 'onslaught', // 4 DP, so budget is not the binding rule
        detachmentIds: ['big', 'other-big'],
      ));
      expect(result.has('detachment.multiple-3dp'), isTrue);
    });

    test('detachments sharing a unique tag conflict', () {
      final result =
          validator.validate(_roster(detachmentIds: ['tagged-a', 'tagged-b']));
      expect(result.has('detachment.tag-conflict'), isTrue);
    });

    test('the same detachment twice is an error', () {
      final result =
          validator.validate(_roster(detachmentIds: ['one-dp', 'one-dp']));
      expect(result.has('detachment.duplicate'), isTrue);
    });
  });

  group('duplicate datasheets scale with battle size', () {
    List<RosterUnit> copies(String datasheetId, int n) =>
        [for (var i = 0; i < n; i++) _r('$datasheetId$i', datasheetId)];

    test('three of a plain datasheet is legal at Strike Force', () {
      final result = validator.validate(_roster(units: copies('tank', 3)));
      expect(result.has('datasheet.over-cap'), isFalse);
    });

    test('three of a plain datasheet is illegal at Incursion', () {
      final result = validator.validate(_roster(
        battleSizeId: 'incursion',
        units: copies('tank', 3),
      ));
      expect(result.has('datasheet.over-cap'), isTrue,
          reason: 'the cap is 2 at Incursion, not 3');
    });

    test('Battleline receives the doubled cap', () {
      final six = validator.validate(_roster(units: copies('troops', 6)));
      final seven = validator.validate(_roster(units: copies('troops', 7)));
      expect(six.has('datasheet.over-cap'), isFalse);
      expect(seven.has('datasheet.over-cap'), isTrue);
    });

    test('an Epic Hero may be taken only once', () {
      final result = validator.validate(_roster(units: copies('hero', 2)));
      expect(result.has('epic-hero.duplicate'), isTrue);
      expect(result.has('datasheet.over-cap'), isTrue);
    });
  });

  group('warlord', () {
    test('a missing warlord is an error', () {
      final result = validator.validate(_roster(warlord: null));
      expect(result.has('warlord.missing'), isTrue);
    });

    test('a non-Character warlord is an error', () {
      final result = validator.validate(_roster(
        units: [_r('tk', 'tank')],
        warlord: 'tk',
      ));
      expect(result.has('warlord.not-character'), isTrue);
    });

    test('a Character warlord passes', () {
      final result = validator.validate(_roster());
      expect(result.has('warlord.not-character'), isFalse);
      expect(result.has('warlord.missing'), isFalse);
    });
  });

  group('slots: an upgrade costs one slot however many targets', () {
    test('three enhancements fill Strike Force exactly', () {
      final result = validator.validate(_roster(enhancements: const [
        EnhancementSelection(enhancementId: 'e1', targetInstanceId: 'cap'),
        EnhancementSelection(enhancementId: 'e2', targetInstanceId: 'cap'),
        EnhancementSelection(enhancementId: 'e3', targetInstanceId: 'cap'),
      ]));
      expect(result.has('slots.over'), isFalse);
      expect(result.has('slots.unused'), isFalse);
    });

    test('a three-target upgrade consumes one slot, not three', () {
      final result = validator.validate(_roster(
        units: [_r('a', 'tank'), _r('b', 'tank'), _r('c', 'tank')],
        upgrades: const [
          UpgradeSelection(upgradeId: 'up', targetInstanceIds: ['a', 'b', 'c']),
        ],
      ));
      expect(result.has('slots.over'), isFalse);
      // 1 of 3 used, so two remain.
      expect(
        result.findings.firstWhere((f) => f.code == 'slots.unused').message,
        contains('2 of 3'),
      );
    });

    test('four slot-consuming choices exceed Strike Force', () {
      final result = validator.validate(_roster(
        units: [_r('a', 'tank')],
        enhancements: const [
          EnhancementSelection(enhancementId: 'e1', targetInstanceId: 'cap'),
          EnhancementSelection(enhancementId: 'e2', targetInstanceId: 'cap'),
          EnhancementSelection(enhancementId: 'e3', targetInstanceId: 'cap'),
        ],
        upgrades: const [
          UpgradeSelection(upgradeId: 'up', targetInstanceIds: ['a']),
        ],
      ));
      expect(result.has('slots.over'), isTrue);
    });

    test('an enhancement on a non-Character is an error', () {
      final result = validator.validate(_roster(
        units: [_r('tk', 'tank')],
        enhancements: const [
          EnhancementSelection(enhancementId: 'e1', targetInstanceId: 'tk'),
        ],
      ));
      expect(result.has('enhancement.non-character'), isTrue);
    });

    test('an upgrade on a Character is an error', () {
      final result = validator.validate(_roster(upgrades: const [
        UpgradeSelection(upgradeId: 'up', targetInstanceIds: ['cap']),
      ]));
      expect(result.has('upgrade.character-target'), isTrue);
    });

    test('an upgrade with four targets is an error', () {
      final result = validator.validate(_roster(
        units: [
          _r('a', 'tank'),
          _r('b', 'tank'),
          _r('c', 'tank'),
          _r('d', 'tank')
        ],
        upgrades: const [
          UpgradeSelection(
              upgradeId: 'up', targetInstanceIds: ['a', 'b', 'c', 'd']),
        ],
      ));
      expect(result.has('upgrade.target-count'), isTrue);
    });
  });

  group('leader attachments', () {
    test('a published pairing validates', () {
      final result = validator.validate(_roster(
        units: [_r('sq', 'squad', models: 5)],
        links: const [
          RosterLink(
            type: LinkType.leads,
            fromInstanceId: 'cap',
            toInstanceId: 'sq',
          ),
        ],
      ));
      expect(result.has('attachment.illegal'), isFalse);
    });

    test('an unpublished pairing is an error', () {
      final result = validator.validate(_roster(
        units: [_r('tk', 'tank')],
        links: const [
          RosterLink(
            type: LinkType.leads,
            fromInstanceId: 'cap',
            toInstanceId: 'tk',
          ),
        ],
      ));
      expect(result.has('attachment.illegal'), isTrue);
    });

    test('a leader with no published rule is left alone, not invented for', () {
      // 'hero' has no leader-attachment entry. Absent data must not become a
      // fabricated restriction.
      final result = validator.validate(_roster(
        units: [_r('h', 'hero'), _r('sq', 'squad', models: 5)],
        links: const [
          RosterLink(
            type: LinkType.leads,
            fromInstanceId: 'h',
            toInstanceId: 'sq',
          ),
        ],
      ));
      expect(result.has('attachment.illegal'), isFalse);
    });
  });

  group('the reference list validates clean', () {
    final snapshot = Directory(snapshotDir.path);
    final available = snapshot.existsSync();

    test('a real 2,000 pt list produces no errors but the points that moved',
        () {
      final roster = Roster.fromJson(jsonDecode(
          File('test/fixtures/tau_strike_force_2000.json').readAsStringSync()));
      final faction = correctedLoader().loadFaction('tau-empire');
      final result =
          RosterValidator(MapCatalogue.ofFaction(faction)).validate(roster);

      // Everything the validator judges about how the list is *built* is
      // still clean; the only error is the $referenceListOverrun points two
      // repriced datasheets added under it (see [referenceListCost]).
      expect(result.errors.map((f) => f.code), ['points.over'],
          reason: result.errors.map((f) => f.toString()).join('\n'));
      expect(result.cost.total, referenceListCost);

      // The two informational observations a builder should surface: the list
      // spends 2 of 3 Detachment Points and takes none of its 3 slots.
      expect(result.has('detachment.under-budget'), isTrue);
      expect(result.has('slots.unused'), isTrue);
      expect(result.has('points.under'), isFalse, reason: 'over, not under');
    }, skip: available ? null : 'no snapshot; run tools/fetch-40kdc.sh');
  });
  group('wargear past what the datasheet allows', () {
    test('the reference army is not one of them', () {
      // This check was written once before and withdrawn: it called a
      // validated 2,000 point list illegal in four places, because the cap it
      // read was 40kdc's `max_count: 3` spread across ten different guns
      // rather than the hardpoint's own limit. With the per-item cap in hand
      // — four T'au flamers, one shield generator — the same list is clean.
      final loader = correctedLoader();
      if (!loader.root.existsSync()) return;
      final dataset =
          Dataset.of(loader.loadFaction('tau-empire'), revision: 't');
      final roster = Roster.fromJson(jsonDecode(
          File('test/fixtures/tau_strike_force_2000.json').readAsStringSync()));
      final result = RosterValidator(dataset).validate(roster);
      expect(
        result.findings.where((f) => f.code == 'wargear.over-limit'),
        isEmpty,
        reason: result.findings.map((f) => f.message).join('\n'),
      );
    }, skip: snapshotAvailable ? null : 'no snapshot');

    test('a fifth flamer on a four-hardpoint suit is reported', () {
      final loader = correctedLoader();
      if (!loader.root.existsSync()) return;
      final dataset =
          Dataset.of(loader.loadFaction('tau-empire'), revision: 't');
      final roster = Roster.fromJson(jsonDecode(
          File('test/fixtures/tau_strike_force_2000.json').readAsStringSync()));
      final over = roster.copyWith(units: [
        for (final unit in roster.units)
          if (dataset.unit(unit.datasheetId)?.id ==
              'commander-in-coldstar-battlesuit')
            unit.copyWith(wargear: [
              for (final w in unit.wargear)
                if (w.itemId == 'tau-flamer')
                  WargearSelection(itemId: w.itemId, count: 5)
                else
                  w,
            ])
          else
            unit,
      ]);

      final findings = RosterValidator(dataset)
          .validate(over)
          .findings
          .where((f) => f.code == 'wargear.over-limit');
      expect(findings, isNotEmpty);
      expect(findings.first.message, contains('allows 4'));
      expect(findings.first.severity, Severity.error);
    }, skip: snapshotAvailable ? null : 'no snapshot');
  });
}
