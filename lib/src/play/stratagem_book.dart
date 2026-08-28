/// Which stratagems are playable right now, and on what (DESIGN.md §7.3).
///
/// Stratagems are the feature §7.0 called this app's differentiator, and the
/// reason it works at all is that nothing here needs the player to maintain
/// state. Phase comes from where they are scrolled (§7.2); round, active
/// player and CP are the three things already tracked; everything else is a
/// query against the event log.
///
/// The one rule this file exists to get right is that **an unplayable
/// stratagem is shown, greyed, with the reason** — never hidden. "Why can't I
/// use that" is the question a player asks mid-game, and an app that answers
/// it by omission is worse than a printed card.
library;

import '../battle/battle_event.dart';
import '../battle/battle_state.dart';
import '../roster/roster.dart';
import '../rules/catalogue.dart';
import '../source/source_models.dart';
import 'rules_renderer.dart';

/// Why a stratagem cannot be played, in the order a player would notice.
enum StratagemBlock {
  /// Not enough Command Points.
  cp,

  /// `your-turn` in the opponent's turn, or the reverse.
  turn,

  /// Its own `once-per-phase` / `-turn` / `-battle` limit is spent.
  timing,
}

class AvailableStratagem {
  final SourceStratagem stratagem;

  /// `Core`, or the detachment that brings it — which matters at two or three
  /// detachments (§4.4), where half the list is not yours to play.
  final String source;

  /// The rendered effect, when the data carries one. Most stratagems have no
  /// `ability_id` at all.
  final RenderedRule? effect;

  /// The stratagem as printed — when, target, effect, restrictions.
  ///
  /// What a player reads. [effect] is a sentence derived from structure and
  /// exists for the handful that carry one; this is the card (§3.12).
  String? get text => stratagem.text;

  /// Empty when playable.
  final Set<StratagemBlock> blocks;

  const AvailableStratagem({
    required this.stratagem,
    required this.source,
    required this.blocks,
    this.effect,
  });

  bool get playable => blocks.isEmpty;

  String get id => stratagem.id;
  String get name => stratagem.name;
  int get cpCost => stratagem.cpCost;

  /// A short phrase for the row, or null when nothing is in the way.
  String? get blockedReason {
    if (blocks.contains(StratagemBlock.timing)) {
      return switch (stratagem.timing) {
        'once-per-battle' => 'already used this battle',
        'once-per-turn' => 'already used this round',
        _ => 'already used this phase',
      };
    }
    if (blocks.contains(StratagemBlock.turn)) {
      return stratagem.playerTurn == 'opponent-turn'
          ? "opponent's turn only"
          : 'your turn only';
    }
    if (blocks.contains(StratagemBlock.cp)) return 'not enough CP';
    return null;
  }
}

/// A unit the stratagem could be played on.
class StratagemTarget {
  final String instanceId;
  final String label;

  /// Null when the unit can be nominated.
  final String? blockedReason;

  const StratagemTarget({
    required this.instanceId,
    required this.label,
    this.blockedReason,
  });

  bool get eligible => blockedReason == null;
}

class StratagemBook {
  /// Core stratagems plus those of the detachments actually taken.
  final List<SourceStratagem> stratagems;

  /// Detachment id → display name, so a row can say where it came from.
  final Map<String, String> detachmentNames;

  final SourceAbility? Function(String abilityId)? abilityLookup;

  const StratagemBook({
    required this.stratagems,
    this.detachmentNames = const {},
    this.abilityLookup,
  });

  /// The book for one army: core stratagems, plus each detachment's own.
  ///
  /// Scoping here rather than at the point of display is what stops a
  /// Retaliation Cadre stratagem appearing in a Kauyon list — the kind of
  /// wrong that only shows up when someone plays it.
  factory StratagemBook.forRoster(
    Roster roster, {
    required Iterable<SourceStratagem> all,
    Catalogue? catalogue,
  }) {
    final taken = {for (final d in roster.detachments) d.detachmentId};
    return StratagemBook(
      stratagems: [
        for (final s in all)
          if (s.detachmentId == null || taken.contains(s.detachmentId)) s,
      ],
      detachmentNames: {
        for (final id in taken)
          if (catalogue?.detachment(id)?.name case final name?) id: name,
      },
      abilityLookup: catalogue?.ability,
    );
  }

