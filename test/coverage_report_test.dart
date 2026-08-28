import 'dart:convert';
import 'dart:io';

import 'package:test/test.dart';
import 'package:wh40k_core/wh40k_core.dart';

/// Builds a throwaway snapshot on disk so loader behaviour is exercised for
/// real (missing files, malformed JSON) rather than mocked away.
class _Snapshot {
  final Directory dir;

  _Snapshot() : dir = Directory.systemTemp.createTempSync('wh40k_snapshot');

  void write(String relativePath, Object? json) {
    final file = File('${dir.path}/$relativePath');
    file.parent.createSync(recursive: true);
    file.writeAsStringSync(jsonEncode(json));
  }

  void writeRaw(String relativePath, String contents) {
    final file = File('${dir.path}/$relativePath');
    file.parent.createSync(recursive: true);
    file.writeAsStringSync(contents);
  }

  DatasetLoader get loader => DatasetLoader(dir.path);

  void dispose() => dir.deleteSync(recursive: true);
}

/// A snapshot with every file present and internally consistent.
_Snapshot _healthySnapshot() {
  final s = _Snapshot()
    ..write('core/game-versions.json', [
      {'edition': '11th', 'dataslate': 'launch'},
    ])
    ..write('core/game-modes.json', [])
    ..write('core/force-dispositions.json', [
      {'id': 'reconnaissance', 'name': 'Reconnaissance'},
      {'id': 'priority-assets', 'name': 'Priority Assets'},
    ])
    ..write('core/missions.json', [
      {'id': 'gather-intel', 'name': 'Gather Intel'},
    ])
    ..write('core/mission-matchups.json', [
      {
        'disposition': 'reconnaissance',
        'opponent_disposition': 'reconnaissance',
        'mission_id': 'gather-intel',
      },
    ])
    ..write('core/secondary-cards.json', [])
    ..write('core/deployment-patterns.json', [])
    ..write('core/terrain-templates.json', [])
    ..write('core/weapon-keywords.json', [
      {'id': 'torrent'},
    ])
    ..write('core/unit-keywords.json', [])
    ..write('core/target-profiles.json', [])
    ..write('core/stratagems.json', [])
    ..write('core/testers/factions.json', [])
    ..write('core/testers/units.json', [
      {
        'id': 'unit-a',
        'name': 'Unit A',
        'faction_id': 'testers',
        'profiles': [
          {'name': 'Unit A', 'M': 8, 'T': 5, 'W': 6, 'Sv': 2, 'Ld': 7, 'OC': 2},
        ],
        'points': [
          {'models': 1, 'cost': 80},
        ],
        'ability_ids': ['ability-a'],
        'weapon_ids': ['weapon-a'],
        'game_version': {'edition': '11th', 'dataslate': 'launch'},
      },
    ])
    ..write('core/testers/weapons.json', [
      {
        'id': 'weapon-a',
        'name': 'Test gun',
        'type': 'ranged',
        'profiles': [
          {
            'name': 'Test gun',
            'range': 24,
            'stats': {'A': 2, 'S': 5, 'AP': 0, 'D': 1, 'BS': 3},
            'keywords': [
              {'keyword_id': 'torrent'},
            ],
          },
        ],
        'game_version': {'edition': '11th', 'dataslate': 'launch'},
      },
    ])
    ..write('core/testers/wargear.json', [])
    ..write('core/testers/wargear-options.json', [])
    ..write('core/testers/unit-compositions.json', [])
    ..write('core/testers/detachments.json', [
      {
        'id': 'det-a',
        'name': 'Detachment A',
        'faction_id': 'testers',
        'detachment_points': 1,
        'force_dispositions': ['reconnaissance'],
        'stratagem_ids': ['strat-a'],
        'enhancement_ids': ['enh-a'],
        'game_version': {'edition': '11th', 'dataslate': 'launch'},
      },
    ])
    ..write('core/testers/enhancements.json', [
      {'id': 'enh-a', 'name': 'Enhancement A'},
    ])
    ..write('core/testers/leader-attachments.json', [])
    ..write('core/testers/stratagems.json', [
      {
        'id': 'strat-a',
        'name': 'Stratagem A',
        'detachment_id': 'det-a',
        'cp_cost': 1,
        'phases': ['shooting'],
        'player_turn': 'your-turn',
        'game_version': {'edition': '11th', 'dataslate': 'launch'},
      },
    ])
    ..write('enrichment/testers/abilities.json', [
      {
        'ability_id': 'ability-a',
        'name': 'Ability A',
        'effect': {'type': 'stat-modifier'},
        'unit_ids': ['unit-a'],
        'game_version': {'edition': '11th', 'dataslate': 'launch'},
      },
    ])
    ..write('enrichment/testers/phase-mappings.json', []);
  return s;
}

CoverageReport _analyze(_Snapshot s) {
  final loader = s.loader;
  return CoverageAnalyzer(
    core: loader.loadCore(),
    faction: loader.loadFaction('testers'),
  ).analyze();
}

