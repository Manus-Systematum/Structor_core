import 'dart:io';

import 'package:test/test.dart';
import 'package:wh40k_core/src/source/bsdata/bs_document.dart';
import 'package:wh40k_core/src/source/bsdata/bs_mapper.dart';

import 'support.dart';

/// What a BattleScribe `infoLink` puts on a datasheet, and what it does not.
///
/// Both halves are read off the Sisters of Silence, which carry one of each in
/// the same list of five links: `Daughters of the Abyss` is a link to a shared
/// *profile*, and `Fights First` is a link to a shared rule that BSData hides
/// unless Aleya is leading the unit.
void main() {
  final bsRoot = '$dataRoot/bsdata';
  final available = Directory('$bsRoot/adeptus-custodes').existsSync();

  late final BsFaction custodes;
  if (available) {
    final index = BsIndex();
    for (final f in Directory('$bsRoot/shared').listSync().whereType<File>()) {
      if (f.path.endsWith('.json')) index.add(f, asRoot: false);
    }
    for (final f
        in Directory('$bsRoot/adeptus-custodes').listSync().whereType<File>()) {
      if (f.path.endsWith('.json')) index.add(f);
    }
    index.resolveRootLinks();
    custodes = BsMapper(index).faction('adeptus-custodes');
  }

  Map<String, Object?> unit(String id) =>
      custodes.units.firstWhere((u) => u['id'] == id);

  List<String> abilitiesOf(String id) =>
      (unit(id)['ability_ids']! as List).cast<String>();

  test('a rule linked as a profile reaches the datasheet', () {
    // All three Sisters of Silence datasheets link it, and it is the whole of
    // what they are: Feel No Pain 3+ against Psychic Attacks and mortal
    // wounds. It is a `sharedProfiles` entry rather than a `sharedRules` one,
    // which is the only thing separating it from Fights First below.
    for (final id in ['prosecutors', 'vigilators', 'witchseekers']) {
      expect(abilitiesOf(id), contains('daughters-of-the-abyss'),
          reason: '$id has Daughters of the Abyss printed on it');
    }

    final record = custodes.abilities
        .firstWhere((a) => a['ability_id'] == 'daughters-of-the-abyss');
    expect(record['description'], contains('Feel No Pain 3+'));
  }, skip: available ? null : 'no BSData snapshot');

  test('a rule hidden until a leader joins is not printed on the datasheet',
      () {
    // BSData carries Fights First on all three, hidden while `associations of
    // Aleya < 1` — which is how "Aleya's unit fights first" is written. Read
    // as an unconditional link it becomes a rule the datasheet does not have.
    for (final id in ['prosecutors', 'vigilators', 'witchseekers']) {
      expect(abilitiesOf(id), isNot(contains('fights-first')),
          reason: '$id only fights first while Aleya leads it');
    }
  }, skip: available ? null : 'no BSData snapshot');

  test('a rule hidden only by a choice nobody made stays on the datasheet', () {
    // The other direction, and the reason a hidden modifier cannot simply be
    // taken at face value: Witchseekers link `Scouts` with a name modifier and
    // no visibility condition at all, and the datasheets that hide a rule
    // *while* something is taken — Deep Strike in Boarding Actions — have it
    // in every other game.
    expect(abilitiesOf('witchseekers'), contains('scouts-6'));
  }, skip: available ? null : 'no BSData snapshot');
}
