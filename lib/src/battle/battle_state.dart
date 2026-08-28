/// Game state, derived from an event log (DESIGN.md §7.4).
///
/// Two decisions carry most of the weight here.
///
/// **There is no `phase`.** Phase is where the player is scrolled, not state
/// they maintain (§7.2). Six taps a turn to advance a state machine is rent
/// charged for something the player already knows. Only round and active
/// player are tracked, changing five and ten times a game respectively.
///
/// **The round is derived from the turns, not stepped.** A battle round is
/// both players having taken a turn, so it advances when the turn returns to
/// whoever opened — which the setup records, since the opener is decided at
/// the table rather than implied by attacker/defender. `SetRound` remains as
/// the override for when the app and the table disagree.
///
/// **`stratagemsUsed` stores `{round, phase}` per use** rather than a
/// "this phase" list that gets cleared on transition. With no transition there
/// is nothing to clear, so the one-per-phase rule becomes a query against
/// whichever phase the player is reading. Lists that reset on transition are
/// exactly where "why is this unit still greyed out" bugs live.
library;

import '../missions/mission_setup.dart';
import 'battle_event.dart';

/// A stratagem use, remembered with enough context to answer the rule.
class StratagemUse {
  final String stratagemId;
  final String? targetInstanceId;
  final int round;
  final String phase;
  final int cp;

  const StratagemUse({
    required this.stratagemId,
    required this.round,
    required this.phase,
    required this.cp,
    this.targetInstanceId,
  });
}

class UnitState {
  final UnitStatus status;

  /// Null until the player records a casualty; the weapon table then falls
  /// back to full strength rather than guessing (§7.3.5).
  final int? modelsRemaining;

  final Set<UnitFlag> flags;
  final Set<String> oncePerBattleUsed;

  const UnitState({
    this.status = UnitStatus.onBoard,
    this.modelsRemaining,
    this.flags = const {},
    this.oncePerBattleUsed = const {},
  });

  UnitState copyWith({
    UnitStatus? status,
    int? modelsRemaining,
    Set<UnitFlag>? flags,
    Set<String>? oncePerBattleUsed,
  }) =>
      UnitState(
        status: status ?? this.status,
        modelsRemaining: modelsRemaining ?? this.modelsRemaining,
        flags: flags ?? this.flags,
        oncePerBattleUsed: oncePerBattleUsed ?? this.oncePerBattleUsed,
      );

  bool get isDestroyed => status == UnitStatus.destroyed;
  bool get isInReserves => status == UnitStatus.reserves;
  bool has(UnitFlag flag) => flags.contains(flag);
}

/// Victory points for one side, kept per round so caps can be applied and a
/// round-by-round breakdown shown.
class SideScore {
  final Map<int, int> primary;
  final Map<int, int> secondary;

  /// The caps the published rules put on each source (§7.3.26). Applied to
  /// the totals rather than to the entries: the log records what the player
  /// said happened, and the rules say points in excess of the maximum are
  /// *ignored*, not that they cannot be scored.
  final ScoreCaps primaryCaps;
  final ScoreCaps secondaryCaps;

  const SideScore({
    this.primary = const {},
    this.secondary = const {},
    this.primaryCaps = const ScoreCaps(),
    this.secondaryCaps = const ScoreCaps(),
  });

  /// The tables are capped as they are built, so these are plain sums and a
  /// round's figure and the total always agree.
  int get primaryTotal => primary.values.fold(0, (a, b) => a + b);
  int get secondaryTotal => secondary.values.fold(0, (a, b) => a + b);
  int get total => primaryTotal + secondaryTotal;

  /// Points still available this round from one source, or null when
  /// uncapped. The board shows it as `3 of 15 left` so a player who scores
  /// into a cap can see why the number stopped moving (§7.3.26).
  int? headroom(int round, {required bool primaryKind}) {
    final caps = primaryKind ? primaryCaps : secondaryCaps;
    if (caps.perRound >= 1 << 29) return null;
    final table = primaryKind ? primary : secondary;
    return (caps.perRound - (table[round] ?? 0)).clamp(0, caps.perRound);
  }

