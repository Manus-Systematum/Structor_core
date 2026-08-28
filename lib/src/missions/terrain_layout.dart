/// Competitive terrain layouts — the actual table, not just the zones
/// (DESIGN.md §7.3.1).
///
/// A deployment pattern says where the two armies set up. It says nothing
/// about the ruins, and in 11e the terrain is what the game is played around:
/// the same pattern with different terrain is a different game. The layouts
/// place every piece by position and rotation against a shared library of
/// templates, so the table can be drawn rather than described.
///
/// **These are Battlemaster layouts, not Chapter Approved ones.** Upstream
/// publishes 45 from `battlemaster-11e` and one from `kotc`, and no Chapter
/// Approved set at all — the missions carry that source, the terrain does
/// not. The UI names the source rather than implying otherwise (§7.6).
library;

import 'dart:math' as math;

import '../source/json.dart';
import 'mission_pack.dart';

/// A building placed inside a template's area — a ruin, a wall, a bastion.
///
/// This is the level the models actually stand in and shoot through. It is
/// nested one deeper than the piece: a layout places a *piece*, the piece's
/// template describes an **area terrain footprint**, and the buildings within
/// that area are its `features`. Drawing only the footprint gives you the
/// zone with nothing standing in it.
class TerrainFeature {
  final String id;

  /// The part template this feature's shape comes from.
  final String templateId;

  /// Placement within the parent template's local frame, not the board's.
  final BoardPoint position;
  final double rotationDegrees;

  const TerrainFeature({
    required this.id,
    required this.templateId,
    required this.position,
    this.rotationDegrees = 0,
  });

  factory TerrainFeature.fromJson(Object? v) {
    final j = asMap(v);
    return TerrainFeature(
      id: strOr(j['id'], ''),
      templateId: strOr(j['template'], ''),
      position: BoardPoint.fromJson(j['position']),
      rotationDegrees: dblOr(j['rotation_degrees'], 0),
    );
  }
}

/// A reusable piece shape, in inches, in its own local coordinates.
/// The kinds of object the printed layouts distinguish by colour.
///
/// **A property of the object, not of the ground it stands on.** One area
/// footprint routinely carries a lettered ruin *and* a barricade, and the
/// printed map colours those differently while leaving the area itself grey
/// (§7.3.23).
enum TerrainGroup {
  /// The lettered wall sections — AB, CD, EF, GH. What blocks line of sight
  /// and what models climb.
  ruin,

  /// Structures that are neither: the generator blocks and towers.
  structure,

  /// Barricades, rails, pipes and the loose corner pieces.
  barricade,

  /// A part with no group recorded. Drawn neutral rather than guessed.
  unknown,
}

class TerrainTemplate {
  final String id;
  final String name;

  /// `area` for a terrain footprint, `feature` for a building part.
  final String kind;

  /// The area terrain boundary — the ground you are *within*, not the walls.
  final List<BoardPoint> footprint;

  /// The buildings standing in that area. 38 of the 69 templates have them.
  final List<TerrainFeature> features;

  const TerrainTemplate({
    required this.id,
    required this.name,
    this.kind = '',
    this.footprint = const [],
    this.features = const [],
  });

  factory TerrainTemplate.fromJson(Object? v) {
    final j = asMap(v);
    final kind = strOr(j['kind'], '');
    final isFeature = kind == 'feature';
    final footprint = _footprintOf(j['footprint'], centred: isFeature);
    return TerrainTemplate(
      id: strOr(j['id'], ''),
      name: strOr(j['name'], ''),
      kind: kind,
      // A feature's shape is already authored about its own origin. An area's
      // is anchored at a bounding-box corner and has to be recentred to join
      // the frame its buildings are placed in.
      footprint: isFeature ? footprint : _centreOnOrigin(footprint),
      features: asList(j['features']).map(TerrainFeature.fromJson).toList(),
    );
  }

  bool get isFeature => kind == 'feature';

  /// Labels upstream transcribes wrongly.
  ///
  /// The lettered parts run `AB`, `CD`, `EF`, `GH`; upstream writes the
  /// second as `CO`, an O for a D. The sequence gives it away and the owner
  /// of the terrain confirms it. Corrected here rather than in
  /// `data-corrections.yaml` because that file is keyed by faction and this
  /// is core data — and because the fault is a display string with no rules
  /// behind it. If terrain corrections ever grow past this one, they belong
  /// in the corrections file properly.
  static const _mislabelled = {'CO': 'CD'};

