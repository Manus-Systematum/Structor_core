/// Reading BattleScribe catalogues (DESIGN.md §3.10).
///
/// BSData publishes JSON rather than the historic `.cat` XML, but the shape is
/// still BattleScribe's: a graph, not a table. Three things follow from that,
/// and every one of them is a thing 40kdc-data had already done for us.
///
/// **Entries live where they are declared, not where they are used.** A
/// catalogue's `entryLinks` point at `targetId`s that may be in the same file,
/// in a library file, in another faction's catalogue, or in the game system.
/// `Aeldari - Craftworlds.json` is 106 entry links and *no entries at all*, so
/// resolution is not an optimisation — nothing is readable without it.
///
/// **A link carries overrides.** The same weapon entry is linked from a dozen
/// datasheets, each supplying its own constraints. Resolving a link therefore
/// merges the target with the link, rather than simply returning the target.
///
/// **Ids are opaque.** `4d0d-af9d-53c2-bc31` means nothing outside BSData, and
/// nothing else in this project speaks it. Mapping to our own id space happens
/// one layer up, in `bs_mapper.dart`; this file stays faithful to the source.
library;

import 'dart:convert';
import 'dart:io';

import '../json.dart';

/// One node of the catalogue graph.
///
/// Deliberately untyped beyond the handful of fields every kind of node has.
/// BattleScribe uses the same envelope for a datasheet, a model, a weapon and
/// a wargear option, distinguished only by `type` and by which lists are
/// populated, and modelling each as its own class would mean guessing at that
/// distinction before the data has been read.
class BsEntry {
  final Map<String, dynamic> json;

  /// The catalogue this node was declared in. Kept because a resolved entry
  /// can come from a different file than the one that linked to it, and the
  /// faction a unit belongs to is decided by the declaring catalogue.
  final String sourceId;

  const BsEntry(this.json, this.sourceId);

  String get id => strOr(json['id'], '');
  String get name => strOr(json['name'], '');

  /// `unit`, `model`, `upgrade` — or empty on groups and profiles.
  String get type => strOr(json['type'], '');

  bool get hidden => json['hidden'] == true;

  List<Object?> get profiles => asList(json['profiles']);
  List<Object?> get constraints => asList(json['constraints']);
  List<Object?> get costs => asList(json['costs']);
  List<Object?> get modifiers => asList(json['modifiers']);
  List<Object?> get modifierGroups => asList(json['modifierGroups']);
  List<Object?> get categoryLinks => asList(json['categoryLinks']);
  List<Object?> get entryLinks => asList(json['entryLinks']);
  List<Object?> get infoLinks => asList(json['infoLinks']);
  List<Object?> get selectionEntries => asList(json['selectionEntries']);
  List<Object?> get selectionEntryGroups =>
      asList(json['selectionEntryGroups']);

  /// The `pts` cost, or null when this entry carries none.
  ///
  /// Every entry lists all eight cost types — Crusade Points, Blackstone
  /// Fragments and the rest are all zero on a normal datasheet — so the type
  /// id has to be matched rather than the first cost taken.
  int? costFor(String costTypeId) {
    for (final raw in costs) {
      final c = asMap(raw);
      if (str(c['typeId']) == costTypeId) return asInt(c['value']);
    }
    return null;
  }

  /// Category names attached to this entry — `Infantry`, `Character`,
  /// `Faction: T'au Empire`. This is where 11e keywords actually live.
  List<String> get categoryNames => [
        for (final raw in categoryLinks)
          if (str(asMap(raw)['name']) case final n?) n,
      ];

  /// The category flagged `primary`, which is the battlefield role.
  String? get primaryCategory {
    for (final raw in categoryLinks) {
      final c = asMap(raw);
      if (c['primary'] == true) return str(c['name']);
    }
    return null;
  }
}

/// Every entry of every loaded catalogue, addressable by id.
///
/// One index spans the game system, the shared catalogues and a faction's own
/// files, because a `targetId` does not say which file it lives in and the
/// answer is regularly "a different one".
class BsIndex {
  final Map<String, BsEntry> _byId = {};

  /// Profile type names by id — `Unit`, `Abilities`, `Ranged Weapons`.
  /// Declared in the game system and extended per catalogue.
  final Map<String, String> profileTypes = {};

  /// Characteristic names by id, per profile type. A `Unit` profile's `M` and
  /// a weapon's `A` are different characteristic ids that both appear inline.
  final Map<String, String> costTypes = {};

  /// Root nodes worth walking: the shared selection entries of every
  /// non-library catalogue, which is where datasheets are declared.
  final List<BsEntry> roots = [];

  /// Catalogue display names by id, for provenance in the conflict log.
  final Map<String, String> catalogueNames = {};

  /// Top-level entry links, kept until every file is loaded.
  ///
  /// A catalogue may hold no entries at all and simply *select* from a
  /// library: `Aeldari - Drukhari.json` is one such, and Craftworlds is 106
  /// links and nothing else. Its datasheets are the ones it links to — not
  /// everything in the library, which also holds the other faction's.
  final List<Object?> _rootLinks = [];

