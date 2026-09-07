import 'dart:io';

import 'package:test/test.dart';
import 'package:wh40k_core/wh40k_core.dart';

import 'support.dart';

/// Units from a faction the army does not own (DESIGN.md §4.18).
void main() {
  final root = Directory(snapshotDir.path);
  final skip = root.existsSync() ? null : 'no snapshot';
  final loader = DatasetLoader(snapshotDir.path,
      corrections: DatasetLoader.correctionsAt(correctionsPath));

  group('the table is a transcription, and stays one', () {
    // The point of naming an abilityId in every entry: if upstream withdraws
    // a rule or rewrites it into something else, this fails instead of the
    // app quietly enforcing a rule nobody publishes.
    test('every rule still exists upstream and still admits allies', () {
      if (!root.existsSync()) return;

      // The abilities pool is shared across faction files rather than scoped
      // to one, so any faction that carries the ability is enough to find it.
      final seen = <String, SourceAbility>{};
      for (final faction in [
        'genestealer-cults',
        'drukhari',
        'aeldari',
        'agents-of-the-imperium',
        'chaos-daemons',
        // Wretched Thralls is published in exactly one bundle. The enrichment
        // pool is per-faction copies of a shared set, and the copies are not
        // identical.
        'chaos-knights',
      ]) {
        for (final ability in loader.loadFaction(faction).abilities) {
          seen.putIfAbsent(ability.abilityId, () => ability);
        }
      }

      for (final rule in AllyRules.all) {
        final ability = seen[rule.abilityId];
        expect(ability, isNotNull,
            reason: '${rule.name} (${rule.abilityId}) is no longer published');
        final text = (ability!.description ?? '').toLowerCase();
        expect(text, contains('you can include'),
            reason: '${rule.name} no longer reads as an inclusion rule');
        // What it admits, still named in its own text. Stronger than looking
        // for "even though they do not have", which only five of the seven
        // say — The Star Children's Blessings and Wretched Thralls state the
        // permission without that clause.
        expect(rule.grantedKeywords.any(text.contains), isTrue,
            reason: '${rule.name} no longer names '
                '${rule.grantedKeywords.join(" or ")}');
      }
    }, skip: skip);

    test('every granted keyword is a faction some datasheet actually has', () {
      if (!root.existsSync()) return;
      final published = <String>{};
      for (final faction in [
        'genestealer-cults',
        'drukhari',
        'aeldari',
        'agents-of-the-imperium',
        'chaos-daemons',
      ]) {
        for (final unit in loader.loadFaction(faction).units) {
          // Faction keywords and plain ones alike: `Anhrathe` is published as
          // a plain keyword on units whose faction keyword is `Asuryani`.
          for (final keyword in [...unit.factionKeywords, ...unit.keywords]) {
            published.add(foldKeyword(keyword));
          }
        }
      }
      for (final rule in AllyRules.all) {
        for (final granted in rule.grantedKeywords) {
          expect(published, contains(granted),
              reason: '${rule.name} admits "$granted", which no datasheet has');
        }
      }
    }, skip: skip);

    test('the detachment a rule names exists', () {
      if (!root.existsSync()) return;
      for (final rule in AllyRules.all) {
        if (rule.requiresDetachmentId case final id?) {
          final faction = loader.loadFaction('genestealer-cults');
          expect(faction.detachments.map((d) => d.id), contains(id),
              reason: '${rule.name} names a detachment that is gone');
        }
      }
    }, skip: skip);
  });

  group('telling an ally from an army s own datasheet', () {
    test('a curly apostrophe does not make a faction its own ally', () {
      if (!root.existsSync()) return;
      // factions.json writes `T’au Empire` and 66 of its own datasheets write
      // `T'au Empire`. Compared raw, the whole faction reads as allied.
      final tau = loader.loadFaction('tau-empire');
      final krootox =
          tau.units.firstWhere((u) => u.name.startsWith('Krootox Rampagers'));

      expect(krootox.factionKeywords.first, contains("'"));
      expect(tau.factionKeywords.first, contains('’'));
      expect(AllyRules.isAlly(krootox, tau.factionKeywords), isFalse);
    }, skip: skip);

    test('a chapter is not an ally of its own Chapter Approved parent', () {
      if (!root.existsSync()) return;
      final astartes = loader.loadFaction('adeptus-astartes');
      final wolves = astartes.units.firstWhere(
          (u) => u.factionKeywords.any((k) => k.contains('Space Wolves')));

      expect(wolves.factionKeywords, contains('Adeptus Astartes'));
      expect(AllyRules.isAlly(wolves, astartes.factionKeywords), isFalse);
    }, skip: skip);

    test('Astra Militarum in a Cult bundle is an ally', () {
      if (!root.existsSync()) return;
      final cult = loader.loadFaction('genestealer-cults');
      final guard = cult.units.firstWhere(
          (u) => u.factionKeywords.contains('Astra Militarum'));

      expect(AllyRules.isAlly(guard, cult.factionKeywords), isTrue);
      expect(AllyRules.admitting(guard, cult.factionKeywords)?.abilityId,
          'brood-brothers');
    }, skip: skip);
  });

  group('what the validator says about them', () {
    late Catalogue cult;
    late RosterEditor editor;

    setUpAll(() {
      if (!root.existsSync()) return;
      cult = MapCatalogue.ofFaction(loader.loadFaction('genestealer-cults'));
      editor = RosterEditor(cult);
    });

    Roster withGuard({String? detachmentId}) {
      var roster = RosterEditor.blank(
          name: 'p', factionId: 'genestealer-cults');
      if (detachmentId != null) {
        roster = editor.addDetachment(roster, detachmentId);
      }
      final guard = cult.allUnits.firstWhere((u) =>
          u.factionKeywords.contains('Astra Militarum') &&
          !u.keywords.any((k) => k.toLowerCase() == 'aircraft') &&
          !u.keywords.any((k) => k.toLowerCase() == 'epic hero'));
      return editor.addUnit(roster, guard.id);
    }

    test('an ally with no detachment to admit it is reported', () {
      if (!root.existsSync()) return;
      final findings = RosterValidator(cult).validate(withGuard());

      expect(findings.errors.map((f) => f.code),
          contains('ally.detachment-missing'));
    }, skip: skip);

    test('and is not reported once the detachment is taken', () {
      if (!root.existsSync()) return;
      final findings = RosterValidator(cult)
          .validate(withGuard(detachmentId: 'brood-brothers-auxilia'));

      expect(findings.errors.map((f) => f.code),
          isNot(contains('ally.detachment-missing')));
      expect(
          findings.errors.map((f) => f.code), isNot(contains('ally.not-permitted')));
    }, skip: skip);

    test('an excluded keyword is reported by name', () {
      if (!root.existsSync()) return;
      var roster = editor.addDetachment(
        RosterEditor.blank(name: 'p', factionId: 'genestealer-cults'),
        'brood-brothers-auxilia',
      );
      // 40kdc already filters most of the exclusion list out of the bundle —
      // no AIRCRAFT, COMMISSAR, EPIC HERO or RATLING Astra Militarum sheet is
      // shipped with the Cult. One OGRYN is, which is why the check earns its
      // place rather than duplicating what upstream already did.
      final ogryn = cult.allUnits.firstWhere((u) =>
          u.factionKeywords.contains('Astra Militarum') &&
          u.keywords.any((k) => k.toLowerCase() == 'ogryn'));
      roster = editor.addUnit(roster, ogryn.id);

      final findings = RosterValidator(cult).validate(roster);
      expect(findings.errors.map((f) => f.code),
          contains('ally.excluded-keyword'));
    }, skip: skip);

    test('an allied Warlord is reported where the rule wants one of yours',
        () {
      if (!root.existsSync()) return;
      // setWarlord refuses a non-Character, so the ally has to be one for the
      // check to have anything to report.
      var roster = editor.addDetachment(
        RosterEditor.blank(name: 'p', factionId: 'genestealer-cults'),
        'brood-brothers-auxilia',
      );
      final character = cult.allUnits.firstWhere((u) =>
          u.factionKeywords.contains('Astra Militarum') && u.isCharacter);
      roster = editor.addUnit(roster, character.id);
      roster = editor.setWarlord(roster, roster.units.single.instanceId);

      final findings = RosterValidator(cult).validate(roster);
      expect(findings.errors.map((f) => f.code), contains('ally.warlord'));
    }, skip: skip);

    test('the army own datasheets say nothing at all', () {
      if (!root.existsSync()) return;
      final own = cult.allUnits.firstWhere(
          (u) => u.factionKeywords.contains('Genestealer Cults'));
      final roster = editor.addUnit(
        RosterEditor.blank(name: 'p', factionId: 'genestealer-cults'),
        own.id,
      );

      final codes = RosterValidator(cult).validate(roster).findings.map(
            (f) => f.code,
          );
      expect(codes.where((c) => c.startsWith('ally.')), isEmpty);
    }, skip: skip);

    test('a catalogue that does not know its faction stays quiet', () {
      if (!root.existsSync()) return;
      // A snapshot written before §4.18 carries no faction keywords, and
      // guessing from an empty set would make every datasheet an ally.
      final blind = MapCatalogue(
        cult.allUnits,
        detachments: cult.allDetachments,
        compositions: [
          for (final u in cult.allUnits)
            if (cult.composition(u.id) case final c?) c,
        ],
      );
      final roster = RosterEditor(blind).addUnit(
        RosterEditor.blank(name: 'p', factionId: 'genestealer-cults'),
        cult.allUnits
            .firstWhere((u) => u.factionKeywords.contains('Astra Militarum'))
            .id,
      );

      final codes =
          RosterValidator(blind).validate(roster).findings.map((f) => f.code);
      expect(codes.where((c) => c.startsWith('ally.')), isEmpty);
    }, skip: skip);
  });
}
