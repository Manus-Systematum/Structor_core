import 'dart:convert';
import 'dart:math' as math;
import 'dart:io';

import 'package:test/test.dart';
import 'package:wh40k_core/wh40k_core.dart';

import 'support.dart';

MissionPack loadPack(String root) {
  List<Object?> read(String path) {
    final file = File('$root/$path');
    if (!file.existsSync()) return const [];
    final decoded = jsonDecode(file.readAsStringSync());
    return decoded is List ? decoded : const [];
  }

  return MissionPack.fromJson(
    dispositions: read('core/force-dispositions.json'),
    missions: read('core/missions.json'),
    matchups: read('core/mission-matchups.json'),
    cards: read('core/secondary-cards.json'),
    deployments: read('core/deployment-patterns.json'),
    terrainLayouts: read('core/terrain-layouts.json'),
    terrainTemplates: read('core/terrain-templates.json'),
  );
}

void main() {
  final root = Directory(snapshotDir.path);
  final available = root.existsSync();
  final pack = available ? loadPack(root.path) : const MissionPack();
  final skip = available ? null : 'no snapshot';

  group('the published tables', () {
    test('all forty-six load, from two community sources', () {
      expect(pack.terrainLayouts, hasLength(46));
      expect(pack.terrainLayouts.map((l) => l.sourceLabel).toSet(),
          {'Battlemaster', 'KOTC'});
    }, skip: skip);

    test('every piece resolves a shape, objective-bearing ones included', () {
      // Either by template reference or from its own inline footprint —
      // seventeen pieces publish the latter, so both paths have to work or
      // those pieces silently vanish from the drawing.
      //
      // **Counting objective pieces here is the point.** The first version of
      // this test skipped them, mirroring the renderer's own `continue`, and
      // so agreed with the bug: 275 of the 745 pieces carry an objective and
      // 270 of those are ruins, and every one was being dropped from the
      // table while the test stayed green.
      var pieces = 0;
      var withObjective = 0;
      for (final layout in pack.terrainLayouts) {
        for (final piece in layout.pieces) {
          if (piece.isObjective) withObjective++;
          if (piece.templateId.isEmpty && piece.footprint.isEmpty) continue;
          expect(piece.outline(pack.terrainTemplates), isNotEmpty,
              reason: '${layout.id}/${piece.id}');
          pieces++;
        }
      }
      // 740 of 745 at the current revision — five objective markers publish
      // no shape at all, which is the only legitimate reason to draw none.
      expect(pieces, greaterThan(700));
      expect(withObjective, greaterThan(250));
    }, skip: skip);

    test('an objective is usually a building, not a bare marker', () {
      // The user-visible symptom of getting this wrong: circles floating
      // where the ruins should be, and a third of the table missing.
      final objectives = [
        for (final layout in pack.terrainLayouts)
          for (final piece in layout.pieces)
            if (piece.isObjective) piece,
      ];
      final drawable = objectives
          .where((p) => p.outline(pack.terrainTemplates).length >= 3)
          .length;
      expect(objectives, hasLength(275));
      expect(drawable, greaterThan(250),
          reason: 'the objective sits *in* the ruin');
    }, skip: skip);

    test('every layout names a deployment pattern that exists', () {
      for (final layout in pack.terrainLayouts) {
        expect(pack.deployment(layout.deploymentPatternId), isNotNull,
            reason: layout.id);
      }
    }, skip: skip);
  });

  group('placement', () {
    test('pieces land on the board, which pins the transform', () {
      // Rotate about the template's own origin, *then* translate by position.
      // Rotating about the footprint's centroid instead shifts every layout
      // off the long edge, and the result still looks like a plausible table
      // — which is exactly why this is asserted rather than eyeballed.
      //
      // The tolerance is measured, not guessed: 633 of 745 pieces sit wholly
      // on the board, and the rest overhang an edge by at most 3.73", the
      // same figure repeating across layouts because it belongs to a handful
      // of edge templates. The diagram clips to the board, so an overhanging
      // piece is trimmed rather than drawn outside it.
      for (final layout in pack.terrainLayouts) {
        final board = pack.deployment(layout.deploymentPatternId)!.boardSize;
        for (final piece in layout.pieces) {
          for (final p in piece.outline(pack.terrainTemplates)) {
            expect(p.x, inInclusiveRange(-4, board.x + 4),
                reason: '${layout.id}/${piece.id}');
            expect(p.y, inInclusiveRange(-4, board.y + 4),
                reason: '${layout.id}/${piece.id}');
          }
        }
      }
    }, skip: skip);

    test('a rectangle template becomes four corners', () {
      // Nineteen templates publish width/height instead of points. Missing
      // this leaves those pieces invisible with nothing reporting an error.
      final piece = TerrainPiece.fromJson(const {
        'id': 'p',
        'template': 't',
        'position': {'x': 0, 'y': 0},
      });
      final outline = piece.outline({
        't': TerrainTemplate.fromJson(const {
          'id': 't',
          'name': 'T',
          'footprint': {'type': 'rectangle', 'width': 3.75, 'height': 4.5},
        }),
      });
      expect(outline, hasLength(4));
      double span(Iterable<double> vs) =>
          vs.reduce((a, b) => a > b ? a : b) -
          vs.reduce((a, b) => a < b ? a : b);
      expect(span(outline.map((p) => p.x)), 3.75);
      expect(span(outline.map((p) => p.y)), 4.5);
    });

    test('an unrotated piece is its template, moved', () {
      final piece = TerrainPiece.fromJson(const {
        'id': 'p',
        'template': 't',
        'position': {'x': 10, 'y': 5},
      });
      final outline = piece.outline({
        't': const TerrainTemplate(
          id: 't',
          name: 'T',
          footprint: [BoardPoint(0, 0), BoardPoint(2, 0), BoardPoint(2, 1)],
        ),
      });
      expect(outline.map((p) => '${p.x},${p.y}'),
          ['10.0,5.0', '12.0,5.0', '12.0,6.0']);
    });

    test('a quarter turn swaps the axes', () {
      final piece = TerrainPiece.fromJson(const {
        'id': 'p',
        'template': 't',
        'position': {'x': 0, 'y': 0},
        'rotation_degrees': 90,
      });
      final outline = piece.outline({
        't': const TerrainTemplate(
            id: 't', name: 'T', footprint: [BoardPoint(2, 0)]),
      });
      expect(outline.single.x, closeTo(0, 1e-9));
      expect(outline.single.y, closeTo(2, 1e-9));
    });

    test('buildings on separate pieces do not intersect', () {
      // The symptom that found this: ruins overlapping each other on screen.
      // A `feature` rectangle names where the object *sits*, so it is centred
      // on its origin; anchoring it at a corner shifts every wall by half its
      // own size and pushes 152 building pairs into each other.
      //
      // Parts *within* one composite are allowed to overlap — that is how an
      // L-shape is built out of rectangles — so only cross-piece pairs count.
      bool inside(BoardPoint p, List<BoardPoint> poly) {
        var hit = false;
        for (var i = 0, j = poly.length - 1; i < poly.length; j = i++) {
          final a = poly[i];
          final b = poly[j];
          if ((a.y > p.y) != (b.y > p.y) &&
              p.x < (b.x - a.x) * (p.y - a.y) / (b.y - a.y) + a.x) {
            hit = !hit;
          }
        }
        return hit;
      }

      var crossPieceOverlaps = 0;
      for (final layout in pack.terrainLayouts) {
        final walls = <(String, List<BoardPoint>)>[];
        for (final piece in layout.pieces) {
          for (final building in piece.buildings(pack.terrainTemplates)) {
            walls.add((piece.id, building.outline));
          }
        }
        for (var i = 0; i < walls.length; i++) {
          for (var j = i + 1; j < walls.length; j++) {
            final (idA, a) = walls[i];
            final (idB, b) = walls[j];
            if (idA == idB) continue;
            if (a.any((p) => inside(p, b)) || b.any((p) => inside(p, a))) {
              crossPieceOverlaps++;
            }
          }
        }
      }
      // Two, both flush against a neighbour at zero penetration depth.
      expect(crossPieceOverlaps, lessThanOrEqualTo(2));
    }, skip: skip);

    test('the walls stand on their own base', () {
      // The symptom that found this: the bases sat rotated and offset around
      // the objectives instead of under the buildings. A template's features
      // are authored about the origin; its area footprint is exported from a
      // bounding-box corner. Left as authored the two are in different
      // frames and only a fifth of the walls land on their own ground.
      bool inside(BoardPoint p, List<BoardPoint> poly) {
        var hit = false;
        for (var i = 0, j = poly.length - 1; i < poly.length; j = i++) {
          final a = poly[i];
          final b = poly[j];
          if ((a.y > p.y) != (b.y > p.y) &&
              p.x < (b.x - a.x) * (p.y - a.y) / (b.y - a.y) + a.x) {
            hit = !hit;
          }
        }
        return hit;
      }

      var on = 0;
      var total = 0;
      for (final layout in pack.terrainLayouts) {
        for (final piece in layout.pieces) {
          final area = piece.outline(pack.terrainTemplates);
          if (area.length < 3) continue;
          for (final wall in piece.buildings(pack.terrainTemplates)) {
            for (final vertex in wall.outline) {
              total++;
              if (inside(vertex, area)) on++;
            }
          }
        }
      }
      expect(total, greaterThan(4000));
      // 89% at the current revision, against 20% before the frames were
      // reconciled and 84% while the anchor was the bounding box rather than
      // the area centroid. Not 100% because a ruin's wall legitimately
      // overhangs the edge of its base.
      expect(on / total, greaterThan(0.87));
    }, skip: skip);

    test('the areas cover the same ground as the walls', () {
      // The independent check on the same thing, and the one that settled the
      // convention: the walls span 3.5"..56.5" across a 60" board, so bases
      // that reach 3.6" *past* every edge are offset outward, not merely
      // generous. Centred, the areas span 2.9"..57.1" — the same table.
      var wallMin = 999.0, wallMax = -999.0;
      var areaMin = 999.0, areaMax = -999.0;
      for (final layout in pack.terrainLayouts) {
        if (layout.deploymentPatternId == 'kotc-colosseum') continue;
        for (final piece in layout.pieces) {
          for (final p in piece.outline(pack.terrainTemplates)) {
            if (p.x < areaMin) areaMin = p.x;
            if (p.x > areaMax) areaMax = p.x;
          }
          for (final wall in piece.buildings(pack.terrainTemplates)) {
            for (final p in wall.outline) {
              if (p.x < wallMin) wallMin = p.x;
              if (p.x > wallMax) wallMax = p.x;
            }
          }
        }
      }
      expect((areaMin - wallMin).abs(), lessThan(1.5));
      expect((areaMax - wallMax).abs(), lessThan(1.5));
    }, skip: skip);

    test('every template shape ends up centred on its own origin', () {
      // The two kinds get there by different routes, which is the whole
      // subtlety: a feature is *authored* about its origin, an area is
      // authored from a bounding-box corner and recentred. Both must end up
      // in the same frame or the walls do not stand on their base.
      final feature = TerrainTemplate.fromJson(const {
        'id': 'f',
        'name': 'wall',
        'kind': 'feature',
        'footprint': {'type': 'rectangle', 'width': 4, 'height': 2},
      });
      final area = TerrainTemplate.fromJson(const {
        'id': 'a',
        'name': 'ground',
        'kind': 'area',
        'footprint': {
          'points': [
            {'x': 0, 'y': 0},
            {'x': 4, 'y': 0},
            {'x': 4, 'y': 2},
            {'x': 0, 'y': 2},
          ],
        },
      });

      for (final shape in [feature.footprint, area.footprint]) {
        final xs = shape.map((p) => p.x);
        final ys = shape.map((p) => p.y);
        expect(xs.reduce((a, b) => a < b ? a : b), -2);
        expect(xs.reduce((a, b) => a > b ? a : b), 2);
        expect(ys.reduce((a, b) => a < b ? a : b), -1);
        expect(ys.reduce((a, b) => a > b ? a : b), 1);
      }
    });

    test('a building is placed through both frames', () {
      // Feature-within-template, then template-within-board. Getting either
      // transform alone puts the walls somewhere plausible and wrong.
      final templates = {
        'area': TerrainTemplate.fromJson(const {
          'id': 'area',
          'kind': 'area',
          'footprint': {
            'points': [
              {'x': 0, 'y': 0},
              {'x': 10, 'y': 0},
              {'x': 10, 'y': 10},
            ],
          },
          'features': [
            {
              'id': 'f1',
              'template': 'wall',
              'position': {'x': 2, 'y': 0},
            },
          ],
        }),
        'wall': TerrainTemplate.fromJson(const {
          'id': 'wall',
          'kind': 'feature',
          'footprint': {'type': 'rectangle', 'width': 2, 'height': 2},
        }),
      };

      final piece = TerrainPiece.fromJson(const {
        'id': 'p',
        'template': 'area',
        'position': {'x': 100, 'y': 50},
      });
      final walls = piece.buildings(templates);
      expect(walls, hasLength(1));
      // Centred 2x2 at feature offset (2,0), piece offset (100,50).
      expect(walls.single.outline.map((p) => p.x), containsAll([101.0, 103.0]));
      expect(walls.single.outline.map((p) => p.y), containsAll([49.0, 51.0]));
    });

    test('a piece whose template has no features has no buildings', () {
      final piece = TerrainPiece.fromJson(const {
        'id': 'p',
        'template': 't',
        'position': {'x': 0, 'y': 0},
      });
      expect(
        piece.buildings({
          't': const TerrainTemplate(id: 't', name: 'T', footprint: [
            BoardPoint(0, 0),
            BoardPoint(1, 0),
            BoardPoint(1, 1),
          ]),
        }),
        isEmpty,
      );
    });

    test('two parts on one base point away from each other', () {
      // The real L-shapes are not in the data — every lettered part is
      // published as a bounding box — so the tick stands in for the corner.
      // Which corner is chosen is measured rather than picked: facing out of
      // the base puts 86% of the 630 sharing pairs back to back, against 56%
      // for the corner nearest a base vertex.
      //
      // "Out of the base" is measured from the base's **area centroid** — the
      // same centre the base itself is anchored on. Using the mean of its
      // vertices instead puts the centre near one end of an irregular
      // footprint, and the tick then lands on a corner that is not the one
      // facing away from the middle of the piece.
      BoardPoint centre(List<BoardPoint> points) {
        var x = 0.0;
        var y = 0.0;
        for (final p in points) {
          x += p.x;
          y += p.y;
        }
        return BoardPoint(x / points.length, y / points.length);
      }

      var pairs = 0;
      var apart = 0;
      for (final layout in pack.terrainLayouts) {
        for (final piece in layout.pieces) {
          final parts = piece
              .buildings(pack.terrainTemplates)
              .where((b) => b.cornerMark.length >= 3)
              .toList();
          for (var i = 0; i < parts.length; i++) {
            for (var j = i + 1; j < parts.length; j++) {
              pairs++;
              final a = centre(parts[i].outline);
              final b = centre(parts[j].outline);
              final ta = parts[i].cornerMark[1];
              final tb = parts[j].cornerMark[1];
              final aAway =
                  (ta.x - a.x) * (a.x - b.x) + (ta.y - a.y) * (a.y - b.y) > 0;
              final bAway =
                  (tb.x - b.x) * (b.x - a.x) + (tb.y - b.y) * (b.y - a.y) > 0;
              if (aAway && bAway) apart++;
            }
          }
        }
      }
      expect(pairs, greaterThan(600));
      expect(apart / pairs, greaterThan(0.8));
    }, skip: skip);

    test('area bases touch but do not sit on top of each other', () {
      // A gap in the earlier tests: they checked walls against walls and
      // never areas against areas, so a reader reported two middle pieces
      // overlapping on Purge vs Assets 02 and nothing here disagreed.
      //
      // The overlaps are real but shallow — 124 pairs of 5,700, none deeper
      // than 0.39". That is pieces placed touching, not a broken transform:
      // anchoring on the bounding box instead of the area centroid takes the
      // deepest to 2.30", and anchoring areas at a bounding-box *corner*
      // gives 306 overlaps. The bound is on depth, because depth is what
      // tells a graze from a misplacement.
      bool inside(BoardPoint p, List<BoardPoint> poly) {
        var hit = false;
        for (var i = 0, j = poly.length - 1; i < poly.length; j = i++) {
          final a = poly[i];
          final b = poly[j];
          if ((a.y > p.y) != (b.y > p.y) &&
              p.x < (b.x - a.x) * (p.y - a.y) / (b.y - a.y) + a.x) {
            hit = !hit;
          }
        }
        return hit;
      }

      double toSegment(BoardPoint p, BoardPoint a, BoardPoint b) {
        final vx = b.x - a.x;
        final vy = b.y - a.y;
        final len = vx * vx + vy * vy;
        final t = len == 0
            ? 0.0
            : (((p.x - a.x) * vx + (p.y - a.y) * vy) / len).clamp(0.0, 1.0);
        final dx = p.x - (a.x + t * vx);
        final dy = p.y - (a.y + t * vy);
        return math.sqrt(dx * dx + dy * dy);
      }

      double depth(List<BoardPoint> a, List<BoardPoint> b) {
        var worst = 0.0;
        for (final p in a) {
          if (!inside(p, b)) continue;
          var nearest = double.infinity;
          for (var i = 0; i < b.length; i++) {
            final d = toSegment(p, b[i], b[(i + 1) % b.length]);
            if (d < nearest) nearest = d;
          }
          if (nearest > worst) worst = nearest;
        }
        return worst;
      }

      var deep = 0;
      var worst = 0.0;
      for (final layout in pack.terrainLayouts) {
        final areas = [
          for (final piece in layout.pieces)
            if (piece.outline(pack.terrainTemplates) case final o
                when o.length >= 3)
              o,
        ];
        for (var i = 0; i < areas.length; i++) {
          for (var j = i + 1; j < areas.length; j++) {
            final d =
                math.max(depth(areas[i], areas[j]), depth(areas[j], areas[i]));
            if (d > worst) worst = d;
            if (d > 1.0) deep++;
          }
        }
      }
      // Nothing exceeds an inch. Loose enough that a piece genuinely placed
      // flush does not fail it, tight enough that the 2.30" the bounding-box
      // anchor produced would.
      expect(deep, isZero, reason: 'deepest overlap was $worst inches');
    }, skip: skip);

    test('an unresolvable shape draws nothing rather than a blob', () {
      final piece = TerrainPiece.fromJson(const {
        'id': 'p',
        'template': 'missing',
        'position': {'x': 3, 'y': 3},
      });
      expect(piece.outline(const {}), isEmpty);
    });
  });

  group('the markings on the pieces', () {
    test('a building carries the letter its physical piece is marked with', () {
      final labels = {
        for (final layout in pack.terrainLayouts)
          for (final piece in layout.pieces)
            for (final building in piece.buildings(pack.terrainTemplates))
              building.label,
      };
      // Setting real terrain out to match the diagram is the point of having
      // it, and the letter is what makes that possible.
      //
      // The set runs AB, CD, EF, GH. Upstream writes the second as `CO`, an
      // O for a D — the sequence gives it away and the owner of the terrain
      // confirms it. This test asserted `CO` when it was written, which is
      // what encoding a typo into a test looks like.
      expect(labels, containsAll(['AB', 'CD', 'EF', 'GH']));
      expect(labels, isNot(contains('CO')));
      expect(labels, isNot(contains('')));
    }, skip: skip);

    test('the source prefix goes, and a mirrored piece keeps its name', () {
      String labelOf(String name) =>
          TerrainTemplate.fromJson({'id': 'x', 'name': name, 'kind': 'feature'})
              .label;
      expect(labelOf('Battlemaster AB'), 'AB');
      expect(labelOf('Battlemaster Small L'), 'Small L');
      // The same physical piece, laid the other way round.
      expect(labelOf('Battlemaster Small L flip'), 'Small L');
      expect(labelOf('Catwalk'), 'Catwalk');
    });

    test('rotation is real information, so the tick has something to show', () {
      // A bounding box is symmetric: 0° and 180° draw the same picture. That
      // upstream distinguishes them anyway is the evidence the underlying
      // shape is not symmetric — these are L-shaped ruins and the rotation
      // says where the L points. Without the tick the diagram throws that
      // away and two differently-turned pieces look identical.
      // By label, not by template id: the re-import of 2026-08-27 replaced
      // every id and kept every letter (§3.27).
      final byPart = <String, Set<double>>{};
      for (final template in pack.terrainTemplates.values) {
        for (final feature in template.features) {
          final part = pack.terrainTemplates[feature.templateId];
          if (part == null) continue;
          (byPart[part.label] ??= {}).add(feature.rotationDegrees);
        }
      }
      for (final label in const ['EF', 'GH', 'CD', 'Small L']) {
        expect(byPart[label], containsAll([0.0, 90.0, 180.0, 270.0]),
            reason: label);
      }
    }, skip: skip);

    test('the tick turns with its piece and stays on it', () {
      final templates = {
        'area': TerrainTemplate.fromJson(const {
          'id': 'area',
          'kind': 'area',
          'footprint': {
            'points': [
              {'x': 0, 'y': 0},
              {'x': 10, 'y': 0},
              {'x': 10, 'y': 10},
              {'x': 0, 'y': 10},
            ],
          },
          'features': [
            {
              'id': 'f',
              'template': 'wall',
              'position': {'x': 0, 'y': 0},
            },
          ],
        }),
        'wall': TerrainTemplate.fromJson(const {
          'id': 'wall',
          'kind': 'feature',
          'footprint': {'type': 'rectangle', 'width': 4, 'height': 2},
        }),
      };

      List<BoardPoint> markAt(double degrees) => TerrainPiece.fromJson({
            'id': 'p',
            'template': 'area',
            'position': const {'x': 0, 'y': 0},
            'rotation_degrees': degrees,
          }).buildings(templates).single.cornerMark;

      // Three points: along one edge, the corner, along the other.
      expect(markAt(0), hasLength(3));
      // The corner is a corner of the box, so it sits at half the extents.
      expect(markAt(0)[1].x.abs(), closeTo(2, 1e-9));
      expect(markAt(0)[1].y.abs(), closeTo(1, 1e-9));
      // And it moves when the piece turns, which is the whole point: a
      // symmetric box drawn at 0 and at 180 is otherwise the same picture.
      expect(markAt(180)[1].x, closeTo(-markAt(0)[1].x, 1e-9));
      expect(markAt(180)[1].y, closeTo(-markAt(0)[1].y, 1e-9));
    });

    test('every part the layouts use is published as a bounding box', () {
      // Recorded rather than worked around. The real Battlemaster pieces are
      // L-shaped; upstream models each as a `width`/`height` rectangle,
      // including the one *named* "Small L". Properly L-shaped polygons do
      // exist in the library — corner-short, corner-ruin-left and four more
      // — but no layout references any of them, so drawing the real shape
      // would mean inventing geometry the data does not have (§7.6).
      final used = {
        for (final template in pack.terrainTemplates.values)
          for (final feature in template.features) feature.templateId,
      };
      expect(used, isNotEmpty);
      for (final id in used) {
        expect(pack.terrainTemplates[id]!.footprint, hasLength(4),
            reason: '$id is a bounding box, not an outline');
      }

      // The unused L-shapes, so this test fails loudly if upstream ever
      // starts placing them and the note above goes stale.
      expect(pack.terrainTemplates['corner-short']!.footprint, hasLength(6));
      expect(used, isNot(contains('corner-short')));
    }, skip: skip);
  });

  group('finding the table for a matchup', () {
    test('the lookup commutes, because the table does', () {
      // The mission table is asymmetric — (A vs B) and (B vs A) are different
      // missions — but the *terrain* is one physical table, and upstream
      // publishes each pairing once. Looking up only the declared order finds
      // nothing for ten of the twenty-five matchups.
      final forward = pack.layoutsFor(
          disposition: 'reconnaissance', opponentDisposition: 'take-and-hold');
      final reverse = pack.layoutsFor(
          disposition: 'take-and-hold', opponentDisposition: 'reconnaissance');

      expect(forward, isNotEmpty);
      expect(forward.map((l) => l.id), reverse.map((l) => l.id));
    }, skip: skip);

    test('every one of the twenty-five matchups has three tables', () {
      final dispositions = pack.allDispositions.map((d) => d.id).toList();
      expect(dispositions, hasLength(5));

      for (final mine in dispositions) {
        for (final theirs in dispositions) {
          final layouts =
              pack.layoutsFor(disposition: mine, opponentDisposition: theirs);
          expect(layouts, hasLength(3), reason: '$mine vs $theirs');
          expect(layouts.map((l) => l.variant), [1, 2, 3]);
        }
      }
    }, skip: skip);

    test('an unknown disposition finds nothing rather than throwing', () {
      expect(
        pack.layoutsFor(
            disposition: 'nonesuch', opponentDisposition: 'take-and-hold'),
        isEmpty,
      );
    }, skip: skip);
  });

  test('the chosen table is carried in the setup, and survives a round trip',
      () {
    const setup = MissionSetup(
      myDisposition: 'reconnaissance',
      opponentDisposition: 'take-and-hold',
      myMissionId: 'reconnaissance-sweep',
      opponentMissionId: 'purge-and-secure',
      deploymentId: 'tipping-point',
      terrainLayoutId: 'reconnaissance-vs-take-and-hold-2',
    );
    final restored =
        MissionSetup.fromJson(jsonDecode(jsonEncode(setup.toJson())));
    expect(restored.terrainLayoutId, 'reconnaissance-vs-take-and-hold-2');

    // Absent on a game set up before tables were bundled, which must read as
    // "no table chosen" rather than failing to load.
    final old = MissionSetup.fromJson(const {
      'myDisposition': 'a',
      'opponentDisposition': 'b',
      'myMissionId': 'm',
      'opponentMissionId': 'n',
    });
    expect(old.terrainLayoutId, isNull);
  });
  group('walls read off a published diagram', () {
    // Battlemaster's own layout picture for the first Take and Hold vs Purge
    // the Foe table shows where each ruin's walls stand. The layout was
    // `take-and-hold-vs-purge-the-foe-1` until the re-import of 2026-08-27
    // renamed every table; it is `bm-take-vs-purge-01` now, with the same
    // pieces under the same ids and the same letters on them (§3.27). The picture was tied to this data
    // by fitting one affine map against all six objective positions *and*
    // both halves of the staggered deployment zones, so the correspondence is
    // not a guess about which piece is which.
    test('EF stands in the same corner of its box at both placements', () {
      final layout = pack.terrainLayouts
          .firstWhere((l) => l.id == 'bm-take-vs-purge-01');
      final templates = pack.terrainTemplates;

      BoardPoint tickOf(String pieceId) {
        final piece = layout.pieces.firstWhere((p) => p.id == pieceId);
        final ef =
            piece.buildings(templates).firstWhere((b) => b.label == 'EF');
        // The middle point of the three is the corner itself.
        return ef.cornerMark[1];
      }

      // Read from the picture: the walls hug the corner of EF's box that the
      // part's own frame calls (+w, +h). The two placements are 180 degrees
      // apart, so confirming both is the cross-check — a misread would put
      // them in corners that are not opposite.
      final a = tickOf('area-04');
      final b = tickOf('area-12');
      expect(a.x, closeTo(5.5, 0.15));
      expect(a.y, closeTo(16.55, 0.15));
      expect(b.x, closeTo(54.5, 0.15));
      expect(b.y, closeTo(27.45, 0.15));
    }, skip: skip);

    test('AB and CD stand in different corners from EF and GH', () {
      // The first reading assumed one corner served all four lettered ruins.
      // Re-rendering the layout into the picture's own frame showed EF and GH
      // agreeing and AB and CD plainly not, which is the value of comparing
      // drawings rather than counting pixels.
      final layout = pack.terrainLayouts
          .firstWhere((l) => l.id == 'bm-take-vs-purge-01');
      final templates = pack.terrainTemplates;

      BoardPoint tick(String pieceId, String label) => layout.pieces
          .firstWhere((p) => p.id == pieceId)
          .buildings(templates)
          .firstWhere((b) => b.label == label)
          .cornerMark[1];

      final ab = tick('area-02', 'AB');
      expect(ab.x, closeTo(22.438, 0.05));
      expect(ab.y, closeTo(15.558, 0.05));
      final cd = tick('area-11', 'CD');
      expect(cd.x, closeTo(17.0, 0.05));
      expect(cd.y, closeTo(32.5, 0.05));
    }, skip: skip);

    test('the two placements of a part mirror through the board centre', () {
      // This layout is point-symmetric, so every part appears twice at 180
      // degrees. The pair must reflect through (30, 22) exactly — a corner
      // recorded on the wrong vertex still satisfies one placement and
      // breaks this.
      final layout = pack.terrainLayouts
          .firstWhere((l) => l.id == 'bm-take-vs-purge-01');
      final templates = pack.terrainTemplates;

      BoardPoint tick(String pieceId, String label) => layout.pieces
          .firstWhere((p) => p.id == pieceId)
          .buildings(templates)
          .firstWhere((b) => b.label == label)
          .cornerMark[1];

      for (final pair in const [
        ('area-02', 'area-10', 'AB'),
        ('area-11', 'area-03', 'CD'),
        ('area-04', 'area-12', 'EF'),
        ('area-04', 'area-12', 'GH'),
      ]) {
        final a = tick(pair.$1, pair.$3);
        final b = tick(pair.$2, pair.$3);
        expect(a.x + b.x, closeTo(60, 0.05), reason: pair.$3);
        expect(a.y + b.y, closeTo(44, 0.05), reason: pair.$3);
      }
    }, skip: skip);

    test('an obstacle keeps the heuristic, having no L to point at', () {
      // Small L, Corner and the barriers are obstacles rather than ruins, so
      // there is no wall corner to record. They must still get a tick.
      final layout = pack.terrainLayouts
          .firstWhere((l) => l.id == 'bm-take-vs-purge-01');
      final templates = pack.terrainTemplates;
      final piece = layout.pieces.firstWhere((p) => p.id == 'area-11');
      final small =
          piece.buildings(templates).firstWhere((b) => b.label == 'Small L');
      expect(small.cornerMark, hasLength(3));
      // Found by its label, not its id: the re-import of 2026-08-27 replaced
      // every template id, and the id this once named is gone (§3.27).
      expect(
        templates.values.firstWhere((t) => t.label == 'Small L').wallCorner,
        isNull,
      );
    }, skip: skip);
  });
  group('the inks the printed maps use', () {
    // A property of the object, not of the ground: one area routinely carries
    // a lettered ruin and a barricade, and the printed map colours them
    // differently while leaving the area grey (§7.3.23).
    test('every placed part has a group', () {
      if (pack.terrainLayouts.isEmpty) return;
      final ungrouped = <String>{};
      var total = 0;
      for (final layout in pack.terrainLayouts) {
        for (final piece in layout.pieces) {
          for (final building in piece.buildings(pack.terrainTemplates)) {
            total++;
            if (building.group == TerrainGroup.unknown) {
              ungrouped.add(building.label);
            }
          }
        }
      }
      expect(total, greaterThan(700));
      // Empty: all twelve published parts are named in the table. The KOTC
      // walls do not appear because they carry no part template at all, so
      // `buildings` never yields them.
      expect(ungrouped, isEmpty);
    });

    test('every lettered part is a ruin, and one unlettered part is too', () {
      // This read "and only those" until the re-import of 2026-08-27 added
      // `Ruin Part`, which stands beside `CD` and `GH` in one composite as
      // the third piece of that ruin (§3.27). The direction worth keeping is
      // that a letter always means a ruin — the letters are what a player
      // matches against the printed table — and that nothing else drifts in
      // unnoticed, which is why the exception is named rather than widened.
      if (pack.terrainLayouts.isEmpty) return;
      final unlettered = <String>{};
      for (final layout in pack.terrainLayouts) {
        for (final piece in layout.pieces) {
          for (final b in piece.buildings(pack.terrainTemplates)) {
            if (RegExp(r'^(AB|CD|EF|GH)$').hasMatch(b.label)) {
              expect(b.group, TerrainGroup.ruin,
                  reason: '${b.label} in ${layout.id}');
            } else if (b.group == TerrainGroup.ruin) {
              unlettered.add(b.label);
            }
          }
        }
      }
      expect(unlettered, {'Ruin Part'});
    });

    // Named individually because the printed picture is the only source for
    // them: Pipes reads as a structure there rather than a barricade
    // (corrected 2026-08-24).
    test('each part is in the group the printed layout draws it in', () {
      if (pack.terrainTemplates.isEmpty) return;
      // By label, not by id: the re-import of 2026-08-27 replaced every
      // template id, and the ids these once named are gone. The letters are
      // stamped on the physical pieces and cannot change (§3.27).
      Iterable<TerrainGroup> groupsOf(String label) => pack
          .terrainTemplates.values
          .where((t) => t.label == label)
          .map((t) => t.group);

      void expectGroup(String label, TerrainGroup group) {
        final found = groupsOf(label);
        expect(found, isNotEmpty, reason: '$label is no longer published');
        expect(found, everyElement(group), reason: label);
      }

      // `CO` is upstream's misspelling of `CD` and folds into it; `Small L
      // flip` is the same physical piece the other way round.
      for (final part in ['AB', 'CD', 'EF', 'GH', 'Ruin Part']) {
        expectGroup(part, TerrainGroup.ruin);
      }
      for (final part in ['Generator', 'Tower', 'Pipes']) {
        expectGroup(part, TerrainGroup.structure);
      }
      for (final part in [
        'Small L',
        'Corner',
        'Short Barrier',
        'Long Barrier',
      ]) {
        expectGroup(part, TerrainGroup.barricade);
      }
    });

    test('one area can carry two different inks', () {
      if (pack.terrainLayouts.isEmpty) return;
      var mixed = 0;
      for (final layout in pack.terrainLayouts) {
        for (final piece in layout.pieces) {
          final groups = piece
              .buildings(pack.terrainTemplates)
              .map((b) => b.group)
              .toSet();
          if (groups.length > 1) mixed++;
        }
      }
      // The reason the group cannot live on the area: it is not one colour.
      expect(mixed, greaterThan(0));
    });
  });
}
