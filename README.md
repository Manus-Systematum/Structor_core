# Structor core

The rules engine behind [Structor](https://structor.systematum.net), a
Warhammer 40,000 11th-edition companion app: the dataset model, the roster
and points rules, the mission and secondary logic, the importer, and the
tools that build distributable data bundles from a 40kdc snapshot.

No Flutter, no UI, no platform code. Two apps depend on it — the iOS one in
`Structor` and the Android one in `Structor_android` — which is why it is
here rather than inside either of them.

```yaml
dependencies:
  wh40k_core:
    git:
      url: git@github.com:Manus-Systematum/Structor_core.git
      ref: main
```

## The dataset is not in this repository

It is large, it is derived from upstream snapshots, and it belongs to the
repository that publishes it. The tools and the tests look for a sibling
checkout of `Structor`, and `STRUCTOR_DATA` overrides that:

```bash
STRUCTOR_DATA=/path/to/Structor/data dart run bin/bundle.dart
```

Every test that needs the dataset skips when it is absent, so a clone with
nothing beside it still runs its own suite green — it tests what it can
rather than pretending to test what it cannot.

## Tests

```bash
flutter test
```

538 of them, and the design decisions they pin are recorded in `DESIGN.md`
in the Structor repository.

## Licence

MIT for this code. The data it reads is not: each source keeps its own terms,
which the app's About screen names in full.
