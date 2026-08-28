/// Builds distributable dataset bundles from a 40kdc snapshot (DESIGN.md §3.4).
///
///     dart run bin/bundle.dart [--data <dir>] [--out <dir>] [--revision <rev>]
///
/// Writes one gzipped bundle per faction plus a shared core bundle, and a
/// manifest listing them with sizes and SHA-256 hashes. The output directory
/// is a complete static site: copy it to Pages, a Release or a bucket.
library;

import 'dart:convert';
import 'dart:io';

import 'package:wh40k_core/wh40k_core.dart';

import 'paths.dart';

const _coreFiles = [
  'force-dispositions',
  'missions',
  'mission-matchups',
  'secondary-cards',
  'deployment-patterns',
  // The competitive terrain layouts and the piece shapes they place. ~21 KB
  // gzipped together, against a 10 KB core bundle — the layouts are what turn
  // the deployment diagram from a picture of two zones into the actual table.
  'terrain-layouts',
  'terrain-templates',
  'weapon-keywords',
  'unit-keywords',
  'stratagems',
];

const _factionFiles = [
  // The faction's own record: its display name, its army rule, and the
  // aliases the importer matches an export's faction line against. Bundling
  // it was overlooked, so `factionRuleId` arrived null in the app and every
  // roster built or imported there lost For the Greater Good / Oath of
  // Moment — while the CLI, which reads the snapshot directly, kept it.
  'factions',
  'units',
  'weapons',
  'wargear',
  'wargear-options',
  'unit-compositions',
  'detachments',
  'enhancements',
  'leader-attachments',
  'stratagems',
];

const _enrichmentFiles = ['abilities', 'phase-mappings'];