  /// Which corner of a part's own box its L-shaped walls stand in.
  ///
  /// **Read off a published picture, because the geometry is not in the
  /// data.** Every lettered part ships as a `width`/`height` rectangle, so
  /// the real L cannot be recovered from the footprint — but the walls are
  /// drawn in Battlemaster's own layout diagrams, and one diagram is enough
  /// to pin a part for good, since the physical piece never changes. The
  /// entries below were matched against the published
  /// `take-and-hold-vs-purge-the-foe-1` table, whose six objective pieces
  /// carry `EF`+`GH`, `AB`+`Corner` and `Small L`+`CD` between them, each at
  /// two rotations 180° apart so the two placements cross-check each other.
  ///
  /// The value indexes the centred rectangle footprint, whose vertices run
  /// `0:(-w,-h) 1:(+w,-h) 2:(+w,+h) 3:(-w,+h)`.
  ///
  /// **All four lettered ruins are confirmed.** They were not read off the
  /// picture by eye — the layout was re-rendered into the picture's own frame
  /// and the shapes compared, which turns "what pixel is that wall on" into
  /// "do these two drawings agree". The first attempt assumed one corner for
  /// all four; `EF` and `GH` matched and `AB` and `CD` visibly did not, and
  /// the corrected pair matches on all eight placements.
  ///
  /// `Small L`, `Corner` and the barriers are deliberately absent: they are
  /// obstacles, not ruins, so they have no L to point at. They keep the
  /// measured heuristic in [_cornerMark].
  static const _wallCorner = <String, int>{
    'bm-bm-terrain-11e-1-part-ab': 3,
    'bm-bm-terrain-11e-1-part-co': 1,
    'bm-bm-terrain-11e-1-part-ef': 2,
    'bm-bm-terrain-11e-1-part-gh': 2,
  };

  /// The corner this part's walls occupy, or null when it has not been
  /// confirmed against a published diagram.
  int? get wallCorner => _wallCorner[id];

  /// Which ink the printed layout draws this part in (§7.3.23).
  ///
  /// Keyed on the part rather than on the area, because one area carries
  /// several parts and the printed map colours them separately. There are
  /// twelve parts in the whole published set, so this is a list rather than a
  /// rule — and a part missing from it draws neutral rather than joining a
  /// group by default.
  TerrainGroup get group => switch (id) {
        'bm-bm-terrain-11e-1-part-ab' ||
        'bm-bm-terrain-11e-1-part-co' ||
        'bm-bm-terrain-11e-1-part-ef' ||
        'bm-bm-terrain-11e-1-part-gh' =>
          TerrainGroup.ruin,
        'bm-bm-terrain-11e-1-part-generator' ||
        'bm-bm-terrain-11e-1-part-tower' ||
        'bm-bm-terrain-11e-1-part-pipes' =>
          TerrainGroup.structure,
        'bm-bm-terrain-11e-1-part-small-l' ||
        'bm-bm-terrain-11e-1-part-small-l-flip' ||
        'bm-bm-terrain-11e-1-part-corner' ||
        'bm-bm-terrain-11e-1-part-short-barrier' ||
        'bm-bm-terrain-11e-1-part-long-barrier' =>
          TerrainGroup.barricade,
        _ => TerrainGroup.unknown,
      };

  /// The marking on the physical piece — `AB`, `CD`, `EF`, `GH`, `Tower`.
  ///
  /// Battlemaster's parts are lettered, and the whole point of a table
  /// diagram is setting the real terrain out to match it, so the letter is
  /// what turns the picture into instructions. It lives in the name and
  /// nowhere else: there is no label field upstream.
  ///
  /// `Small L` and `Small L flip` are the same physical piece placed either
  /// way round, so both read `Small L`.
  String get label {
    var out = name;
    for (final prefix in const ['Battlemaster ']) {
      if (out.startsWith(prefix)) out = out.substring(prefix.length);
    }
    if (out.endsWith(' flip')) out = out.substring(0, out.length - 5);
    out = out.trim();
    return _mislabelled[out] ?? out;
  }
}

/// A building placed on the board, with the letter it is marked with.
class PlacedBuilding {
  final String label;

  /// Which ink the printed layout draws it in (§7.3.23).
  final TerrainGroup group;

  final List<BoardPoint> outline;

