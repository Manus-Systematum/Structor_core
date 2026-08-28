/// Compact stable identifiers for content, used by the QR payload (§6.4).
///
/// A QR list names things by **hash of the semantic id**, not by index into a
/// dataset table. Indices are a byte cheaper but break the moment two devices
/// are on different dataset revisions — which at a tournament is the common
/// case, not the edge case. Hashing costs about 150 bytes on a 2,000 pt list
/// and buys full version independence.
///
/// This is an identity shortener, not a security primitive: FNV-1a truncated
/// to 24 bits, chosen because it is dependency-free and byte-identical on every
/// platform. Collisions are not tolerated in silence — [ContentHasher.collisions]
/// finds them at build time so the namespace can be widened before shipping.
library;

/// 24-bit FNV-1a over the UTF-16 code units of [id].
int contentHash24(String id) {
  const offsetBasis = 0x811c9dc5;
  const prime = 0x01000193;

  var hash = offsetBasis;
  for (final unit in id.codeUnits) {
    hash ^= unit & 0xff;
    hash = (hash * prime) & 0xffffffff;
    if (unit > 0xff) {
      hash ^= (unit >> 8) & 0xff;
      hash = (hash * prime) & 0xffffffff;
    }
  }
  // Fold the high byte in rather than discarding it, so all 32 bits of
  // avalanche contribute to the 24 we keep.
  return (hash ^ (hash >> 24)) & 0xffffff;
}

/// Three big-endian bytes, the wire form for §6.4.
List<int> contentHashBytes(String id) {
  final hash = contentHash24(id);
  return [(hash >> 16) & 0xff, (hash >> 8) & 0xff, hash & 0xff];
}

String contentHashHex(String id) =>
    contentHash24(id).toRadixString(16).padLeft(6, '0');

/// Hashes a fixed namespace of ids and can report collisions within it.
class ContentHasher {
  final Map<int, List<String>> _byHash;

  ContentHasher(Iterable<String> ids) : _byHash = {} {
    for (final id in ids) {
      final bucket = _byHash.putIfAbsent(contentHash24(id), () => []);
      // One id registered from two tables is not a collision. A Thunderfire
      // Cannon is a datasheet *and* the gun on it, and both name the same
      // thing — reporting `[thunderfire-cannon, thunderfire-cannon]` said the
      // namespace needed widening when what it needed was a set.
      if (bucket.contains(id)) continue;
      bucket.add(id);
    }
  }

  int hashOf(String id) => contentHash24(id);

  /// Ids sharing a hash. Empty is the required state; anything else means the
  /// namespace must be widened to four bytes before the QR format can rely on
  /// three (§6.4).
  List<List<String>> get collisions =>
      _byHash.values.where((ids) => ids.length > 1).toList();

  /// Resolves a hash back to its id, or null when unknown or ambiguous.
  String? resolve(int hash) {
    final ids = _byHash[hash];
    return ids != null && ids.length == 1 ? ids.single : null;
  }

  int get size => _byHash.length;
}