void main(List<String> args) {
  var dataDir = '$dataRoot/40kdc';
  var outDir = '$projectRoot/dist';
  var revision = 'local';
  var correctionsPath = '$projectRoot/data-corrections.yaml';
  var updatesDir = '$dataRoot/updates';
  var layoutsDir = '';
  var layoutOut = '';

  for (var i = 0; i < args.length; i++) {
    switch (args[i]) {
      case '--data':
        if (i + 1 < args.length) dataDir = args[++i];
      case '--out':
        if (i + 1 < args.length) outDir = args[++i];
      case '--revision':
        if (i + 1 < args.length) revision = args[++i];
      case '--corrections':
        if (i + 1 < args.length) correctionsPath = args[++i];
      case '--updates':
        if (i + 1 < args.length) updatesDir = args[++i];
      case '--layouts':
        if (i + 1 < args.length) layoutsDir = args[++i];
      case '--layout-out':
        if (i + 1 < args.length) layoutOut = args[++i];
      case '-h':
      case '--help':
        stdout.writeln('usage: dart run bin/bundle.dart '
            '[--data <dir>] [--out <dir>] [--revision <rev>] '
            '[--corrections <file>] [--updates <dir>] '
            '[--layouts <dir>] [--layout-out <dir>]');
        return;
    }
  }

  final loader = DatasetLoader(
    dataDir,
    corrections: DatasetLoader.correctionsAt(correctionsPath),
  );
  if (!loader.root.existsSync()) {
    stderr.writeln('no snapshot at $dataDir - run tools/fetch-40kdc.sh first');
    exit(2);
  }

  final out = Directory(outDir);
  if (!out.existsSync()) out.createSync(recursive: true);

  List<Object?> read(String path) {
    final file = File('$dataDir/$path.json');
    if (!file.existsSync()) return const [];
    final decoded = jsonDecode(file.readAsStringSync());
    return decoded is List ? decoded : const [];
  }

  final entries = <BundleEntry>[];
  final correctionNotes = <String>[];
  final staleCorrections = <String>[];
  final appliedCorrections = <Correction>[];

  BundleEntry write(DatasetBundle bundle, String displayName,
      {String? parentId, List<String> aliases = const []}) {
    final compressed = bundle.encode();
    final digest = sha256Of(compressed);
    final file = _published('${bundle.id}.json.gz', digest);
    File('$outDir/$file').writeAsBytesSync(compressed);
    return BundleEntry(
      id: bundle.id,
      kind: bundle.kind,
      name: displayName,
      file: file,
      sha256: digest,
      bytes: compressed.length,
      revision: bundle.revision,
      parentId: parentId,
      aliases: aliases,
    );
  }

  stdout.writeln('bundling from $dataDir\n');

  entries.add(write(
    DatasetBundle(
      id: 'core',
      kind: BundleKind.core,
      revision: revision,
      files: {
        for (final f in _coreFiles) f: read('core/$f'),
        // The Chapter Approved Mission Deck's own questions, which belong to
        // no faction (§3.16). Empty here; the patch supplies them.
        'faqs': read('core/faqs'),
      },
    ),
    'Core rules data',
  ));

  for (final factionId in loader.availableFactions()) {
    final files = <String, List<Object?>>{
      for (final f in _factionFiles) f: read('core/$factionId/$f'),
      // Empty from 40kdc, which publishes no FAQs. The file exists so the
      // August patch has somewhere to add them, and so a later one can
      // replace them without an app release (§3.16).
      'faqs': read('core/$factionId/faqs'),
      for (final f in _enrichmentFiles) f: read('enrichment/$factionId/$f'),
    };

    for (final corrected in [
      loader.correctedAbilities(factionId),
      loader.correctedUnits(factionId),
      loader.correctedWeapons(factionId),
    ]) {
      for (final c in corrected.applied) {
        correctionNotes.add('$factionId/${c.subject}');
        appliedCorrections.add(c);
      }
      for (final c in corrected.unmatched) {
        staleCorrections.add('$factionId/${c.subject}');
      }
    }
    files['abilities'] = loader.correctedAbilities(factionId).records;
    files['units'] = loader.correctedUnits(factionId).records;
    files['weapons'] = loader.correctedWeapons(factionId).records;

    final self = files['factions']!
        .whereType<Map<String, Object?>>()
        .where((j) => j['id']?.toString() == factionId)
        .firstOrNull;
    final displayName = self?['name']?.toString();
    final parentId = self?['parent_faction_id']?.toString();

    // No datasheets and no parent is a faction that cannot field an army —
    // an upstream stub rather than something to offer in the picker. With a
    // parent it is a chapter, whose datasheets are the parent's.
    if (files['units']!.isEmpty && parentId == null) {
      stdout.writeln('  skip $factionId (no units, no parent)');
      continue;
    }
    // The faction's published name — `T’au Empire`, not the `Tau Empire` that
    // title-casing the id produces. Falls back to the id when the record is
    // absent, so a faction still lists rather than vanishing.
    entries.add(write(
      DatasetBundle(
        id: factionId,
        kind: BundleKind.faction,
        revision: revision,
        files: files,
      ),
      displayName == null || displayName.isEmpty
          ? _title(factionId)
          : displayName,
      parentId: parentId,
      aliases: [
        for (final a in (self?['aliases'] as List? ?? const []))
          if (a != null && a.toString().isNotEmpty) a.toString(),
      ],
    ));
  }

  // Corrections ship as their own downloads (§3.15), so a rules update that
  // the upstream source has not caught up with reaches installed apps through
  // the manifest rather than through the App Store. Adding one later is a new
  // file here and a new row there; nothing in the app changes.
  final patches = <PatchEntry>[];
  final updates = Directory(updatesDir);
  if (updates.existsSync()) {
    final files = updates
        .listSync()
        .whereType<File>()
        .where((f) => f.path.endsWith('.json'))
        .toList()
      ..sort((a, b) => a.path.compareTo(b.path));
    for (final source in files) {
      final patch =
          DatasetPatch.fromJson(jsonDecode(source.readAsStringSync()));
      if (patch.id.isEmpty || patch.operations.isEmpty) continue;
      final compressed = patch.encode();
      final digest = sha256Of(compressed);
      final file = _published('patch-${patch.id}.json.gz', digest);
      File('$outDir/$file').writeAsBytesSync(compressed);
      patches.add(PatchEntry(
        id: patch.id,
        name: patch.name,
        file: file,
        sha256: digest,
        bytes: compressed.length,
        appliesTo: patch.appliesTo,
      ));
    }
  }

  // The rendered terrain layouts, fetched on demand (§3.17). Copied rather
  // than compressed: a PNG is already compressed, and gzipping it again buys
  // nothing but a decode step on a phone.
  final assets = <AssetEntry>[];
  // Named rather than derived: the last attempt guessed a relative path and
  // wrote eleven megabytes outside the repository.
  final imagesDir =
      layoutOut.isNotEmpty ? layoutOut : '$outDir/../layout-images';
  if (layoutsDir.isNotEmpty && Directory(layoutsDir).existsSync()) {
    final images = Directory(layoutsDir)
        .listSync()
        .whereType<File>()
        .where((f) => f.path.endsWith('.png'))
        .toList()
      ..sort((a, b) => a.path.compareTo(b.path));
    for (final image in images) {
      final bytes = image.readAsBytesSync();
      final digest = sha256Of(bytes);
      final name = _published(image.uri.pathSegments.last, digest);
      // Written beside the bundles but **not** into the app's assets: forty
      // five of them is eleven megabytes and the whole data bundle is six.
      // They are fetched on demand from wherever the manifest is served
      // (§3.4); until that is configured the app has no image to show and
      // says so rather than offering a button that does nothing.
      final at = File('$imagesDir/$name')..createSync(recursive: true);
      at.writeAsBytesSync(bytes);
      assets.add(AssetEntry(
        // The id is the layout's own name, which the app asks for; the file
        // beside it carries the hash.
        id: image.uri.pathSegments.last.replaceAll('.png', ''),
        kind: 'terrain-layout',
        file: 'layout-images/$name',
        sha256: digest,
        bytes: bytes.length,
      ));
    }
  }

  final manifest = DatasetManifest(
    // Stamped by the caller rather than read from the clock, so a rebuild of
    // the same revision produces byte-identical bundles.
    generated: revision,
    source: '40kdc-data',
    bundles: entries,
    patches: patches,
    assets: assets,
  );
  File('$outDir/manifest.json').writeAsStringSync(
      '${const JsonEncoder.withIndent('  ').convert(manifest.toJson())}\n');

  // Content-named files are never overwritten, so the previous build's copies
  // are still here. Left alone they would ship in the binary and be published
  // beside the current ones — dead weight that nothing points at.
  final published = {
    for (final entry in entries) entry.file,
    for (final patch in patches) patch.file,
  };
  final swept = _sweep(Directory(outDir), '.json.gz', published);
  final sweptImages = assets.isEmpty
      ? 0
      : _sweep(Directory(imagesDir), '.png',
          {for (final asset in assets) asset.file.split('/').last});
  if (swept + sweptImages > 0) {
    stdout.writeln('swept ${swept + sweptImages} superseded '
        'file${swept + sweptImages == 1 ? '' : 's'}\n');
  }

  var total = 0;
  for (final entry in entries) {
    total += entry.bytes;
    stdout.writeln('  ${entry.file.padRight(34)} '
        '${_kb(entry.bytes).padLeft(8)}  ${entry.sha256.substring(0, 12)}');
  }
  stdout
    ..writeln()
    ..writeln('${entries.length} bundles, ${_kb(total)} total')
    ..writeln('manifest: $outDir/manifest.json');

  if (assets.isNotEmpty) {
    final total = assets.fold(0, (n, a) => n + a.bytes);
    stdout.writeln('  ${assets.length} layout images, ${_kb(total)} '
        '(fetched on demand)');
  }

  for (final patch in patches) {
    final ops =
        DatasetPatch.decode(File('$outDir/${patch.file}').readAsBytesSync())
            .operations;
    stdout.writeln('  ${patch.file.padRight(34)} '
        '${_kb(patch.bytes).padLeft(8)}  ${ops.length} corrections '
        '(${patch.appliesTo})');
  }

  for (final c in loader.corrections.neverApplied(appliedCorrections)) {
    staleCorrections.add('*/${c.subject}');
  }

  if (correctionNotes.isNotEmpty) {
    stdout.writeln('\ncorrections applied: ${correctionNotes.join(', ')}');
  }
  // A correction that matches nothing is either a typo or one upstream has
  // since adopted. Either way it is now shadowing nothing and should go.
  if (staleCorrections.isNotEmpty) {
    stderr.writeln('\nWARNING: corrections matched no ability — remove them '
        'from $correctionsPath if upstream has fixed the data:\n'
        '  ${staleCorrections.join('\n  ')}');
  }
}

