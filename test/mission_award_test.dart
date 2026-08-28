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
  MissionCard cardWith(List<Object?> awards) => MissionCard(
        id: 'x',
        name: 'X',
        cardType: 'primary',
        text: '',
        awards: awards,
      );

  Object? award({
    required String timing,
    String? phase,
    int? min,
    int? max,
    int? vp,
  }) =>
      {
        'trigger': {
          'timing': timing,
          if (phase != null) 'phase': phase,
          if (min != null || max != null)
            'battle_round': {
              if (min != null) 'min': min,
              if (max != null) 'max': max,
            },
        },
        if (vp != null) 'vp': vp,
      };

  group('an award knows where it pays out', () {
    test('a command-phase award belongs to the command phase', () {
      final card = cardWith([
        award(timing: 'end-of-phase', phase: 'command', min: 2, vp: 4),
      ]);
      expect(card.scoresIn(phase: 'command', round: 2), isTrue);
      expect(card.scoresIn(phase: 'end', round: 2), isFalse);
    });

    test('it does not pay before its round', () {
      // Round 1 is not "not yet" — it is a different tier of the same
      // mission, and offering it would offer points that cannot be taken.
      final card = cardWith([
        award(timing: 'end-of-phase', phase: 'command', min: 2, vp: 4),
      ]);
      expect(card.scoresIn(phase: 'command', round: 1), isFalse);
      expect(card.scoresIn(phase: 'command', round: 2), isTrue);
    });

    test('a closed window shuts again', () {
      final card = cardWith([
        award(
            timing: 'end-of-phase', phase: 'command', min: 2, max: 3, vp: 5),
      ]);
      expect(card.scoresIn(phase: 'command', round: 3), isTrue);
      expect(card.scoresIn(phase: 'command', round: 4), isFalse);
    });

    test('end-of-turn and end-of-battle stay in the end section', () {
      final card = cardWith([
        award(timing: 'end-of-turn', vp: 3),
        award(timing: 'end-of-battle', vp: 5),
      ]);
      expect(card.scoresIn(phase: 'end', round: 1), isTrue);
      expect(card.scoresIn(phase: 'command', round: 3), isFalse);
    });

    test('flat payouts are offered, per-something ones are not', () {
      final card = cardWith([
        award(timing: 'end-of-phase', phase: 'command', min: 2, vp: 4),
        {
          'trigger': {
            'timing': 'end-of-phase',
            'phase': 'command',
            'battle_round': {'min': 2},
          },
          'vp_per': 3,
          'per': 'controlled-objective',
        },
      ]);
      expect(card.payoutsIn(phase: 'command', round: 2), [4]);
      expect(card.awardsIn(phase: 'command', round: 2), hasLength(2),
          reason: 'the per-objective tier still counts as scoring here');
    });
  });

  group('against the shipped cards', () {
    final root = Directory(snapshotDir.path);
    final available = root.existsSync();

    test('every primary scores in the command phase from round 2', () {
      final pack = loadPack(root.path);
      final primaries = pack.cards.values.where((c) => c.isPrimary).toList();
      expect(primaries, isNotEmpty);
      for (final card in primaries) {
        expect(card.scoresIn(phase: 'command', round: 2), isTrue,
            reason: card.name);
        expect(card.scoresIn(phase: 'command', round: 1), isFalse,
            reason: '${card.name} must not pay in round 1');
      }
    }, skip: available ? null : 'no snapshot');

    test('no award is phased anywhere but the command phase', () {
      // If upstream ever adds one, the phase sections need to learn about it
      // rather than silently dropping it.
      final pack = loadPack(root.path);
      for (final card in pack.cards.values) {
        for (final a in card.scoringAwards) {
          if (a.timing != 'end-of-phase') continue;
          expect(a.phase, 'command', reason: card.name);
        }
      }
    }, skip: available ? null : 'no snapshot');
  });
}