  /// A three-point polyline hugging one corner of the piece — the corner tick
  /// the diagram draws.
  ///
  /// **Why this is recoverable at all.** The published footprint is a
  /// bounding box, which is symmetric, so a box alone cannot say which way a
  /// piece is turned. But `part-ef`, `part-gh`, `part-co` and `part-small-l`
  /// each appear at 0°, 90°, 180° *and* 270°, and 0 and 180 are the same
  /// picture for a rectangle — upstream would have no reason to distinguish
  /// them unless the real shape is asymmetric. It is: these are L-shaped
  /// ruins, and `rotation_degrees` is carrying where the L points.
  ///
  /// So the rotation is real information the box was throwing away, and the
  /// tick puts it back. Which corner is chosen is the one facing furthest out
  /// of the piece's own base, so two parts on one base point away from each
  /// other the way they are laid out — see [_cornerMark].
  ///
  /// It shows **how the piece is turned**, not a measured wall position,
  /// because upstream publishes none.
  final List<BoardPoint> cornerMark;

  const PlacedBuilding({
    this.group = TerrainGroup.unknown,
    required this.label,
    required this.outline,
    this.cornerMark = const [],
  });
}

/// The corner tick for [outline], on whichever of its corners points furthest
/// out of [base].
///
/// **Which corner is chosen is a guess, but a measured one.** Upstream
/// publishes a bounding box for every lettered part, so the real L-shape is
/// not in the data and cannot be drawn. What *is* in the data is where each
/// part sits within its area terrain, and a ruin's corner faces outward — so
/// the box corner furthest from the middle of its own base stands in for it.
/// Two parts sharing a base then point away from each other, which is how
/// they are laid out on the table.
///
/// Measured across the 630 pairs of parts that share a base: pointing away
/// from the base's middle puts **86%** of pairs back to back, against 56% for
/// the corner nearest a base vertex — which was the first rule tried and is
/// barely better than the geometry would give by accident.
///
/// Falls back to the first vertex when there is no base to measure against.
List<BoardPoint> _cornerMark(
  List<BoardPoint> outline, {
  List<BoardPoint> base = const [],
  int? corner,
}) {
  if (outline.length < 3) return const [];

  // A confirmed corner is a fact and outranks the heuristic. `_place` keeps
  // vertex order through rotation and translation, so the index recorded in
  // the part's own frame still names the same corner of the placed outline.
  if (corner != null && corner >= 0 && corner < outline.length) {
    return _tickAt(outline, corner);
  }

  var chosen = 0;
  if (base.length >= 3) {
    // The same centre the base is anchored on. Measuring from the mean of the
    // base's vertices instead put the centre near one end of an irregular
    // footprint, so "furthest out" chose a corner that is not the one facing
    // away from the middle of the piece.
    final centre = _centroidOf(base);

    var best = -1.0;
    for (var i = 0; i < outline.length; i++) {
      final dx = outline[i].x - centre.x;
      final dy = outline[i].y - centre.y;
      final distance = dx * dx + dy * dy;
      if (distance > best) {
        best = distance;
        chosen = i;
      }
    }
  }

  return _tickAt(outline, chosen);
}

/// The tick itself: a polyline hugging [chosen], reaching partway down each
/// edge that meets there.
///
/// **A fraction of each edge, not a fixed length**, so the arms come out at
/// the proportions of the piece — the long wall reads long and the short one
/// short. That is the whole of "which way is this piece turned" once the
/// corner is known.
List<BoardPoint> _tickAt(List<BoardPoint> outline, int chosen) {
  const reach = 0.45;
  BoardPoint towards(BoardPoint from, BoardPoint to) => BoardPoint(
        from.x + (to.x - from.x) * reach,
        from.y + (to.y - from.y) * reach,
      );
  final corner = outline[chosen];
  final before = outline[(chosen - 1 + outline.length) % outline.length];
  final after = outline[(chosen + 1) % outline.length];
  return [towards(corner, before), corner, towards(corner, after)];
}

/// The area centroid of a closed ring, or its bounding-box centre when the
/// ring is degenerate.
///
/// The **area** centroid, not the mean of the vertices: an outline with more
/// points along one edge than another pulls its vertex mean towards the
/// crowded side, which for a Battlemaster footprint can land near one end of
/// the piece rather than in the middle of it.
BoardPoint _centroidOf(List<BoardPoint> points) {
  var twiceArea = 0.0;
  var cx = 0.0;
  var cy = 0.0;
  for (var i = 0; i < points.length; i++) {
    final a = points[i];
    final b = points[(i + 1) % points.length];
    final cross = a.x * b.y - b.x * a.y;
    twiceArea += cross;
    cx += (a.x + b.x) * cross;
    cy += (a.y + b.y) * cross;
  }
  if (twiceArea.abs() >= 1e-9) {
    return BoardPoint(cx / (3 * twiceArea), cy / (3 * twiceArea));
  }
  var minX = points.first.x, maxX = points.first.x;
  var minY = points.first.y, maxY = points.first.y;
  for (final p in points) {
    if (p.x < minX) minX = p.x;
    if (p.x > maxX) maxX = p.x;
    if (p.y < minY) minY = p.y;
    if (p.y > maxY) maxY = p.y;
  }
  return BoardPoint((minX + maxX) / 2, (minY + maxY) / 2);
}

