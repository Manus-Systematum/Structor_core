import 'dart:convert';
import 'dart:io';

import 'package:test/test.dart';
import 'package:wh40k_core/wh40k_core.dart';

/// Ordering one published dataset against another (DESIGN.md §3.38).
void main() {
  BundleEntry entry(String id, String digest) => BundleEntry(
        id: id,
        kind: BundleKind.faction,
        name: id,
        file: '$id.$digest.json.gz',
        sha256: digest,
        bytes: 1,
        revision: 'local',
      );

  DatasetManifest manifestOf(List<BundleEntry> bundles, {int revision = 0}) =>
      DatasetManifest(
        revision: revision,
        generated: 'local',
        source: 'test',
        bundles: bundles,
      );

  final noon = DateTime.utc(2026, 9, 12, 12, 0, 0);

  group('the revision a build stamps', () {
    test('is the build time, readable as a date', () {
      final built = manifestOf([entry('orks', 'aaa')]);
      expect(nextManifestRevision(built: built, now: noon), 20260912120000);
    });

    test('is kept when the files are the same, so a rebuild is no update', () {
      // Publishing the same dataset twice must not make installed apps treat
      // it as newer than itself, nor churn the committed manifest.
      final previous = manifestOf([entry('orks', 'aaa')], revision: 20260901000000);
      final built = manifestOf([entry('orks', 'aaa')]);
      expect(nextManifestRevision(built: built, previous: previous, now: noon),
          20260901000000);
    });

    test('moves when any file changes', () {
      final previous = manifestOf([entry('orks', 'aaa')], revision: 20260901000000);
      final built = manifestOf([entry('orks', 'bbb')]);
      expect(nextManifestRevision(built: built, previous: previous, now: noon),
          20260912120000);
    });

    test('moves when a file is added or dropped, not only changed', () {
      final previous = manifestOf([entry('orks', 'aaa')], revision: 20260901000000);
      expect(
        nextManifestRevision(
            built: manifestOf([entry('orks', 'aaa'), entry('tau', 'ccc')]),
            previous: previous,
            now: noon),
        greaterThan(previous.revision),
      );
      expect(
        nextManifestRevision(
            built: manifestOf(const []), previous: previous, now: noon),
        greaterThan(previous.revision),
      );
    });

    test('still goes up on a machine whose clock is behind', () {
      // Otherwise a build from a laptop set to last year would publish a
      // dataset every installed app refuses as older than what it has.
      final previous = manifestOf([entry('orks', 'aaa')], revision: 20260912120000);
      final built = manifestOf([entry('orks', 'bbb')]);
      final lastYear = DateTime.utc(2025, 1, 1);
      expect(
          nextManifestRevision(built: built, previous: previous, now: lastYear),
          20260912120001);
    });

    test('takes a fresh stamp over an unversioned predecessor', () {
      // Every manifest written before this existed reads as zero, which must
      // not be kept just because the files happen to match.
      final previous = manifestOf([entry('orks', 'aaa')]);
      final built = manifestOf([entry('orks', 'aaa')]);
      expect(nextManifestRevision(built: built, previous: previous, now: noon),
          20260912120000);
    });
  });

  group('the manifest carries it', () {
    test('through a round trip', () {
      final manifest = manifestOf([entry('orks', 'aaa')], revision: 42);
      final back = DatasetManifest.fromJson(jsonDecode(jsonEncode(manifest)));
      expect(back.revision, 42);
    });

    test('as zero when it is absent', () {
      final unversioned = DatasetManifest.fromJson({
        'schema': 1,
        'generated': 'local',
        'source': 'test',
        'bundles': [],
      });
      expect(unversioned.revision, 0);
    });

    test('without raising the schema, so an older app still reads it', () {
      // A build that predates revisions ignores a key it does not know. Had
      // the schema moved, every installed app would refuse the new manifest as
      // `isFuture` and stop receiving updates altogether.
      final manifest = manifestOf(const [], revision: 20260912120000);
      expect(manifest.schema, 1);
      expect(manifest.isFuture, isFalse);
    });
  });

  group('the shipped manifest', () {
    final shipped = File(
        '../Wh40k_Companion/packages/wh40k_app/assets/bundles/manifest.json');

    test('is versioned', () {
      if (!shipped.existsSync()) return;
      final manifest =
          DatasetManifest.fromJson(jsonDecode(shipped.readAsStringSync()));
      expect(manifest.revision, greaterThan(20260101000000),
          reason: 'run tools/rebuild-assets.sh — an unversioned build loses '
              'to any published dataset, including an older one');
    }, skip: shipped.existsSync() ? null : 'no sibling app checkout');
  });
}
