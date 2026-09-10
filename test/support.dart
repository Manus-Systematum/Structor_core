import 'dart:io';

import 'package:wh40k_core/wh40k_core.dart';

/// Where the dataset and the corrections live, which is no longer here.
///
/// This package is the rules engine; the data it is fed — the 40kdc snapshot,
/// the merge, `data-corrections.yaml` — belongs to the Structor repository
/// that builds the bundles, and is far too large to carry twice. Tests that
/// need it look in a sibling checkout, and `STRUCTOR_DATA` overrides that for
/// anyone whose directories are arranged differently.
///
/// Nothing here fails when it is absent: every test that reads the dataset is
/// guarded by [snapshotAvailable] and skips instead, so this package's suite
/// is green on a clone with no dataset beside it — testing what it can rather
/// than pretending to test what it cannot.
final dataRoot = Platform.environment['STRUCTOR_DATA'] ??
    ['../Structor/data', '../Wh40k_Companion/data'].firstWhere(
        (at) => Directory(at).existsSync(),
        orElse: () => '../Structor/data');
final correctionsPath = '$dataRoot-corrections.yaml';

final snapshotDir = Directory('$dataRoot/merged');

bool get snapshotAvailable => snapshotDir.existsSync();

/// A loader with the shipped corrections applied (DESIGN.md §3.6) — the same
/// view the bundler, the app and the snapshot writer get.
///
/// Tests that touch the reference roster need this, because the fixture is
/// produced by an importer reading corrected data: a Commander's Gun Drone is
/// only wargear it can take once the correction says so.
///
/// The cross-check deliberately does **not** use this. Its whole value is
/// comparing upstream against upstream.
DatasetLoader correctedLoader() => DatasetLoader(
      snapshotDir.path,
      corrections: DatasetLoader.correctionsAt(correctionsPath),
    );

/// What the reference list costs against today's data — not what it prints.
///
/// The export prints **2,000** and was a legal Strike Force when it was made.
/// Two of its sixteen units cost ten points more now, and Games Workshop's own
/// published points back the higher figure in both cases:
///
/// | unit | export | GW today |
/// | --- | --- | --- |
/// | Crisis Starscythe Battlesuits (×2) | 120 | 100 + 6 flamers at 5 = 130 |
/// | The Twin Lance | 220 | 230 |
///
/// Whether Games Workshop raised them or the exporting app had them wrong is
/// not something this repository can tell, and the tests do not claim either:
/// what is checked is that our arithmetic reproduces the source Games
/// Workshop publishes, unit by unit. Fourteen of the sixteen still price to
/// their printed figure exactly, which is what makes the fixture worth
/// keeping — the importer, the copy-index brackets and the per-instance
/// wargear charges are all still under test.
///
/// **A fresh export would restore the stronger check**, where the total and
/// the printed total are the same number and any divergence at all is a bug.
/// Until there is one, this constant carries the difference explicitly so
/// that a *new* divergence still fails rather than hiding inside a stale one.
const referenceListCost = 2030;

/// The overrun the reference list now reports at a 2,000 point cap.
///
/// The list is genuinely illegal against today's points, which is the
/// validator working: an army built to a limit does not stay under it when
/// the limit's currency is repriced.
const referenceListOverrun = referenceListCost - 2000;

/// The same arithmetic for the 1,000 point Incursion fixture, which prints
/// 995.
///
/// It drifts by the same 30 and for the same two datasheets — two Starscythe
/// units and The Twin Lance — which is the strongest evidence available here
/// that the difference is a points change and not something the importer is
/// doing to these two lists. Nothing else in either export moved.
const incursionListCost = 1025;