/// Deletes files of a kind that the manifest no longer names.
///
/// Scoped by extension and by directory: this runs over the app's own asset
/// folder, and a sweep that took anything it did not recognise would be one
/// wrong `--out` away from deleting the wrong tree.
int _sweep(Directory dir, String extension, Set<String> keep) {
  if (!dir.existsSync()) return 0;
  var swept = 0;
  for (final file in dir.listSync().whereType<File>()) {
    final name = file.uri.pathSegments.last;
    if (!name.endsWith(extension) || keep.contains(name)) continue;
    file.deleteSync();
    swept++;
  }
  return swept;
}

String _kb(int bytes) => '${(bytes / 1024).toStringAsFixed(1)} KB';

String _title(String id) => id
    .split('-')
    .map((w) => w.isEmpty ? w : '${w[0].toUpperCase()}${w.substring(1)}')
    .join(' ');

/// `core.json.gz` published as `core.4b8f2a1c9e70.json.gz` (§3.19).
///
/// The content decides the name, so a file that changed is a URL nothing has
/// ever cached and a file that did not keeps the URL everything already has.
/// Twelve hex characters is what the build log already prints of the digest,
/// and the app verifies the whole of it anyway — the name only has to be
/// unique, not authoritative.
///
/// The hash goes before the extension rather than after the stem, so
/// `core.json.gz` keeps its `.json.gz` and the server keeps typing it right.
String _published(String name, String sha256) {
  final dot = name.indexOf('.');
  final stem = dot == -1 ? name : name.substring(0, dot);
  final extension = dot == -1 ? '' : name.substring(dot);
  return '$stem.${sha256.substring(0, 12)}$extension';
}
