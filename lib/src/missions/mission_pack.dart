/// Mission data and the matchup table (DESIGN.md §7.3.1).
///
/// The table is **asymmetric**: `(A vs B)` and `(B vs A)` are different cells
/// yielding different missions, so both players are playing their own primary
/// at the same time on the same table. Twenty-five ordered pairs, twenty-five
/// distinct missions, mirrors on the diagonal.
///
/// That is what makes force disposition a *decision* rather than a derivation
/// once an army has more than one detachment: each detachment offers one
/// disposition, the army declares one, and the declaration picks which mission
/// you play against whatever your opponent declares.
library;

import '../source/json.dart';
import '../source/source_models.dart';
import 'terrain_layout.dart';

class ForceDisposition {
  final String id;
  final String name;
  final String text;

  const ForceDisposition({
    required this.id,
    required this.name,
    required this.text,
  });

  factory ForceDisposition.fromJson(Object? v) {
    final j = asMap(v);
    return ForceDisposition(
      id: strOr(j['id'], ''),
      name: strOr(j['name'], ''),
      text: strOr(j['text'], ''),
    );
  }
}

class Mission {
  final String id;
  final String name;
  final int? vpPerRoundCap;
  final int? vpPerGameCap;

  const Mission({
    required this.id,
    required this.name,
    this.vpPerRoundCap,
    this.vpPerGameCap,
  });

  factory Mission.fromJson(Object? v) {
    final j = asMap(v);
    return Mission(
      id: strOr(j['id'], ''),
      name: strOr(j['name'], ''),
      vpPerRoundCap: asInt(j['vp_per_round_cap']),
      vpPerGameCap: asInt(j['vp_per_game_cap']),
    );
  }
}

/// A point on the table, in **inches from the bottom-left corner**.
class BoardPoint {
  final double x;
  final double y;

  const BoardPoint(this.x, this.y);

  factory BoardPoint.fromJson(Object? v) {
    final j = asMap(v);
    return BoardPoint(dblOr(j['x'], 0), dblOr(j['y'], 0));
  }
}

/// A deployment zone or a player's territory, as absolute board coordinates.
///
/// The source gives a shape *plus* a `position` offset, and expresses shapes
/// as either a polygon or a `width`/`height` rectangle. Both are flattened to
/// one absolute point list here so nothing downstream has to know the
/// difference or remember to apply the offset — forgetting it draws both
/// players' zones stacked in the same corner.
class BoardArea {
  /// `attacker` or `defender`.
  final String player;

  final String name;
  final List<BoardPoint> points;

  /// `0xAARRGGBB` from the source's hex, or null when it publishes none.
  final int? color;

  const BoardArea({
    required this.player,
    required this.points,
    this.name = '',
    this.color,
  });

  factory BoardArea.fromJson(Object? v) {
    final j = asMap(v);
    final origin = BoardPoint.fromJson(j['position']);
    final shape = asMap(j['shape']);

    final List<BoardPoint> local;
    if (strOr(shape['type'], '') == 'rectangle') {
      final w = dblOr(shape['width'], 0);
      final h = dblOr(shape['height'], 0);
      local = [
        const BoardPoint(0, 0),
        BoardPoint(w, 0),
        BoardPoint(w, h),
        BoardPoint(0, h),
      ];
    } else {
      local = asList(shape['points']).map(BoardPoint.fromJson).toList();
    }

    return BoardArea(
      player: strOr(j['player'], ''),
      name: strOr(j['name'], ''),
      points: [
        for (final p in local) BoardPoint(origin.x + p.x, origin.y + p.y),
      ],
      color: _hexColor(str(j['color'])),
    );
  }

  bool get isAttacker => player == 'attacker';
  bool get isDefender => player == 'defender';
}

/// `#3b82f6` → `0xFF3B82F6`. Null for anything that is not a 6-digit hex, so a
/// malformed colour falls back to the theme rather than painting black.
int? _hexColor(String? raw) {
  if (raw == null) return null;
  final hex = raw.startsWith('#') ? raw.substring(1) : raw;
  if (hex.length != 6) return null;
  final value = int.tryParse(hex, radix: 16);
  return value == null ? null : 0xFF000000 | value;
}

class DeploymentPattern {
  final String id;
  final String name;
  final String description;

  /// Where each player sets up.
  final List<BoardArea> zones;

  /// The halves of the table each player owns, which several missions score
  /// against. Larger than the deployment zones and not the same shape.
  final List<BoardArea> territories;

  final List<BoardPoint> objectives;

  const DeploymentPattern({
    required this.id,
    required this.name,
    required this.description,
    this.zones = const [],
    this.territories = const [],
    this.objectives = const [],
  });

