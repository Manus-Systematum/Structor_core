/// Tolerant JSON accessors for the 40kdc source format.
///
/// The upstream data is community-authored and legitimately heterogeneous:
/// a weapon's `A` is `2` on a missile pod and `"D6"` on a flamer, `BS` is
/// `null` on Torrent weapons, and optional fields are sometimes absent rather
/// than null. Parsing must bend rather than throw — a single malformed record
/// should degrade one entity, not fail an entire faction.
library;

Map<String, dynamic> asMap(Object? v) =>
    v is Map ? v.map((k, val) => MapEntry(k.toString(), val)) : <String, dynamic>{};

List<Object?> asList(Object? v) => v is List ? v : const [];

/// Stringifies scalars, preserving `null`. Numbers become their plain form so
/// that `2` reads as `"2"` rather than `"2.0"`.
String? str(Object? v) {
  if (v == null) return null;
  if (v is num && v == v.roundToDouble() && v.isFinite) {
    return v.toInt().toString();
  }
  return v.toString();
}

String strOr(Object? v, String fallback) => str(v) ?? fallback;

int? asInt(Object? v) {
  if (v is int) return v;
  if (v is num) return v.toInt();
  if (v is String) return int.tryParse(v.trim());
  return null;
}

int intOr(Object? v, int fallback) => asInt(v) ?? fallback;

/// Board geometry arrives as a mix of ints and decimals — a deployment zone
/// corner is `12`, a terrain footprint vertex is `7.2668` — so coordinates are
/// read as doubles throughout rather than losing the fraction.
double? asDouble(Object? v) {
  if (v is num) return v.toDouble();
  if (v is String) return double.tryParse(v.trim());
  return null;
}

double dblOr(Object? v, double fallback) => asDouble(v) ?? fallback;

/// String list from a JSON array, dropping nulls and empties.
List<String> strList(Object? v) => asList(v)
    .map(str)
    .whereType<String>()
    .where((s) => s.isNotEmpty)
    .toList(growable: false);

/// Reads the first present key from [keys]. Upstream sometimes renames fields
/// between dataslates (`unique_tags` vs `tags`), so callers name both.
Object? pick(Map<String, dynamic> json, List<String> keys) {
  for (final k in keys) {
    final v = json[k];
    if (v != null) return v;
  }
  return null;
}
