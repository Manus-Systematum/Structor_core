import 'package:test/test.dart';
import 'package:wh40k_core/src/source/bsdata/bs_slug.dart';
import 'package:wh40k_core/wh40k_core.dart';

import 'support.dart';

void main() {
  group('normalising BattleScribe markup', () {
    test('small caps and bold both mean keyword, so they become one thing', () {
      // `**^^T’au Empire^^**` is the commonest shape in the data and the worst
      // to read raw. One emphasis level is enough on a phone.
      expect(normaliseRuleText('**^^T’au Empire^^** models'),
          '**T’au Empire** models');
      expect(normaliseRuleText('^^Grey Knights Infantry^^ model only.'),
          '**Grey Knights Infantry** model only.');
      // Both orders appear. This one left a stray `**` mid-sentence: "If your
      // Army Faction is Adepta Sororitas**, each unit…".
      expect(normaliseRuleText('is ^^**Adepta Sororitas**^^, each unit'),
          'is **Adepta Sororitas**, each unit');
    });

    test('invisible characters go', () {
      // Non-breaking spaces and hyphens carry nothing a screen needs, and
      // 4,152 of them are in the merged data.
      expect(normaliseRuleText('ranged weapons'), 'ranged weapons');
      expect(normaliseRuleText('Rad‑Zone'), 'Rad-Zone');
    });

    test('a bullet is a clause, not a character mid-sentence', () {
      // Inline, they read as part of the previous sentence: "If you do: ▫
      // Place this unit in…".
      expect(
        normaliseRuleText('If you do: ▫ Place this unit. ▫ It can move.'),
        'If you do:\n• Place this unit.\n• It can move.',
      );
    });

    test('datasheet notation is left exactly as printed', () {
      // `[SUSTAINED HITS 1]` is how a datasheet writes it, not markup.
      expect(normaliseRuleText('has the **[SUSTAINED HITS 1]** ability'),
          'has the **[SUSTAINED HITS 1]** ability');
    });

    test('emphasis survives into the data rather than being stripped', () {
      // Which words are keywords is information: `**T’AU EMPIRE** models` and
      // `T’au Empire models` do not say the same thing to someone checking
      // whether a rule applies. Rendering it is the app's job.
      expect(normaliseRuleText('**T’AU EMPIRE** models'),
          contains('**T’AU EMPIRE**'));
    });
  });

  group('splitting into runs', () {
    test('bold and italic become their own runs', () {
      final spans = ruleSpans('While a **Harvester** is near, *see note*.');
      expect(spans.map((s) => s.text),
          ['While a ', 'Harvester', ' is near, ', 'see note', '.']);
      expect(spans[1].bold, isTrue);
      expect(spans[3].italic, isTrue);
    });

    test('plain text is one run', () {
      expect(ruleSpans('Nothing marked here.').single.bold, isFalse);
    });

    test('no run is empty', () {
      // An empty span renders as nothing and costs a TextSpan to say so.
      for (final span in ruleSpans('**A** **B**')) {
        expect(span.text, isNotEmpty);
      }
    });
  });

  test('the shipped data carries no raw markers', () {
    // The point of doing this at ingest: every consumer sees it cleaned, and
    // a marker reaching a screen is a bug nobody notices until a game.
    final loader = DatasetLoader(snapshotDir.path,
        corrections: DatasetLoader.correctionsAt(correctionsPath));
    if (!loader.root.existsSync()) return;

    final offenders = <String>[];
    for (final factionId in loader.availableFactions()) {
      for (final ability in loader.loadFaction(factionId).abilities) {
        final text = ability.description;
        if (text == null) continue;
        if (text.contains('^^') ||
            text.contains(' ') ||
            text.contains('▪') ||
            text.contains('■')) {
          offenders.add('$factionId/${ability.abilityId}');
        }
      }
    }
    expect(offenders, isEmpty, reason: offenders.take(5).join(', '));
  });
  test('an unpaired small-caps marker is dropped, not printed', () {
    // Custodes' Revered Companions opens a small-caps run and closes it in
    // the wrong place: `**^Anathema Psykana**` at one end, `Psykana^^**` at
    // the other. The folds only match balanced runs, so the odd marker
    // survived them and reached the screen as a literal caret.
    expect(normaliseRuleText('a **^Foo** and that Bar^^** unit'),
        isNot(contains('^')));
    // The balanced case still folds to emphasis rather than being stripped.
    expect(normaliseRuleText('the ^^Foo^^ unit'), 'the **Foo** unit');
  });
  test('a detachment rule carries its printed wording', () {
    // What a player looks up mid-game, and for 127 of 239 rules the app had
    // only a community paraphrase of the structured effect to show — every
    // Adepta Sororitas detachment among them. The wording was in BSData the
    // whole time: a detachment rule is a `sharedRule`, or a `rules` entry on
    // the non-datasheet container the detachments hang off, and the harvest
    // walked neither.
    final loader = DatasetLoader(snapshotDir.path,
        corrections: DatasetLoader.correctionsAt(correctionsPath));
    if (!loader.root.existsSync()) return;

    var total = 0, described = 0;
    for (final factionId in loader.availableFactions()) {
      for (final ability in loader.loadFaction(factionId).abilities) {
        if (ability.abilityType != 'detachment') continue;
        total++;
        if ((ability.description ?? '').trim().isNotEmpty) described++;
      }
    }
    expect(total, greaterThan(200));
    // 234 of 263 as counted here, which walks chapters as well as parents.
    // It was under half before the harvest reached shared rules.
    expect(described / total, greaterThan(0.85),
        reason: '$described of $total detachment rules are printed');
  });
  test('bold and small caps fold in every order the data writes them', () {
    // Four orders exist and only two were handled. The missed pair came from
    // Custodes' Revered Companions, which opens nested and closes
    // interleaved. The bare small-caps rule then ran on half a pair and ate
    // the space in front of it — `All other**Adeptus Custodes` — which is a
    // spacing bug produced by a markup bug, and reads as a source typo.
    for (final raw in const [
      'a **^^Foo^^** b', // nested, bold outside
      'a ^^**Foo**^^ b', // nested, small caps outside
      'a ^^**Foo^^** b', // interleaved
      'a **^^Foo**^^ b', // interleaved, the other way
      'a ^^Foo^^ b', // small caps alone
      'a **Foo** b', // bold alone
    ]) {
      expect(normaliseRuleText(raw), 'a **Foo** b', reason: raw);
    }
  });

  test('no ability description carries a caret or a tripled marker', () {
    final loader = DatasetLoader(snapshotDir.path,
        corrections: DatasetLoader.correctionsAt(correctionsPath));
    if (!loader.root.existsSync()) return;

    final offenders = <String>[];
    for (final factionId in loader.availableFactions()) {
      for (final ability in loader.loadFaction(factionId).abilities) {
        final text = ability.description ?? '';
        if (text.contains('^') || text.contains('***')) {
          offenders.add('$factionId/${ability.abilityId}');
        }
      }
    }
    expect(offenders, isEmpty, reason: offenders.take(5).join(', '));
  });
  test('a rule with a number in its name keeps the number', () {
    // BSData writes `Scouts X"` as one shared rule, and a datasheet that has
    // `Scouts 6"` links it with a name modifier. Reading the target's bare
    // name filed every such datasheet under `scouts` — the rulebook
    // explanation, which carries no distance — so a Dominion Squad showed
    // "Scouts" with no number and never reached the Scout moves list.
    final loader = DatasetLoader(snapshotDir.path,
        corrections: DatasetLoader.correctionsAt(correctionsPath));
    if (!loader.root.existsSync()) return;

    final sisters = loader.loadFaction('adepta-sororitas');
    final dominions = sisters.units.firstWhere((u) => u.id == 'dominion-squad');
    expect(dominions.abilityIds, contains('scouts-6'));
    expect(dominions.abilityIds, isNot(contains('scouts')));

    // Not one datasheet: the same shape carries Deadly Demise, Feel No Pain
    // and Firing Deck, and the numbers are the whole content of those rules.
    var numbered = 0;
    for (final factionId in loader.availableFactions()) {
      for (final unit in loader.loadFaction(factionId).units) {
        for (final id in unit.abilityIds) {
          if (RegExp(r'^scouts-\d').hasMatch(id)) numbered++;
        }
      }
    }
    expect(numbered, greaterThan(50));
  });

  test('every movement characteristic carries its inch mark', () {
    // Upstream writes it both ways — `7"` on most datasheets and a bare `10`
    // on a handful — so one screen showed `5"` on a statline and `10` in the
    // move list, which reads as two different kinds of number.
    final loader = DatasetLoader(snapshotDir.path,
        corrections: DatasetLoader.correctionsAt(correctionsPath));
    if (!loader.root.existsSync()) return;

    final offenders = <String>[];
    for (final factionId in loader.availableFactions()) {
      for (final unit in loader.loadFaction(factionId).units) {
        for (final profile in unit.profiles) {
          final m = profile.m;
          if (m == null || m.isEmpty || m == '-') continue;
          if (!m.endsWith('"')) offenders.add('$factionId/${unit.id}: $m');
        }
      }
    }
    expect(offenders, isEmpty, reason: offenders.take(5).join(', '));
  });
  test('Combat Patrol content is not offered in a matched-play list', () {
    // The 40kdc snapshot was first ingested with Combat Patrol units in it,
    // and the mode scope is carried per record. Datasheets were already
    // filtered; detachments were not, so every faction offered its Combat
    // Patrol formation beside the real ones at 1 DP — `Sudden Dawn Cadre`
    // for T'au, `’Ardmob` for Orks, 24 of them in all.
    final loader = DatasetLoader(snapshotDir.path,
        corrections: DatasetLoader.correctionsAt(correctionsPath));
    if (!loader.root.existsSync()) return;

    var patrolDetachments = 0, patrolUnits = 0;
    for (final factionId in loader.availableFactions()) {
      final dataset = Dataset.of(loader.loadFaction(factionId), revision: 't');
      for (final d in dataset.buildableDetachments) {
        if (!d.isMatchedPlay) patrolDetachments++;
      }
      for (final u in dataset.buildableUnits) {
        if (!u.isMatchedPlay) patrolUnits++;
      }
      // Still resolvable by id, so a roster naming one still opens (§2.2).
      expect(dataset.allDetachments.length,
          greaterThanOrEqualTo(dataset.buildableDetachments.length));
    }
    expect(patrolDetachments, 0);
    expect(patrolUnits, 0);

    // The T'au one by name, so this fails loudly rather than by a count.
    final tau = Dataset.of(loader.loadFaction('tau-empire'), revision: 't');
    expect(tau.buildableDetachments.map((d) => d.name),
        isNot(contains('Sudden Dawn Cadre')));
    expect(tau.detachment('sudden-dawn-cadre'), isNotNull,
        reason: 'narrowed what is offered, not what can be read');
  });

  test('an accented name is one datasheet, not two', () {
    // `Brôkhyr Iron-master` slugs to `brokhyr-iron-master` in 40kdc, which
    // transliterates, and would slug to `br-khyr-iron-master` here, where `ô`
    // is not `[a-z0-9]` and becomes a separator. The two never met, so the
    // merge added a second copy instead of filling in the first.
    expect(bsSlug('Brôkhyr Iron-master'), 'brokhyr-iron-master');
    expect(bsSlug('Khârn the Betrayer'), 'kharn-the-betrayer');
    expect(bsSlug('Ûthar the Destined'), 'uthar-the-destined');
    expect(bsSlug('Kâhl'), 'kahl');

    final loader = DatasetLoader(snapshotDir.path,
        corrections: DatasetLoader.correctionsAt(correctionsPath));
    if (!loader.root.existsSync()) return;
    for (final factionId in loader.availableFactions()) {
      final seen = <String, String>{};
      for (final unit in loader.loadFaction(factionId).units) {
        final name = unit.name.trim().toLowerCase();
        final first = seen[name];
        expect(first, isNull,
            reason: '$factionId: ${unit.name} is both $first and ${unit.id}');
        seen[name] = unit.id;
      }
    }
  });
  test('a rule the effect does not place is filed by its mapping', () {
    // The turn page files a rule by `phases.contains(phase)`, and the phases
    // came only from walking the structured effect. `Righteous Repugnance` is
    // a bare `add 3 Attacks` — nothing in its structure says Shooting or
    // Fight — so it appeared in no phase section of any list with Morvenn
    // Vahl in it. `phase-mappings.json` said all five the whole time and was
    // read into FactionData and then read by nothing: **5,222 of the 8,533
    // published mappings** were in that position.
    const renderer = RulesRenderer();
    final loader = DatasetLoader(snapshotDir.path,
        corrections: DatasetLoader.correctionsAt(correctionsPath));
    if (!loader.root.existsSync()) return;

    final sisters =
        Dataset.of(loader.loadFaction('adepta-sororitas'), revision: 't');
    final ability = sisters.ability('righteous-repugnance')!;
    expect(renderer.render(ability).phases, isEmpty,
        reason: 'the effect names no phase, which is why this was missed');
    expect(
      renderer
          .render(ability, published: sisters.phasesFor(ability.abilityId))
          .phases,
      containsAll(['shooting', 'fight']),
    );

    // Union, not replacement: where the effect *does* name a phase, that
    // still holds.
    var derivedSomewhere = 0;
    for (final a in sisters.faction.abilities) {
      if (renderer.render(a).phases.isNotEmpty) derivedSomewhere++;
    }
    expect(derivedSomewhere, greaterThan(0));
  });
  test('a rule is not filed under every phase just because it is unknown', () {
    // `phase-mappings.json` is community-authored and lists all five phases
    // where it has no answer, which the turn page honours literally — so
    // `Righteous Repugnance` appeared in the Charge section of a list with
    // Morvenn Vahl in it. Reported by the app's user.
    //
    // **All five is sometimes a real claim**, which is why the pattern is
    // corrected case by case rather than ignored: 183 mappings do it and 37
    // of them are right.
    final loader = correctedLoader();
    if (!loader.root.existsSync()) return;

    List<String> phasesOf(String faction, String id) => loader
        .loadFaction(faction)
        .phaseMappings
        .firstWhere((m) => m.sourceId == id)
        .phases;

    // Its own text: "selected to shoot or fight".
    expect(phasesOf('adepta-sororitas', 'righteous-repugnance'),
        unorderedEquals(['shooting', 'fight']));
    expect(phasesOf('drukhari', 'crucible-of-malediction'), ['shooting']);
    expect(phasesOf('world-eaters', 'idols-of-khorne'), ['command']);

    // …and one that really does apply in every phase is untouched:
    // "Once per battle, at the start of any phase".
    expect(phasesOf('chaos-daemons', 'unholy-vigour'), hasLength(5));
  });
}