  factory DeploymentPattern.fromJson(Object? v) {
    final j = asMap(v);
    return DeploymentPattern(
      id: strOr(j['id'], ''),
      name: strOr(j['name'], ''),
      description: strOr(j['description'], ''),
      zones: asList(j['zones']).map(BoardArea.fromJson).toList(),
      territories: asList(j['territories']).map(BoardArea.fromJson).toList(),
      objectives: asList(j['objectives']).map(BoardPoint.fromJson).toList(),
    );
  }

  bool get hasGeometry => zones.any((z) => z.points.isNotEmpty);

  /// The table's extent in inches, **measured from the data** rather than
  /// assumed to be 60×44. `kotc-colosseum` is 36×36, so a hardcoded standard
  /// board would draw it at half scale in the corner.
  BoardPoint get boardSize {
    var w = 0.0;
    var h = 0.0;
    for (final area in [...zones, ...territories]) {
      for (final p in area.points) {
        if (p.x > w) w = p.x;
        if (p.y > h) h = p.y;
      }
    }
    for (final o in objectives) {
      if (o.x > w) w = o.x;
      if (o.y > h) h = o.y;
    }
    return BoardPoint(w, h);
  }

  BoardArea? zoneFor({required bool attacker}) {
    for (final zone in zones) {
      if (zone.isAttacker == attacker) return zone;
    }
    return null;
  }
}

/// A primary or secondary card.
///
/// [text] is an original paraphrase written by the data project, not GW's
/// printed wording (§7.3.4). Enough to play from; not authoritative for a
/// rules dispute, and the UI must not imply otherwise.
/// When one of a card's payouts becomes available (DESIGN.md §7.3.11).
///
/// The awards were carried raw because nothing asked them anything. Putting
/// scoring where it happens does: across all 43 cards, **every** `end-of-phase`
/// award is `phase: command` and **every** one is gated at `battle_round >= 2`
/// — which is the primary mission's round-2-onward tier, and the single
/// largest source of victory points in a game. Leaving it in the END section
/// meant the player met it a phase and a scroll away from where the rulebook
/// says to score it.
class MissionAward {
  /// `end-of-turn`, `end-of-phase`, `end-of-battle`.
  final String timing;

  /// The phase for an `end-of-phase` award. Always `command` in the current
  /// data, but read rather than assumed.
  final String? phase;

  final int? roundMin;
  final int? roundMax;

  /// A flat payout, when the award names one.
  final int? vp;

  /// A payout per something the app cannot see — per controlled objective, per
  /// unit destroyed. These name no total, so the UI offers a stepper.
  final int? vpPer;
  final String? per;

  const MissionAward({
    required this.timing,
    this.phase,
    this.roundMin,
    this.roundMax,
    this.vp,
    this.vpPer,
    this.per,
  });

  factory MissionAward.fromJson(Object? v) {
    final j = asMap(v);
    final trigger = asMap(j['trigger']);
    final round = asMap(trigger['battle_round']);
    return MissionAward(
      timing: strOr(trigger['timing'], ''),
      phase: str(trigger['phase']),
      roundMin: asInt(round['min']),
      roundMax: asInt(round['max']),
      vp: asInt(j['vp']),
      vpPer: asInt(j['vp_per']),
      per: str(j['per']),
    );
  }

  /// True when this award can pay out in [phase] of [round].
  ///
  /// A round outside the trigger's window is not "not yet" — it is a different
  /// tier of the same mission, and showing it would offer points that cannot
  /// be taken.
  bool appliesIn({required String phase, required int round}) {
    if (roundMin != null && round < roundMin!) return false;
    if (roundMax != null && round > roundMax!) return false;
    return switch (timing) {
      'end-of-phase' => this.phase == phase,
      'end-of-turn' => phase == 'end',
      // Scored once the game is over, which the END section is the only place
      // to offer.
      'end-of-battle' => phase == 'end',
      _ => false,
    };
  }

  /// A payout the app can offer as a button, or null when only the player can
  /// know the total.
  int? get flatPayout => vp;
}

class MissionCard {
  final String id;
  final String name;
  final String cardType;
  final String text;
  final List<Object?> awards;
  final List<Object?> actions;

  /// `when_drawn`, raw. Only Forward Position uses it — drawn in the first
  /// battle round it goes back in the deck — and one card does not justify a
  /// typed model.
  final Object? rawWhenDrawn;

