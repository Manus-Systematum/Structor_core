import 'dart:convert';
import 'dart:io';

import 'package:test/test.dart';

import 'support.dart';

/// A partial merge must not damage the factions it was not asked about.
///
/// The bug this guards: `_copyRemaining` filled the merged tree from raw
/// 40kdc for every path the *current run* had not rewritten, so
/// `merge.dart tau-empire` copied the un-enriched Space Marine abilities over
/// output a previous run had merged — 2,723 rules silently lost their printed
/// text. The tree is derived and gitignored, so no test and no diff saw it,
/// and only `tools/rebuild-assets.sh` merging everything kept the shipped
/// bundles correct.
void main() {
  final merged = Directory(snapshotDir.path);
  final available = merged.existsSync();

  int textCoverage(String faction) {
    final file = File('${merged.path}/enrichment/$faction/abilities.json');
    if (!file.existsSync()) return -1;
    final list = jsonDecode(file.readAsStringSync()) as List;
    if (list.isEmpty) return -1;
    final withText = list.where((r) {
      final d = (r as Map)['description'];
      return d is String && d.trim().isNotEmpty;
    }).length;
    return (100 * withText / list.length).round();
  }

  test('every merged faction kept its printed rules text', () {
    // Runs against whatever state the tree is in. A partial merge that
    // clobbered its neighbours shows up here as a faction at 0%.
    final dir = Directory('${merged.path}/enrichment');
    final factions = dir
        .listSync()
        .whereType<Directory>()
        .map((d) => d.path.split('/').last)
        .toList()
      ..sort();

    final bare = <String>[];
    for (final f in factions) {
      final pct = textCoverage(f);
      if (pct >= 0 && pct < 50) bare.add('$f ($pct%)');
    }

    expect(bare, isEmpty,
        reason: 'these factions have merged output with almost no printed '
            'rules text, which is what a partial merge leaves behind — '
            'rerun `dart run bin/merge.dart` with no arguments');
  }, skip: available ? null : 'no merged tree');

  test('the manifest records what the tree holds', () {
    final file = File('${merged.path}/.merged.json');
    expect(file.existsSync(), isTrue,
        reason: 'the manifest is how a later partial merge knows which '
            'factions it must not overwrite');
    final j = jsonDecode(file.readAsStringSync()) as Map;
    final factions = (j['factions'] as List).cast<String>();
    expect(factions, isNotEmpty);

    // Every faction the manifest claims must actually have output, or the
    // protection is guarding a file that is not there.
    for (final f in factions) {
      expect(
        Directory('${merged.path}/enrichment/$f').existsSync() ||
            Directory('${merged.path}/core/$f').existsSync(),
        isTrue,
        reason: '$f is in the manifest but has no merged output',
      );
    }
  }, skip: available ? null : 'no merged tree');
}