/// Shifts a shape so its bounding box is centred on the origin.
///
/// **The two levels are authored in different frames.** A template's features
/// are placed around the origin — their cluster centre averages (0.5, 0.7)
/// across all 38 composites — while its area footprint is exported anchored
/// at a bounding-box *corner*, averaging (5.0, 3.3). Left as authored, every
/// base sits offset from the walls standing on it: only 20% of wall vertices
/// fall inside their own area, and the areas inflate 3.6″ past every board
/// edge while the walls stay within 3.5″..56.5″. Centring the footprint puts
/// the two in one frame — 84% containment, and an area extent of
/// 2.9″..57.1″ against the walls' 3.5″..56.5″.
List<BoardPoint> _centreOnOrigin(List<BoardPoint> points) {
  if (points.isEmpty) return points;
  final centre = _centroidOf(points);
  return [for (final p in points) BoardPoint(p.x - centre.x, p.y - centre.y)];
}

/// Rotate about the origin, then translate. The one placement rule in this
/// file, applied at both levels: piece-within-board and feature-within-piece.
List<BoardPoint> _place(
  List<BoardPoint> points,
  BoardPoint origin,
  double degrees,
) {
  final radians = degrees * math.pi / 180.0;
  final cos = math.cos(radians);
  final sin = math.sin(radians);
  return [
    for (final p in points)
      BoardPoint(
        origin.x + p.x * cos - p.y * sin,
        origin.y + p.x * sin + p.y * cos,
      ),
  ];
}

/// A footprint, from either shape the source uses.
///
/// Nineteen of the sixty-nine templates are `width`/`height` rectangles
/// rather than polygons — the same split `BoardArea` handles for deployment
/// zones. Reading only `points` leaves those pieces with no outline, and a
/// piece with no outline is not an error anywhere: it simply does not appear
/// on the table.
///
/// **A rectangle's origin depends on what it is.** An `area` footprint is a
/// region authored from its corner, like a deployment zone. A `feature` is a
/// physical object — a wall, a container — and its placement names where the
/// object *sits*, so its rectangle is centred on the origin.
///
/// That is measured, not assumed: across all 46 layouts, centring feature
/// rectangles leaves 14 intersecting building pairs out of 17,010, and
/// corner-anchoring them leaves 152. Of the 14, twelve are parts of a single
/// composite ruin interlocking — which is how an L-shape is built out of
/// rectangles — and the remaining two are flush against each other at zero
/// depth.
List<BoardPoint> _footprintOf(Object? raw, {required bool centred}) {
  final shape = asMap(raw);
  if (strOr(shape['type'], '') == 'rectangle') {
    final w = dblOr(shape['width'], 0);
    final h = dblOr(shape['height'], 0);
    if (w <= 0 || h <= 0) return const [];
    if (centred) {
      return [
        BoardPoint(-w / 2, -h / 2),
        BoardPoint(w / 2, -h / 2),
        BoardPoint(w / 2, h / 2),
        BoardPoint(-w / 2, h / 2),
      ];
    }
    return [
      const BoardPoint(0, 0),
      BoardPoint(w, 0),
      BoardPoint(w, h),
      BoardPoint(0, h),
    ];
  }
  return asList(shape['points']).map(BoardPoint.fromJson).toList();
}

/// One piece on the table.
///
/// Placement is **rotate about the template's own origin, then translate by
/// `position`** — verified against the shipped layouts, where that convention
/// lands every piece on the 60×44 board and rotating about the footprint's
/// centroid does not.
class TerrainPiece {
  final String id;
  final String name;
  final String pieceType;

  /// The shared shape this piece uses, or empty when it carries its own.
  final String templateId;

  /// A shape published inline instead of by reference. Seventeen pieces do
  /// this, so both paths have to work.
  final List<BoardPoint> footprint;

  final BoardPoint position;
  final double rotationDegrees;

  /// Some pieces *are* the objective markers, rather than terrain near one.
  final bool isObjective;

  const TerrainPiece({
    required this.id,
    required this.position,
    this.name = '',
    this.pieceType = '',
    this.templateId = '',
    this.footprint = const [],
    this.rotationDegrees = 0,
    this.isObjective = false,
  });