  /// Every total a *per-something* award can actually come to (§7.3.27).
  ///
  /// `2 VP: For each enemy unit destroyed this turn`, capped at 5, can only
  /// ever be worth 2, 4 or 5 — the third kill is worth one point, not two.
  /// The card says the rate and the ceiling and leaves the arithmetic to the
  /// player, which at a table with a clock is where mistakes come from.
  ///
  /// Only awards that name **both** a rate and a maximum appear here. An
  /// uncapped `3 VP each` has no ladder — it runs as far as the board allows,
  /// and the stepper stays for those.
  /// The rate a line pays when it pays *per* something and never stops
  /// (§7.3.27), or null.
  ///
  /// `3 VP each: For each objective you control` has no ceiling of its own —
  /// only the round's — so there is no short list of totals to offer. The
  /// figure is the same one [ladderFor] takes, read off the line.
  int? uncappedRateFor(int rate) {
    for (final raw in awards) {
      final award = asMap(raw);
      final per = asInt(award['vp_per']);
      if (per != null && per == rate && asInt(award['vp_max']) == null) {
        return per;
      }
    }
    return null;
  }

  List<int> ladderFor(int rate) {
    for (final raw in awards) {
      final award = asMap(raw);
      final per = asInt(award['vp_per']);
      final max = asInt(award['vp_max']);
      if (per == null || max == null || per != rate || per <= 0) continue;
      final out = <int>[];
      for (var total = per; out.isEmpty || out.last < max; total += per) {
        out.add(total > max ? max : total);
        if (out.last >= max) break;
      }
      return out;
    }
    return const [];
  }

  const MissionCard({
    required this.id,
    required this.name,
    required this.cardType,
    required this.text,
    this.awards = const [],
    this.actions = const [],
    this.rawWhenDrawn,
  });

  factory MissionCard.fromJson(Object? v) {
    final j = asMap(v);
    return MissionCard(
      id: strOr(j['id'], ''),
      name: strOr(j['name'], ''),
      cardType: strOr(j['card_type'], ''),
      text: strOr(j['text'], ''),
      awards: asList(j['awards']),
      actions: asList(j['actions']),
      rawWhenDrawn: j['when_drawn'],
    );
  }

  bool get isPrimary => cardType == 'primary';
  bool get isSecondary => cardType == 'secondary';
  bool get requiresAction => actions.isNotEmpty;

  /// The card's payouts, typed.
  List<MissionAward> get scoringAwards =>
      [for (final raw in awards) MissionAward.fromJson(raw)];

  /// Payouts available in [phase] of [round], distinct flat amounts first.
  List<MissionAward> awardsIn({required String phase, required int round}) => [
        for (final award in scoringAwards)
          if (award.appliesIn(phase: phase, round: round)) award,
      ];

  /// Distinct flat payouts available in [phase] of [round], ascending — the
  /// figures the UI can offer as buttons.
  List<int> payoutsIn({required String phase, required int round}) {
    final seen = <int>{
      for (final award in awardsIn(phase: phase, round: round))
        if (award.flatPayout case final vp?) vp,
    };
    return seen.toList()..sort();
  }

  /// True when something on this card pays out in [phase] of [round], whether
  /// or not the app can name the figure.
  bool scoresIn({required String phase, required int round}) =>
      awardsIn(phase: phase, round: round).isNotEmpty;
}

class MissionMatchupEntry {
  final String disposition;
  final String opponentDisposition;
  final String missionId;

  const MissionMatchupEntry({
    required this.disposition,
    required this.opponentDisposition,
    required this.missionId,
  });

  factory MissionMatchupEntry.fromJson(Object? v) {
    final j = asMap(v);
    return MissionMatchupEntry(
      disposition: strOr(j['disposition'], ''),
      opponentDisposition: strOr(j['opponent_disposition'], ''),
      missionId: strOr(j['mission_id'], ''),
    );
  }
}

/// One cell of the decision grid: declaring [disposition] against
/// [opponentDisposition] means playing [mission].
class MissionOutcome {
  final String disposition;
  final String opponentDisposition;
  final Mission? mission;
  final MissionCard? card;

  const MissionOutcome({
    required this.disposition,
    required this.opponentDisposition,
    this.mission,
    this.card,
  });
}

class MissionPack {
  final Map<String, ForceDisposition> dispositions;
  final Map<String, Mission> missions;
  final Map<String, MissionCard> cards;
  final List<DeploymentPattern> deployments;
  final List<MissionMatchupEntry> matchups;

  /// Published competitive tables (§7.3.1). Empty on a pack built before they
  /// were bundled, which the setup screen degrades around.
  final List<TerrainLayout> terrainLayouts;

  final Map<String, TerrainTemplate> terrainTemplates;

  const MissionPack({
    this.dispositions = const {},
    this.missions = const {},
    this.cards = const {},
    this.deployments = const [],
    this.matchups = const [],
    this.terrainLayouts = const [],
    this.terrainTemplates = const {},
  });

