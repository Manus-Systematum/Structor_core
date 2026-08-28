/// Distributable dataset bundles and their manifest (DESIGN.md §3.4).
///
/// The app ships with no rules data of its own and fetches versioned bundles
/// instead. Until this existed, faction and mission data rode along as app
/// assets — which meant a second faction cost another quarter-megabyte in the
/// binary and a points update needed an App Store release.
///
/// A bundle is one gzipped JSON document per faction, plus one for the shared
/// core. The manifest lists them with a SHA-256 over the compressed bytes, so
/// a download can be verified and a cached copy can be skipped when unchanged.
///
/// **Not signed.** §3.4 calls for a signed manifest; this is integrity only.
/// A hash proves the bytes arrived intact, not that they came from you. Worth
/// adding before the manifest is served from anywhere the project does not
/// control.
library;

import 'dart:convert';
import 'dart:io';

import 'package:crypto/crypto.dart';

import '../source/json.dart';
import 'patch.dart';

const bundleSchemaVersion = 1;

enum BundleKind { core, faction }

class BundleEntry {
  final String id;
  final BundleKind kind;
  final String name;

  /// File name relative to the manifest.
  final String file;

  /// SHA-256 of the compressed bytes.
  final String sha256;

  final int bytes;

  /// Upstream revision this was built from, so a stale cache is detectable
  /// even when the file name is unchanged.
  final String revision;

  /// The faction this one inherits datasheets from, or null when it stands
  /// alone.
  ///
  /// The twelve Space Marine chapters publish their own detachments,
  /// stratagems and enhancements and **no datasheets at all** — a Blood
  /// Angels army fields Adeptus Astartes units. Naming the parent here rather
  /// than copying the datasheets into each chapter keeps twelve copies of the
  /// largest faction out of the download, and says what the data already
  /// says.
  final String? parentId;

  /// Other names this faction goes by, from its own record. Two factions
  /// publish one: Adeptus Astartes is also *Space Marines*, and an export
  /// written by a human is at least as likely to say that.
  final List<String> aliases;

  const BundleEntry({
    required this.id,
    required this.kind,
    required this.name,
    required this.file,
    required this.sha256,
    required this.bytes,
    required this.revision,
    this.parentId,
    this.aliases = const [],
  });

  factory BundleEntry.fromJson(Object? v) {
    final j = asMap(v);
    return BundleEntry(
      id: strOr(j['id'], ''),
      kind: strOr(j['kind'], 'faction') == 'core'
          ? BundleKind.core
          : BundleKind.faction,
      name: strOr(j['name'], ''),
      file: strOr(j['file'], ''),
      sha256: strOr(j['sha256'], ''),
      bytes: intOr(j['bytes'], 0),
      revision: strOr(j['revision'], 'unknown'),
      parentId: str(j['parentId']),
      aliases: strList(j['aliases']),
    );
  }

  Map<String, Object?> toJson() => {
        'id': id,
        'kind': kind.name,
        'name': name,
        'file': file,
        'sha256': sha256,
        'bytes': bytes,
        'revision': revision,
        if (parentId != null) 'parentId': parentId,
        if (aliases.isNotEmpty) 'aliases': aliases,
      };
}

/// A file the app fetches on demand rather than at load: a rendered terrain
/// layout, today (§3.17).
///
/// Kept out of `bundles` for the same reason patches are — an older build
/// reads an unknown `kind` as a faction — and out of the app binary because
/// forty-five of them is eleven megabytes for something most players open
/// rarely, if ever.
class AssetEntry {
  final String id;

  /// What it is, so a build that does not know this kind can skip it.
  final String kind;

  /// File name relative to the manifest.
  final String file;

  /// SHA-256 of the bytes.
  final String sha256;

  final int bytes;

  const AssetEntry({
    required this.id,
    required this.kind,
    required this.file,
    required this.sha256,
    required this.bytes,
  });

  factory AssetEntry.fromJson(Object? v) {
    final j = asMap(v);
    return AssetEntry(
      id: strOr(j['id'], ''),
      kind: strOr(j['kind'], ''),
      file: strOr(j['file'], ''),
      sha256: strOr(j['sha256'], ''),
      bytes: intOr(j['bytes'], 0),
    );
  }