  /// Points still available for the whole battle, or null when uncapped.
  int? remaining({required bool primaryKind}) {
    final caps = primaryKind ? primaryCaps : secondaryCaps;
    if (caps.perGame >= 1 << 29) return null;
    final scored = primaryKind ? primaryTotal : secondaryTotal;
    return (caps.perGame - scored).clamp(0, caps.perGame);
  }
}

/// Round and game caps on victory points. Defaults are the secondary caps of
/// §7.3.2; a mission supplies its own for the primary.
class ScoreCaps {
  final int perRound;
  final int perGame;

  /// The most one card may ever contribute. Only Fixed Secondary Missions
  /// have one — 20VP each — because a Fixed card stays on the table all
  /// battle and would otherwise have no ceiling of its own (§7.3.26).
  final int perCard;

  const ScoreCaps({
    this.perRound = 15,
    this.perGame = 45,
    this.perCard = 1 << 30,
  });

  static const none =
      ScoreCaps(perRound: 1 << 30, perGame: 1 << 30, perCard: 1 << 30);

  /// What the published rules put on Fixed Secondary Missions.
  static const fixedSecondary = ScoreCaps(perCard: 20);
}

class SecondaryState {
  /// Cards drawn at any point, so a re-draw cannot repeat one.
  final Set<String> used;

  /// Held and not yet scored.
  final List<String> hand;

  final Map<String, int> scored;
  final List<String> discarded;

  const SecondaryState({
    this.used = const {},
    this.hand = const [],
    this.scored = const {},
    this.discarded = const [],
  });
}

class BattleState {
  /// Null until the setup wizard completes. The battle screen is only reached
  /// once it is set (§7.3.1).
  final MissionSetup? setup;

  final int round;
  final Player activePlayer;
  final int cp;

  /// Their command points, tracked the same way and by the same rules — a
  /// Command phase grants one, spending takes one (§7.3.21). Entered rather
  /// than known: the app cannot see their hand any more than their table.
  final int opponentCp;

  final SideScore me;
  final SideScore opponent;
  final Map<String, UnitState> units;
  final List<StratagemUse> stratagemsUsed;

  /// One hand per side. The opponent got one on 2026-08-24 (§7.3.16); before
  /// that only [Player.me] had cards and the field was a single state.
  final Map<Player, SecondaryState> hands;

  /// Turns in which a side has already taken the command point for
  /// discarding secondaries, by side (§7.3.26).
  ///
  /// Superseded, 2026-08-27: this was one trade per *battle round*, shared.
  /// The published sequence puts it at the end of **your** turn, one or more
  /// cards discarded together for a single point, so the allowance is per
  /// side and per turn — and a turn, not a round, is what refreshes it.
  final Map<Player, Set<int>> cpTradedTurns;

  /// Sides that have spent the once-per-battle command point to swap a
  /// secondary for a fresh one.
  final Set<Player> redrawUsed;

  /// Turns taken so far. The trade allowance is keyed on it.
  final int turn;

  /// This player's hand — what almost every caller wants.
  SecondaryState get secondaries => hands[Player.me] ?? const SecondaryState();

  SecondaryState secondariesOf(Player side) =>
      hands[side] ?? const SecondaryState();

  const BattleState({
    this.setup,
    this.round = 1,
    this.activePlayer = Player.me,
    this.cp = 0,
    this.opponentCp = 0,
    this.me = const SideScore(),
    this.opponent = const SideScore(),
    this.units = const {},
    this.stratagemsUsed = const [],
    this.hands = const {},
    this.cpTradedTurns = const {},
    this.redrawUsed = const {},
    this.turn = 1,
  });

  /// Whether this side is playing Fixed Secondary Missions, which is decided
  /// at setup and changes almost every rule about them: a Fixed card cannot
  /// be discarded, is not spent by achieving it, and caps at 20VP.
  bool get isFixed =>
      (setup?.secondaryMode ?? SecondaryMode.tactical) == SecondaryMode.fixed;