  factory MissionPack.fromJson({
    required List<Object?> dispositions,
    required List<Object?> missions,
    required List<Object?> matchups,
    required List<Object?> cards,
    required List<Object?> deployments,
    List<Object?> terrainLayouts = const [],
    List<Object?> terrainTemplates = const [],
  }) {
    final parsedCards = cards.map(MissionCard.fromJson).toList();
    return MissionPack(
      dispositions: {
        for (final raw in dispositions)
          if (ForceDisposition.fromJson(raw) case final d when d.id.isNotEmpty)
            d.id: d,
      },
      missions: {
        for (final raw in missions)
          if (Mission.fromJson(raw) case final m when m.id.isNotEmpty) m.id: m,
      },
      cards: {
        for (final card in parsedCards)
          if (card.id.isNotEmpty) card.id: card,
      },
      deployments: deployments.map(DeploymentPattern.fromJson).toList(),
      matchups: matchups.map(MissionMatchupEntry.fromJson).toList(),
      terrainLayouts: terrainLayouts.map(TerrainLayout.fromJson).toList(),
      terrainTemplates: {
        for (final raw in terrainTemplates)
          if (TerrainTemplate.fromJson(raw) case final t when t.id.isNotEmpty)
            t.id: t,
      },
    );
  }

  bool get isEmpty => matchups.isEmpty;

  List<ForceDisposition> get allDispositions =>
      dispositions.values.toList()..sort((a, b) => a.name.compareTo(b.name));

  List<MissionCard> get secondaryCards =>
      cards.values.where((c) => c.isSecondary).toList()
        ..sort((a, b) => a.name.compareTo(b.name));

  MissionCard? card(String id) => cards[id];

  DeploymentPattern? deployment(String id) {
    for (final pattern in deployments) {
      if (pattern.id == id) return pattern;
    }
    return null;
  }

  /// The published tables for this pairing.
  ///
  /// **The lookup is unordered, and the mission table is not.** `(A vs B)` and
  /// `(B vs A)` are different cells yielding different missions — that is the
  /// whole point of §7.3.1 — but they are the *same physical table*, and
  /// upstream publishes each pairing once. Fifteen unordered pairs, three
  /// variants each. Looking up only the declared order finds nothing for ten
  /// of the twenty-five matchups, and the failure looks like missing data
  /// rather than a lookup that forgot to commute.
  List<TerrainLayout> layoutsFor({
    required String disposition,
    required String opponentDisposition,
  }) {
    final forward = '$disposition-vs-$opponentDisposition';
    final reverse = '$opponentDisposition-vs-$disposition';
    final out = [
      for (final layout in terrainLayouts)
        if (layout.missionMatchupId == forward ||
            layout.missionMatchupId == reverse)
          layout,
    ]..sort((a, b) => a.variant.compareTo(b.variant));
    return out;
  }

  /// The mission played by a player declaring [disposition] against an
  /// opponent declaring [opponentDisposition]. Order matters.
  Mission? missionFor({
    required String disposition,
    required String opponentDisposition,
  }) {
    for (final entry in matchups) {
      if (entry.disposition == disposition &&
          entry.opponentDisposition == opponentDisposition) {
        return missions[entry.missionId];
      }
    }
    return null;
  }

  MissionOutcome outcomeFor({
    required String disposition,
    required String opponentDisposition,
  }) {
    final mission = missionFor(
      disposition: disposition,
      opponentDisposition: opponentDisposition,
    );
    return MissionOutcome(
      disposition: disposition,
      opponentDisposition: opponentDisposition,
      mission: mission,
      card: mission == null ? null : cards[mission.id],
    );
  }

  /// Dispositions an army may declare, given the detachments it took. More
  /// than one means the player has a choice — the decision this screen exists
  /// to support.
  List<ForceDisposition> availableTo(Iterable<SourceDetachment> detachments) {
    final ids = <String>{
      for (final detachment in detachments) ...detachment.forceDispositions,
    };
    return [
      for (final id in ids)
        if (dispositions[id] case final d?) d,
    ]..sort((a, b) => a.name.compareTo(b.name));
  }

  /// The full decision grid: every disposition the army could declare, against
  /// every disposition the opponent might.
  ///
  /// Rendered as a matrix and never as a recommendation — the app knows
  /// neither the matchup, the terrain, nor how the player plays (§7.3.1).
  List<List<MissionOutcome>> grid(Iterable<ForceDisposition> mine) => [
        for (final ours in mine)
          [
            for (final theirs in allDispositions)
              outcomeFor(
                disposition: ours.id,
                opponentDisposition: theirs.id,
              ),
          ],
      ];
}