  Map<String, Object?> toJson() => {
        'id': id,
        'kind': kind,
        'file': file,
        'sha256': sha256,
        'bytes': bytes,
      };
}

class DatasetManifest {
  final int schema;
  final String generated;
  final String source;
  final List<BundleEntry> bundles;

  /// Corrections to apply on top of the bundles (§3.15).
  ///
  /// A list of their own rather than another [BundleKind], and the schema
  /// stays at 1: a build that predates patches reads `bundles` and ignores a
  /// key it does not know, so it keeps working unpatched. Had these ridden
  /// along inside `bundles`, that same build would have read `kind: patch` as
  /// `faction` — [BundleEntry.fromJson] falls back — and tried to load a
  /// patch as an army.
  final List<PatchEntry> patches;

  /// Files fetched on demand — the rendered terrain layouts (§3.17).
  final List<AssetEntry> assets;

  const DatasetManifest({
    required this.generated,
    required this.source,
    required this.bundles,
    this.patches = const [],
    this.assets = const [],
    this.schema = bundleSchemaVersion,
  });

  factory DatasetManifest.fromJson(Object? v) {
    final j = asMap(v);
    return DatasetManifest(
      schema: intOr(j['schema'], 0),
      generated: strOr(j['generated'], ''),
      source: strOr(j['source'], ''),
      bundles: asList(j['bundles']).map(BundleEntry.fromJson).toList(),
      patches: asList(j['patches']).map(PatchEntry.fromJson).toList(),
      assets: asList(j['assets']).map(AssetEntry.fromJson).toList(),
    );
  }

  Map<String, Object?> toJson() => {
        'schema': schema,
        'generated': generated,
        'source': source,
        'bundles': [for (final b in bundles) b.toJson()],
        if (patches.isNotEmpty)
          'patches': [for (final p in patches) p.toJson()],
        if (assets.isNotEmpty) 'assets': [for (final a in assets) a.toJson()],
      };

  /// True when this manifest was produced by a newer builder than this build
  /// understands. Refusing is safer than guessing at unknown fields.
  bool get isFuture => schema > bundleSchemaVersion;

  BundleEntry? entry(String id) {
    for (final bundle in bundles) {
      if (bundle.id == id) return bundle;
    }
    return null;
  }

  /// Every asset of one kind, by id.
  Map<String, AssetEntry> assetsOf(String kind) => {
        for (final a in assets)
          if (a.kind == kind) a.id: a,
      };

  List<BundleEntry> get factions =>
      bundles.where((b) => b.kind == BundleKind.faction).toList()
        ..sort((a, b) => a.name.compareTo(b.name));
}

/// The payload of one bundle: named JSON documents, exactly as published
/// upstream.
///
/// Records are kept in source form for the same reason snapshots are (§2.2):
/// a bundle downloaded today must stay readable by a build whose model has
/// since moved on.
class DatasetBundle {
  final String id;
  final BundleKind kind;
  final String revision;
  final Map<String, List<Object?>> files;

  const DatasetBundle({
    required this.id,
    required this.kind,
    required this.revision,
    required this.files,
  });

  factory DatasetBundle.fromJson(Object? v) {
    final j = asMap(v);
    final raw = asMap(j['files']);
    return DatasetBundle(
      id: strOr(j['id'], ''),
      kind: strOr(j['kind'], 'faction') == 'core'
          ? BundleKind.core
          : BundleKind.faction,
      revision: strOr(j['revision'], 'unknown'),
      files: {
        for (final entry in raw.entries)
          entry.key: entry.value is List
              ? entry.value as List<Object?>
              : const <Object?>[],
      },
    );
  }

  Map<String, Object?> toJson() => {
        'id': id,
        'kind': kind.name,
        'revision': revision,
        'files': files,
      };

  List<Object?> file(String name) => files[name] ?? const [];

  /// Gzipped UTF-8 JSON — the wire form.
  List<int> encode() => gzip.encode(utf8.encode(jsonEncode(toJson())));

  static DatasetBundle decode(List<int> compressed) =>
      DatasetBundle.fromJson(jsonDecode(utf8.decode(gzip.decode(compressed))));
}

String sha256Of(List<int> bytes) => sha256.convert(bytes).toString();
