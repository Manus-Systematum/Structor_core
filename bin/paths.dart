import 'dart:io';

/// Where the dataset lives, which is not in this repository.
///
/// This package is the rules engine and the tools that read a dataset; the
/// dataset itself — the 40kdc snapshot, the merge, the corrections, the
/// updates — belongs to the Structor repository that builds the bundles from
/// it. `STRUCTOR_DATA` names it outright; otherwise a sibling checkout is
/// assumed, under either name the repository is cloned as.
String get dataRoot =>
    Platform.environment['STRUCTOR_DATA'] ??
    ['../Structor/data', '../Wh40k_Companion/data'].firstWhere(
        (at) => Directory(at).existsSync(),
        orElse: () => '../Structor/data');

/// The repository the dataset is in, for the files beside `data/` rather than
/// inside it — `data-corrections.yaml`, `crosscheck-accepted.yaml`.
String get projectRoot => Directory(dataRoot).parent.path;
