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
    ['../Structor/data', '../Wh40k_Companion/data']
        .firstWhere((at) => Directory(at).existsSync(),
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
