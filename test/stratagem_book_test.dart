import 'dart:convert';
import 'dart:io';

import 'package:test/test.dart';
import 'package:wh40k_core/wh40k_core.dart';

import 'support.dart';

SourceStratagem _stratagem({
  required String id,
  int cp = 1,
  List<String> phases = const ['shooting'],
  String playerTurn = 'either',
  String timing = 'once-per-phase',
  String? detachmentId,
  Object? restrictions,
}) =>
    SourceStratagem.fromJson({
      'id': id,
      'name': id.toUpperCase(),
      'cp_cost': cp,
      'phases': phases,
      'player_turn': playerTurn,
      'timing': timing,
      'detachment_id': detachmentId,
      'target_restrictions': restrictions,
    });

void main() {
  group('availability', () {
    final book = StratagemBook(stratagems: [
      _stratagem(id: 'cheap'),
      _stratagem(id: 'dear', cp: 3),
      _stratagem(id: 'yours', playerTurn: 'your-turn'),
      _stratagem(id: 'theirs', playerTurn: 'opponent-turn'),
      _stratagem(id: 'elsewhere', phases: ['fight']),
    ]);

    test('only this phase, playable first', () {
      final rows = book.forPhase('shooting', state: const BattleState(cp: 2));
      expect(rows.map((r) => r.id), isNot(contains('elsewhere')));
      // 'dear' costs 3 against 2 CP, 'theirs' is out of turn; both sort down.
      expect(rows.take(2).map((r) => r.id), containsAll(['cheap', 'yours']));
      expect(rows.every((r) => r.playable), isFalse);
      expect(rows.last.playable, isFalse);
    });

    test('an unaffordable stratagem is greyed, not hidden', () {
      // Hiding it answers "why can't I use that" by omission, which reads as
      // a missing stratagem rather than as a rule.
      final rows = book.forPhase('shooting', state: const BattleState(cp: 2));
      final dear = rows.firstWhere((r) => r.id == 'dear');
      expect(dear.playable, isFalse);
      expect(dear.blocks, contains(StratagemBlock.cp));
      expect(dear.blockedReason, 'not enough CP');
    });

    test('turn restrictions cut both ways', () {
      const yourTurn = BattleState(cp: 5);
      const theirTurn = BattleState(cp: 5, activePlayer: Player.opponent);

      List<String> playableIn(BattleState state) => [
            for (final r in book.forPhase('shooting', state: state))
              if (r.playable) r.id,
          ];

      expect(playableIn(yourTurn), containsAll(['cheap', 'dear', 'yours']));
      expect(playableIn(yourTurn), isNot(contains('theirs')));
      expect(playableIn(theirTurn), contains('theirs'));
      expect(playableIn(theirTurn), isNot(contains('yours')));

      final blocked = book
          .forPhase('shooting', state: yourTurn)
          .firstWhere((r) => r.id == 'theirs');
      expect(blocked.blockedReason, "opponent's turn only");
    });
  });

  group('use limits are a query, not a lifecycle', () {
    BattleState after(List<BattleEvent> events) =>
        BattleLog(events: events).state;

    const bothPhases = ['shooting', 'fight'];
    final book = StratagemBook(stratagems: [
      _stratagem(id: 'phasely', phases: bothPhases),
      _stratagem(id: 'turnly', timing: 'once-per-turn', phases: bothPhases),
      _stratagem(id: 'battlely', timing: 'once-per-battle', phases: bothPhases),
    ]);

    const play = UseStratagem(
      stratagemId: 'phasely',
      round: 1,
      phase: 'shooting',
      cp: 1,
    );

    test('once-per-phase frees up in the next phase and the next round', () {
      final state = after([const AdjustCp(5), play]);

      String? reasonIn(String phase, {int? round}) => book
          .forPhase(phase,
              state: round == null
                  ? state
                  : BattleLog(events: [
                      const AdjustCp(5),
                      play,
                      SetRound(round),
                    ]).state)
          .firstWhere((r) => r.id == 'phasely')
          .blockedReason;

      expect(reasonIn('shooting'), 'already used this phase');
      expect(reasonIn('fight'), isNull, reason: 'a different phase');
      expect(reasonIn('shooting', round: 2), isNull,
          reason: 'a different round');
    });

    test('once-per-turn and once-per-battle outlive the phase', () {
      final state = after([
        const AdjustCp(9),
        const UseStratagem(
            stratagemId: 'turnly', round: 1, phase: 'shooting', cp: 1),
        const UseStratagem(
            stratagemId: 'battlely', round: 1, phase: 'shooting', cp: 1),
        SetRound(2),
      ]);

      Map<String, String?> reasons(String phase) => {
            for (final r in book.forPhase(phase, state: state))
              r.id: r.blockedReason,
          };

      // Round 2 releases the per-turn one and not the per-battle one.
      expect(reasons('shooting')['turnly'], isNull);
      expect(reasons('shooting')['battlely'], 'already used this battle');
      expect(reasons('fight')['battlely'], 'already used this battle');
    });

    test('spending CP is the log talking, not the widget', () {
      final state = after([const AdjustCp(3), play]);
      expect(state.cp, 2);
      expect(state.stratagemsUsed.single.stratagemId, 'phasely');
    });
  });

  group('scoping to the roster', () {
    test("another detachment's stratagems are not in the book", () {
      final roster = Roster(
        name: 'test',
        factionId: 'tau-empire',
        battleSizeId: 'strike-force',
        detachments: const [RosterDetachment(detachmentId: 'kauyon')],
        units: const [],
      );
      final book = StratagemBook.forRoster(
        roster,
        all: [
          _stratagem(id: 'core-one'),
          _stratagem(id: 'kauyon-one', detachmentId: 'kauyon'),
          _stratagem(id: 'montka-one', detachmentId: 'montka'),
        ],
      );
      expect(book.stratagems.map((s) => s.id),
          containsAll(['core-one', 'kauyon-one']));
      expect(book.stratagems.map((s) => s.id), isNot(contains('montka-one')));
    });
  });

  group('targets', () {
    final available = snapshotAvailable;

    late Dataset dataset;
    late Roster roster;

    setUpAll(() {
      if (!available) return;
      dataset = Dataset.of(
        correctedLoader().loadFaction('tau-empire'),
        revision: 'test',
      );
      roster = Roster.fromJson(jsonDecode(
          File('test/fixtures/tau_strike_force_2000.json').readAsStringSync()));
    });

    test('a keyword restriction disqualifies with its reason', () {
      // EPIC CHALLENGE is CHARACTER-only. Every combat unit is still listed,
      // because a unit missing from the picker reads as a bug.
      const book = StratagemBook(stratagems: []);
      final epicChallenge = _stratagem(
        id: 'epic-challenge',
        restrictions: {
          'required_keywords': ['Character'],
        },
      );

      final targets = book.targetsFor(
        epicChallenge,
        roster: roster,
        catalogue: dataset,
        phase: 'fight',
      );

      expect(targets, hasLength(roster.combatUnits().length));
      final characters = targets.where((t) => t.eligible).toList();
      expect(characters, isNotEmpty, reason: 'the list has Commanders');
      for (final target in characters) {
        final group = roster
            .combatUnits()
            .firstWhere((g) => g.first.instanceId == target.instanceId);
        expect(
          group.any((u) =>
              dataset.unit(u.datasheetId)?.hasKeyword('Character') ?? false),
          isTrue,
          reason: target.label,
        );
      }
      expect(
        targets
            .firstWhere((t) => t.label.startsWith('Broadside'))
            .blockedReason,
        'not Character',
      );
    }, skip: available ? null : 'no snapshot');

    test('one stratagem per unit per phase, with the reason shown', () {
      const book = StratagemBook(stratagems: []);
      final anyUnit = _stratagem(id: 'any');
      final state = BattleLog(events: const [
        AdjustCp(5),
        UseStratagem(
          stratagemId: 'any',
          targetInstanceId: 'u01',
          round: 1,
          phase: 'shooting',
          cp: 1,
        ),
      ]).state;

      String? reasonFor(String phase) => book
          .targetsFor(anyUnit,
              roster: roster, catalogue: dataset, phase: phase, state: state)
          .firstWhere((t) => t.instanceId == 'u01')
          .blockedReason;

      expect(reasonFor('shooting'), 'already used a Stratagem this phase');
      expect(reasonFor('fight'), isNull, reason: 'the rule is per phase');
    }, skip: available ? null : 'no snapshot');
  });

  group('the reference army', () {
    final available = snapshotAvailable;

    test('carries core plus both detachments, and nothing else', () {
      final faction = correctedLoader().loadFaction('tau-empire');
      final core = correctedLoader().loadCore();
      final dataset = Dataset.of(faction, revision: 'test');
      final roster = Roster.fromJson(jsonDecode(
          File('test/fixtures/tau_strike_force_2000.json').readAsStringSync()));

      final book = StratagemBook.forRoster(
        roster,
        all: [...core.coreStratagems, ...faction.stratagems],
        catalogue: dataset,
      );

      final sources = {for (final s in book.stratagems) s.detachmentId};
      expect(sources, {
        null,
        'advanced-acquisition-cadre',
        'experimental-prototype-cadre',
      });

      // Every phase of the turn page has something to offer.
      for (final phase in [
        'command',
        'movement',
        'shooting',
        'charge',
        'fight'
      ]) {
        expect(
            book.forPhase(phase, state: const BattleState(cp: 3)), isNotEmpty,
            reason: phase);
      }

      // And the source is named, because at two detachments half the list is
      // not the half you are reading.
      final shooting =
          book.forPhase('shooting', state: const BattleState(cp: 3));
      expect(shooting.map((s) => s.source),
          contains('Experimental Prototype Cadre'));
    }, skip: available ? null : 'no snapshot');
  });

  group('stratagems carry their printed text', () {
    test('nearly all of them do, and it reads as a card', () {
      // This was the last surface showing a name and a cost and nothing about
      // what the thing does: 2,236 stratagems, none with text (§3.12).
      final root = Directory(snapshotDir.path);
      if (!root.existsSync()) return;
      final loader = DatasetLoader(snapshotDir.path,
          corrections: DatasetLoader.correctionsAt(correctionsPath));

      var total = 0, withText = 0;
      for (final factionId in loader.availableFactions()) {
        for (final s in loader.loadFaction(factionId).stratagems) {
          total++;
          if ((s.text ?? '').trim().isNotEmpty) withText++;
        }
      }
      expect(total, greaterThan(2000));
      // 2,130 of 2,246 (95%). It was 85% until the name key stopped keeping
      // punctuation — `FOOL’S FLIGHT` never met Wahapedia's `FOOLS’ FLIGHT` —
      // and until the pass visited factions BSData does not ship, which is
      // where Crimson Fists' 66 were hiding. The 116 left are absent upstream:
      // 112 have no row at all and 4 have one Wahapedia left blank.
      expect(withText / total, greaterThan(0.92),
          reason: '$withText of $total carry text');
    });

    test('the markup is the one the app renders', () {
      // Wahapedia marks keywords with `<b>`; the app reads `**`. A tag
      // reaching a screen shows as a literal `<b>` mid-sentence (§3.10).
      final root = Directory(snapshotDir.path);
      if (!root.existsSync()) return;
      final loader = DatasetLoader(snapshotDir.path,
          corrections: DatasetLoader.correctionsAt(correctionsPath));

      for (final factionId in loader.availableFactions()) {
        for (final s in loader.loadFaction(factionId).stratagems) {
          final text = s.text;
          if (text == null) continue;
          expect(text, isNot(contains('<b>')), reason: s.id);
          expect(text, isNot(contains('<br')), reason: s.id);
          expect('**'.allMatches(text).length.isEven, isTrue,
              reason: '${s.id}: unbalanced emphasis');
        }
      }
    });

    test('a list of conditions stays a list', () {
      // COMMAND RE-ROLL names eight kinds of roll, and Wahapedia writes them
      // as `<ul><li>`. Stripping the tags ran them together into
      // `**Advance roll****Charge roll****Damage roll**` — every word still
      // there, the shape of the rule gone. A bullet belongs at the start of
      // its own line or it is not doing its job.
      final root = Directory(snapshotDir.path);
      if (!root.existsSync()) return;
      final loader = DatasetLoader(snapshotDir.path,
          corrections: DatasetLoader.correctionsAt(correctionsPath));

      var withBullets = 0;
      for (final factionId in loader.availableFactions()) {
        for (final s in loader.loadFaction(factionId).stratagems) {
          final text = s.text;
          if (text == null) continue;
          expect(text, isNot(contains('****')),
              reason: '${s.id}: run-together emphasis, usually a lost list');
          if (!text.contains('\u2022 ')) continue;
          withBullets++;
          for (final line in text.split('\n')) {
            expect('\u2022 '.allMatches(line), hasLength(lessThan(2)),
                reason: '${s.id}: two bullets on one line');
          }
        }
      }
      // 47 of them at the time of writing; the check is that lists survive
      // the pipeline at all, so the bound is loose.
      expect(withBullets, greaterThan(30),
          reason: 'bulleted stratagems exist; $withBullets found');
    });
  });
}
