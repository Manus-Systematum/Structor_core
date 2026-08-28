import 'dart:convert';

import 'package:test/test.dart';
import 'package:wh40k_core/wh40k_core.dart';

BattleLog logOf(List<BattleEvent> events) => BattleLog(events: events);

void main() {
  group('the log is the state', () {
    test('an empty log is the start of a game', () {
      const empty = BattleLog();
      expect(empty.state.round, 1);
      expect(empty.state.activePlayer, Player.me);
      expect(empty.state.cp, 0);
      expect(empty.canUndo, isFalse);
    });

    test('undo is a pop, and restores the previous state exactly', () {
      final log = logOf(const [
        SetRound(2),
        AdjustCp(3),
        SetActivePlayer(Player.opponent),
      ]);
      expect(log.state.cp, 3);
      expect(log.state.activePlayer, Player.opponent);

      final undone = log.undo();
      expect(undone.state.activePlayer, Player.me);
      expect(undone.state.cp, 3, reason: 'only the last event is removed');
      expect(undone.undo().state.cp, 0);
    });

    test('undoing an empty log is a no-op rather than an error', () {
      expect(const BattleLog().undo().events, isEmpty);
    });

    test('CP never goes negative', () {
      expect(logOf(const [AdjustCp(1), AdjustCp(-5)]).state.cp, 0);
    });
  });

  group('one stratagem per unit per phase', () {
    final log = logOf(const [
      SetRound(2),
      UseStratagem(
        stratagemId: 'overwatch',
        targetInstanceId: 'u01',
        round: 2,
        phase: 'shooting',
        cp: 1,
      ),
    ]);

    test('the rule is a query against round and phase', () {
      final state = log.state;
      expect(state.hasUsedStratagem('u01', phase: 'shooting'), isTrue);
      expect(state.hasUsedStratagem('u01', phase: 'fight'), isFalse,
          reason: 'a different phase in the same round is free');
      expect(
          state.hasUsedStratagem('u01', phase: 'shooting', round: 3), isFalse,
          reason: 'a later round is free');
      expect(state.hasUsedStratagem('u02', phase: 'shooting'), isFalse,
          reason: 'the rule is per unit');
    });

    test('nothing has to be cleared when the round advances', () {
      // The bug this design avoids: a "used this phase" list that must be
      // reset on transition, and greys a unit out forever when it is not.
      final later = log.add(const SetRound(3));
      expect(later.state.hasUsedStratagem('u01', phase: 'shooting'), isFalse);
      expect(later.state.stratagemsUsed, hasLength(1),
          reason: 'the history is kept; only the query moves on');
    });

    test('spending a stratagem deducts its CP', () {
      expect(
          logOf(const [
            AdjustCp(5),
            UseStratagem(stratagemId: 's', round: 1, phase: 'command', cp: 2),
          ]).state.cp,
          3);
    });
  });

  group('units', () {
    test('casualties are recorded and feed the weapon table', () {
      final state = logOf(const [
        SetModelsRemaining(instanceId: 'u02', models: 2),
      ]).state;
      expect(state.unit('u02').modelsRemaining, 2);
      expect(state.modelsRemaining, {'u02': 2});
    });

    test('a unit at full strength is absent, not zero', () {
      // Absent means "use the roster figure"; recording a number would make
      // the aggregator scale against a guess.
      expect(const BattleLog().state.modelsRemaining, isEmpty);
      expect(const BattleLog().state.unit('u01').modelsRemaining, isNull);
    });

    test('losing the last model destroys the unit', () {
      final state =
          logOf(const [SetModelsRemaining(instanceId: 'u01', models: 0)]).state;
      expect(state.unit('u01').isDestroyed, isTrue);
    });

    test('flags set and clear', () {
      final on = logOf(const [
        SetUnitFlag(instanceId: 'u01', flag: UnitFlag.fellBack, value: true),
      ]);
      expect(on.state.unit('u01').has(UnitFlag.fellBack), isTrue);

      final off = on.add(const SetUnitFlag(
          instanceId: 'u01', flag: UnitFlag.fellBack, value: false));
      expect(off.state.unit('u01').has(UnitFlag.fellBack), isFalse);
    });

    test('once-per-battle abilities are remembered', () {
      final state = logOf(const [
        UseOncePerBattle(instanceId: 'u09', abilityId: 'homing-beacon'),
      ]).state;
      expect(state.unit('u09').oncePerBattleUsed, contains('homing-beacon'));
    });
  });

  group('scoring', () {
    test('both sides are tracked separately', () {
      final state = logOf(const [
        ScoreVp(side: Player.me, kind: ScoreKind.primary, round: 1, vp: 10),
        ScoreVp(
            side: Player.opponent, kind: ScoreKind.primary, round: 1, vp: 6),
      ]).state;
      expect(state.me.total, 10);
      expect(state.opponent.total, 6);
    });

    test('secondaries cap per round', () {
      final state = logOf(const [
        ScoreVp(side: Player.me, kind: ScoreKind.secondary, round: 1, vp: 20),
      ]).state;
      expect(state.me.secondaryTotal, 15, reason: '15 per round');
    });

    test('secondaries cap per game, trimming later rounds', () {
      final state = logOf([
        for (var round = 1; round <= 5; round++)
          ScoreVp(
              side: Player.me, kind: ScoreKind.secondary, round: round, vp: 15),
      ]).state;
      expect(state.me.secondaryTotal, 45);
      expect(state.me.secondary[1], 15, reason: 'early rounds keep theirs');
      expect(state.me.secondary[4], 0, reason: 'the cap trims later rounds');
    });

    // Superseded, 2026-08-27: the primary was uncapped here because nothing
    // the app read published its limits. The Warhammer Event Companion does
    // — 15 a round and 45 a battle, the same as the secondary (§7.3.26).
    test('primary is capped the same way the secondary is', () {
      final state = logOf(const [
        ScoreVp(side: Player.me, kind: ScoreKind.primary, round: 1, vp: 20),
      ]).state;
      expect(state.me.primaryTotal, 15);
    });

    test('a round cannot be driven below zero', () {
      // Scores are deltas so that undo and correction share one mechanism,
      // but correcting an over-count twice left the round owing points.
      final state = logOf(const [
        ScoreVp(side: Player.me, kind: ScoreKind.primary, round: 1, vp: 5),
        ScoreVp(side: Player.me, kind: ScoreKind.primary, round: 1, vp: -5),
        ScoreVp(side: Player.me, kind: ScoreKind.primary, round: 1, vp: -5),
      ]).state;
      expect(state.me.primary[1], 0);
      expect(state.me.primaryTotal, 0);
    });

    test('a corrected round does not drag the total down', () {
      final state = logOf(const [
        ScoreVp(side: Player.me, kind: ScoreKind.primary, round: 1, vp: 10),
        ScoreVp(side: Player.me, kind: ScoreKind.primary, round: 2, vp: 3),
        ScoreVp(side: Player.me, kind: ScoreKind.primary, round: 2, vp: -9),
      ]).state;
      expect(state.me.primary[2], 0, reason: 'round 2 bottoms out');
      expect(state.me.primaryTotal, 10, reason: 'round 1 is untouched');
    });

    test('a negative correction still works above zero', () {
      final state = logOf(const [
        ScoreVp(side: Player.me, kind: ScoreKind.secondary, round: 1, vp: 8),
        ScoreVp(side: Player.me, kind: ScoreKind.secondary, round: 1, vp: -3),
      ]).state;
      expect(state.me.secondary[1], 5);
    });
  });

  group('the secondary deck', () {
    test('draws accumulate in hand and are never re-drawn', () {
      final state = logOf(const [
        DrawSecondary('outflank'),
        DrawSecondary('cleanse'),
        DrawSecondary('outflank'),
      ]).state;
      expect(state.secondaries.hand, ['outflank', 'cleanse']);
      expect(state.secondaries.used, {'outflank', 'cleanse'});
    });

    test('a held card can be discarded at will', () {
      final state = logOf(const [
        DrawSecondary('plunder'),
        DiscardSecondary('plunder'),
      ]).state;
      expect(state.secondaries.hand, isEmpty);
      expect(state.secondaries.discarded, ['plunder']);
      expect(state.secondaries.used, contains('plunder'),
          reason: 'discarded is still drawn; it must not come back');
    });

    test('scoring a card removes it from hand and adds VP', () {
      final state = logOf(const [
        DrawSecondary('beacon'),
        ScoreSecondaryCard(cardId: 'beacon', round: 2, vp: 5),
      ]).state;
      expect(state.secondaries.hand, isEmpty);
      expect(state.secondaries.scored['beacon'], 5);
      expect(state.me.secondaryTotal, 5);
    });
  });

  group('the opponent has command points too', () {
    const setup = MissionSetup(
      myDisposition: 'a',
      opponentDisposition: 'b',
      myMissionId: 'm',
      opponentMissionId: 'n',
    );

    // Each turn grants a point to *both* players, not only the one taking it.
    test('a turn beginning grants one to each', () {
      final log = BattleLog(events: const [
        ConfigureBattle(setup),
        EndTurn(),
      ]);
      // Two turns have begun: mine at setup, theirs on the handover.
      expect(log.state.cp, 2);
      expect(log.state.opponentCp, 2);
    });

    test('whoever opens does not open a point ahead', () {
      final log = BattleLog(events: const [
        ConfigureBattle(MissionSetup(
          myDisposition: 'a',
          opponentDisposition: 'b',
          myMissionId: 'm',
          opponentMissionId: 'n',
          iGoFirst: false,
        )),
      ]);
      expect(log.state.opponentCp, 1);
      expect(log.state.cp, 1);
    });

    test('spending one side does not touch the other', () {
      final log = BattleLog(events: const [
        ConfigureBattle(setup),
        EndTurn(),
        AdjustCp(-1, side: Player.opponent),
      ]);
      expect(log.state.cp, 2);
      expect(log.state.opponentCp, 1);
    });

    test('neither side goes below zero', () {
      final log = BattleLog(events: const [
        AdjustCp(-5, side: Player.opponent),
        AdjustCp(-5),
      ]);
      expect(log.state.opponentCp, 0);
      expect(log.state.cp, 0);
    });

    test('their trade pays them', () {
      final log = BattleLog(events: const [
        DrawSecondary('outflank', side: Player.opponent),
        DiscardSecondary('outflank', side: Player.opponent, forCp: true),
      ]);
      expect(log.state.opponentCp, 1);
      expect(log.state.cp, 0);
    });

    test('a CP event with no side is mine, as it always was', () {
      final back = BattleEvent.fromJson({'type': 'cp', 'delta': 2});
      expect((back as AdjustCp).side, Player.me);
      expect(back.delta, 2);
    });
  });

  group('a card can be traded for a command point', () {
    // One per battle round, and the round is the unit rather than the turn:
    // passing the turn back must not refresh it (§7.3.18).
    test('trading adds a command point and spends the round', () {
      final log = BattleLog(events: const [
        DrawSecondary('outflank'),
        DiscardSecondary('outflank', forCp: true),
      ]);
      expect(log.state.cp, 1);
      expect(log.state.cpTradedTurns[Player.me], {1});
      expect(log.state.secondaries.hand, isEmpty);
      expect(log.state.secondaries.discarded, ['outflank']);
    });

    // The picker offers discarded cards so a mis-recorded discard can be
    // taken back (§7.3.25) — and a card back in hand is not still discarded.
    test('drawing a discarded card takes it out of the discard pile', () {
      final log = BattleLog(events: const [
        DrawSecondary('outflank'),
        DiscardSecondary('outflank'),
        DrawSecondary('outflank'),
      ]);
      expect(log.state.secondaries.hand, ['outflank']);
      expect(log.state.secondaries.discarded, isEmpty);
    });

    test('a plain discard is not a trade', () {
      final log = BattleLog(events: const [
        DrawSecondary('outflank'),
        DiscardSecondary('outflank'),
      ]);
      expect(log.state.cp, 0);
      expect(log.state.cpTradedTurns[Player.me], isEmpty);
    });

    test('the allowance is per round, not per turn', () {
      final log = BattleLog(events: const [
        ConfigureBattle(MissionSetup(
          myDisposition: 'a',
          opponentDisposition: 'b',
          myMissionId: 'm',
          opponentMissionId: 'n',
        )),
        DrawSecondary('outflank'),
        DiscardSecondary('outflank', forCp: true),
        EndTurn(),
      ]);
      // Their turn now, still battle round one.
      expect(log.state.round, 1);
      // Superseded, 2026-08-27: the allowance was one per battle round and
      // is now one per *your* turn (§7.3.26), so passing the turn is exactly
      // what refreshes it.
      expect(log.state.cpTradedTurns[Player.me], contains(1));
      expect(log.state.canTradeForCp(Player.me), isTrue,
          reason: 'a new turn, a new allowance');
    });

    test('their trade does not spend my command points', () {
      final log = BattleLog(events: const [
        DrawSecondary('outflank', side: Player.opponent),
        DiscardSecondary('outflank', side: Player.opponent, forCp: true),
      ]);
      expect(log.state.cp, 0, reason: 'only my CP is tracked');
      expect(log.state.secondariesOf(Player.opponent).discarded, ['outflank']);
    });

    test('the flag survives the round trip', () {
      const event = DiscardSecondary('outflank', forCp: true);
      final back = BattleEvent.fromJson(event.toJson()) as DiscardSecondary;
      expect(back.forCp, isTrue);
      expect(BattleEvent.fromJson({'type': 'discardSecondary', 'card': 'x'}),
          isA<DiscardSecondary>().having((e) => e.forCp, 'forCp', isFalse));
    });
  });

  group('the opponent has a deck of their own', () {
    // The decks are copies of the same 18 cards, so the same objective can sit
    // in both hands at once. Treating one draw as spending the other player's
    // card is a different game (§7.3.16).
    test('both sides can hold the same card', () {
      final state = logOf(const [
        DrawSecondary('outflank'),
        DrawSecondary('outflank', side: Player.opponent),
      ]).state;
      expect(state.secondariesOf(Player.me).hand, ['outflank']);
      expect(state.secondariesOf(Player.opponent).hand, ['outflank']);
    });

    test('one side drawing does not spend the other side of the deck', () {
      final state = logOf(const [
        DrawSecondary('cleanse', side: Player.opponent),
        DiscardSecondary('cleanse', side: Player.opponent),
      ]).state;
      expect(state.secondariesOf(Player.opponent).used, {'cleanse'});
      expect(state.secondaries.used, isEmpty,
          reason: 'their discard must not take the card out of my deck');
    });

    test('a scored card credits the side that held it', () {
      final state = logOf(const [
        DrawSecondary('beacon', side: Player.opponent),
        ScoreSecondaryCard(
            cardId: 'beacon', round: 2, vp: 5, side: Player.opponent),
      ]).state;
      expect(state.opponent.secondaryTotal, 5);
      expect(state.me.secondaryTotal, 0);
      expect(state.secondariesOf(Player.opponent).scored['beacon'], 5);
    });

    // Logs written before sides existed carry no `side` field at all, and a
    // saved battle in progress is exactly that.
    test('a card event with no side replays as mine', () {
      final drawn =
          BattleEvent.fromJson({'type': 'drawSecondary', 'card': 'outflank'})
              as DrawSecondary;
      final scored = BattleEvent.fromJson({
        'type': 'scoreSecondary',
        'card': 'outflank',
        'round': 1,
        'vp': 4,
      }) as ScoreSecondaryCard;
      expect(drawn.side, Player.me);
      expect(scored.side, Player.me);
    });

    test('a side survives the round trip through JSON', () {
      const event = DrawSecondary('outflank', side: Player.opponent);
      final back = BattleEvent.fromJson(event.toJson()) as DrawSecondary;
      expect(back.side, Player.opponent);
      expect(back.cardId, 'outflank');
    });
  });

  group('persistence', () {
    test('a log round trips through JSON', () {
      final original = logOf(const [
        SetRound(3),
        SetActivePlayer(Player.opponent),
        AdjustCp(4),
        UseStratagem(
          stratagemId: 'overwatch',
          targetInstanceId: 'u01',
          round: 3,
          phase: 'shooting',
          cp: 1,
        ),
        SetModelsRemaining(instanceId: 'u02', models: 2),
        SetUnitFlag(
            instanceId: 'u03', flag: UnitFlag.battleShocked, value: true),
        DrawSecondary('cleanse'),
        ScoreSecondaryCard(cardId: 'cleanse', round: 3, vp: 4),
        ScoreVp(
            side: Player.opponent, kind: ScoreKind.primary, round: 3, vp: 8),
        UseOncePerBattle(instanceId: 'u09', abilityId: 'beacon'),
      ]);

      final restored =
          BattleLog.fromJson(jsonDecode(jsonEncode(original.toJson())));

      expect(restored.events, hasLength(original.events.length));
      final a = original.state;
      final b = restored.state;
      expect(b.round, a.round);
      expect(b.activePlayer, a.activePlayer);
      expect(b.cp, a.cp);
      expect(b.me.total, a.me.total);
      expect(b.opponent.total, a.opponent.total);
      expect(b.unit('u02').modelsRemaining, 2);
      expect(b.unit('u03').has(UnitFlag.battleShocked), isTrue);
      expect(b.unit('u09').oncePerBattleUsed, contains('beacon'));
      expect(b.hasUsedStratagem('u01', phase: 'shooting'), isTrue);
    });

    test('an unrecognised event is skipped, not fatal', () {
      final log = BattleLog.fromJson([
        {'type': 'round', 'round': 4},
        {'type': 'from-a-later-version'},
      ]);
      expect(log.events, hasLength(1));
      expect(log.state.round, 4);
    });

    test('a game saved before the first-turn choice reads as "I went first"',
        () {
      // Every game played before the choice existed ran that way, so the old
      // default is the correct reading of the absent field rather than a
      // guess — and it keeps those games' rounds advancing on the right tap.
      final setup = MissionSetup.fromJson(const {
        'myDisposition': 'recon',
        'opponentDisposition': 'assault',
        'myMissionId': 'm1',
        'opponentMissionId': 'm2',
      });
      expect(setup.iGoFirst, isTrue);
    });
  });

  group('who goes first', () {
    MissionSetup setup({required bool iGoFirst}) => MissionSetup(
          myDisposition: 'recon',
          opponentDisposition: 'assault',
          myMissionId: 'm1',
          opponentMissionId: 'm2',
          iGoFirst: iGoFirst,
        );

    test('the opponent opening is the state the game starts in', () {
      final log = logOf([ConfigureBattle(setup(iGoFirst: false))]);
      expect(log.state.activePlayer, Player.opponent);
      expect(log.state.round, 1);
      expect(log.state.opener, Player.opponent);
    });

    test('and it survives a round trip', () {
      final log = logOf([ConfigureBattle(setup(iGoFirst: false))]);
      final restored = BattleLog.fromJson(jsonDecode(jsonEncode(log.toJson())));
      expect(restored.state.activePlayer, Player.opponent);
      expect(restored.state.setup?.iGoFirst, isFalse);
    });
  });

  group('ending a turn', () {
    BattleState after(List<BattleEvent> events, {bool iGoFirst = true}) =>
        BattleLog(events: [
          ConfigureBattle(MissionSetup(
            myDisposition: 'a',
            opponentDisposition: 'b',
            myMissionId: 'm',
            opponentMissionId: 'n',
            iGoFirst: iGoFirst,
          )),
          ...events,
        ]).state;

    test('the first turn grants a point to each side', () {
      // Every turn grants one to both players, so who opens does not decide
      // who is a point up.
      expect(after(const []).cp, 1);
      expect(after(const [], iGoFirst: false).cp, 1);
    });

    test('every handover grants another to each', () {
      var s = after(const [EndTurn()]);
      expect(s.activePlayer, Player.opponent);
      expect(s.cp, 2, reason: 'their turn grants you one too');
      expect(s.opponentCp, 2);

      s = after(const [EndTurn(), EndTurn()]);
      expect(s.activePlayer, Player.me);
      expect(s.cp, 3);
      expect(s.opponentCp, 3);
    });

    test('the round advances when the turn returns to the opener', () {
      expect(after(const [EndTurn()]).round, 1);
      expect(after(const [EndTurn(), EndTurn()]).round, 2);
      expect(after(const [EndTurn(), EndTurn(), EndTurn()]).round, 2);
      expect(
          after(const [EndTurn(), EndTurn(), EndTurn(), EndTurn()]).round, 3);
    });

    test('the round stops at five', () {
      final s = after(List.filled(20, const EndTurn()));
      expect(s.round, 5);
    });

    test('going second, the round turns when it returns to them', () {
      // The opponent opens, so the first handover is theirs and the round
      // cannot turn on it. It turns on yours, which passes back to the opener.
      expect(after(const [], iGoFirst: false).activePlayer, Player.opponent);
      final theirs = after(const [EndTurn()], iGoFirst: false);
      expect(theirs.activePlayer, Player.me);
      expect(theirs.round, 1, reason: 'their turn ended, yours begins');
      expect(theirs.cp, 2, reason: 'two turns have begun, each granting one');

      final mine = after(const [EndTurn(), EndTurn()], iGoFirst: false);
      expect(mine.activePlayer, Player.opponent);
      expect(mine.round, 2);
    });

    test('it round-trips through the log', () {
      final log = BattleLog(events: const [EndTurn()]);
      final back = BattleLog.fromJson(log.toJson());
      expect(back.events.single, isA<EndTurn>());
    });

    test('undo takes back the point and the round with it', () {
      final log = BattleLog(events: const [
        ConfigureBattle(MissionSetup(
            myDisposition: 'a',
            opponentDisposition: 'b',
            myMissionId: 'm',
            opponentMissionId: 'n')),
        EndTurn(),
        EndTurn(),
      ]);
      expect(log.state.round, 2);
      expect(log.state.cp, 3, reason: 'three turns have begun');
      final undone = log.undo();
      expect(undone.state.round, 1);
      expect(undone.state.cp, 2);
    });
  });

  group('the timeline places every event in its round', () {
    BattleLog gameOf(List<BattleEvent> events, {bool iGoFirst = true}) =>
        BattleLog(events: [
          ConfigureBattle(MissionSetup(
              myDisposition: 'a',
              opponentDisposition: 'b',
              myMissionId: 'm',
              opponentMissionId: 'n',
              iGoFirst: iGoFirst)),
          ...events,
        ]);

    test('an event with no round of its own takes it from the events before',
        () {
      // DrawSecondary carries no round: stamping one at creation would put a
      // derived value in the log and let an undo leave it wrong.
      final log = gameOf(const [
        DrawSecondary('a'),
        EndTurn(),
        EndTurn(),
        DrawSecondary('b'),
      ]);
      final draws =
          log.timeline.where((e) => e.event is DrawSecondary).toList();
      expect(draws.map((e) => e.round), [1, 2]);
    });

    test('it agrees with the state it is derived alongside', () {
      // The two walk the same events by the same rules; this is what catches
      // one being changed without the other.
      for (final events in [
        const <BattleEvent>[],
        const [EndTurn()],
        const [EndTurn(), EndTurn(), EndTurn()],
        const [EndTurn(), SetRound(4), EndTurn()],
        const [SetActivePlayer(Player.opponent), EndTurn()],
        List<BattleEvent>.filled(14, const EndTurn()),
      ]) {
        for (final first in [true, false]) {
          final log = gameOf(events, iGoFirst: first);
          expect(log.timeline.last.round, log.state.round,
              reason: 'round disagrees');
          expect(log.timeline.last.activePlayer, log.state.activePlayer,
              reason: 'turn disagrees');
        }
      }
    });

    test('every event is present, in order', () {
      final log = gameOf(const [
        AdjustCp(1),
        ScoreVp(side: Player.me, kind: ScoreKind.primary, round: 1, vp: 4),
        EndTurn(),
      ]);
      expect(log.timeline, hasLength(log.events.length));
      expect(log.timeline.map((e) => e.index), [0, 1, 2, 3]);
      expect(log.timeline.last.event, isA<EndTurn>());
    });

    test('an empty log has an empty timeline', () {
      expect(const BattleLog().timeline, isEmpty);
    });
  });

  group('the round advances on its own', () {
    BattleLog gameWhere({required bool iGoFirst}) => logOf([
          ConfigureBattle(MissionSetup(
            myDisposition: 'recon',
            opponentDisposition: 'assault',
            myMissionId: 'm1',
            opponentMissionId: 'm2',
            iGoFirst: iGoFirst,
          )),
        ]);

    test('a full cycle of turns is one battle round', () {
      var log = gameWhere(iGoFirst: true);
      expect(log.state.round, 1);

      // My turn ends: still round 1, because the opponent has not played.
      log = log.add(const SetActivePlayer(Player.opponent));
      expect(log.state.round, 1);

      // Theirs ends and the turn comes back to me — that is a battle round.
      log = log.add(const SetActivePlayer(Player.me));
      expect(log.state.round, 2);
      expect(log.state.activePlayer, Player.me);
    });

    test('and it counts from whoever opened, not from me', () {
      var log = gameWhere(iGoFirst: false);
      expect(log.state.activePlayer, Player.opponent);

      // Passing to me is the *first* half of round 1 here, not the end of it.
      log = log.add(const SetActivePlayer(Player.me));
      expect(log.state.round, 1,
          reason: 'the opponent opened, so my turn completes nothing');

      log = log.add(const SetActivePlayer(Player.opponent));
      expect(log.state.round, 2);
    });

    test('re-selecting the active player is not half a round', () {
      // A double tap on the toggle, or a rebuild replaying the same event.
      var log = gameWhere(iGoFirst: true)
          .add(const SetActivePlayer(Player.opponent))
          .add(const SetActivePlayer(Player.opponent));
      expect(log.state.round, 1);

      log = log.add(const SetActivePlayer(Player.me));
      expect(log.state.round, 2);
    });

    test('the game stops at five rounds rather than running on', () {
      var log = gameWhere(iGoFirst: true);
      for (var i = 0; i < 12; i++) {
        log = log.add(SetActivePlayer(
            log.state.activePlayer == Player.me ? Player.opponent : Player.me));
      }
      expect(log.state.round, 5);
    });

    test('the manual stepper still overrides, and counting resumes from it',
        () {
      // The correction path: the app and the table disagree, the player fixes
      // the number, and the automatic advance carries on from the new one
      // rather than snapping back.
      var log = gameWhere(iGoFirst: true).add(const SetRound(3));
      expect(log.state.round, 3);

      log = log
          .add(const SetActivePlayer(Player.opponent))
          .add(const SetActivePlayer(Player.me));
      expect(log.state.round, 4);
    });

    test('undo takes the round back with the turn', () {
      // The reason this is derived rather than stored: one pop puts both back,
      // with no inverse operation to get wrong.
      final log = gameWhere(iGoFirst: true)
          .add(const SetActivePlayer(Player.opponent))
          .add(const SetActivePlayer(Player.me));
      expect(log.state.round, 2);

      final undone = log.undo();
      expect(undone.state.round, 1);
      expect(undone.state.activePlayer, Player.opponent);
    });

    test('passing is announced before it is tapped', () {
      final log = gameWhere(iGoFirst: true);
      expect(log.state.passingEndsRound, isFalse,
          reason: 'my turn is the first half');

      final mid = log.add(const SetActivePlayer(Player.opponent));
      expect(mid.state.passingEndsRound, isTrue);
    });
  });

  // §7.3.26 — the published Secondary sequence, with the two corrections the
  // app keeps: one card is drawn at a time, and `Choose` stays a free
  // correction rather than a rule.
  group('the published secondary sequence', () {
    const fixed = ConfigureBattle(MissionSetup(
      myDisposition: 'a',
      opponentDisposition: 'b',
      myMissionId: 'm',
      opponentMissionId: 'n',
      secondaryMode: SecondaryMode.fixed,
    ));
    const tactical = ConfigureBattle(MissionSetup(
      myDisposition: 'a',
      opponentDisposition: 'b',
      myMissionId: 'm',
      opponentMissionId: 'n',
    ));

    test('achieving a tactical mission spends it', () {
      final log = BattleLog(events: const [
        tactical,
        DrawSecondary('outflank'),
        ScoreSecondaryCard(cardId: 'outflank', round: 1, vp: 5),
      ]);
      expect(log.state.secondaries.hand, isEmpty);
      expect(log.state.me.secondaryTotal, 5);
    });

    test('a fixed mission stays on the table and caps at 20', () {
      // It is active all battle, so achieving it is not what spends it — and
      // without a ceiling of its own it would have none.
      final log = BattleLog(events: const [
        fixed,
        DrawSecondary('marked'),
        ScoreSecondaryCard(cardId: 'marked', round: 1, vp: 12),
        ScoreSecondaryCard(cardId: 'marked', round: 2, vp: 12),
      ]);
      expect(log.state.secondaries.hand, ['marked'],
          reason: 'a fixed card is not discarded by achieving it');
      expect(log.state.secondaries.scored['marked'], 20);
      expect(log.state.me.secondaryTotal, 20);
    });

    test('a fixed mission cannot be discarded, nor traded, nor redrawn', () {
      final state = const BattleLog(events: [fixed]).state;
      expect(state.isFixed, isTrue);
      expect(state.canTradeForCp(Player.me), isFalse);
      expect(state.canRedraw(Player.me), isFalse);
    });

    test('the discard point is once per your turn, not per round', () {
      final log = BattleLog(events: const [
        tactical,
        DrawSecondary('a'),
        DrawSecondary('b'),
        DiscardSecondary('a', forCp: true),
        DiscardSecondary('b', forCp: true),
      ]);
      // One point for the act, however many cards went with it — on top of
      // the point a battle starts with.
      expect(log.state.cp, 2);
      expect(log.state.canTradeForCp(Player.me), isFalse);

      final next = log.add(const EndTurn()).add(const EndTurn());
      expect(next.state.canTradeForCp(Player.me), isTrue,
          reason: 'a new turn of mine, a new allowance');
    });

    test('the redraw spends a point, once per battle', () {
      final log = BattleLog(events: const [
        tactical,
        AdjustCp(3),
        DrawSecondary('a'),
        DrawSecondary('b'),
        RedrawSecondary('a'),
      ]);
      expect(log.state.cp, 3,
          reason: 'one to start, three added, one spent on the swap');
      expect(log.state.secondaries.hand, ['b']);
      expect(log.state.canRedraw(Player.me), isFalse);

      final again = log.add(const RedrawSecondary('b'));
      expect(again.state.cp, 3, reason: 'the second one is not paid for');
    });

    test('a round caps at 15 and the battle at 45', () {
      final log = BattleLog(events: const [
        tactical,
        ScoreVp(side: Player.me, kind: ScoreKind.primary, round: 1, vp: 20),
        ScoreVp(side: Player.me, kind: ScoreKind.primary, round: 2, vp: 15),
        ScoreVp(side: Player.me, kind: ScoreKind.primary, round: 3, vp: 15),
        ScoreVp(side: Player.me, kind: ScoreKind.primary, round: 4, vp: 15),
      ]);
      // The primary was uncapped before this; 15 a round, 45 a battle.
      expect(log.state.me.primary[1], 15);
      expect(log.state.me.primaryTotal, 45);
      expect(log.state.me.headroom(1, primaryKind: true), 0);
      expect(log.state.me.remaining(primaryKind: true), 0);
    });

    test('a redraw survives the round trip', () {
      const event = RedrawSecondary('outflank', side: Player.opponent);
      final back = BattleEvent.fromJson(event.toJson()) as RedrawSecondary;
      expect(back.cardId, 'outflank');
      expect(back.side, Player.opponent);
    });
  });

  // §7.3.29 — what a turn scored, and taking it back.
  group('a turn\'s scoring', () {
    const setup = ConfigureBattle(MissionSetup(
      myDisposition: 'a',
      opponentDisposition: 'b',
      myMissionId: 'm',
      opponentMissionId: 'n',
    ));

    test('it gathers only this turn, and both sides of it', () {
      final log = BattleLog(events: const [
        setup,
        ScoreVp(side: Player.me, kind: ScoreKind.primary, round: 1, vp: 5),
        EndTurn(),
        ScoreVp(
            side: Player.opponent, kind: ScoreKind.primary, round: 1, vp: 4),
        ScoreSecondaryCard(
            cardId: 'outflank', round: 1, vp: 3, side: Player.opponent),
      ]);
      expect(log.scoringIn(1).map((e) => e.event), [isA<ScoreVp>()]);
      expect(log.scoringIn(2).length, 2);
      expect(log.state.turn, 2);
    });

    test('the timeline and the state agree about the turn', () {
      // They walk the same events by different code, and a review that
      // disagreed with the tally would correct the wrong turn.
      final log = BattleLog(events: const [setup, EndTurn(), EndTurn()]);
      expect(log.timeline.last.turn, log.state.turn);
    });

    test('taking a secondary back returns it and subtracts its points', () {
      final log = BattleLog(events: const [
        setup,
        DrawSecondary('outflank'),
        ScoreSecondaryCard(cardId: 'outflank', round: 2, vp: 5),
      ]);
      expect(log.state.me.secondaryTotal, 5);
      expect(log.state.secondaries.hand, isEmpty);

      final back =
          log.add(const UnscoreSecondary(cardId: 'outflank', vp: 5, round: 2));
      expect(back.state.me.secondaryTotal, 0);
      expect(back.state.secondaries.hand, ['outflank'],
          reason: 'a correction is not a statement that it was never drawn');
      expect(back.state.secondaries.scored, isEmpty);
    });

    test('it subtracts from the round it was scored in', () {
      // The state knows what a card scored, not when. Guessing the round
      // would move points between rounds, which is what the table exists to
      // get right.
      final log = BattleLog(events: const [
        setup,
        ScoreVp(side: Player.me, kind: ScoreKind.secondary, round: 3, vp: 4),
        DrawSecondary('outflank'),
        ScoreSecondaryCard(cardId: 'outflank', round: 2, vp: 5),
        UnscoreSecondary(cardId: 'outflank', vp: 5, round: 2),
      ]);
      expect(log.state.me.secondary[2] ?? 0, 0);
      expect(log.state.me.secondary[3], 4, reason: 'untouched');
    });

    test('a correction is a delta, so undo still works one pop at a time', () {
      final log = BattleLog(events: const [
        setup,
        DrawSecondary('outflank'),
        ScoreSecondaryCard(cardId: 'outflank', round: 1, vp: 5),
        UnscoreSecondary(cardId: 'outflank', vp: 5, round: 1),
      ]);
      expect(log.undo().state.me.secondaryTotal, 5);
    });

    test('an unscore survives the round trip', () {
      const event = UnscoreSecondary(
          cardId: 'outflank', vp: 5, round: 2, side: Player.opponent);
      final back = BattleEvent.fromJson(event.toJson()) as UnscoreSecondary;
      expect(back.cardId, 'outflank');
      expect(back.vp, 5);
      expect(back.round, 2);
      expect(back.side, Player.opponent);
    });
  });
}