  factory TerrainPiece.fromJson(Object? v) {
    final j = asMap(v);
    return TerrainPiece(
      id: strOr(j['id'], ''),
      name: strOr(j['name'], ''),
      pieceType: strOr(j['piece_type'], ''),
      templateId: strOr(j['template'], ''),
      // A piece's own inline footprint is an area, never a building part, so
      // it is recentred like any other.
      footprint: _centreOnOrigin(_footprintOf(j['footprint'], centred: false)),
      position: BoardPoint.fromJson(j['position']),
      // Absent on a quarter of the pieces, which simply means unrotated.
      rotationDegrees: dblOr(j['rotation_degrees'], 0),
      isObjective: j['is_objective'] == true,
    );
  }

  /// This piece's outline in board coordinates, given the template library.
  ///
  /// Empty when the shape cannot be resolved, so a caller draws nothing
  /// rather than a degenerate blob at the origin.
  List<BoardPoint> outline(Map<String, TerrainTemplate> templates) {
    final local =
        footprint.isNotEmpty ? footprint : templates[templateId]?.footprint;
    if (local == null || local.isEmpty) return const [];
    return _place(local, position, rotationDegrees);
  }

  /// The buildings standing in this piece's area, in board coordinates.
  ///
  /// Two transforms composed: the feature sits in its template's local frame,
  /// and the template sits on the board. Empty for a piece whose template
  /// publishes no features — plenty of area terrain is just open ground.
  ///
  /// > **The outlines are bounding boxes, not true shapes.** Every part the
  /// > shipped layouts use is modelled upstream as a `width`/`height`
  /// > rectangle, including the one *named* `Small L`, which is published as
  /// > a plain 1.5×2.5 box. The library does contain properly L-shaped
  /// > polygons — `corner-short`, `corner-ruin-left` and four more — but no
  /// > layout references any of them. Drawing the real L would mean drawing
  /// > a shape the data does not have (§7.6), so the diagram shows the
  /// > footprint it publishes and says so.
  List<PlacedBuilding> buildings(Map<String, TerrainTemplate> templates) {
    final template = templates[templateId];
    if (template == null) return const [];

    // The base these parts stand on, so each tick can face its nearest
    // corner of it rather than a fixed corner of its own box.
    final base = outline(templates);

    final out = <PlacedBuilding>[];
    for (final feature in template.features) {
      final part = templates[feature.templateId];
      if (part == null || part.footprint.length < 3) continue;
      final inTemplate =
          _place(part.footprint, feature.position, feature.rotationDegrees);
      final placed = _place(inTemplate, position, rotationDegrees);
      out.add(PlacedBuilding(
        label: part.label,
        group: part.group,
        outline: placed,
        cornerMark: _cornerMark(placed, base: base, corner: part.wallCorner),
      ));
    }
    return out;
  }
}

/// One published table: a deployment pattern plus every piece on it.
class TerrainLayout {
  final String id;
  final String name;
  final String description;

  /// `battlemaster-11e` or `kotc`. Surfaced rather than hidden — a player
  /// choosing a table wants to know whose layout it is.
  final String source;

  /// The pairing this table is published for. **Unordered**: the physical
  /// table is the same whichever player declared which disposition, so
  /// `a-vs-b` covers `b-vs-a` too (see [MissionPack.layoutsFor]).
  final String missionMatchupId;

  final int variant;
  final String deploymentPatternId;
  final List<TerrainPiece> pieces;

  const TerrainLayout({
    required this.id,
    required this.name,
    this.description = '',
    this.source = '',
    this.missionMatchupId = '',
    this.variant = 0,
    this.deploymentPatternId = '',
    this.pieces = const [],
  });

  factory TerrainLayout.fromJson(Object? v) {
    final j = asMap(v);
    return TerrainLayout(
      id: strOr(j['id'], ''),
      name: strOr(j['name'], ''),
      description: strOr(j['description'], ''),
      source: strOr(j['source'], ''),
      missionMatchupId: strOr(j['mission_matchup_id'], ''),
      variant: intOr(j['variant'], 0),
      deploymentPatternId: strOr(j['deployment_pattern_id'], ''),
      pieces: asList(j['pieces']).map(TerrainPiece.fromJson).toList(),
    );
  }

  /// A short label for the source, for a UI that must not imply these are
  /// Games Workshop's own competitive layouts.
  String get sourceLabel => switch (source) {
        'battlemaster-11e' => 'Battlemaster',
        'kotc' => 'KOTC',
        '' => 'Unattributed',
        _ => source,
      };
}
