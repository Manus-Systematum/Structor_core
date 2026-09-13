import 'dart:convert';
import 'dart:io';

import 'package:test/test.dart';
import 'package:wh40k_core/src/source/bsdata/bs_document.dart';
import 'package:wh40k_core/src/source/bsdata/bs_mapper.dart';
import 'package:wh40k_core/src/source/json.dart';
import 'package:wh40k_core/wh40k_core.dart';

import 'support.dart';

/// Crusade progression is kept in the dataset and shown by nothing
/// (DESIGN.md §3.39).
///
/// Both halves are tested because each is easy to lose to the other: filtering
/// Crusade out of the datasheet was a fix for real pollution, and "keeping" it
/// by relaxing that filter would bring the pollution straight back.
void main() {
  final crusadeFile = File('${snapshotDir.path}/core/chaos-daemons/crusade.json');
  final skip = crusadeFile.existsSync() ? null : 'no merged snapshot';

  List<Map<String, Object?>> crusadeOf(String factionId) {
    final file = File('${snapshotDir.path}/core/$factionId/crusade.json');
    return [
      for (final raw in jsonDecode(file.readAsStringSync()) as List)
        asMap(raw),
    ];
  }

  group('kept', () {
    test('a datasheet keeps the Crusade progression BSData links to it', () {
      if (!crusadeFile.existsSync()) return;
      final skarbrand =
          crusadeOf('chaos-daemons').firstWhere((r) => r['unit_id'] == 'skarbrand');
      final subtrees = asList(skarbrand['crusade']).map(asMap).toList();
      final top = subtrees.firstWhere((s) => s['name'] == 'Crusade');

      expect(asList(top['contains']).map(asMap).map((c) => c['name']),
          contains('Mighty Champions'));
      // By BSData id, so the Crusade work can resolve the full tree from the
      // snapshot rather than the dataset having to carry all of it now.
      expect(top['bsdata_id'], isNotEmpty);
    }, skip: skip);

    test('and across the factions, not only the one looked at', () {
      if (!crusadeFile.existsSync()) return;
      final files = Directory('${snapshotDir.path}/core')
          .listSync()
          .whereType<Directory>()
          .where((d) => File('${d.path}/crusade.json').existsSync())
          .toList();
      expect(files.length, greaterThan(30));
    }, skip: skip);
  });

  group('shown by nothing', () {
    // On a fixture, because the real leak is not the names that are kept.
    // "Crusade" and "Mighty Champions" are groups with no rule text and would
    // never become abilities; what polluted a datasheet was the rules *inside*
    // those trees. A first version of this test checked the kept names against
    // the real data and passed with the filter switched off.
    test('a rule inside a Crusade tree does not reach the datasheet', () {
      final dir = Directory.systemTemp.createTempSync('crusade');
      addTearDown(() => dir.deleteSync(recursive: true));
      final file = File('${dir.path}/fixture.json')
        ..writeAsStringSync(jsonEncode(_fixture));
      final index = BsIndex()..add(file);
      final mapped = BsMapper(index).faction('fixture');

      final unit = mapped.units.single;
      final onTheDatasheet = <String>{
        ...asList(unit['ability_ids']).map((i) => '$i'),
        for (final budget in asList(unit['wargear_budgets']).map(asMap))
          ...asList(budget['items']).map((i) => '$i'),
        for (final ability in mapped.abilities) '${ability['ability_id']}',
      };

      // Not vacuous: the datasheet's own rule is read.
      expect(onTheDatasheet, contains('own-rule'));
      expect(onTheDatasheet, isNot(contains('battle-trait-rule')),
          reason: 'a rule from inside the Crusade tree reached the datasheet');

      // And the tree it came from is kept, by name and BSData id.
      final kept = asList(mapped.crusade.single['crusade']).map(asMap).single;
      expect(kept['name'], 'Crusade');
      expect(kept['bsdata_id'], 'g1');
      expect(asList(kept['contains']).map(asMap).single['name'],
          'Mighty Champions');
    });

    test('and the bundles the app ships carry none of it', () {
      final bundles = Directory(
          '../Wh40k_Companion/packages/wh40k_app/assets/bundles');
      if (!bundles.existsSync()) return;
      for (final file in bundles
          .listSync()
          .whereType<File>()
          .where((f) => f.path.endsWith('.json.gz') && !f.path.contains('patch-'))) {
        final bundle = DatasetBundle.decode(file.readAsBytesSync());
        expect(bundle.files.containsKey('crusade'), isFalse,
            reason: '${bundle.id} ships Crusade data before Crusade exists — '
                'the bundler must not name crusade.json until it is shown');
      }
    }, skip: Directory('../Wh40k_Companion/packages/wh40k_app/assets/bundles')
            .existsSync()
        ? null
        : 'no sibling app checkout');
  });
}

/// One datasheet with a rule of its own, and a Crusade group holding an entry
/// that carries a rule — the shape BSData gives every character.
const _fixture = {
  'catalogue': {
    'id': 'fixture',
    'name': 'Fixture',
    'costTypes': [
      {'id': 'pts', 'name': 'pts'},
    ],
    'profileTypes': [
      {'id': 'ab', 'name': 'Abilities'},
      {'id': 'un', 'name': 'Unit'},
    ],
    'sharedSelectionEntries': [
      {
        'id': 'u1',
        'name': 'Test Hero',
        'type': 'model',
        'categoryLinks': [
          {'name': 'Character', 'primary': true},
        ],
        'costs': [
          {'typeId': 'pts', 'value': 100},
        ],
        'profiles': [
          {
            'name': 'Test Hero',
            'typeName': 'Unit',
            'characteristics': [
              {'name': 'M', r'$text': '6"'},
              {'name': 'T', r'$text': '4'},
              {'name': 'W', r'$text': '4'},
              {'name': 'Sv', r'$text': '3+'},
              {'name': 'LD', r'$text': '6+'},
              {'name': 'OC', r'$text': '1'},
            ],
          },
          {
            'name': 'Own Rule',
            'typeName': 'Abilities',
            'characteristics': [
              {'name': 'Description', r'$text': "The datasheet's own rule."},
            ],
          },
        ],
        'selectionEntryGroups': [
          {
            'id': 'g1',
            'name': 'Crusade',
            'selectionEntries': [
              {
                'id': 'e1',
                'name': 'Mighty Champions',
                'type': 'upgrade',
                'profiles': [
                  {
                    'name': 'Battle Trait Rule',
                    'typeName': 'Abilities',
                    'characteristics': [
                      {'name': 'Description', r'$text': 'A Crusade battle trait.'},
                    ],
                  },
                ],
              },
            ],
          },
        ],
      },
    ],
  },
};
