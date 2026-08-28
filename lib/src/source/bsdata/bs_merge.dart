/// Merging BSData over 40kdc, and writing down where they disagree (§3.10).
///
/// The rule is one line: **BSData wins, 40kdc fills the gaps.** What makes it
/// worth a file is that "gap" has three different meanings, and conflating
/// them loses data.
///
///   - *A record BSData does not have.* Combat Patrol formations, the Crimson
///     Fists — kept whole from 40kdc.
///   - *A field BSData does not produce.* Structured ability effects, phase
///     mappings, base sizes, attachment roles. The BSData record wins on
///     everything it states and inherits the rest, rather than replacing the
///     40kdc record wholesale — a replacement would silently drop the
///     enrichment layer the play surfaces render from.
///   - *A field both state differently.* The conflict. BSData's value is
///     taken and the disagreement is written to the log, because a source
///     swap that quietly changes points is the failure this project has
///     already been bitten by (§3.5).
library;

import '../json.dart';

/// One disagreement between the two lineages.
class DataConflict {
  final String faction;
  final String kind;
  final String id;
  final String field;
  final Object? bsdata;
  final Object? fortykdc;

  const DataConflict({
    required this.faction,
    required this.kind,
    required this.id,
    required this.field,
    required this.bsdata,
    required this.fortykdc,
  });

  Map<String, Object?> toJson() => {
        'faction': faction,
        'kind': kind,
        'id': id,
        'field': field,
        'bsdata': bsdata,
        '40kdc': fortykdc,
        // Recorded on every row rather than stated once in a header: a row
        // pasted into an issue should say on its own which value shipped.
        'resolution': 'bsdata',
      };
}

class MergeResult {
  final List<Map<String, Object?>> records;
  final List<DataConflict> conflicts;

  /// Ids only 40kdc had, kept as they were.
  final List<String> keptFrom40kdc;

  /// Ids only BSData had.
  final List<String> addedByBsdata;

  const MergeResult({
    required this.records,
    required this.conflicts,
    required this.keptFrom40kdc,
    required this.addedByBsdata,
  });
}

/// Merges two record lists keyed by [idField].
///
/// [compare] names the fields worth diffing; everything else is merged without
/// comment. Passing it explicitly rather than diffing every shared key is what
/// keeps the log about points and profiles instead of about provenance.
MergeResult mergeRecords({
  required String faction,
  required String kind,
  required String idField,
  required List<Object?> bsdata,
  required List<Object?> fortykdc,
  required Set<String> compare,
  /// When true, a BSData record only fills a gap: where 40kdc already has one,
  /// the 40kdc record stands untouched. For data BSData produces more thinly
  /// than 40kdc does, overwriting loses more than it gains.
  bool fillOnly = false,
  /// Fields where 40kdc's value stands even though BSData produced one.
  Set<String> keepFrom40kdc = const {},
  /// List fields where both sources' entries are kept, deduplicated.
  ///
  /// Wargear budgets are the case: 40kdc lists what a datasheet may buy and
  /// BSData lists what its wargear groups offer, and the two overlap without
  /// either being complete. Taking one and dropping the other loses options a
  /// player has.
  Set<String> union = const {},
}) {
  final conflicts = <DataConflict>[];
  final byId = <String, Map<String, dynamic>>{};
  final order = <String>[];

  for (final raw in fortykdc) {
    final record = asMap(raw);
    final id = str(record[idField]);
    if (id == null) continue;
    byId[id] = record;
    order.add(id);
  }
  final had40kdc = byId.keys.toSet();

  final added = <String>[];
  for (final raw in bsdata) {
    final incoming = asMap(raw);
    final id = str(incoming[idField]);
    if (id == null) continue;

    final existing = byId[id];
    if (existing != null && fillOnly) continue;
    if (existing == null) {
      byId[id] = incoming;
      order.add(id);
      added.add(id);
      continue;
    }

    for (final key in compare) {
      if (!incoming.containsKey(key) || !existing.containsKey(key)) continue;
      // An absence is not a disagreement. Where BSData produced nothing the
      // 40kdc value stands, and saying so in the conflict log would bury the
      // rows where the two sources genuinely differ.
      if (_isEmpty(incoming[key]) && !_isEmpty(existing[key])) continue;
      final mine = incoming[key];
      final theirs = existing[key];
      if (_sameValue(mine, theirs)) continue;
      conflicts.add(DataConflict(
        faction: faction,
        kind: kind,
        id: id,
        field: key,
        bsdata: mine,
        fortykdc: theirs,
      ));
    }

    // The 40kdc record is the base and BSData is written over it, so a field
    // only 40kdc has — a structured effect, a base size — survives.
    final merged = Map<String, dynamic>.from(existing);
    for (final entry in incoming.entries) {
      // **Empty never wins.** BSData is primary, but a field it failed to
      // produce is a gap in the reading, not a statement that the datasheet
      // has none — and seven units came through with no points at all, which
      // would have shipped them as free.
      if (_isEmpty(entry.value) && !_isEmpty(existing[entry.key])) continue;
      // A unit's weapon list stays 40kdc's for the same reason its weapons do:
      // 40kdc scopes a Commander's missile pod to the Commander and BSData
      // does not, so taking BSData's list points the unit at the generic gun.
      if (keepFrom40kdc.contains(entry.key) &&
          !_isEmpty(existing[entry.key])) {
        continue;
      }
      if (union.contains(entry.key)) {
        merged[entry.key] = _union(existing[entry.key], entry.value);
        continue;
      }
      merged[entry.key] = entry.value;
    }
    // Both lineages are in the record now, so it says so.
    merged['sources'] = ['bsdata', '40kdc'];
    byId[id] = merged;
  }

  return MergeResult(
    records: [for (final id in order) byId[id]!],
    conflicts: conflicts,
    keptFrom40kdc:
        had40kdc.where((id) => !_touchedByBsdata(byId[id])).toList(growable: false),
    addedByBsdata: added,
  );
}