  /// May this side take the command point for discarding now? (§7.3.26)
  ///
  /// Never on Fixed, where the cards cannot be discarded at all; otherwise
  /// once per that side's turn.
  bool canTradeForCp(Player side) =>
      !isFixed && !(cpTradedTurns[side] ?? const {}).contains(turn);

  /// May this side still spend a command point to swap a card? Once per
  /// battle, and never on Fixed.
  bool canRedraw(Player side) => !isFixed && !redrawUsed.contains(side);

  UnitState unit(String instanceId) => units[instanceId] ?? const UnitState();

  /// Whoever takes the first turn of each battle round.
  Player get opener => (setup?.iGoFirst ?? true) ? Player.me : Player.opponent;

  Player get nextPlayer =>
      activePlayer == Player.me ? Player.opponent : Player.me;

  /// True when passing the turn completes the round and advances it. The
  /// header says so before the tap, because a number that moves on its own is
  /// alarming unless it was announced.
  bool get passingEndsRound => nextPlayer == opener && round < 5;

  /// The one-per-phase rule as a **query**, not a lifecycle (§4.4).
  bool hasUsedStratagem(String instanceId,
      {required String phase, int? round}) {
    final r = round ?? this.round;
    return stratagemsUsed.any((u) =>
        u.targetInstanceId == instanceId && u.round == r && u.phase == phase);
  }

  /// Stratagems played this round and phase, whoever they targeted.
  List<StratagemUse> usesIn({required String phase, int? round}) {
    final r = round ?? this.round;
    return stratagemsUsed
        .where((u) => u.round == r && u.phase == phase)
        .toList();
  }

  /// Model counts the weapon aggregator reads, omitting units at full strength
  /// so it uses the roster figure rather than a recorded one.
  Map<String, int> get modelsRemaining => {
        for (final entry in units.entries)
          if (entry.value.modelsRemaining != null)
            entry.key: entry.value.modelsRemaining!,
      };
}

/// One event, placed in the game it happened in (DESIGN.md §7.3.15).
///
/// Most events do not carry a round: drawing a card or losing a model is
/// recorded as it happens and takes its place from the events before it. So
/// the timeline is a replay, exactly as [BattleState] is — the alternative,
/// stamping every event with a round at the point it is created, puts a
/// derived value in the log and makes an undo able to leave it wrong.
class LogEntry {
  final int round;

  /// Turns taken when this event was logged, counted the way [BattleState]
  /// counts them so the two never disagree about which turn a score belongs
  /// to (§7.3.29).
  final int turn;

  final Player activePlayer;
  final BattleEvent event;

  /// Position in the log, so a reader can be pointed at one entry.
  final int index;

  const LogEntry({
    required this.round,
    required this.turn,
    required this.activePlayer,
    required this.event,
    required this.index,
  });
}

/// Applies an event log to produce state. Pure, so undo is a shorter log.
class BattleLog {
  final List<BattleEvent> events;
  final ScoreCaps secondaryCaps;

  /// The primary's caps, which the published rules make the same as the
  /// secondary's: 45 over the battle, 15 in any one round (§7.3.26).
  final ScoreCaps primaryCaps;

  const BattleLog({
    this.events = const [],
    this.secondaryCaps = const ScoreCaps(),
    this.primaryCaps = const ScoreCaps(),
  });

  BattleLog add(BattleEvent event) => BattleLog(
        events: [...events, event],
        secondaryCaps: secondaryCaps,
        primaryCaps: primaryCaps,
      );

  /// Undo. A pop, because state is derived rather than mutated.
  BattleLog undo() => events.isEmpty
      ? this
      : BattleLog(
          events: events.sublist(0, events.length - 1),
          secondaryCaps: secondaryCaps,
          primaryCaps: primaryCaps,
        );

  bool get canUndo => events.isNotEmpty;

