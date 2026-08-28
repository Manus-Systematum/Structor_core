/// Corrections that ship separately from the data they correct (§3.15).
///
/// **The problem.** 40kdc publishes 11th-edition records ahead of the rules,
/// marked `pre-launch-provisional`. When Games Workshop then publishes the
/// Faction Packs, those provisional records are wrong in both directions:
/// missing the wording, and listing stratagems the released detachment does
/// not have. Waiting for the upstream source to catch up leaves the app
/// confidently wrong; editing the upstream snapshot in place makes the next
/// `tools/fetch-40kdc.sh` silently undo the fix.
///
/// **The shape.** A patch is a list of operations over the *source records* —
/// the raw JSON a bundle carries, before any model class has seen it. Three
/// operations cover everything: `set` merges fields into a record, `remove`
/// drops one, `add` appends one.
///
/// Patching the raw maps rather than the parsed models is what makes a patch
/// outlive the build that reads it. A field this version of the app knows
/// nothing about survives the round trip and is picked up the moment a later
/// version's `fromJson` looks for it, so a patch can carry a correction the
/// installed app cannot yet use rather than being rejected by it.
///
/// **It is meant to be deleted.** Each patch names the dataslate it corrects.
/// When 40kdc republishes against the released rules, the patch file and its
/// manifest row go, and nothing else changes.
library;

import 'dart:convert';
import 'dart:io';

import '../source/json.dart';

/// A patch's row in the manifest.
///
/// Patches live in their own list rather than as another [BundleKind], and
/// deliberately: `BundleEntry.fromJson` reads any unrecognised kind as
/// `faction`, so an older build meeting a patch inside `bundles` would try to
/// load it as one. An unknown top-level key it simply ignores — old app, new
/// manifest, no patches applied, nothing broken.
class PatchEntry {
  final String id;
  final String name;

  /// File name relative to the manifest.
  final String file;

  /// SHA-256 of the compressed bytes.
  final String sha256;

  final int bytes;

  /// The upstream dataslate this exists to correct. When the source ships
  /// something else, the patch has done its job and can go.
  final String appliesTo;

  const PatchEntry({
    required this.id,
    required this.name,
    required this.file,
    required this.sha256,
    required this.bytes,
    required this.appliesTo,
  });

  factory PatchEntry.fromJson(Object? v) {
    final j = asMap(v);
    return PatchEntry(
      id: strOr(j['id'], ''),
      name: strOr(j['name'], ''),
      file: strOr(j['file'], ''),
      sha256: strOr(j['sha256'], ''),
      bytes: intOr(j['bytes'], 0),
      appliesTo: strOr(j['appliesTo'], ''),
    );
  }

  Map<String, Object?> toJson() => {
        'id': id,
        'name': name,
        'file': file,
        'sha256': sha256,
        'bytes': bytes,
        'appliesTo': appliesTo,
      };
}

enum PatchOp {
  /// Merge [PatchOperation.values] into the record with this id. Fields the
  /// operation does not name are left alone.
  set,

  /// Drop the record with this id.
  remove,

  /// Append the record. Replaces one already carrying the same id, so a patch
  /// applied twice says the same thing as a patch applied once.
  add,
}

class PatchOperation {
  /// The faction whose file this touches, or `core` for the shared one.
  final String faction;

  /// The file within the bundle, without its extension — `stratagems`.
  final String file;

  final PatchOp op;

  /// The record's id. Required by every operation, `add` included: a record
  /// with no id cannot be superseded, corrected or removed later.
  final String id;

  /// The field [id] is matched against. `id` for most files; `abilities`
  /// keys on `ability_id`, and the operation says so rather than the code
  /// carrying a table of exceptions that a new file would not be in.
  final String key;

  /// The fields to set, for `set` and `add`. Empty for `remove`.
  final Map<String, Object?> values;

  /// Why, in one line. Carried into the bundle so a reader who finds a
  /// surprising record can see what changed it without the source to hand.
  final String? note;

  const PatchOperation({
    required this.faction,
    required this.file,
    required this.op,
    required this.id,
    this.key = 'id',
    this.values = const {},
    this.note,
  });