bool _touchedByBsdata(Map<String, dynamic>? record) =>
    record != null && record['sources'] != null ||
    strOr(asMap(record?['game_version'])['dataslate'], '') == 'bsdata';

/// Both lists, with entries naming an item already present dropped.
List<Object?> _union(Object? mine, Object? theirs) {
  final out = <Object?>[...asList(mine)];
  final seen = <String>{
    for (final raw in out) ...strList(asMap(raw)['items']),
  };
  for (final raw in asList(theirs)) {
    final items = strList(asMap(raw)['items']);
    if (items.any(seen.contains)) continue;
    seen.addAll(items);
    out.add(raw);
  }
  return out;
}

bool _isEmpty(Object? v) =>
    v == null || (v is Iterable && v.isEmpty) || (v is Map && v.isEmpty);

/// Value equality that ignores how a number was spelled.
///
/// One source writes `4` and the other `"4"` for the same Toughness, and a
/// literal comparison would report every characteristic on every datasheet.
bool _sameValue(Object? a, Object? b) {
  if (a == null && b == null) return true;
  if (a is List && b is List) {
    if (a.length != b.length) return false;
    // Order-insensitive. A points table is a set of brackets, not a sequence,
    // and the two sources list them in different orders — 40kdc groups by
    // copy count and BSData by model count. Comparing positionally reported
    // every multi-bracket datasheet as a conflict over nothing.
    final remaining = [...b];
    for (final item in a) {
      final index = remaining.indexWhere((other) => _sameValue(item, other));
      if (index < 0) return false;
      remaining.removeAt(index);
    }
    return true;
  }
  if (a is Map && b is Map) {
    final am = asMap(a);
    final bm = asMap(b);
    final keys = {...am.keys, ...bm.keys};
    for (final k in keys) {
      if (!_sameValue(am[k], bm[k])) return false;
    }
    return true;
  }
  final an = asInt(a);
  final bn = asInt(b);
  if (an != null && bn != null) return an == bn;
  return _foldApostrophes(str(a)) == _foldApostrophes(str(b));
}

/// One source types `T'au`, the other `T’au`.
///
/// That is an encoding difference, not a disagreement about the data, and left
/// alone it filled the log with a row per faction for every name containing an
/// apostrophe — burying the conflicts worth reading. Nothing else about the
/// string is folded: `T'au flamer` against `T'au-tech rifle` is a real
/// difference and stays visible.
String? _foldApostrophes(String? value) =>
    value?.trim().replaceAll(RegExp(r'[’‘ʼ]'), "'");
