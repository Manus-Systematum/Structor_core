import 'package:test/test.dart';
import 'package:wh40k_core/wh40k_core.dart';

import 'support.dart';

void main() {
  final available = snapshotAvailable;

  late Dataset dataset;
  late RosterEditor editor;

  setUpAll(() {
    if (!available) return;
    dataset =
        Dataset.of(correctedLoader().loadFaction('tau-empire'), revision: 't');
    editor = RosterEditor(dataset);
  });

  Roster blank() => RosterEditor.blank(
        name: 'New army',
        factionId: 'tau-empire',
      );

  int priceOf(Roster roster) => PointsCalculator(dataset).price(roster).total;

  group('adding units', () {
    test('a new unit arrives at its smallest legal size, loaded', () {
      // Not "every weapon on the datasheet" — a Crisis suit lists nine and
      // carries three.
      final roster = editor.addUnit(blank(), 'crisis-fireknife-battlesuits');
      final unit = roster.units.single;

      expect(unit.models, 3);
      expect(unit.wargear.map((w) => w.itemId),
          containsAll(['battlesuit-fists', 'plasma-rifle']));
      expect(unit.countOf('battlesuit-fists'), 3, reason: 'one per model');
      expect(priceOf(roster), greaterThan(0));
    }, skip: available ? null : 'no snapshot');

    test('instance ids are never reused', () {
      // A recycled id would silently re-target a link or an enhancement at a
      // different unit.
      var roster = editor.addUnit(blank(), 'broadside-battlesuits');
      roster = editor.addUnit(roster, 'broadside-battlesuits');
      final second = roster.units.last.instanceId;

      roster = editor.removeUnit(roster, roster.units.first.instanceId);
      roster = editor.addUnit(roster, 'ghostkeel-battlesuit');

      expect(roster.units.map((u) => u.instanceId).toSet(), hasLength(2));
      expect(roster.units.last.instanceId, isNot(second));
    }, skip: available ? null : 'no snapshot');

    test('duplicating copies the loadout, not the identity', () {
      var roster = editor.addUnit(blank(), 'broadside-battlesuits');
      final first = roster.units.single.instanceId;
      roster = editor.setWargear(roster, first, 'seeker-missile', 2);
      roster = editor.duplicateUnit(roster, first);

      expect(roster.units, hasLength(2));
      expect(roster.units.last.countOf('seeker-missile'), 2);
      expect(roster.units.last.instanceId, isNot(first));
    }, skip: available ? null : 'no snapshot');
  });

  group('removing a unit takes its baggage with it', () {
    test('links, enhancement and Warlord all go', () {
      var roster = blank();
      roster = editor.addDetachment(roster, 'retaliation-cadre');
      roster = editor.addUnit(roster, 'commander-in-enforcer-battlesuit');
      roster = editor.addUnit(roster, 'crisis-fireknife-battlesuits');
      final leader = roster.units.first.instanceId;
      final squad = roster.units.last.instanceId;

      roster = editor.attach(roster, leader, squad);
      roster = editor.setWarlord(roster, leader);
      roster = editor.setEnhancement(
          roster, 'puretide-engram-neurochip-retaliation-cadre', leader);

      expect(roster.links, hasLength(1));
      expect(roster.enhancements, hasLength(1));

      roster = editor.removeUnit(roster, leader);

      // An enhancement on a unit that is gone is points that stop adding up.
      expect(roster.links, isEmpty);
      expect(roster.enhancements, isEmpty);
      expect(roster.warlordInstanceId, isNull);
      expect(roster.units.single.instanceId, squad);
    }, skip: available ? null : 'no snapshot');

    test('dropping a detachment drops its enhancements', () {
      var roster = blank();
      roster = editor.addDetachment(roster, 'retaliation-cadre');
      roster = editor.addUnit(roster, 'commander-in-enforcer-battlesuit');
      roster = editor.setEnhancement(
        roster,
        'puretide-engram-neurochip-retaliation-cadre',
        roster.units.single.instanceId,
      );

      roster = editor.removeDetachment(roster, 'retaliation-cadre');
      expect(roster.detachments, isEmpty);
      expect(roster.enhancements, isEmpty);
    }, skip: available ? null : 'no snapshot');
  });

  group('attachments', () {
    test('only units the data says may be led are offered', () {
      var roster = blank();
      roster = editor.addUnit(roster, 'commander-in-enforcer-battlesuit');
      roster = editor.addUnit(roster, 'crisis-fireknife-battlesuits');
      roster = editor.addUnit(roster, 'broadside-battlesuits');
      final leader = roster.units.first.instanceId;

      final offered =
          editor.eligibleBodyguards(roster, leader).map((u) => u.datasheetId);
      expect(offered, contains('crisis-fireknife-battlesuits'));
      expect(offered, isNot(contains('broadside-battlesuits')));
    }, skip: available ? null : 'no snapshot');

    test('a unit already led by someone else is not offered again', () {
      var roster = blank();
      roster = editor.addUnit(roster, 'commander-in-enforcer-battlesuit');
      roster = editor.addUnit(roster, 'commander-in-enforcer-battlesuit');
      roster = editor.addUnit(roster, 'crisis-fireknife-battlesuits');
      final first = roster.units[0].instanceId;
      final second = roster.units[1].instanceId;
      final squad = roster.units[2].instanceId;

      roster = editor.attach(roster, first, squad);
      expect(editor.eligibleBodyguards(roster, second), isEmpty);
    }, skip: available ? null : 'no snapshot');

    test('attaching twice replaces rather than accumulates', () {
      var roster = blank();
      roster = editor.addUnit(roster, 'commander-in-enforcer-battlesuit');
      roster = editor.addUnit(roster, 'crisis-fireknife-battlesuits');
      roster = editor.addUnit(roster, 'crisis-fireknife-battlesuits');
      final leader = roster.units[0].instanceId;

      roster = editor.attach(roster, leader, roster.units[1].instanceId);
      roster = editor.attach(roster, leader, roster.units[2].instanceId);

      // A character leads one unit. Two links would be a tangle the validator
      // then has to complain about.
      expect(roster.links, hasLength(1));
      expect(roster.links.single.toInstanceId, roster.units[2].instanceId);
    }, skip: available ? null : 'no snapshot');
  });

  group('wargear', () {
    test('setting a count to zero removes the entry', () {
      var roster = editor.addUnit(blank(), 'broadside-battlesuits');
      final id = roster.units.single.instanceId;

      roster = editor.setWargear(roster, id, 'seeker-missile', 1);
      expect(roster.units.single.countOf('seeker-missile'), 1);

      roster = editor.setWargear(roster, id, 'seeker-missile', 0);
      expect(roster.units.single.countOf('seeker-missile'), 0);
      expect(roster.units.single.wargear.map((w) => w.itemId),
          isNot(contains('seeker-missile')));
    }, skip: available ? null : 'no snapshot');

    test('priced wargear moves the total', () {
      var roster = editor.addUnit(blank(), 'crisis-fireknife-battlesuits');
      final id = roster.units.single.instanceId;

      // The default loadout is three suits with a missile pod each, and pods
      // are 5 points apiece: 100 + 15.
      expect(roster.units.single.countOf('missile-pod'), 3);
      expect(priceOf(roster), 115);

      // setWargear sets the count, it does not add to it.
      roster = editor.setWargear(roster, id, 'missile-pod', 6);
      expect(priceOf(roster), 130);

      roster = editor.setWargear(roster, id, 'missile-pod', 0);
      expect(priceOf(roster), 100);
    }, skip: available ? null : 'no snapshot');

    test('reset restores the default loadout, scaled to the unit', () {
      // Kroot Carnivores rather than a Crisis team: both sources cap a Crisis
      // team at three, so growing one to six was exercising a size the data
      // has never supported and the cap now refuses.
      var roster = editor.addUnit(blank(), 'kroot-carnivores');
      final id = roster.units.single.instanceId;
      final before = roster.units.single;
      final item = before.wargear.first.itemId;
      final perModel = before.countOf(item) / before.models;

      roster = editor.setWargear(roster, id, item, 0);
      roster = editor.setModels(roster, id, before.models * 2);
      roster = editor.resetWargear(roster, id);

      expect(roster.units.single.countOf(item),
          (perModel * before.models * 2).round(),
          reason:
              'the composition describes the smallest unit; this is twice it');
    }, skip: available ? null : 'no snapshot');
  });

  group('a replacement is one decision, not two counters', () {
    test('taking more of one gives up the same number of the other', () {
      // A Fireknife suit has two hardpoints, so the default is three plasma
      // rifles *and* three missile pods across three suits. The datasheet
      // words the choice as "replace the plasma rifle with a missile pod";
      // counting only upwards left the suit holding more guns than it has
      // places to put them.
      var roster = editor.addUnit(blank(), 'crisis-fireknife-battlesuits');
      final id = roster.units.single.instanceId;
      expect(roster.units.single.countOf('plasma-rifle'), 3);
      expect(roster.units.single.countOf('missile-pod'), 3);

      roster = editor.swapWargear(roster, id, 'missile-pod', 5,
          replaces: const ['plasma-rifle']);

      expect(roster.units.single.countOf('missile-pod'), 5);
      expect(roster.units.single.countOf('plasma-rifle'), 1,
          reason: 'two more pods cost two rifles');
    }, skip: available ? null : 'no snapshot');

    test('giving one up hands the other back', () {
      var roster = editor.addUnit(blank(), 'crisis-fireknife-battlesuits');
      final id = roster.units.single.instanceId;

      roster = editor.swapWargear(roster, id, 'missile-pod', 5,
          replaces: const ['plasma-rifle']);
      roster = editor.swapWargear(roster, id, 'missile-pod', 3,
          replaces: const ['plasma-rifle']);

      expect(roster.units.single.countOf('missile-pod'), 3);
      expect(roster.units.single.countOf('plasma-rifle'), 3,
          reason: 'back where it started');
    }, skip: available ? null : 'no snapshot');

    test('a swap never drives the other count negative', () {
      var roster = editor.addUnit(blank(), 'crisis-fireknife-battlesuits');
      final id = roster.units.single.instanceId;

      // More replacements than there are things to replace. The builder is
      // permissive, so this is allowed — it must not produce a negative.
      roster = editor.swapWargear(roster, id, 'missile-pod', 20,
          replaces: const ['plasma-rifle']);

      expect(roster.units.single.countOf('plasma-rifle'), 0);
      expect(roster.units.single.countOf('missile-pod'), 20);
    }, skip: available ? null : 'no snapshot');
  });

  group('a spelled-out choice is mutually exclusive', () {
    LoadoutGroup droneGroup() {
      final datasheet = dataset.unit('stealth-battlesuits')!;
      final loadout = UnitLoadout.forDatasheet(
        datasheet,
        catalogue: dataset,
        vocabulary: {
          for (final b in datasheet.wargearBudgets) ...b.items,
        },
      );
      return loadout.groups.singleWhere((g) => g.items.contains('gun-drone'));
    }

    test('selecting a bundle clears the alternatives', () {
      var roster = editor.addUnit(blank(), 'stealth-battlesuits');
      final id = roster.units.single.instanceId;
      final group = droneGroup();

      roster = editor.selectLoadoutBundle(
          roster, id, group, ['marker-drone', 'gun-drone']);
      expect(roster.units.single.countOf('marker-drone'), 1);
      expect(roster.units.single.countOf('gun-drone'), 1);

      // One kind only: the other must go, or the unit carries three drones
      // where the datasheet allows two.
      roster = editor.selectLoadoutBundle(roster, id, group, ['gun-drone']);
      expect(roster.units.single.countOf('gun-drone'), 1);
      expect(roster.units.single.countOf('marker-drone'), 0);
    }, skip: available ? null : 'no snapshot');

    test('clearing the group takes every item in it', () {
      var roster = editor.addUnit(blank(), 'stealth-battlesuits');
      final id = roster.units.single.instanceId;
      final group = droneGroup();

      roster = editor.selectLoadoutBundle(
          roster, id, group, ['marker-drone', 'gun-drone']);
      roster = editor.selectLoadoutBundle(roster, id, group, null);

      for (final item in group.items) {
        expect(roster.units.single.countOf(item), 0, reason: item);
      }
    }, skip: available ? null : 'no snapshot');
  });

  group('attaching seen from the unit rather than the character', () {
    test('a unit lists the characters that may lead it', () {
      var roster = editor.addUnit(blank(), 'crisis-fireknife-battlesuits');
      roster = editor.addUnit(roster, 'commander-in-enforcer-battlesuit');
      final squad = roster.units.first.instanceId;
      final commander = roster.units.last.instanceId;

      final leaders = editor.eligibleLeaders(roster, squad);
      expect(leaders.map((l) => l.leader.instanceId), contains(commander));
      expect(leaders.single.leadingInstanceId, isNull);
    }, skip: available ? null : 'no snapshot');

    test('a character busy elsewhere is listed, and says so', () {
      // Hiding it would omit the most likely thing you meant to change.
      var roster = editor.addUnit(blank(), 'crisis-fireknife-battlesuits');
      roster = editor.addUnit(roster, 'crisis-starscythe-battlesuits');
      roster = editor.addUnit(roster, 'commander-in-enforcer-battlesuit');
      final first = roster.units[0].instanceId;
      final second = roster.units[1].instanceId;
      final commander = roster.units[2].instanceId;

      roster = editor.attach(roster, commander, first);

      final leaders = editor.eligibleLeaders(roster, second);
      final entry =
          leaders.singleWhere((l) => l.leader.instanceId == commander);
      expect(entry.leadingInstanceId, first);
    }, skip: available ? null : 'no snapshot');

    test('choosing a busy character moves it', () {
      var roster = editor.addUnit(blank(), 'crisis-fireknife-battlesuits');
      roster = editor.addUnit(roster, 'crisis-starscythe-battlesuits');
      roster = editor.addUnit(roster, 'commander-in-enforcer-battlesuit');
      final first = roster.units[0].instanceId;
      final second = roster.units[1].instanceId;
      final commander = roster.units[2].instanceId;

      roster = editor.attach(roster, commander, first);
      roster = editor.attach(roster, commander, second);

      final leads =
          roster.links.where((l) => l.type == LinkType.leads).toList();
      expect(leads, hasLength(1), reason: 'it moved rather than multiplied');
      expect(leads.single.toInstanceId, second);
    }, skip: available ? null : 'no snapshot');
  });

  group('the editor is permissive, the validator is honest', () {
    test('an over-points list is built and then reported, not refused', () {
      // §2.3: findings with severity, never a hard block. A builder that
      // refuses the army standing on your table is worthless.
      var roster = blank();
      roster = editor.addDetachment(roster, 'retaliation-cadre');
      for (var i = 0; i < 20; i++) {
        roster = editor.addUnit(roster, 'riptide-battlesuit');
      }

      expect(roster.units, hasLength(20));
      final result = RosterValidator(dataset).validate(roster);
      expect(result.isLegal, isFalse);
      expect(result.errors.join(' '), contains('points'));
    }, skip: available ? null : 'no snapshot');

    test('a blank roster is legal to hold and reports what it needs', () {
      final result = RosterValidator(dataset).validate(blank());
      expect(result.findings, isNotEmpty);
    }, skip: available ? null : 'no snapshot');
  });

  group('rebuilding the reference army from nothing', () {
    test('the same list, assembled by the editor, prices the same', () {
      // The end-to-end claim: the builder can produce the list the importer
      // produces, and both come to 2000.
      var roster = RosterEditor.blank(
        name: '2k ret',
        factionId: 'tau-empire',
      );
      roster = editor.addDetachment(roster, 'advanced-acquisition-cadre');
      roster = editor.addDetachment(roster, 'experimental-prototype-cadre');

      void add(String datasheetId, Map<String, int> wargear, {int? models}) {
        roster = editor.addUnit(roster, datasheetId);
        final id = roster.units.last.instanceId;
        if (models != null) roster = editor.setModels(roster, id, models);
        for (final w in wargear.entries) {
          roster = editor.setWargear(roster, id, w.key, w.value);
        }
      }

      for (var i = 0; i < 2; i++) {
        add('commander-in-enforcer-battlesuit',
            {'missile-pod': 4, 'battlesuit-fists': 1});
        add('crisis-fireknife-battlesuits',
            {'missile-pod': 6, 'battlesuit-fists': 3, 'plasma-rifle': 0});
        add('commander-in-coldstar-battlesuit',
            {'tau-flamer': 4, 'battlesuit-fists': 1});
        add('crisis-starscythe-battlesuits',
            {'tau-flamer': 6, 'battlesuit-fists': 3, 'burst-cannon': 0});
      }

      expect(roster.units, hasLength(8));
      // 2 x (80 + 130 + 95 + 120) = 850 for the attached half of the list.
      expect(priceOf(roster), 850);
    }, skip: available ? null : 'no snapshot');
  });

  // Paragon Warsuits are the case these were reported against, and they are
  // Sororitas — the shared fixture above is T'au.
  late Dataset sisters;
  late RosterEditor sistersEditor;
  Roster paragons() => sistersEditor.addUnit(
      RosterEditor.blank(name: 'x', factionId: 'adepta-sororitas'),
      'paragon-warsuits');

  setUpAll(() {
    if (!available) return;
    sisters = Dataset.of(correctedLoader().loadFaction('adepta-sororitas'),
        revision: 's');
    sistersEditor = RosterEditor(sisters);
  });

  group('resizing a unit brings its wargear with it', () {
    test('added models arrive with the default kit', () {
      // A squad's guns were only ever set when the unit was created, so
      // growing it changed nothing but the number. Kroot Carnivores, because
      // Paragons cap at their starting size and cannot be grown at all.
      var roster = RosterEditor(dataset).addUnit(blank(), 'kroot-carnivores');
      final editor = RosterEditor(dataset);
      final id = roster.units.single.instanceId;
      final before = roster.units.single;
      final perModel = {
        for (final w in before.wargear) w.itemId: w.count ~/ before.models,
      };

      roster = editor.setModels(roster, id, before.models * 2);
      final after = roster.units.single;

      expect(after.models, before.models * 2);
      for (final w in before.wargear) {
        expect(after.countOf(w.itemId),
            w.count + perModel[w.itemId]! * before.models,
            reason: w.itemId);
      }
    });

    test('shrinking takes the same share back', () {
      var roster = paragons();
      final editor = sistersEditor;
      final id = roster.units.single.instanceId;
      final start = roster.units.single.wargear.toList();

      roster = editor.setModels(roster, id, roster.units.single.models * 2);
      roster = editor.setModels(roster, id, start.isEmpty ? 1 : 3);

      for (final w in start) {
        expect(roster.units.single.countOf(w.itemId), w.count,
            reason: w.itemId);
      }
    });

    test('a deliberate swap is not scaled with the unit', () {
      // A multi-melta bought for one model is one model's multi-melta.
      // Doubling the unit must not double a choice the player made.
      var roster = paragons();
      final editor = sistersEditor;
      final id = roster.units.single.instanceId;
      roster = editor.setWargear(roster, id, 'multi-melta', 1);

      roster = editor.setModels(roster, id, roster.units.single.models * 2);
      expect(roster.units.single.countOf('multi-melta'), 1);
    });
  });

  test('taking a bundle gives up what it replaces', () {
    // Choosing a Paragon's multi-melta left the heavy bolter it replaces on
    // the unit — a model carrying both guns.
    var roster = paragons();
    final editor = sistersEditor;
    final id = roster.units.single.instanceId;
    final datasheet = sisters.unit('paragon-warsuits')!;
    final loadout = UnitLoadout.forDatasheet(datasheet,
        catalogue: sisters, vocabulary: datasheet.wargearVocabulary);

    // The option is published carrier-scoped as `multi-melta-paragon-warsuits`
    // and the roster stores `multi-melta`; unscoped, they are the same item.
    // Read raw this found nothing and the test passed by doing nothing, which
    // is how the bug survived being written about.
    final counter =
        loadout.counters.where((c) => c.itemId == 'multi-melta').single;
    expect(counter.replaces, contains('heavy-bolter'),
        reason: 'the option says what it gives up');

    final bolters = roster.units.single.countOf('heavy-bolter');
    expect(bolters, greaterThan(0));

    roster = editor.swapWargear(roster, id, 'multi-melta', 1,
        replaces: counter.replaces);
    expect(roster.units.single.countOf('multi-melta'), 1);
    expect(roster.units.single.countOf('heavy-bolter'), bolters - 1,
        reason: 'the bolter it replaces is given up');

    // And putting it back restores the bolter.
    roster = editor.swapWargear(roster, id, 'multi-melta', 0,
        replaces: counter.replaces);
    expect(roster.units.single.countOf('heavy-bolter'), bolters);
  });

  group('a unit cannot be grown past what the data supports', () {
    test('the cap is the looser of the composition and the points table', () {
      // They disagree on 35 of 1,961 datasheets. Refusing the size the points
      // table prices would be the builder calling a legal list illegal, which
      // is the failure §2.3 exists to avoid.
      for (final factionId in ['tau-empire', 'adepta-sororitas', 'orks']) {
        final faction = correctedLoader().loadFaction(factionId);
        final data = Dataset.of(faction, revision: 'x');
        final ed = RosterEditor(data);
        for (final unit in faction.units) {
          final cap = ed.maxModels(unit.id);
          if (cap == null) continue;
          final composition = data.composition(unit.id);
          if (composition != null) {
            expect(cap, greaterThanOrEqualTo(composition.defaultModels),
                reason: '${unit.id}: a cap below the smallest legal size');
          }
          for (final bracket in unit.points) {
            expect(
                cap, greaterThanOrEqualTo(bracket.modelsMax ?? bracket.models),
                reason: '${unit.id}: a priced size the builder would refuse');
          }
        }
      }
    });

    test('setModels stops at the cap rather than going past it', () {
      var roster = paragons();
      final id = roster.units.single.instanceId;
      final cap = sistersEditor.maxModels('paragon-warsuits')!;

      roster = sistersEditor.setModels(roster, id, cap + 5);
      expect(roster.units.single.models, cap);
    });

    test('an over-size unit is reported rather than silently free', () {
      // The builder will not create one, but an import or an older save can
      // be in that state, and the symptom is invisible: no bracket covers the
      // size, so the unit prices at zero and the army looks cheaper.
      var roster = paragons();
      final id = roster.units.single.instanceId;
      final cap = sistersEditor.maxModels('paragon-warsuits')!;
      roster = roster.copyWith(units: [
        for (final u in roster.units) u.copyWith(models: cap + 1),
      ]);

      final result = RosterValidator(sisters).validate(roster);
      final finding =
          result.findings.where((f) => f.code == 'unit.over-size').toList();
      expect(finding, hasLength(1));
      expect(finding.single.instanceIds, [id]);
      expect(finding.single.message, contains('no points bracket covers it'));
    });

    test('and a unit at its cap still prices', () {
      // The reason for the cap: a unit grown past every bracket had none to
      // price it and silently cost nothing.
      var roster = paragons();
      final id = roster.units.single.instanceId;
      roster = sistersEditor.setModels(
          roster, id, sistersEditor.maxModels('paragon-warsuits')!);
      final cost = PointsCalculator(sisters).price(roster);
      expect(cost.total, greaterThan(0));
    });
  });

  test('a Paragon multi-melta costs what the datasheet says', () {
    // It priced at 20: the same 10-point upgrade arrived once per model group
    // and the costs were summed.
    final datasheet = sisters.unit('paragon-warsuits')!;
    final costs =
        datasheet.wargearCosts.where((c) => c.itemId == 'multi-melta').toList();
    expect(costs, hasLength(1));
    expect(costs.single.cost, 10);
  });
  group('a repeated entry in replaces is a quantity', () {
    // A Seraphim carries two pistols and swaps both for two hand flamers:
    // one choice, two for two. Iterating `replaces` applied the whole delta
    // once per entry, so two flamers arrived and four pistols left — and 44
    // options across the game are worded that way (§4.5).
    const group = LoadoutGroup(
      optionId: 'seraphim-squad-wgo-mfm-1',
      bundles: [
        ['ministorum-hand-flamer', 'ministorum-hand-flamer'],
        ['inferno-pistol', 'inferno-pistol'],
      ],
      replaces: ['bolt-pistol', 'bolt-pistol'],
    );

    Roster withPistols(int n) => Roster(
          name: 'seraphim',
          factionId: 'adepta-sororitas',
          battleSizeId: 'strike-force',
          units: [
            RosterUnit(
              instanceId: 'u1',
              datasheetId: 'seraphim-squad',
              models: 5,
              wargear: [WargearSelection(itemId: 'bolt-pistol', count: n)],
            ),
          ],
        );

    int countOf(Roster r, String item) => r.units.single.countOf(item);

    test('two for two, not two for four', () {
      final after = editor.selectLoadoutBundle(
        withPistols(10),
        'u1',
        group,
        const ['ministorum-hand-flamer', 'ministorum-hand-flamer'],
      );
      expect(countOf(after, 'ministorum-hand-flamer'), 2);
      expect(countOf(after, 'bolt-pistol'), 8);
    });

    test('clearing hands back exactly what was given up', () {
      var r = editor.selectLoadoutBundle(withPistols(10), 'u1', group,
          const ['ministorum-hand-flamer', 'ministorum-hand-flamer']);
      r = editor.selectLoadoutBundle(r, 'u1', group, null);
      expect(countOf(r, 'ministorum-hand-flamer'), 0);
      expect(countOf(r, 'bolt-pistol'), 10, reason: 'back where it started');
    });

    test('several models can take it, and each pays for its own', () {
      // The squad has five models; two of them swapping is two swaps, not
      // one. The group was yes-or-no, so a squad could make one (§4.5).
      final after = editor.selectLoadoutBundle(
        withPistols(10),
        'u1',
        group,
        const ['ministorum-hand-flamer', 'ministorum-hand-flamer'],
        copies: 2,
      );
      expect(countOf(after, 'ministorum-hand-flamer'), 4);
      expect(countOf(after, 'bolt-pistol'), 6);
    });

    test('going from two models to one hands one model back', () {
      var r = editor.selectLoadoutBundle(withPistols(10), 'u1', group,
          const ['ministorum-hand-flamer', 'ministorum-hand-flamer'],
          copies: 2);
      r = editor.selectLoadoutBundle(r, 'u1', group,
          const ['ministorum-hand-flamer', 'ministorum-hand-flamer'],
          copies: 1);
      expect(countOf(r, 'ministorum-hand-flamer'), 2);
      expect(countOf(r, 'bolt-pistol'), 8);
    });

    test('switching bundles does not give the pistols up twice', () {
      var r = editor.selectLoadoutBundle(withPistols(10), 'u1', group,
          const ['ministorum-hand-flamer', 'ministorum-hand-flamer']);
      r = editor.selectLoadoutBundle(
          r, 'u1', group, const ['inferno-pistol', 'inferno-pistol']);
      expect(countOf(r, 'inferno-pistol'), 2);
      expect(countOf(r, 'ministorum-hand-flamer'), 0);
      expect(countOf(r, 'bolt-pistol'), 8,
          reason: 'the pistols were already given up for the first bundle');
    });

    test('a counter with a repeated replacement gives up that many', () {
      // Mortifiers: two heavy bolters for one of this.
      final base = Roster(
        name: 'm',
        factionId: 'adepta-sororitas',
        battleSizeId: 'strike-force',
        units: const [
          RosterUnit(
            instanceId: 'u1',
            datasheetId: 'mortifiers',
            models: 2,
            wargear: [WargearSelection(itemId: 'heavy-bolter', count: 4)],
          ),
        ],
      );
      final after = editor.swapWargear(base, 'u1', 'penitent-flamer', 1,
          replaces: const ['heavy-bolter', 'heavy-bolter']);
      expect(countOf(after, 'penitent-flamer'), 1);
      expect(countOf(after, 'heavy-bolter'), 2);
    });
  });
}