void main() {
  group('healthy snapshot', () {
    late _Snapshot snapshot;

    setUp(() => snapshot = _healthySnapshot());
    tearDown(() => snapshot.dispose());

    test('produces no error findings', () {
      final report = _analyze(snapshot);
      expect(
        report.findings.where((f) => f.severity == FindingSeverity.error),
        isEmpty,
        reason: report.findings.map((f) => f.summary).join('; '),
      );
      expect(report.hasErrors, isFalse);
    });

    test('counts what it loaded', () {
      final report = _analyze(snapshot);
      expect(report.counts['units'], 1);
      expect(report.counts['weapons'], 1);
      expect(report.counts['stratagems'], 1);
      expect(report.counts['enhancements'], 1);
      expect(report.counts['mission matchups'], 1);
    });

    test('discovers factions from the directory layout', () {
      expect(snapshot.loader.availableFactions(), ['testers']);
    });
  });

  group('referential integrity', () {
    late _Snapshot snapshot;

    setUp(() => snapshot = _healthySnapshot());
    tearDown(() => snapshot.dispose());

    test('dangling weapon reference is an error', () {
      snapshot.write('core/testers/weapons.json', []);
      final report = _analyze(snapshot);
      final finding = report.findings.firstWhere(
        (f) => f.summary.contains('unknown weapons'),
        orElse: () => fail('expected a dangling-weapon finding'),
      );
      expect(finding.severity, FindingSeverity.error);
      expect(finding.examples.single, 'unit-a -> weapon-a');
    });

    test('dangling enhancement reference is an error', () {
      snapshot.write('core/testers/enhancements.json', []);
      final report = _analyze(snapshot);
      expect(
        report.findings.any((f) => f.summary.contains('unknown enhancements')),
        isTrue,
      );
    });

    test('detachment referencing an unknown disposition is an error', () {
      snapshot.write('core/force-dispositions.json', [
        {'id': 'take-and-hold', 'name': 'Take and Hold'},
      ]);
      final report = _analyze(snapshot);
      expect(
        report.findings.any((f) => f.summary.contains('unknown dispositions')),
        isTrue,
      );
    });
  });

  group('completeness checks', () {
    late _Snapshot snapshot;

    setUp(() => snapshot = _healthySnapshot());
    tearDown(() => snapshot.dispose());

    test('a stratagem with no phases is an error', () {
      snapshot.write('core/testers/stratagems.json', [
        {
          'id': 'strat-a',
          'name': 'Stratagem A',
          'detachment_id': 'det-a',
          'cp_cost': 1,
          'phases': <String>[],
          'game_version': {'edition': '11th', 'dataslate': 'launch'},
        },
      ]);
      final report = _analyze(snapshot);
      expect(
        report.findings.any((f) => f.summary.contains('no phase assignment')),
        isTrue,
      );
    });

    test('an unregistered weapon keyword is an error', () {
      snapshot.write('core/weapon-keywords.json', [
        {'id': 'melta'},
      ]);
      final report = _analyze(snapshot);
      final finding = report.findings.firstWhere(
        (f) => f.category == 'keywords',
        orElse: () => fail('expected an unknown-keyword finding'),
      );
      expect(finding.severity, FindingSeverity.error);
      expect(finding.examples, contains('torrent'));
    });
  });

  group('snapshot robustness', () {
    test('missing files are reported, not thrown', () {
      final s = _Snapshot();
      addTearDown(s.dispose);
      final report = _analyze(s);
      expect(report.hasErrors, isTrue);
      expect(report.findings.any((f) => f.category == 'snapshot'), isTrue);
      expect(report.counts['units'], 0);
    });

    test('malformed JSON degrades to a missing file', () {
      final s = _healthySnapshot();
      addTearDown(s.dispose);
      s.writeRaw('core/testers/units.json', '{ this is not json');
      final report = _analyze(s);
      expect(report.counts['units'], 0);
      expect(report.findings.any((f) => f.category == 'snapshot'), isTrue);
    });
  });

  test('provisional dataslates raise a warning', () {
    final s = _healthySnapshot();
    addTearDown(s.dispose);
    s.write('core/testers/units.json', [
      {
        'id': 'unit-a',
        'name': 'Unit A',
        'faction_id': 'testers',
        'profiles': [
          {'name': 'Unit A', 'M': 8, 'T': 5, 'W': 6, 'Sv': 2},
        ],
        'points': [
          {'models': 1, 'cost': 80},
        ],
        'ability_ids': ['ability-a'],
        'weapon_ids': ['weapon-a'],
        'game_version': {'edition': '11th', 'dataslate': 'pre-launch-provisional'},
      },
    ]);
    final report = _analyze(s);
    final finding = report.findings.firstWhere(
      (f) => f.category == 'dataslate',
      orElse: () => fail('expected a dataslate finding'),
    );
    expect(finding.severity, FindingSeverity.warning);
  });
}