  factory PatchOperation.fromJson(Object? v) {
    final j = asMap(v);
    return PatchOperation(
      faction: strOr(j['faction'], ''),
      file: strOr(j['file'], ''),
      op: switch (strOr(j['op'], 'set')) {
        'remove' => PatchOp.remove,
        'add' => PatchOp.add,
        _ => PatchOp.set,
      },
      id: strOr(j['id'], ''),
      key: strOr(j['key'], 'id'),
      values: asMap(j['values']),
      note: str(j['note']),
    );
  }

  Map<String, Object?> toJson() => {
        'faction': faction,
        'file': file,
        'op': op.name,
        'id': id,
        if (key != 'id') 'key': key,
        if (values.isNotEmpty) 'values': values,
        if (note != null) 'note': note,
      };
}

/// One patch file: what it is, what it corrects, and the operations in it.
class DatasetPatch {
  final String id;
  final String name;

  /// The upstream dataslate this corrects — the condition for deleting it.
  final String appliesTo;

  /// Where the corrections came from, for the reader and for the credits.
  final String source;

  final List<PatchOperation> operations;

  const DatasetPatch({
    required this.id,
    required this.name,
    required this.appliesTo,
    required this.source,
    required this.operations,
  });

  factory DatasetPatch.fromJson(Object? v) {
    final j = asMap(v);
    return DatasetPatch(
      id: strOr(j['id'], ''),
      name: strOr(j['name'], ''),
      appliesTo: strOr(j['appliesTo'], ''),
      source: strOr(j['source'], ''),
      operations: asList(j['operations']).map(PatchOperation.fromJson).toList(),
    );
  }

  Map<String, Object?> toJson() => {
        'id': id,
        'name': name,
        'appliesTo': appliesTo,
        'source': source,
        'operations': [for (final o in operations) o.toJson()],
      };

  List<int> encode() => gzip.encode(utf8.encode(jsonEncode(toJson())));

  static DatasetPatch decode(List<int> bytes) =>
      DatasetPatch.fromJson(jsonDecode(utf8.decode(gzip.decode(bytes))));
}

/// Every patch the app holds, applied in one pass.
///
/// Ordering is by patch id, which is a date — a later patch corrects an
/// earlier one rather than racing it, and the result does not depend on the
/// order the files happened to download in.
class PatchSet {
  final List<DatasetPatch> patches;

  PatchSet(List<DatasetPatch> patches)
      : patches = [...patches]..sort((a, b) => a.id.compareTo(b.id));

  const PatchSet.empty() : patches = const [];

  bool get isEmpty => patches.isEmpty;

  /// The records of one bundle file, with every operation for it applied.
  ///
  /// Returns the list unchanged when nothing addresses it, so the common case
  /// costs one lookup and no copying.
  List<Object?> apply(
    List<Object?> records, {
    required String faction,
    required String file,
  }) {
    final ops = [
      for (final patch in patches)
        for (final op in patch.operations)
          if (op.faction == faction && op.file == file && op.id.isNotEmpty) op,
    ];
    if (ops.isEmpty) return records;

    // Every file in one bundle keys the same way, so the field is taken from
    // the operations rather than guessed at per record.
    final key = ops.first.key;

    // Insertion order is the record order, so an untouched file comes back in
    // the order it was published in.
    final byId = <String, Map<String, Object?>>{};
    final loose = <Object?>[];
    for (final raw in records) {
      final id = raw is Map ? strOr(raw[key], '') : '';
      if (id.isEmpty) {
        loose.add(raw);
      } else {
        byId[id] = {...asMap(raw)};
      }
    }

    for (final op in ops) {
      switch (op.op) {
        case PatchOp.remove:
          byId.remove(op.id);
        case PatchOp.set:
          final existing = byId[op.id];
          // A `set` against a record that is not there is not an error worth
          // failing the load over: the upstream source may have removed it
          // already, which is the outcome the patch wanted anyway.
          if (existing != null) byId[op.id] = {...existing, ...op.values};
        case PatchOp.add:
          byId[op.id] = {...op.values, key: op.id};
      }
    }

    return [...byId.values, ...loose];
  }

  /// What this set changes, for the About screen and the logs.
  String get summary {
    if (patches.isEmpty) return 'No corrections applied.';
    final count = patches.fold(0, (n, p) => n + p.operations.length);
    final names = patches.map((p) => p.name).join(', ');
    return '$count correction${count == 1 ? '' : 's'} from $names.';
  }
}
