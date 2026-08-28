/// Everything that can happen in a game (DESIGN.md §7.4).
///
/// State is **derived from the log**, never mutated in place. Mid-game
/// mistakes are constant — a wrong casualty, a stratagem on the wrong unit —
/// so undo has to be a pop rather than an inverse operation per event type.
/// It also means a finished game can be replayed for a summary at no extra
/// cost.
library;

import '../missions/mission_setup.dart';
import '../source/json.dart';

enum Player { me, opponent }

enum UnitStatus { onBoard, reserves, destroyed }

/// Status flags set in the Movement phase that decide what a unit may do
/// later. The eligibility engine of §7.3.7 reads these.
enum UnitFlag { advanced, fellBack, remainedStationary, battleShocked }

enum ScoreKind { primary, secondary }

sealed class BattleEvent {
  const BattleEvent();

  String get type;

  Map<String, Object?> toJson();

  /// `me` unless the field says otherwise, including when it is absent —
  /// which is what a log written before sides existed means.
  static Player _side(Object? value) =>
      strOr(value, 'me') == 'opponent' ? Player.opponent : Player.me;

  static BattleEvent? fromJson(Object? value) {
    final j = asMap(value);
    return switch (strOr(j['type'], '')) {
      'round' => SetRound(intOr(j['round'], 1)),
      'turn' => SetActivePlayer(
          strOr(j['player'], 'me') == 'opponent' ? Player.opponent : Player.me),
      'cp' => AdjustCp(intOr(j['delta'], 0), side: _side(j['side'])),
      'score' => ScoreVp(
          side: _side(j['side']),
          kind: strOr(j['kind'], 'primary') == 'secondary'
              ? ScoreKind.secondary
              : ScoreKind.primary,
          round: intOr(j['round'], 1),
          vp: intOr(j['vp'], 0),
        ),
      'status' => SetUnitStatus(
          instanceId: strOr(j['unit'], ''),
          status: UnitStatus.values.firstWhere(
            (s) => s.name == strOr(j['status'], 'onBoard'),
            orElse: () => UnitStatus.onBoard,
          ),
        ),
      'models' => SetModelsRemaining(
          instanceId: strOr(j['unit'], ''),
          models: intOr(j['models'], 0),
        ),
      'flag' => SetUnitFlag(
          instanceId: strOr(j['unit'], ''),
          flag: UnitFlag.values.firstWhere(
            (f) => f.name == strOr(j['flag'], 'advanced'),
            orElse: () => UnitFlag.advanced,
          ),
          value: j['value'] == true,
        ),
      'stratagem' => UseStratagem(
          stratagemId: strOr(j['stratagem'], ''),
          targetInstanceId: str(j['unit']),
          round: intOr(j['round'], 1),
          phase: strOr(j['phase'], 'command'),
          cp: intOr(j['cp'], 0),
        ),
      'oncePerBattle' => UseOncePerBattle(
          instanceId: strOr(j['unit'], ''),
          abilityId: strOr(j['ability'], ''),
        ),
      'endTurn' => const EndTurn(),
      'setup' => ConfigureBattle(MissionSetup.fromJson(j['setup'])),
      'drawSecondary' =>
        DrawSecondary(strOr(j['card'], ''), side: _side(j['side'])),
      'unscoreSecondary' => UnscoreSecondary(
          cardId: strOr(j['card'], ''),
          vp: intOr(j['vp'], 0),
          round: intOr(j['round'], 1),
          side: _side(j['side']),
        ),
      'redrawSecondary' => RedrawSecondary(
          strOr(j['card'], ''),
          side: _side(j['side']),
        ),
      'discardSecondary' => DiscardSecondary(
          strOr(j['card'], ''),
          side: _side(j['side']),
          forCp: j['forCp'] == true,
        ),
      'scoreSecondary' => ScoreSecondaryCard(
          cardId: strOr(j['card'], ''),
          round: intOr(j['round'], 1),
          vp: intOr(j['vp'], 0),
          side: _side(j['side']),
        ),
      _ => null,
    };
  }
}