  /// Everything one turn put on the board, in the order it was entered
  /// (§7.3.29).
  ///
  /// The end-of-turn review is the only place a player sees a turn's scoring
  /// together, and correcting it is the point: a card scored twice, a primary
  /// entered against the wrong side, a figure counted before the last unit
  /// died. Corrections are appended rather than cut out of the log — the
  /// events are deltas, so taking something back is another delta and undo
  /// still works one pop at a time.
  List<LogEntry> scoringIn(int turn) => [
        for (final entry in timeline)
          if (entry.turn == turn &&
              (entry.event is ScoreVp ||
                  entry.event is ScoreSecondaryCard ||
                  entry.event is UnscoreSecondary))
            entry,
      ];

  List<Map<String, Object?>> toJson() =>
      [for (final event in events) event.toJson()];

  static BattleLog fromJson(
    Object? value, {
    ScoreCaps secondaryCaps = const ScoreCaps(),
  }) {
    final list = value is List ? value : const [];
    return BattleLog(
      events: [
        for (final raw in list)
          if (BattleEvent.fromJson(raw) case final event?) event,
      ],
      secondaryCaps: secondaryCaps,
    );
  }

  /// Every event with the round and turn it belongs to.
  ///
  /// The round and turn rules here must agree with [state]; the two walk the
  /// same events and a test asserts the last entry's round matches.
  List<LogEntry> get timeline {
    MissionSetup? setup;
    var round = 1;
    var turn = 1;
    var activePlayer = Player.me;
    final out = <LogEntry>[];

    for (final (index, event) in events.indexed) {
      switch (event) {
        case final ConfigureBattle e:
          setup = e.setup;
          activePlayer = e.setup.iGoFirst ? Player.me : Player.opponent;
        case EndTurn():
          final opener =
              (setup?.iGoFirst ?? true) ? Player.me : Player.opponent;
          final next = activePlayer == Player.me ? Player.opponent : Player.me;
          if (next == opener && round < 5) round++;
          activePlayer = next;
          turn++;
        case final SetRound e:
          round = e.round;
        case final SetActivePlayer e:
          final opener =
              (setup?.iGoFirst ?? true) ? Player.me : Player.opponent;
          if (e.player != activePlayer && e.player == opener && round < 5) {
            round++;
          }
          activePlayer = e.player;
        default:
          break;
      }
      out.add(LogEntry(
        round: round,
        turn: turn,
        activePlayer: activePlayer,
        event: event,
        index: index,
      ));
    }
    return out;
  }

