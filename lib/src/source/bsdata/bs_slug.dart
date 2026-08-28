/// Turning BattleScribe names into this project's ids (DESIGN.md §3.10).
///
/// BattleScribe ids are opaque — `4d0d-af9d-53c2-bc31` — and nothing else in
/// the project speaks them: saved rosters, corrections, the reference fixture
/// and every 40kdc record are keyed by slug. Mapping names into that same id
/// space is therefore not cosmetic. It is what lets the two sources be
/// compared at all, and what stops a source swap invalidating every list a
/// player has already saved.
///
/// Measured on T'au: 43 of 47 40kdc datasheets are hit by slugifying the
/// BSData name. The four that are not are Combat Patrol formations 40kdc
/// carries and BSData does not, so they are absences rather than mismatches.
library;

/// Suffixes BSData appends to a name to mark which pool a datasheet is in.
///
/// They are shelf labels, not part of the datasheet's identity: `Longstrike
/// [Legends]` is the same unit 40kdc files as `longstrike`. The flag is not
/// discarded — [isLegends] reads it — only kept out of the id.
final _bracketed = RegExp(r'\s*\[[^\]]*\]\s*');

final _apostrophes = RegExp(r"[’‘ʼ']");
final _separators = RegExp(r'[^a-z0-9]+');

/// Accented letters, folded to the plain one 40kdc's ids already use.
///
/// **Without this a name splits into two datasheets.** `Brôkhyr Iron-master`
/// slugs to `brokhyr-iron-master` in 40kdc, which transliterates, and to
/// `br-khyr-iron-master` here, where `ô` is not `[a-z0-9]` and becomes a
/// separator. The two never met, so the merge added a second copy of the
/// datasheet instead of filling in the first: five Leagues of Votann units
/// and Khârn the Betrayer were each offered twice in the picker, one of them
/// unpriced.
const _accents = {
  'à': 'a',
  'á': 'a',
  'â': 'a',
  'ã': 'a',
  'ä': 'a',
  'å': 'a',
  'è': 'e',
  'é': 'e',
  'ê': 'e',
  'ë': 'e',
  'ì': 'i',
  'í': 'i',
  'î': 'i',
  'ï': 'i',
  'ò': 'o',
  'ó': 'o',
  'ô': 'o',
  'õ': 'o',
  'ö': 'o',
  'ø': 'o',
  'ù': 'u',
  'ú': 'u',
  'û': 'u',
  'ü': 'u',
  'ý': 'y',
  'ÿ': 'y',
  'ñ': 'n',
  'ç': 'c',
  'ß': 'ss',
  'æ': 'ae',
};

String _fold(String value) {
  final out = StringBuffer();
  for (final rune in value.runes) {
    final ch = String.fromCharCode(rune);
    out.write(_accents[ch] ?? ch);
  }
  return out.toString();
}

/// `Commander in Coldstar Battlesuit` -> `commander-in-coldstar-battlesuit`.
///
/// Apostrophes are deleted rather than turned into separators, so `T'au` folds
/// to `tau` and `Shas'vre` to `shasvre` — the same rule `normalise` uses for
/// import matching, and the one 40kdc's own ids follow.
String bsSlug(String name) {
  final bare = _fold(name
      .replaceAll(_bracketed, ' ')
      .replaceAll(_apostrophes, '')
      .toLowerCase());
  return bare.replaceAll(_separators, '-').replaceAll(RegExp(r'^-|-$'), '');
}

/// Whether BSData has shelved this datasheet away from matched play.
///
/// `[Legends]` and `[Crucible]` are both out of the tournament pool; the app
/// already filters on the same distinction 40kdc records as `is_legend`.
bool isLegends(String name) {
  final lower = name.toLowerCase();
  return lower.contains('[legends]') || lower.contains('[crucible]');
}

/// The name with the shelf label removed, for display.
String bsDisplayName(String name) => name.replaceAll(_bracketed, ' ').trim();
