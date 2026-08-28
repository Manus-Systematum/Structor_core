import 'dart:convert';
import 'dart:io';

import 'package:test/test.dart';
import 'package:wh40k_core/wh40k_core.dart';

import 'support.dart';

MissionPack loadPack(String root) {
  List<Object?> read(String path) {
    final file = File('$root/$path');
    if (!file.existsSync()) return const [];
    final decoded = jsonDecode(file.readAsStringSync());
    return decoded is List ? decoded : const [];
  }

  return MissionPack.fromJson(
    dispositions: read('core/force-dispositions.json'),
    missions: read('core/missions.json'),
    matchups: read('core/mission-matchups.json'),
    cards: read('core/secondary-cards.json'),
    deployments: read('core/deployment-patterns.json'),
  );
}

void main() {
  final root = Directory(snapshotDir.path);
  final available = root.existsSync();
  final pack = available ? loadPack(root.path) : const MissionPack();

  group('the matchup table', () {
    test('covers every ordered pair of dispositions', () {
      expect(pack.allDispositions, hasLength(5));
      expect(pack.matchups, hasLength(25), reason: '5 × 5 ordered pairs');
      expect(
        pack.matchups.map((m) => m.missionId).toSet(),
        hasLength(25),
        reason: 'one distinct mission per cell',
      );
    }, skip: available ? null : 'no snapshot');

    test('is asymmetric — both players play different primaries', () {
      final mine = pack.missionFor(
        disposition: 'reconnaissance',
        opponentDisposition: 'take-and-hold',
      );
      final theirs = pack.missionFor(
        disposition: 'take-and-hold',
        opponentDisposition: 'reconnaissance',
      );

      expect(mine?.name, 'Reconnaissance Sweep');
      expect(theirs?.name, 'Purge and Secure');
      expect(mine!.id, isNot(theirs!.id),
          reason: 'the table is ordered, not symmetric');
    }, skip: available ? null : 'no snapshot');

    test('mirrors sit on the diagonal', () {
      for (final disposition in pack.allDispositions) {
        final mirror = pack.missionFor(
          disposition: disposition.id,
          opponentDisposition: disposition.id,
        );
        expect(mirror, isNotNull, reason: disposition.id);
      }
      expect(
        pack
            .missionFor(
                disposition: 'reconnaissance',
                opponentDisposition: 'reconnaissance')
            ?.name,
        'Gather Intel',
      );
    }, skip: available ? null : 'no snapshot');

    test('an outcome carries the card text the player reads', () {
      final outcome = pack.outcomeFor(
        disposition: 'reconnaissance',
        opponentDisposition: 'take-and-hold',
      );
      expect(outcome.card, isNotNull);
      expect(outcome.card!.text, isNotEmpty);
      expect(outcome.card!.isPrimary, isTrue);
    }, skip: available ? null : 'no snapshot');
  });

  group('the decision grid', () {
    SourceDetachment detachment(String id, List<String> dispositions) =>
        SourceDetachment.fromJson({
          'id': id,
          'name': id,
          'force_dispositions': dispositions,
        });

    test('two detachments with different dispositions offer a choice', () {
      // The reference army: Advanced Acquisition Cadre is Reconnaissance,
      // Experimental Prototype Cadre is Priority Assets (§7.3.1).
      final available = pack.availableTo([
        detachment('aac', ['reconnaissance']),
        detachment('epc', ['priority-assets']),
      ]);
      expect(available.map((d) => d.id),
          containsAll(['reconnaissance', 'priority-assets']));
      expect(available, hasLength(2), reason: 'a real decision');
    }, skip: available ? null : 'no snapshot');

    test('detachments sharing a disposition offer no choice', () {
      final options = pack.availableTo([
        detachment('a', ['take-and-hold']),
        detachment('b', ['take-and-hold']),
      ]);
      expect(options, hasLength(1));
    }, skip: available ? null : 'no snapshot');

    test('the grid is my options by every opponent declaration', () {
      final mine = pack.availableTo([
        detachment('aac', ['reconnaissance']),
        detachment('epc', ['priority-assets']),
      ]);
      final grid = pack.grid(mine);

      expect(grid, hasLength(2));
      expect(grid.first, hasLength(5));
      expect(
        grid.expand((row) => row).every((cell) => cell.mission != null),
        isTrue,
        reason: 'every cell resolves',
      );

      // The two choices genuinely differ against the same opponent.
      final row = {for (final r in grid) r.first.disposition: r.first};
      expect(row['reconnaissance']!.mission!.id,
          isNot(row['priority-assets']!.mission!.id));
    }, skip: available ? null : 'no snapshot');
  });

  group('mission setup', () {
    const setup = MissionSetup(
      myDisposition: 'reconnaissance',
      opponentDisposition: 'take-and-hold',
      myMissionId: 'reconnaissance-sweep',
      opponentMissionId: 'purge-and-secure',
      deploymentId: 'tipping-point',
      twist: 'drew nothing',
      iAmAttacker: false,
      secondaryMode: SecondaryMode.fixed,
      opponentName: 'Dave',
    );

    test('round trips through JSON', () {
      final restored =
          MissionSetup.fromJson(jsonDecode(jsonEncode(setup.toJson())));
      expect(restored.myMissionId, 'reconnaissance-sweep');
      expect(restored.opponentMissionId, 'purge-and-secure');
      expect(restored.iAmAttacker, isFalse);
      expect(restored.secondaryMode, SecondaryMode.fixed);
      expect(restored.opponentName, 'Dave');
      expect(restored.isMirror, isFalse);
    });

    test('setup is carried in the battle log', () {
      final log = const BattleLog().add(const ConfigureBattle(setup));
      expect(log.state.setup?.myMissionId, 'reconnaissance-sweep');

      final restored = BattleLog.fromJson(jsonDecode(jsonEncode(log.toJson())));
      expect(restored.state.setup?.opponentMissionId, 'purge-and-secure');
      expect(restored.state.setup?.deploymentId, 'tipping-point');
    });

    test('undo removes the setup', () {
      final log = const BattleLog().add(const ConfigureBattle(setup));
      expect(log.undo().state.setup, isNull);
    });

    test('a mirror matchup is flagged', () {
      const mirror = MissionSetup(
        myDisposition: 'reconnaissance',
        opponentDisposition: 'reconnaissance',
        myMissionId: 'gather-intel',
        opponentMissionId: 'gather-intel',
      );
      expect(mirror.isMirror, isTrue);
    });
  });

  group('deployments and secondaries', () {
    test('deployment patterns load with their descriptions', () {
      expect(pack.deployments, isNotEmpty);
      expect(pack.deployments.first.name, isNotEmpty);
      expect(pack.deployments.first.description, isNotEmpty);
    }, skip: available ? null : 'no snapshot');

    test('eighteen secondaries, some requiring an action', () {
      expect(pack.secondaryCards, hasLength(18));
      expect(pack.secondaryCards.where((c) => c.requiresAction), isNotEmpty);
      expect(pack.secondaryCards.every((c) => c.text.isNotEmpty), isTrue);
    }, skip: available ? null : 'no snapshot');

    test('every primary mission carries scoring text', () {
      // What the scoring panel shows beside the stepper. A mission whose card
      // is missing would leave the player entering VP for a rule the app
      // declined to state.
      final primaries = pack.cards.values.where((c) => c.isPrimary).toList();
      expect(primaries, hasLength(25));
      expect(primaries.every((c) => c.text.isNotEmpty), isTrue);
    }, skip: available ? null : 'no snapshot');
  });

  group('the table, as geometry', () {
    DeploymentPattern byId(String id) =>
        pack.deployments.firstWhere((d) => d.id == id);

    test('every pattern publishes two zones and a drawable shape', () {
      for (final pattern in pack.deployments) {
        expect(pattern.zones, hasLength(2), reason: pattern.id);
        expect(pattern.hasGeometry, isTrue, reason: pattern.id);
        expect(pattern.zoneFor(attacker: true), isNotNull, reason: pattern.id);
        expect(pattern.zoneFor(attacker: false), isNotNull, reason: pattern.id);
      }
    }, skip: available ? null : 'no snapshot');

    test('a rectangle zone becomes four corners in board coordinates', () {
      // Hammer and Anvil states its zones as width/height rather than a
      // polygon. Flattening both shapes at parse time is what lets the painter
      // draw one thing.
      final zone = byId('hammer-and-anvil').zoneFor(attacker: true)!;
      expect(zone.points, hasLength(4));
    }, skip: available ? null : 'no snapshot');

    test("a zone's position offset is applied, not dropped", () {
      // The attacker's polygon is authored at the origin and moved into place
      // by `position`. Ignoring it stacks both players in the same corner —
      // the picture would look plausible and be wrong.
      final attacker = byId('tipping-point').zoneFor(attacker: true)!;
      final defender = byId('tipping-point').zoneFor(attacker: false)!;
      final attackerLeft =
          attacker.points.map((p) => p.x).reduce((a, b) => a < b ? a : b);
      final defenderLeft =
          defender.points.map((p) => p.x).reduce((a, b) => a < b ? a : b);
      expect(attackerLeft, greaterThan(defenderLeft));
      expect(attackerLeft, 40, reason: 'its position is x=40');
    }, skip: available ? null : 'no snapshot');

    test('the board is measured from the data, not assumed to be 60×44', () {
      final standard = byId('tipping-point').boardSize;
      expect(standard.x, 60);
      expect(standard.y, 44);

      // The reason it is measured: this one is not a standard table, and a
      // hardcoded 60×44 would draw it at half scale in the corner.
      final colosseum = byId('kotc-colosseum').boardSize;
      expect(colosseum.x, 36);
      expect(colosseum.y, 36);
    }, skip: available ? null : 'no snapshot');

    test('objectives are five markers, inside the board', () {
      final pattern = byId('tipping-point');
      final size = pattern.boardSize;
      expect(pattern.objectives, hasLength(5));
      for (final o in pattern.objectives) {
        expect(o.x, inInclusiveRange(0, size.x));
        expect(o.y, inInclusiveRange(0, size.y));
      }
    }, skip: available ? null : 'no snapshot');

    test('a pattern with no geometry is drawable-checkable, not a crash', () {
      const bare = DeploymentPattern(id: 'x', name: 'X', description: '');
      expect(bare.hasGeometry, isFalse);
      expect(bare.boardSize.x, 0);
      expect(bare.zoneFor(attacker: true), isNull);
    });

    test('a malformed colour falls back rather than painting black', () {
      final area = BoardArea.fromJson(const {
        'player': 'attacker',
        'color': 'not-a-colour',
        'shape': {'type': 'rectangle', 'width': 2, 'height': 2},
      });
      expect(area.color, isNull);

      final good = BoardArea.fromJson(const {
        'player': 'defender',
        'color': '#3b82f6',
        'shape': {'type': 'rectangle', 'width': 2, 'height': 2},
      });
      expect(good.color, 0xFF3B82F6);
    });
  });

  group('mission cards carry their printed text', () {
    test('every card has it, and it names the VP', () {
      // 40kdc publishes the structure and a paraphrase beside it. The
      // paraphrase reads as a summary because it is one; a player checking
      // whether they scored wants the sentence off the card (§3.11).
      if (!available) return;

      final cards = pack.cards.values.toList();
      expect(cards.length, greaterThan(40));

      final vp = RegExp(r'\d+ VP');
      final untexted = <String>[];
      final unpriced = <String>[];
      for (final card in cards) {
        if (card.text.trim().isEmpty) {
          untexted.add(card.id);
        } else if (!vp.hasMatch(card.text)) {
          unpriced.add(card.id);
        }
      }
      expect(untexted, isEmpty, reason: 'cards with no text');
      expect(unpriced, isEmpty, reason: 'cards whose text names no VP');
    });

    test('the markup is the one the app renders', () {
      // The source marks keywords two ways — `**bold**` on the primaries and
      // `<b>` on the secondaries — and only the first is what `ruleSpans`
      // reads. A tag reaching a screen shows as literal `<b>`.
      if (!available) return;

      for (final card in pack.cards.values) {
        expect(card.text, isNot(contains('<b>')), reason: card.id);
        expect(card.text, isNot(contains(r'$undefined')), reason: card.id);
        expect('**'.allMatches(card.text).length.isEven, isTrue,
            reason: '${card.id}: unbalanced emphasis');
      }
    });
  });
  group('the action section', () {
    // The front of a card names the action and stops: Secure Asset reads
    // "A friendly unit **secured the asset** this turn (see reverse)". The
    // reverse was nowhere in the app, and no source publishes its printed
    // wording — gdmissions' payload does not carry it either. So the section
    // is composed from 40kdc's structure at merge time (§3.13).
    MissionCard card(String id) => pack.cards[id]!;

    String actionPart(MissionCard c) {
      final at = c.text.indexOf('ACTION ·');
      return at < 0 ? '' : c.text.substring(at);
    }

    test('names the action and what it is performed on', () {
      final text = actionPart(card('secure-asset'));
      expect(text, contains('ACTION · Secure Asset: Objective Action'));
      expect(text, contains('When: your Shooting phase, once per turn.'));
      expect(
        text,
        contains('excluding your **home objective**'),
        reason: 'the target filter is the difference between a legal '
            'action and an illegal one',
      );
    }, skip: available ? null : 'no snapshot');

    test('every card that has an action shows one', () {
      final withActions =
          pack.cards.values.where((c) => c.requiresAction).toList();
      expect(withActions, hasLength(15));
      for (final c in withActions) {
        expect(actionPart(c), isNotEmpty, reason: '${c.id} has no section');
      }
    }, skip: available ? null : 'no snapshot');

    test('a card without actions gains nothing', () {
      expect(card('immovable-object').text, isNot(contains('ACTION ·')));
    }, skip: available ? null : 'no snapshot');

    // The composer maps a closed vocabulary and renders nothing for a value
    // it does not know, which is the failure mode that produced this bug in
    // the first place. If upstream adds a value, this fails rather than
    // dropping it silently.
    test('the structure uses no vocabulary the composer cannot render', () {
      final starts = <String>{};
      final timings = <String>{};
      final targets = <String>{};
      final effects = <String>{};
      final restrictions = <String>{};
      for (final c in pack.cards.values) {
        for (final raw in c.actions) {
          final action = raw as Map<String, dynamic>;
          if (action['starts'] case final String v) starts.add(v);
          if (action['timing'] case final String v) timings.add(v);
          if (action['effect'] case final Map<String, dynamic> e) {
            effects.add(e['type'] as String);
          }
          if (action['restrictions'] case final Map<String, dynamic> r) {
            restrictions.add(r['type'] as String);
          }
          if (action['completes'] case final Map<String, dynamic> done) {
            final params = done['parameters'] as Map<String, dynamic>;
            if (params['target_kind'] case final String v) targets.add(v);
          }
        }
      }
      expect(starts, {'shooting'});
      expect(timings, {'start-of-turn', 'end-of-turn', 'start-of-battle'});
      expect(targets, {'objective', 'terrain', 'enemy-unit'});
      expect(effects, {'unit-tag', 'objective-tag', 'terrain-area-tag'});
      expect(restrictions, {'operation-markers'});
    }, skip: available ? null : 'no snapshot');
  });
}
