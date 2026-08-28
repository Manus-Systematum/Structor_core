/// Everything the army carries, in one searchable list (DESIGN.md §7.3.8).
///
/// The reference page is what you open when the inline row is not enough — so
/// its job is *recall*, not filtering: one query across detachment rules, unit
/// abilities, enhancements and stratagems, because mid-game you remember a
/// word and not which of those four it lives in.
///
/// It does not carry a core-rules crib of its own. Weapon keywords are read
/// where they are used — on the weapon table, by tapping the chip — rather
/// than in a glossary here, and their text comes from BSData (§3.14) rather
/// than from anything written for this app.
///
/// Superseded, 2026-08-24: this said the app carried no keyword text at all,
/// because `weapon-keywords.json` gives names and nothing else and writing the
/// summaries would mean reproducing rules from memory. The second half is
/// still true and is why nothing here is written; what changed is that a
/// source already shipped from turned out to publish them.
library;

import '../roster/roster.dart';
import '../rules/catalogue.dart';
import 'rules_renderer.dart';
import 'stratagem_book.dart';

enum ReferenceKind { detachmentRule, unitAbility, enhancement, stratagem }

class ReferenceEntry {
  final ReferenceKind kind;
  final String id;
  final String title;

  /// Where it comes from — a datasheet, a detachment, `Core`.
  final String source;

  /// Rendered rules text, or empty when the data carries no effect.
  final String body;

  /// Cost, restrictions, phases — whatever is worth a second line.
  final String detail;

  /// True when this army actually took it, as opposed to merely being offered
  /// it by a detachment.
  final bool inPlay;

  const ReferenceEntry({
    required this.kind,
    required this.id,
    required this.title,
    required this.source,
    this.body = '',
    this.detail = '',
    this.inPlay = true,
  });

  String get _haystack => '$title\n$source\n$body\n$detail'.toLowerCase();

  bool matches(String query) {
    final needle = query.trim().toLowerCase();
    if (needle.isEmpty) return true;
    // Every word, anywhere — "fire cadre" should find Cadre Fireblade without
    // the player guessing the word order.
    return needle.split(RegExp(r'\s+')).every(_haystack.contains);
  }
}

class ReferenceIndex {
  final List<ReferenceEntry> entries;

  const ReferenceIndex(this.entries);

  /// Builds the index for one army.
  factory ReferenceIndex.forRoster(
    Roster roster, {
    required Catalogue catalogue,
    StratagemBook book = const StratagemBook(stratagems: []),
  }) {
    const renderer = RulesRenderer();
    final entries = <ReferenceEntry>[];

    String render(String? abilityId) {
      if (abilityId == null) return '';
      final ability = catalogue.ability(abilityId);
      return ability == null ? '' : renderer.render(ability).text;
    }

    for (final taken in roster.detachments) {
      final detachment = catalogue.detachment(taken.detachmentId);
      if (detachment == null) continue;
      final ruleId = detachment.detachmentRuleId;
      final ability = ruleId == null ? null : catalogue.ability(ruleId);
      entries.add(ReferenceEntry(
        kind: ReferenceKind.detachmentRule,
        id: ruleId ?? detachment.id,
        title: ability?.name ?? detachment.name,
        source: detachment.name,
        body: render(ruleId),
        detail: '${detachment.detachmentPoints} DP',
      ));
    }

    // Enhancements the detachments offer, flagged with whether this army took
    // one. "What could I have taken" gets asked as often as "what did I take".
    final bought = {for (final e in roster.enhancements) e.enhancementId};
    final upgraded = {for (final u in roster.upgrades) u.upgradeId};
    for (final enhancement in catalogue.enhancements) {
      final detachmentId = enhancement.detachmentId;
      if (detachmentId != null &&
          !roster.detachments.any((d) => d.detachmentId == detachmentId)) {
        continue;
      }
      final detail = [
        '${enhancement.cost} pts',
        if (enhancement.isUpgrade) 'Unit Upgrade' else 'Enhancement',
        if (enhancement.restrictionSummary.isNotEmpty)
          enhancement.restrictionSummary,
      ].join(' · ');
      entries.add(ReferenceEntry(
        kind: ReferenceKind.enhancement,
        id: enhancement.id,
        title: enhancement.name,
        source: detachmentId == null
            ? 'Faction'
            : catalogue.detachment(detachmentId)?.name ?? detachmentId,
        body: render(enhancement.abilityId),
        detail: detail,
        inPlay: bought.contains(enhancement.id) ||
            upgraded.contains(enhancement.id),
      ));
    }

    // One entry per ability, naming every datasheet that has it. Five
    // identical Gun Drone rows — one per battlesuit that took one — is five
    // times the scrolling for the same sentence.
    final abilityOrder = <String>[];
    final abilityOwners = <String, List<String>>{};
    for (final rosterUnit in roster.units) {
      final datasheet = catalogue.unit(rosterUnit.datasheetId);
      if (datasheet == null) continue;
      for (final abilityId in datasheet.ruleVocabulary) {
        final owners = abilityOwners.putIfAbsent(abilityId, () {
          abilityOrder.add(abilityId);
          return <String>[];
        });
        if (!owners.contains(datasheet.name)) owners.add(datasheet.name);
      }
    }
    for (final abilityId in abilityOrder) {
      final ability = catalogue.ability(abilityId);
      if (ability == null) continue;
      final rendered =
          renderer.render(ability, published: catalogue.phasesFor(abilityId));
      final owners = abilityOwners[abilityId]!;
      entries.add(ReferenceEntry(
        kind: ReferenceKind.unitAbility,
        id: abilityId,
        title: ability.name,
        // Named in full: on the reference page the question is usually "who
        // has this", and a count would not answer it.
        source: owners.join(', '),
        body: rendered.text,
        detail: rendered.phases.isEmpty
            ? ''
            : rendered.phases.map((p) => '$p phase').join(' · '),
      ));
    }

    for (final stratagem in book.stratagems) {
      final detachmentId = stratagem.detachmentId;
      entries.add(ReferenceEntry(
        kind: ReferenceKind.stratagem,
        id: stratagem.id,
        title: stratagem.name,
        source: detachmentId == null
            ? 'Core'
            : catalogue.detachment(detachmentId)?.name ?? detachmentId,
        body: render(stratagem.abilityId),
        detail: [
          '${stratagem.cpCost} CP',
          if (stratagem.type case final type?) type.replaceAll('-', ' '),
          if (stratagem.phases.isNotEmpty) stratagem.phases.join(' · '),
        ].join(' · '),
      ));
    }

    return ReferenceIndex(entries);
  }

  List<ReferenceEntry> of(ReferenceKind kind) => [
        for (final e in entries)
          if (e.kind == kind) e
      ];

  /// Every entry matching [query], in the index's own order so sections stay
  /// coherent while the list narrows.
  List<ReferenceEntry> search(String query) => [
        for (final e in entries)
          if (e.matches(query)) e
      ];

  bool get isEmpty => entries.isEmpty;
}