  /// Stratagems belonging to [phase], playable ones first.
  ///
  /// Unplayable ones stay in the list. Sorting them down keeps the phase
  /// section readable without hiding the answer to "why not".
  List<AvailableStratagem> forPhase(
    String phase, {
    BattleState state = const BattleState(),
  }) {
    const renderer = RulesRenderer();
    final out = <AvailableStratagem>[];

    for (final stratagem in stratagems) {
      if (!stratagem.phases.contains(phase)) continue;

      final blocks = <StratagemBlock>{};
      if (stratagem.cpCost > state.cp) blocks.add(StratagemBlock.cp);
      if (!_playableThisTurn(stratagem, state)) blocks.add(StratagemBlock.turn);
      if (_timingSpent(stratagem, state, phase)) {
        blocks.add(StratagemBlock.timing);
      }

      final abilityId = stratagem.abilityId;
      final ability =
          abilityId == null ? null : abilityLookup?.call(abilityId);

      out.add(AvailableStratagem(
        stratagem: stratagem,
        source: stratagem.detachmentId == null
            ? 'Core'
            : detachmentNames[stratagem.detachmentId] ??
                stratagem.detachmentId!,
        blocks: blocks,
        effect: ability == null ? null : renderer.render(ability),
      ));
    }

    out.sort((a, b) {
      if (a.playable != b.playable) return a.playable ? -1 : 1;
      final byCost = a.cpCost.compareTo(b.cpCost);
      return byCost != 0 ? byCost : a.name.compareTo(b.name);
    });
    return out;
  }

  /// Units [stratagem] may be played on, with a reason against each that
  /// cannot be.
  ///
  /// The one-per-phase rule is per **unit**, so a unit that has already had a
  /// stratagem this phase is shown and disabled rather than dropped — the
  /// player is looking for it, and its absence would read as a bug.
  List<StratagemTarget> targetsFor(
    SourceStratagem stratagem, {
    required Roster roster,
    required Catalogue catalogue,
    required String phase,
    BattleState state = const BattleState(),
  }) {
    final out = <StratagemTarget>[];
    for (final group in roster.combatUnits()) {
      final head = group.first;
      final keywords = <String>[
        for (final unit in group)
          ...?catalogue.unit(unit.datasheetId)?.keywords,
      ];
      final label = catalogue.labelFor(group);

      String? reason;
      if (!stratagem.permitsTarget(keywords)) {
        final needed = stratagem.requiredKeywords.isNotEmpty
            ? stratagem.requiredKeywords.join(' and ')
            : stratagem.requiredKeywordsAny.join(' or ');
        reason = 'not $needed';
      } else if (state.hasUsedStratagem(head.instanceId, phase: phase)) {
        reason = 'already used a Stratagem this phase';
      }

      out.add(StratagemTarget(
        instanceId: head.instanceId,
        label: label,
        blockedReason: reason,
      ));
    }
    return out;
  }

  bool _playableThisTurn(SourceStratagem stratagem, BattleState state) =>
      switch (stratagem.playerTurn) {
        'your-turn' => state.activePlayer == Player.me,
        'opponent-turn' => state.activePlayer == Player.opponent,
        _ => true,
      };

  /// The stratagem's own use limit, as a query against the log.
  bool _timingSpent(
    SourceStratagem stratagem,
    BattleState state,
    String phase,
  ) =>
      switch (stratagem.timing) {
        'once-per-battle' =>
          state.stratagemsUsed.any((u) => u.stratagemId == stratagem.id),
        'once-per-turn' => state.stratagemsUsed.any(
            (u) => u.stratagemId == stratagem.id && u.round == state.round),
        // The default, and the one 11e leans on.
        _ => state
            .usesIn(phase: phase)
            .any((u) => u.stratagemId == stratagem.id),
      };
}