  /// Top-level shared groups. Detachments and enhancements live here rather
  /// than inside any datasheet, so anything walking only [roots] misses them.
  final List<BsEntry> sharedGroups = [];

  /// The faction's own `sharedRules`, which is where a detachment rule's
  /// printed wording lives.
  ///
  /// Root catalogues only. The game system's shared rules are the core rules
  /// and a sibling faction's are not this one's, and harvesting either would
  /// file them as abilities of an army that does not have them.
  final List<BsEntry> ownRules = [];

  /// The faction's own `sharedSelectionEntries`, which is where the container
  /// holding its detachments sits. Same list that seeds [roots], kept
  /// separately because `resolveRootLinks` later adds borrowed datasheets to
  /// that one.
  final List<BsEntry> ownEntries = [];

  BsIndex();

  /// Reads one BattleScribe JSON file — game system or catalogue — into the
  /// index. Files may be added in any order; nothing is resolved until asked.
  void add(File file, {bool asRoot = true}) {
    final decoded = jsonDecode(file.readAsStringSync());
    final root = asMap(decoded);
    final body = asMap(root['catalogue'] ?? root['gameSystem']);
    if (body.isEmpty) return;

    final id = strOr(body['id'], file.path);
    catalogueNames[id] = strOr(body['name'], file.path.split('/').last);

    for (final raw in asList(body['costTypes'])) {
      final c = asMap(raw);
      if (str(c['id']) case final k?) costTypes[k] = strOr(c['name'], k);
    }
    for (final raw in asList(body['profileTypes'])) {
      final p = asMap(raw);
      if (str(p['id']) case final k?) profileTypes[k] = strOr(p['name'], k);
    }

    // Everything addressable, wherever it sits. `sharedSelectionEntries` is
    // the usual home, but entries nested inside a datasheet are link targets
    // too — a weapon declared inside one unit is linked from others.
    void collect(Object? node) {
      if (node is List) {
        for (final child in node) {
          collect(child);
        }
        return;
      }
      if (node is! Map) return;
      final map = asMap(node);
      if (str(map['id']) case final key?) {
        // A link and its target share no id, so this cannot collide; where a
        // file genuinely repeats an id, first declaration wins and the
        // duplicate is reported rather than silently replacing it.
        _byId.putIfAbsent(key, () => BsEntry(map, id));
      }
      for (final value in map.values) {
        collect(value);
      }
    }

    for (final key in const [
      'sharedSelectionEntries',
      'sharedSelectionEntryGroups',
      'sharedProfiles',
      'sharedRules',
      'rules',
      'categoryEntries',
      'entryLinks',
      'forceEntries',
    ]) {
      collect(body[key]);
    }

    for (final raw in asList(body['sharedSelectionEntryGroups'])) {
      sharedGroups.add(BsEntry(asMap(raw), id));
    }

    if (asRoot) {
      for (final raw in asList(body['sharedRules'])) {
        ownRules.add(BsEntry(asMap(raw), id));
      }
      for (final raw in asList(body['sharedSelectionEntries'])) {
        final entry = BsEntry(asMap(raw), id);
        ownEntries.add(entry);
        roots.add(entry);
      }
      _rootLinks.addAll(asList(body['entryLinks']));
    }
  }

  /// Resolves the top-level links of every root catalogue into roots.
  ///
  /// Call once, after the last [add]. Until every file is in the index a link
  /// may point at a catalogue not yet loaded, so this cannot happen inline.
  void resolveRootLinks() {
    final seen = {for (final root in roots) root.id};
    for (final raw in _rootLinks) {
      final target = resolve(raw);
      if (target == null) continue;
      if (!seen.add(target.id)) continue;
      roots.add(target);
    }
    _rootLinks.clear();
  }

  BsEntry? byId(String? id) => id == null ? null : _byId[id];

  int get size => _byId.length;

  /// The entry a link points at, with the link's own overrides folded in.
  ///
  /// The link supplies constraints and costs for *this* use of a shared
  /// entry — a burst cannon is 0-1 on a Stealth suit and 0-2 elsewhere — so
  /// returning the bare target would report the same options everywhere.
  BsEntry? resolve(Object? link) {
    final l = asMap(link);
    final target = byId(str(l['targetId']));
    if (target == null) return null;

    final merged = Map<String, dynamic>.from(target.json);
    // The link's name wins: a datasheet may link a shared entry under the
    // name it wants shown, and that is the name a player reads.
    if (str(l['name']) case final n? when n.isNotEmpty) merged['name'] = n;
    for (final key in const ['constraints', 'costs', 'modifiers']) {
      final extra = asList(l[key]);
      if (extra.isNotEmpty) {
        merged[key] = [...asList(merged[key]), ...extra];
      }
    }
    if (l['hidden'] == true) merged['hidden'] = true;
    return BsEntry(merged, target.sourceId);
  }
}
