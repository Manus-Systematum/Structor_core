import 'package:test/test.dart';
import 'package:wh40k_core/wh40k_core.dart';

/// §3.15. A patch corrects the shipped data without a build, so the failure
/// that matters is not "the correction did not apply" — that is visible — but
/// "the correction applied to the wrong thing, or twice, or destroyed a
/// record it was only meant to touch".
void main() {
  List<Object?> records() => [
        {'id': 'a', 'name': 'Alpha', 'cp_cost': 1},
        {'id': 'b', 'name': 'Beta', 'cp_cost': 2, 'text': 'old'},
      ];

  DatasetPatch patchOf(List<PatchOperation> ops, {String id = '2026-08-26'}) =>
      DatasetPatch(
        id: id,
        name: 'test',
        appliesTo: 'pre-launch-provisional',
        source: 'test',
        operations: ops,
      );

  List<Object?> applied(List<PatchOperation> ops) => PatchSet([patchOf(ops)])
      .apply(records(), faction: 'orks', file: 'stratagems');

  Map<String, Object?> at(List<Object?> list, String id) =>
      list.cast<Map<String, Object?>>().firstWhere((r) => r['id'] == id);

  test('set merges fields and leaves the rest alone', () {
    final out = applied([
      const PatchOperation(
        faction: 'orks',
        file: 'stratagems',
        op: PatchOp.set,
        id: 'b',
        values: {'text': 'new'},
      ),
    ]);

    expect(at(out, 'b')['text'], 'new');
    expect(at(out, 'b')['cp_cost'], 2, reason: 'not named, not touched');
    expect(at(out, 'b')['name'], 'Beta');
    expect(out, hasLength(2));
  });

  // The reason removal is an operation and not an omission: patches are
  // distributed as data-pack updates, so a stratagem the released rules do
  // not have has to be *said* to be gone.
  test('remove drops the record it names and only that one', () {
    final out = applied([
      const PatchOperation(
        faction: 'orks',
        file: 'stratagems',
        op: PatchOp.remove,
        id: 'a',
      ),
    ]);

    expect(out, hasLength(1));
    expect(at(out, 'b')['name'], 'Beta');
  });

  test('add appends, and a second application does not duplicate it', () {
    const op = PatchOperation(
      faction: 'orks',
      file: 'stratagems',
      op: PatchOp.add,
      id: 'c',
      values: {'name': 'Gamma', 'cp_cost': 1},
    );

    final once = applied([op]);
    expect(once, hasLength(3));
    expect(at(once, 'c')['name'], 'Gamma');

    final twice = PatchSet([
      patchOf([op]),
      patchOf([op], id: '2026-09-01')
    ]).apply(records(), faction: 'orks', file: 'stratagems');
    expect(twice, hasLength(3), reason: 'the id is the identity');
  });

  test('an operation for another faction or file is not applied', () {
    final out = PatchSet([
      patchOf(const [
        PatchOperation(
          faction: 'tau-empire',
          file: 'stratagems',
          op: PatchOp.remove,
          id: 'a',
        ),
        PatchOperation(
          faction: 'orks',
          file: 'enhancements',
          op: PatchOp.remove,
          id: 'b',
        ),
      ])
    ]).apply(records(), faction: 'orks', file: 'stratagems');

    expect(out, hasLength(2), reason: 'neither addressed this file');
  });

  test('a set against a record that is not there is not an error', () {
    // The upstream source may have removed it already, which is the outcome
    // the patch wanted. Failing the load over it would take the whole faction
    // down for a correction that is no longer needed.
    final out = applied([
      const PatchOperation(
        faction: 'orks',
        file: 'stratagems',
        op: PatchOp.set,
        id: 'gone',
        values: {'text': 'x'},
      ),
    ]);
    expect(out, hasLength(2));
  });

  test('later patches win, whatever order they arrived in', () {
    final out = PatchSet([
      patchOf(const [
        PatchOperation(
          faction: 'orks',
          file: 'stratagems',
          op: PatchOp.set,
          id: 'b',
          values: {'text': 'september'},
        )
      ], id: '2026-09-01'),
      patchOf(const [
        PatchOperation(
          faction: 'orks',
          file: 'stratagems',
          op: PatchOp.set,
          id: 'b',
          values: {'text': 'august'},
        )
      ], id: '2026-08-26'),
    ]).apply(records(), faction: 'orks', file: 'stratagems');

    expect(at(out, 'b')['text'], 'september');
  });

  test('a record with no id survives untouched', () {
    final out = PatchSet([
      patchOf(const [
        PatchOperation(
          faction: 'orks',
          file: 'stratagems',
          op: PatchOp.remove,
          id: 'a',
        )
      ])
    ]).apply([
      ...records(),
      {'name': 'no id at all'},
    ], faction: 'orks', file: 'stratagems');

    expect(
        out
            .whereType<Map<String, Object?>>()
            .where((r) => r['name'] == 'no id at all'),
        hasLength(1));
  });

  test('nothing to apply returns the very same list', () {
    final input = records();
    expect(
      const PatchSet.empty().apply(input, faction: 'orks', file: 'stratagems'),
      same(input),
    );
  });

  test('a patch survives the round trip through its bundle', () {
    final patch = patchOf(const [
      PatchOperation(
        faction: 'orks',
        file: 'stratagems',
        op: PatchOp.set,
        id: 'b',
        values: {'text': 'new'},
        note: 'why',
      ),
    ]);

    final back = DatasetPatch.decode(patch.encode());
    expect(back.id, '2026-08-26');
    expect(back.appliesTo, 'pre-launch-provisional');
    expect(back.operations.single.note, 'why');
    expect(back.operations.single.values['text'], 'new');
  });

  // A build that predates patches has to keep working against a manifest
  // that has them — that is the whole point of shipping them out of band.
  test('an older build ignores the patches it does not know about', () {
    final manifest = DatasetManifest(
      generated: 'r1',
      source: '40kdc-data',
      bundles: const [],
      patches: const [
        PatchEntry(
          id: '2026-08-26',
          name: 'August 2026 rules update',
          file: 'patch-2026-08-26.json.gz',
          sha256: 'abc',
          bytes: 10,
          appliesTo: 'pre-launch-provisional',
        ),
      ],
    );

    final json = manifest.toJson();
    expect(json['schema'], bundleSchemaVersion,
        reason: 'patches did not need a schema bump');

    final reread = DatasetManifest.fromJson(json);
    expect(reread.isFuture, isFalse);
    expect(reread.patches.single.appliesTo, 'pre-launch-provisional');
  });
}