class SetRound extends BattleEvent {
  final int round;

  const SetRound(this.round);

  @override
  String get type => 'round';

  @override
  Map<String, Object?> toJson() => {'type': type, 'round': round};
}

class SetActivePlayer extends BattleEvent {
  final Player player;

  const SetActivePlayer(this.player);

  @override
  String get type => 'turn';

  @override
  Map<String, Object?> toJson() => {'type': type, 'player': player.name};
}

/// The active player hands over (DESIGN.md §7.3.13).
///
/// One event rather than three, because ending a turn is one act at the table
/// and was three taps in the app: switch the player, remember the round moved
/// when it came back round, and remember the command point. All of that is
/// derived from this now, so the log reads as a game rather than as
/// bookkeeping, and nothing is forgotten because it was a separate control.
class EndTurn extends BattleEvent {
  const EndTurn();

  @override
  String get type => 'endTurn';

  @override
  Map<String, Object?> toJson() => {'type': type};
}

/// A command point gained or spent.
///
/// Carries a side since 2026-08-24: the opponent's points are tracked too, and
/// a log written before that means mine, which is what the absent field reads
/// as (§7.3.21).
class AdjustCp extends BattleEvent {
  final int delta;
  final Player side;

  const AdjustCp(this.delta, {this.side = Player.me});

  @override
  String get type => 'cp';

  @override
  Map<String, Object?> toJson() =>
      {'type': type, 'delta': delta, 'side': side.name};
}

class ScoreVp extends BattleEvent {
  final Player side;
  final ScoreKind kind;
  final int round;
  final int vp;

  const ScoreVp({
    required this.side,
    required this.kind,
    required this.round,
    required this.vp,
  });

  @override
  String get type => 'score';

  @override
  Map<String, Object?> toJson() => {
        'type': type,
        'side': side.name,
        'kind': kind.name,
        'round': round,
        'vp': vp,
      };
}

class SetUnitStatus extends BattleEvent {
  final String instanceId;
  final UnitStatus status;

  const SetUnitStatus({required this.instanceId, required this.status});

  @override
  String get type => 'status';

  @override
  Map<String, Object?> toJson() =>
      {'type': type, 'unit': instanceId, 'status': status.name};
}

class SetModelsRemaining extends BattleEvent {
  final String instanceId;
  final int models;

  const SetModelsRemaining({required this.instanceId, required this.models});

  @override
  String get type => 'models';

  @override
  Map<String, Object?> toJson() =>
      {'type': type, 'unit': instanceId, 'models': models};
}

class SetUnitFlag extends BattleEvent {
  final String instanceId;
  final UnitFlag flag;
  final bool value;

  const SetUnitFlag({
    required this.instanceId,
    required this.flag,
    required this.value,
  });

  @override
  String get type => 'flag';

  @override
  Map<String, Object?> toJson() =>
      {'type': type, 'unit': instanceId, 'flag': flag.name, 'value': value};
}

/// Records both the CP spend and the fact that this unit has now used a
/// stratagem in this round and phase — which is what 11e's one-per-phase rule
/// is checked against (§4.4).
class UseStratagem extends BattleEvent {
  final String stratagemId;
  final String? targetInstanceId;
  final int round;
  final String phase;
  final int cp;

  const UseStratagem({
    required this.stratagemId,
    required this.round,
    required this.phase,
    required this.cp,
    this.targetInstanceId,
  });

  @override
  String get type => 'stratagem';

  @override
  Map<String, Object?> toJson() => {
        'type': type,
        'stratagem': stratagemId,
        if (targetInstanceId != null) 'unit': targetInstanceId,
        'round': round,
        'phase': phase,
        'cp': cp,
      };
}

class UseOncePerBattle extends BattleEvent {
  final String instanceId;
  final String abilityId;