  BattleState get state {
    MissionSetup? setup;
    var round = 1;
    var activePlayer = Player.me;
    var cp = 0;
    var opponentCp = 0;
    final primary = {Player.me: <int, int>{}, Player.opponent: <int, int>{}};
    final secondary = {Player.me: <int, int>{}, Player.opponent: <int, int>{}};
    final units = <String, UnitState>{};
    final uses = <StratagemUse>[];

    // A pair of everything: the decks are copies, so both sides can hold the
    // same card and each side's "already seen" is its own.
    final cpTraded = {for (final p in Player.values) p: <int>{}};
    final redrawUsed = <Player>{};
    var turn = 1;
    final secondaryUsed = {for (final p in Player.values) p: <String>{}};
    final hand = {for (final p in Player.values) p: <String>[]};
    final scoredCards = {for (final p in Player.values) p: <String, int>{}};
    final discarded = {for (final p in Player.values) p: <String>[]};

    UnitState of(String id) => units[id] ?? const UnitState();

    for (final event in events) {
      switch (event) {
        case final ConfigureBattle e:
          setup = e.setup;
          // Who opens is a setup decision, not always the player holding the
          // phone. Before this, a game the opponent started ran a whole round
          // labelled with the wrong active player.
          activePlayer = e.setup.iGoFirst ? Player.me : Player.opponent;
          // A turn beginning grants a command point to **both** players, not
          // only the one taking it (§7.3.21). Whoever opens does not open a
          // point ahead.
          cp += 1;
          opponentCp += 1;
        case final SetRound e:
          round = e.round;
        case EndTurn():
          // Handing over is the only turn control. The round advances when
          // the turn returns to whoever opened, and both players gain a
          // command point — both derived, so an older log replays the same
          // and neither can be forgotten by a player who was concentrating on
          // the table.
          final opener =
              (setup?.iGoFirst ?? true) ? Player.me : Player.opponent;
          final next = activePlayer == Player.me ? Player.opponent : Player.me;
          if (next == opener && round < 5) round++;
          activePlayer = next;
          turn++;
          cp += 1;
          opponentCp += 1;
        case final SetActivePlayer e:
          // A battle round is both players having taken a turn, so the round
          // advances when the turn comes back round to whoever opened —
          // derived here rather than left as a stepper the player must
          // remember. `SetRound` still overrides, which is the correction path
          // when the table and the app disagree.
          final opener =
              (setup?.iGoFirst ?? true) ? Player.me : Player.opponent;
          if (e.player != activePlayer && e.player == opener && round < 5) {
            round++;
          }
          activePlayer = e.player;
        case final AdjustCp e:
          if (e.side == Player.me) {
            cp = (cp + e.delta).clamp(0, 1 << 30);
          } else {
            opponentCp = (opponentCp + e.delta).clamp(0, 1 << 30);
          }
        case final ScoreVp e:
          final table = e.kind == ScoreKind.primary
              ? primary[e.side]!
              : secondary[e.side]!;
          // A round cannot score negative. The events are deltas so that undo
          // and correction share one mechanism, but correcting an over-count
          // twice used to leave a round owing points and drag the running
          // total down with it — the same clamp [AdjustCp] already has.
          table[e.round] = ((table[e.round] ?? 0) + e.vp).clamp(0, 1 << 30);
        case final SetUnitStatus e:
          units[e.instanceId] = of(e.instanceId).copyWith(status: e.status);
        case final SetModelsRemaining e:
          units[e.instanceId] =
              of(e.instanceId).copyWith(modelsRemaining: e.models);
          if (e.models <= 0) {
            units[e.instanceId] =
                units[e.instanceId]!.copyWith(status: UnitStatus.destroyed);
          }
        case final SetUnitFlag e:
          final current = of(e.instanceId);
          units[e.instanceId] = current.copyWith(
            flags: {
              ...current.flags,
              if (e.value) e.flag,
            }..removeWhere((f) => f == e.flag && !e.value),
          );
        case final UseStratagem e:
          uses.add(StratagemUse(
            stratagemId: e.stratagemId,
            targetInstanceId: e.targetInstanceId,
            round: e.round,
            phase: e.phase,
            cp: e.cp,
          ));
          cp = (cp - e.cp).clamp(0, 1 << 30);
        case final UseOncePerBattle e:
          final current = of(e.instanceId);
          units[e.instanceId] = current.copyWith(
            oncePerBattleUsed: {...current.oncePerBattleUsed, e.abilityId},
          );
        case final DrawSecondary e:
          secondaryUsed[e.side]!.add(e.cardId);
          if (!hand[e.side]!.contains(e.cardId)) hand[e.side]!.add(e.cardId);
          // A card taken back into hand is no longer discarded. The picker
          // offers discarded cards so a mis-recorded discard can be undone
          // (§7.3.25); leaving it in both lists would show it twice.
          discarded[e.side]!.remove(e.cardId);
        case final DiscardSecondary e:
          hand[e.side]!.remove(e.cardId);
          discarded[e.side]!.add(e.cardId);
          if (e.forCp) {
            // One point for the act, however many cards went with it, and
            // once per that side's turn (§7.3.26). Recorded rather than
            // refused: the log says what happened at the table, and the
            // screens are what stop a second one being offered.
            if (cpTraded[e.side]!.add(turn)) {
              if (e.side == Player.me) {
                cp++;
              } else {
                opponentCp++;
              }
            }
          }
        case final ScoreSecondaryCard e:
          final fixed = (setup?.secondaryMode ?? SecondaryMode.tactical) ==
              SecondaryMode.fixed;
          // A Fixed mission stays on the table: achieving it is not what
          // spends it, and it caps at 20VP over the whole battle. A Tactical
          // one is discarded the moment it is achieved (§7.3.26).
          final already = scoredCards[e.side]![e.cardId] ?? 0;
          final gained =
              fixed ? e.vp.clamp(0, (20 - already).clamp(0, 20)) : e.vp;
          if (!fixed) hand[e.side]!.remove(e.cardId);
          scoredCards[e.side]![e.cardId] = already + gained;
          final table = secondary[e.side]!;
          table[e.round] = (table[e.round] ?? 0) + gained;
        case final UnscoreSecondary e:
          // Back into the hand, out of the tally. Not into the deck: the card
          // was drawn, and a correction to how it was scored is not a
          // statement that it never was.
          scoredCards[e.side]!.remove(e.cardId);
          if (!hand[e.side]!.contains(e.cardId)) hand[e.side]!.add(e.cardId);
          discarded[e.side]!.remove(e.cardId);
          final table = secondary[e.side]!;
          table[e.round] = ((table[e.round] ?? 0) - e.vp).clamp(0, 1 << 30);
        case final RedrawSecondary e:
          // Once per battle, at the end of the Command phase, a command point
          // buys one swap. The draw that follows is the player's own.
          hand[e.side]!.remove(e.cardId);
          discarded[e.side]!.add(e.cardId);
          if (redrawUsed.add(e.side)) {
            if (e.side == Player.me) {
              cp = (cp - 1).clamp(0, 1 << 30);
            } else {
              opponentCp = (opponentCp - 1).clamp(0, 1 << 30);
            }
          }
      }
    }

    return BattleState(
      setup: setup,
      round: round,
      activePlayer: activePlayer,
      cp: cp,
      opponentCp: opponentCp,
      // The primary is capped the same way and was not capped at all before
      // (§7.3.26): 45 over the battle, 15 in any one round.
      me: SideScore(
        primary: Map.unmodifiable(_capped(primary[Player.me]!, primaryCaps)),
        secondary:
            Map.unmodifiable(_capped(secondary[Player.me]!, secondaryCaps)),
        primaryCaps: primaryCaps,
        secondaryCaps: secondaryCaps,
      ),
      opponent: SideScore(
        primary:
            Map.unmodifiable(_capped(primary[Player.opponent]!, primaryCaps)),
        secondary: Map.unmodifiable(
            _capped(secondary[Player.opponent]!, secondaryCaps)),
        primaryCaps: primaryCaps,
        secondaryCaps: secondaryCaps,
      ),
      units: Map.unmodifiable(units),
      stratagemsUsed: List.unmodifiable(uses),
      cpTradedTurns: {
        for (final p in Player.values) p: Set.unmodifiable(cpTraded[p]!),
      },
      redrawUsed: Set.unmodifiable(redrawUsed),
      turn: turn,
      hands: {
        for (final p in Player.values)
          p: SecondaryState(
            used: Set.unmodifiable(secondaryUsed[p]!),
            hand: List.unmodifiable(hand[p]!),
            scored: Map.unmodifiable(scoredCards[p]!),
            discarded: List.unmodifiable(discarded[p]!),
          ),
      },
    );
  }

  /// Applies the per-round then per-game cap, in round order so an early round
  /// keeps its points and a later one is trimmed.
  Map<int, int> _capped(Map<int, int> byRound, ScoreCaps caps) {
    final rounds = byRound.keys.toList()..sort();
    final out = <int, int>{};
    var running = 0;
    for (final round in rounds) {
      var vp = byRound[round]!.clamp(0, caps.perRound);
      if (running + vp > caps.perGame) {
        vp = caps.perGame - running;
      }
      if (vp < 0) vp = 0;
      out[round] = vp;
      running += vp;
    }
    return out;
  }
}