  const UseOncePerBattle({required this.instanceId, required this.abilityId});

  @override
  String get type => 'oncePerBattle';

  @override
  Map<String, Object?> toJson() =>
      {'type': type, 'unit': instanceId, 'ability': abilityId};
}

/// Card events carry the side that holds the card.
///
/// They did not until 2026-08-24, when the opponent gained a hand of their own
/// (§7.3.16). `side` defaults to [Player.me] so a log written before that
/// replays to the same state it always did — the absent field reads as "mine",
/// which is what it meant.
class DrawSecondary extends BattleEvent {
  final String cardId;
  final Player side;

  const DrawSecondary(this.cardId, {this.side = Player.me});

  @override
  String get type => 'drawSecondary';

  @override
  Map<String, Object?> toJson() =>
      {'type': type, 'card': cardId, 'side': side.name};
}

class DiscardSecondary extends BattleEvent {
  final String cardId;
  final Player side;

  /// Traded for a command point rather than simply binned.
  ///
  /// One card per battle round, and the record says which it was: "discarded"
  /// and "discarded for CP" are different decisions, and a CP that appeared
  /// with no reason attached is the kind of thing an opponent asks about.
  final bool forCp;

  const DiscardSecondary(this.cardId,
      {this.side = Player.me, this.forCp = false});

  @override
  String get type => 'discardSecondary';

  @override
  Map<String, Object?> toJson() => {
        'type': type,
        'card': cardId,
        'side': side.name,
        if (forCp) 'forCp': true,
      };
}

/// A command point spent to swap one secondary for a fresh one (§7.3.26).
///
/// Once per battle, at the end of the Command phase. Its own event rather
/// than a flag on [DiscardSecondary], because it is a different decision with
/// a different cost — a plain discard *gains* a point at the end of the turn,
/// this one *spends* one — and a log that cannot tell them apart cannot
/// answer where the points went.
class RedrawSecondary extends BattleEvent {
  final String cardId;
  final Player side;

  const RedrawSecondary(this.cardId, {this.side = Player.me});

  @override
  String get type => 'redrawSecondary';

  @override
  Map<String, Object?> toJson() =>
      {'type': 'redrawSecondary', 'card': cardId, 'side': side.name};
}

/// Taking back a secondary that was scored (§7.3.29).
///
/// Its own event, and it carries the figures rather than looking them up:
/// what to subtract and which round's tally it came from. The state knows
/// what a card scored but not when, and a correction that guessed the round
/// would move points between rounds — which is the one thing the per-round
/// table exists to get right.
class UnscoreSecondary extends BattleEvent {
  final String cardId;
  final Player side;

  /// What the card was credited, and the round it was credited in.
  final int vp;
  final int round;

  const UnscoreSecondary({
    required this.cardId,
    required this.vp,
    required this.round,
    this.side = Player.me,
  });

  @override
  String get type => 'unscoreSecondary';

  @override
  Map<String, Object?> toJson() => {
        'type': 'unscoreSecondary',
        'card': cardId,
        'vp': vp,
        'round': round,
        'side': side.name,
      };
}

class ScoreSecondaryCard extends BattleEvent {
  final String cardId;
  final int round;
  final int vp;
  final Player side;

  const ScoreSecondaryCard({
    required this.cardId,
    required this.round,
    required this.vp,
    this.side = Player.me,
  });

  @override
  String get type => 'scoreSecondary';

  @override
  Map<String, Object?> toJson() => {
        'type': type,
        'card': cardId,
        'round': round,
        'vp': vp,
        'side': side.name,
      };
}

/// The completed setup wizard, recorded as a single event so it persists,
/// replays and undoes with everything else (DESIGN.md §7.3.1).
class ConfigureBattle extends BattleEvent {
  final MissionSetup setup;

  const ConfigureBattle(this.setup);

  @override
  String get type => 'setup';

  @override
  Map<String, Object?> toJson() => {'type': type, 'setup': setup.toJson()};
}
