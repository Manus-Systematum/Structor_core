/// Renders structured ability effects into short English (DESIGN.md §7.3.6).
///
/// Required infrastructure rather than a nicety: abilities in the source data
/// carry structured effects and **no prose at all** — 0 of 129 T'au abilities
/// have a text field. Without this the play screen can name a rule but not say
/// what it does.
///
/// Two properties follow from generating the text rather than transcribing it.
/// The output is **ours**, which sidesteps the copyright constraint of §0
/// entirely; and it is terse and uniform in a way printed rules never are,
/// which matters on a phone held in one hand mid-game.
///
/// Where a shape is not recognised the renderer **says so** (§7.6). A rules aid
/// that quietly invents a sentence is worse than one that admits a gap.
library;

import '../source/json.dart';
import '../source/source_models.dart';

class RenderedRule {
  final String abilityId;
  final String name;

  /// What a player reads: the rule as printed where the source has it,
  /// otherwise the sentence derived from the structured effect.
  final String text;

  /// The sentence derived from the structured effect, always.
  ///
  /// Kept beside [text] rather than replaced by it. Nothing on a screen shows
  /// this — the printed rule is better writing than any paraphrase of ours —
  /// but it is how the structured data can still be inspected, and how §3.6's
  /// corrections stay checkable now that they no longer change what is
  /// displayed. A correction fixes what the app *does*; the printed text
  /// fixes what it *says*, and the two are tested separately (§3.10).
  final String derived;

  /// Whether [text] is the printed rule rather than [derived].
  final bool isPrinted;

  /// Phases mentioned by `phase-is` conditions, so the card can surface itself
  /// in the right section of the turn page.
  final List<String> phases;

  /// Effect or condition types encountered but not understood. Non-empty means
  /// [text] contains a visible placeholder rather than a silent omission.
  final List<String> unrendered;

  const RenderedRule({
    required this.abilityId,
    required this.name,
    required this.text,
    required this.phases,
    required this.unrendered,
    String? derived,
    this.isPrinted = false,
  }) : derived = derived ?? text;

  bool get isComplete => unrendered.isEmpty;

  /// Whether the description repeats the name and nothing else.
  ///
  /// 166 of 7,484 abilities render as *Deep Strike: Deep Strike* or
  /// *Leader: grants Leader*. The effect record is honest — DEEP STRIKE is a
  /// core keyword whose meaning lives in the rulebook, and there is nothing
  /// for the renderer to say — but printed as a name and a description it
  /// reads as a rule the app failed to explain, and it costs two lines
  /// apiece on a screen read mid-game.
  ///
  /// These are **keywords, and should be shown as keywords**: the name alone,
  /// in a row of chips. Detected rather than listed, because a hand-kept list
  /// of core keywords would go stale the first time upstream adds one.
  bool get isBareKeyword {
    // Printed wording is never a bare keyword: whatever the structure says,
    // the rule has a sentence of its own to show.
    if (isPrinted) return false;
    if (text.isEmpty || text == '—') return true;
    final body = _plain(text);
    return body == _plain(name) || body == 'grants ${_plain(name)}';
  }

  static String _plain(String value) => value
      .toLowerCase()
      .replaceAll(RegExp(r'[^a-z0-9 ]'), ' ')
      .replaceAll(RegExp(r'\s+'), ' ')
      .trim();

  @override
  String toString() => '$name — $text';
}

class RulesRenderer {
  const RulesRenderer();

  /// Grant targets that are bookkeeping rather than rules.
  ///
  /// Curated rather than derived, because upstream marks them no differently
  /// from a real rule name — both are just ids that no ability record
  /// defines. Kept short on purpose: these seven are 332 of the 561 dangling
  /// grants, and anything not on the list still renders its name, which is
  /// the safer failure. Worth deleting an entry the moment upstream publishes
  /// a record for it.
  static const _markers = {
    'special-embark-rule',
    'once-per-battle-special',
    'once-per-round-special',
    'attached-unit-eligibility',
    'faction-metadata',
    'target-in-engagement',
    'post-attack-debuff',
  };

  /// [published] are the phases `phase-mappings.json` files this ability
  /// under, which are **not** derivable from the effect.
  ///
  /// **The structure only names a phase when the effect is about one.**
  /// `Righteous Repugnance` is a bare `stat-modifier` — add 3 Attacks — so
  /// walking it yields no phase at all, and the turn page files rules by
  /// `phases.contains(phase)`. The rule never appeared in the Shooting or
  /// Fight section of a list that has Morvenn Vahl in it, and 5,222 of the
  /// 8,533 published mappings were in the same position: read into
  /// `FactionData.phaseMappings` and then read by nothing.
  RenderedRule render(SourceAbility ability,
      {Iterable<String> published = const []}) {
    final ctx = _Ctx();
    var text = _effect(ability.effect, ctx);

    final frequency = str(ability.usage['frequency']);
    if (frequency != null) text = '$text (${_frequency(ability.usage)})';

    // **Printed text is what a player reads.**
    //
    // The renderer exists because 40kdc publishes structure and no wording:
    // it says what an effect means in English so a screen has something to
    // show. Where BSData supplies the rule as printed, that sentence is the
    // one in the player's codex, and no paraphrase of ours improves on it —
    // "Shooting phase: grants a shoot while hidden" against the rule itself.
    //
    // **The structure does not go away, it stops being the display.** Phases
    // still come from walking the effect, and everything that reads an effect
    // rather than a sentence — the invulnerable save on the statline, scout
    // distance, §3.6's corrections — is untouched. A correction fixes what the
    // app *does*; the printed text fixes what it *says*.
    final derived = text.isEmpty ? '—' : _sentence(text);
    final printed = ability.description?.trim();

    return RenderedRule(
      abilityId: ability.abilityId,
      name: ability.name,
      text: printed != null && printed.isNotEmpty ? printed : derived,
      derived: derived,
      isPrinted: printed != null && printed.isNotEmpty,
      // Union, not replacement. The derived phase is the more specific
      // statement where the effect has one — `Shooting phase: …` — and the
      // published mapping covers the rules whose effect names none.
      phases: {...ctx.phases, ...published}.toList(),
      unrendered: ctx.unrendered.toList(),
    );
  }

  /// How often a rule may be used, with the count substituted.
  ///
  /// `n-per-battle` carries its number alongside as `count`; rendering the
  /// frequency alone printed the placeholder, so the Ghostkeel's Stealth
  /// Drones read "(n per battle)" on a rule usable twice.
  String _frequency(Map<String, dynamic> usage) {
    final frequency = strOr(usage['frequency'], '');
    final count = str(usage['count']);
    if (count == null) return _words(frequency);
    return _words(frequency.replaceAll(RegExp(r'\bn\b'), count));
  }

  // ---------------------------------------------------------------- effects

  String _effect(Map<String, dynamic> node, _Ctx ctx) {
    if (node.isEmpty) return '';
    final type = strOr(node['type'], '');
    final mod = asMap(node['modifier']);

    switch (type) {
      case 'sequence':
        final steps = asList(node['steps'])
            .map((s) => _effect(asMap(s), ctx))
            .where((s) => s.isNotEmpty)
            .toList();
        return steps.join('; ');

      case 'conditional':
        final condition = _condition(asMap(node['condition']), ctx);
        final inner = _effect(asMap(node['effect']), ctx);
        // A condition on nothing is nothing. Holy Vanguard's whole effect is
        // a grant of an unpublished marker, and left to itself the condition
        // rendered as "While leading a unit: ." — a sentence promising a rule
        // and then not giving one, which is worse than saying nothing.
        if (inner.isEmpty) return '';
        return condition.isEmpty ? inner : '$condition: $inner';

      case 'dice-gated':
        final dice = strOr(node['dice'], 'D6');
        final threshold = str(node['threshold']) ?? '?';
        final comparison =
            strOr(node['comparison'], 'gte') == 'gte' ? '+' : '';
        final success = _effect(asMap(node['on_success']), ctx);
        final fail = _effect(asMap(node['on_fail']), ctx);
        final tail = fail.isEmpty ? '' : ', otherwise $fail';
        return 'on a $dice of $threshold$comparison, $success$tail';

      case 'stat-modifier':
        final stat = _statName(strOr(mod['stat'], '?'));
        final qualifier =
            str(mod['weapon_type']) ?? str(mod['attack_type']);
        final scope = qualifier == null ? '' : ' (${_words(qualifier)})';
        // Whose characteristic changes is the whole meaning of an ability
        // like Enforcer Commander, where the AP being worsened is the
        // *attacker's*. Rendering it ownerless reads as a buff.
        final owner = switch (strOr(node['target'], '')) {
          'attacker' => "attacker's ",
          'defender' => "target's ",
          _ => '',
        };
        return '$owner${_statChange(stat, mod, ctx)}$scope';

      case 'aura':
        final range = str(mod['range']) ?? '?';
        final eligible = _eligibility(asMap(mod['eligible']));
        final inner = _effect(asMap(mod['effect']), ctx);
        return 'aura $range": $eligible$inner';

      case 'choice':
        final label = str(node['choice_label']);
        final options = asList(node['options'])
            .map((o) => _effect(asMap(o), ctx))
            .where((s) => s.isNotEmpty)
            .toList();
        final body = options.join(', or ');
        return label == null ? 'choose: $body' : '${_words(label)} — $body';

      case 'select-units':
        final selector = asMap(node['selector']);
        final count = str(selector['count']) ?? '1';
        final owner = _words(strOr(selector['owner'], 'friendly'));
        final keywords = strList(selector['keywords']).map(_keyword).join(' ');
        final within = str(selector['within_inches']);
        final range = within == null ? '' : ' within $within"';
        final inner = _effect(asMap(node['effect']), ctx);
        return 'select $count $owner $keywords unit(s)$range: $inner';

      case 'stance-select':
        final when = _words(strOr(node['select'], 'start of battle round'));
        final names = asList(node['options'])
            .map((o) => str(asMap(o)['name']))
            .whereType<String>()
            .toList();
        return 'at $when, select one: ${names.join(' / ')}';

      case 'rule-state':
        final rule = _words(strOr(mod['rule'], 'that rule'));
        return strOr(mod['direction'], '') == 'suppressed'
            ? 'cannot $rule'
            : 'can $rule';

      case 'resurrection':
        final frequency = str(mod['type']);
        final qualifier = frequency == null ? '' : ' (${_words(frequency)})';
        return 'returns destroyed models$qualifier';

      case 'unit-attachment':
        return 'may be led by ${_keyword(strOr(mod['led_by'], 'a character'))}';

      case 'fight-first':
        return 'Fights First';

      case 'fight-on-death':
        return 'may fight after being destroyed';

      case 'shoot-on-death':
        return 'may shoot after being destroyed';

      case 'roll-modifier':
        final roll = _rollName(strOr(mod['roll'], 'all'));
        final context = str(mod['context']);
        final when = context == null ? '' : ' (${_words(context)})';
        return switch (strOr(mod['operation'], 'add')) {
          'ignore-modifiers' => 'ignore modifiers to $roll rolls',
          'ignore-engagement-penalty' =>
            'ignore the Engagement Range penalty to $roll rolls',
          // A fixed roll, not a bonus: Sentinel Protocols hits on 5+ in
          // Overwatch regardless of BS.
          'set' => '$roll on ${str(mod['value']) ?? '?'}+$when',
          'crit-on' =>
            'critical $roll on ${str(mod['value']) ?? '?'}+$when',
          'add' || 'subtract' => '${_signed(mod)} to $roll$when',
          final other => _unknownOperation(other, '$roll rolls', mod, ctx),
        };

      case 'bs-modifier':
        return '${_signed(mod)} to Hit';

      case 'charge-roll-modifier':
        return '${_signed(mod)} to Charge rolls';

      case 're-roll':
        final roll = _rollName(strOr(mod['roll'], 'hit'));
        // The adjective belongs before the roll name: "failed Hit rolls", not
        // "Hit failed rolls".
        return switch (strOr(mod['subset'], 'all-failures')) {
          'ones' => 're-roll $roll rolls of 1',
          'all-failures' => 're-roll failed $roll rolls',
          'all' => 're-roll $roll rolls',
          final other => 're-roll ${_words(other)} $roll rolls',
        };

      case 'keyword-grant':
        final keywords = strList(mod['keywords']).map(_keyword).join(', ');
        return 'gains $keywords';

      // A keyword on the weapons rather than on the unit. "Gains ASSAULT"
      // would say the models have it, which is a different rule.
      case 'weapon-keyword-grant':
        final keywords = strList(mod['keywords']).map(_keyword).join(', ');
        final weaponType = str(mod['weapon_type']);
        final which =
            weaponType == null ? 'weapons' : '${_words(weaponType)} weapons';
        return '$which gain $keywords';

      case 'unit-keyword':
        return 'gains ${_keyword(strOr(mod['keyword_id'], '?'))}';

      case 'ability-grant':
        // `ability_id` was not read, so the Immolator's Purge and Cleanse —
        // which names `benefit-of-cover` outright — rendered as "grants a
        // bonus". §3.0 calls this shape lossy, and it is, but only where the
        // record genuinely says nothing: where it names the rule, saying
        // which rule costs nothing and is the whole of the answer.
        final ability = str(mod['ability']) ?? str(mod['ability_id']);
        if (ability != null) {
          // A marker, not a rule. 561 of 640 grant targets are ids upstream
          // never publishes, and they fall into two kinds: names that mean
          // something to a player — `benefit-of-cover` appears 99 times — and
          // internal bookkeeping like `special-embark-rule`, which rendered
          // as "grants special embark rule" and told nobody anything. There
          // is no flag distinguishing them, so the bookkeeping ones are
          // listed; the list is short because they are few and heavily
          // repeated, covering 332 of the 561.
          if (_markers.contains(ability)) return '';
          return 'grants ${_words(ability)}';
        }
        // `weapon_id` is the shape a drone uses (§7.3.7); `weapon` is the
        // older free-text one. Either names the gun, which is the point.
        final weapon = str(mod['weapon']) ?? str(mod['weapon_id']);
        if (weapon != null) return 'grants a ${_words(weapon)}';
        return 'grants a ${_words(strOr(mod['grant_type'], 'bonus'))}';

      // ------------------------------------------------- resource pools
      //
      // The Sisters of Battle mechanic, and the reason these were noticed:
      // Miracle dice are the faction's whole identity, and every rule that
      // touches the pool rendered as a bare `[type]`.

      case 'resource-gain':
        final amount = str(mod['amount']) ?? '1';
        return 'gain $amount ${_pool(mod['pool_id'])}';

      case 'pool-add-die':
        final value = str(mod['value']);
        return value == null
            ? 'add a die to the ${_pool(mod['pool_id'])} pool'
            : 'add a $value to the ${_pool(mod['pool_id'])} pool';

      case 'replace-roll-from-pool':
        final rolls = strList(mod['rolls']);
        final which = rolls.isEmpty
            ? 'a roll'
            : 'a ${_list(rolls.map(_words).toList())} roll';
        return 'replace $which with a ${_pool(mod['pool_id'])}';

      case 'stratagem-cost-modifier':
        final operation = strOr(mod['operation'], 'increase');
        final amount = str(mod['amount']) ?? '1';
        final sign = operation == 'reduce' || operation == 'decrease'
            ? '-'
            : '+';
        final scope = str(mod['applies_to']);
        final what = scope == null ? 'Stratagems' : _words(scope);
        return '$sign${amount}CP to $what';

      case 'modifier-immunity':
        final scope = str(mod['scope']);
        return scope == null
            ? 'ignores modifiers'
            : 'ignores modifiers to ${_words(scope)}';

      case 'movement-modifier':
        final distance = str(mod['distance']);
        final moveType = _words(strOr(mod['move_type'], 'move'));
        return distance == null ? moveType : '$moveType $distance"';

      case 'mortal-wounds':
        final count = strOr(mod['count'], '1').toUpperCase();
        final range = str(mod['range']);
        final within = range == null ? '' : ' to units within $range"';
        return '$count mortal wounds$within';

      case 'invulnerable-save':
        return '${str(mod['invuln_sv']) ?? '?'}+ invulnerable save';

      case 'feel-no-pain':
        return 'Feel No Pain ${str(mod['threshold']) ?? '?'}+';

      case 'damage-reduction':
        return strOr(mod['reduction'], '') == 'to-zero'
            ? 'damage reduced to 0'
            : 'damage reduced by ${str(mod['reduction']) ?? '?'}';

      case 'cp-gain':
        return 'gain ${str(mod['amount']) ?? '1'}CP';

      case 'cp-refund':
        return strOr(mod['type'], '') == 'stratagem-for-0cp'
            ? 'use that Stratagem for 0CP'
            : 'refunds CP';

      case 'fallback-and-act':
        return 'may act normally after Falling Back';

      case 'deep-strike':
        return 'Deep Strike';

      case 'cover-benefit':
        return 'has the Benefit of Cover';

      case 'objective-control-modifier':
        if (mod['sticky'] == true) {
          return 'objectives remain controlled after leaving';
        }
        if (mod['operation'] == null) return 'modifies objective control';
        return _statChange('OC', mod, ctx);

      case 'leadership-modifier':
        final test = _words(strOr(mod['test'], 'Leadership'));
        return 'must take a $test test';

      case 'attack-restriction':
        return _words(strOr(mod['restriction'], 'restricted'));

      case 'targeting-permission':
        final attack = _words(strOr(mod['attack_type'], ''));
        final range = str(mod['range']);
        return range == null
            ? 'restricts $attack targeting'
            : 'may only be targeted by $attack attacks within $range"';

      case 'disembark-after-move':
        final after = _words(strOr(mod['after'], 'moving'));
        final charge =
            mod['can_charge'] == true ? ' and may charge' : ' but may not charge';
        return 'may disembark after $after$charge';

      case 'resource-spend':
        return 'spends ${_words(strOr(mod['resource'], 'a resource'))}';

      case 'designate-target':
        final designation = _keyword(strOr(node['designation'], 'marked'));
        final select = asMap(node['select']);
        final count = str(select['count']) ?? '1';
        final scope = _words(strOr(select['scope'], 'unit'));
        final applies = _effect(asMap(asMap(node['applies'])['effect']), ctx);
        final duration = str(node['duration']);
        // Durations are written both ways upstream — `end-of-turn` and
        // `until-next-command-phase` — so the connective has to come from the
        // value rather than be pasted in front of it.
        final until = duration == null ? '' : ' ${_until(duration)}';
        final result = applies.isEmpty ? '' : ' — that unit suffers $applies';
        return 'designate $count $scope as $designation$result$until';

      case '':
        return '';

      default:
        ctx.unrendered.add(type);
        return '[$type]';
    }
  }

  // ------------------------------------------------------------- conditions

  String _condition(Map<String, dynamic> node, _Ctx ctx) {
    if (node.isEmpty) return '';

    final operator = str(node['operator']);
    if (operator != null) {
      final parts = asList(node['operands'])
          .map((o) => _condition(asMap(o), ctx))
          .where((s) => s.isNotEmpty)
          .toList();
      if (parts.isEmpty) return '';
      if (operator != 'and') return parts.join(' or ');

      final buffer = StringBuffer(parts.first);
      for (final part in parts.skip(1)) {
        // "Shooting phase and except vs VEHICLE" is worse English than
        // "Shooting phase, except vs VEHICLE" for the same condition.
        buffer.write(part.startsWith('except ') ? ', ' : ' and ');
        buffer.write(part);
      }
      return buffer.toString();
    }

    final type = strOr(node['type'], '');
    final params = asMap(node['parameters']);
    final negated = node['negated'] == true;

    final rendered = switch (type) {
      'phase-is' => _phase(strOr(params['phase'], ''), ctx),
      'player-turn-is' => strOr(params['turn'], '') == 'opponent'
          ? "opponent's turn"
          : 'your turn',
      'timing-is' => _words(strOr(params['timing'], '')),
      'target-has-keyword' => _targetKeyword(params),
      'unit-has-keyword' =>
        'while ${_keyword(strOr(params['keyword'], '?'))}',
      'attack-is-type' =>
        '${_words(strOr(params['attack_type'], ''))} attacks',
      'battle-round' => _battleRound(params),
      'unit-within-range-of' =>
        'within ${str(params['range']) ?? '?'}" of a '
            '${_words(strOr(params['target_type'], 'unit'))}',
      'opponent-unit-within-range' =>
        'against the ${_words(strOr(params['target_qualifier'], 'nearest enemy'))}',
      'was-hit-by-attack' =>
        'after being hit by ${_words(strOr(params['attack_type'], ''))} attacks',
      'unit-below-starting-strength' => negated
          ? '${_words(strOr(params['subject'], 'unit'))} at full strength'
          : '${_words(strOr(params['subject'], 'unit'))} below starting strength',

      'attack-stat-compare' =>
        '${_statName(strOr(params['attacker_stat'], '?'))} '
            '${_words(strOr(params['comparison'], 'vs'))} '
            '${_statName(strOr(params['target_stat'], '?'))}',
      'destroyed-by-attack-type' =>
        'destroyed by ${_words(strOr(params['attack_type'], ''))} attacks',
      'model-is-leader' =>
        'while led by ${_keyword(strOr(params['leader_type'], 'a character'))}',
      'terrain-area-control' =>
        'controlling ${_words(strOr(params['area'], 'the terrain area'))}',
      'units-destroyed' => 'if ${str(params['count_min']) ?? '1'}+ '
          '${_words(strOr(params['side'], 'enemy'))} unit(s) were destroyed '
          '${_words(strOr(params['window'], 'this phase'))}',

      // Parameterless conditions: the type name carries the whole meaning.
      'is-attached' => 'while leading a unit',
      'remained-stationary' => 'if it Remained Stationary',
      'unit-below-half-strength' => 'below half strength',
      'charged-this-turn' => 'if it charged this turn',
      'advanced-this-turn' => 'if it Advanced',
      'is-battle-shocked' => 'while Battle-shocked',
      'engagement-state' => 'while in Engagement Range',
      'has-lost-wounds' => 'if it has lost wounds',
      'controls-objective' => 'while controlling an objective',
      'within-range-of-objective' => 'within range of an objective',
      'disembarked-from-transport' => 'after disembarking',
      'damage-is-mortal' => 'against mortal wounds',

      _ => null,
    };

    if (rendered == null) {
      ctx.unrendered.add('condition:$type');
      return '[$type]';
    }

    // `unit-below-starting-strength` folds negation into its own wording; every
    // other condition negates uniformly.
    if (negated && type != 'unit-below-starting-strength') {
      return 'unless $rendered';
    }
    return rendered;
  }

  /// Which targets a rule applies to.
  ///
  /// Carved out rather than exclusions, when that is how the rule reads:
  /// Starscythe improves AP against everything *except* VEHICLE and MONSTER,
  /// and spelling that as two negated conditions joined by "and" is unreadable
  /// at the table.
  String _targetKeyword(Map<String, dynamic> params) {
    final excluded = strList(params['excluded_keywords']).map(_keyword);
    if (excluded.isNotEmpty) return 'except vs ${excluded.join(' or ')}';

    final single = str(params['keyword']);
    final required = [
      ...strList(params['keywords']),
      if (single != null) single,
    ].map(_keyword);
    return required.isEmpty ? 'vs ?' : 'vs ${required.join(' or ')}';
  }

  /// `{required_keywords: [NECRONS], excluded_keywords: [MONSTER]}` becomes
  /// `NECRONS (not MONSTER) `, ready to prefix an aura's effect.
  String _eligibility(Map<String, dynamic> eligible) {
    if (eligible.isEmpty) return '';
    final required = strList(eligible['required_keywords']).map(_keyword);
    final excluded = strList(eligible['excluded_keywords']).map(_keyword);
    final parts = <String>[
      if (required.isNotEmpty) required.join(' '),
      if (excluded.isNotEmpty) '(not ${excluded.join(' ')})',
    ];
    return parts.isEmpty ? '' : '${parts.join(' ')} — ';
  }

  /// A duration phrase that reads once, however the value is spelled.
  String _until(String duration) {
    final words = _words(duration);
    return words.startsWith('until ') ? words : 'until $words';
  }

  String _battleRound(Map<String, dynamic> params) {
    final min = str(params['min']);
    final max = str(params['max']);
    if (min != null && max != null) return 'battle rounds $min-$max';
    if (min != null) return 'from battle round $min';
    if (max != null) return 'until battle round $max';
    return 'battle round';
  }

  String _phase(String phase, _Ctx ctx) {
    if (phase.isEmpty) return '';
    ctx.phases.add(phase);
    return '${_capitalise(phase)} phase';
  }

  // ---------------------------------------------------------------- helpers

  /// A characteristic change written the way the operation actually behaves.
  ///
  /// The data uses twelve operations, not two. Collapsing them into `+N`/`-N`
  /// is how the Coldstar Commander's *Move set to 12* became `+12 Move` — a
  /// buff of half again on a suit that already moves 12 — and how thirteen
  /// `{operation: add, value: -1}` AP improvements read as penalties.
  String _statChange(String stat, Map<String, dynamic> mod, _Ctx ctx) {
    final value = asInt(mod['value']);
    final magnitude = (value ?? 1).abs();
    return switch (strOr(mod['operation'], 'add')) {
      'add' || 'subtract' => '${_signed(mod)} $stat',
      'set' => '$stat set to ${value ?? '?'}',
      'improve' => '$stat improved by $magnitude',
      'worsen' => '$stat worsened by $magnitude',
      'multiply' => '$stat ×$magnitude',
      'halve' => '$stat halved',
      'improve-vs-D1' =>
        '$stat improved by $magnitude against Damage 1 attacks',
      'set-on-crit-wound' =>
        'on a Critical Wound, $stat set to ${value ?? '?'}',
      final other => _unknownOperation(other, stat, mod, ctx),
    };
  }

  /// An operation the renderer does not know. Shown, not guessed at (§7.6):
  /// silently treating it as an addition is exactly the failure this method
  /// exists to stop repeating.
  String _unknownOperation(
    String operation,
    String subject,
    Map<String, dynamic> mod,
    _Ctx ctx,
  ) {
    ctx.unrendered.add('operation:$operation');
    final value = str(mod['value']);
    return '[$operation${value == null ? '' : ' $value'}] $subject';
  }

  /// `{operation: add, value: 1}` becomes `+1`; a negative value keeps its
  /// sign, because `{add, -1}` on AP is an improvement, not a bonus of one.
  String _signed(Map<String, dynamic> mod) {
    final value = asInt(mod['value']) ?? 1;
    final effective =
        strOr(mod['operation'], 'add') == 'subtract' ? -value.abs() : value;
    return effective < 0 ? '$effective' : '+$effective';
  }

  static const _stats = {
    'M': 'Move',
    'T': 'Toughness',
    'W': 'Wound',
    'Sv': 'Save',
    'Ld': 'Leadership',
    'OC': 'OC',
    'A': 'Attacks',
    'S': 'Strength',
    'AP': 'AP',
    'D': 'Damage',
    'BS': 'BS',
    'WS': 'WS',
    'R': 'Range',
  };

  /// Unmapped characteristics fall through as words rather than as ids —
  /// `detection-range` reads as a stat, `detection-range` reads as a bug.
  String _statName(String stat) => _stats[stat] ?? _words(stat);

  static const _rolls = {
    'hit': 'Hit',
    'wound': 'Wound',
    'save': 'Save',
    'charge': 'Charge',
    'advance': 'Advance',
    'damage': 'Damage',
    'all': 'all',
    'any': 'any roll',
  };

  String _rollName(String roll) => _rolls[roll] ?? _words(roll);

  /// Keywords are shown as the rulebook shows them: upper case.
  String _keyword(String keyword) => keyword.toUpperCase();

  /// `before-bearer-removed` becomes `before bearer removed`.
  String _words(String value) =>
      value.replaceAll('-', ' ').replaceAll('_', ' ').trim();

  /// `miracle-dice-pool` becomes `Miracle dice`.
  ///
  /// A pool is a named game resource rather than a description of one, so it
  /// reads as a proper noun — "gain 1 Miracle dice", not "gain 1 miracle dice
  /// pool".
  String _pool(Object? id) {
    final raw = str(id);
    if (raw == null) return 'die';
    final name = _capitalise(
        raw.endsWith('-pool') ? raw.substring(0, raw.length - 5) : raw);
    return name.isEmpty ? 'die' : name;
  }

  /// `a, b or c` — the connective the rules use for a list of eligible rolls.
  String _list(List<String> parts) {
    if (parts.isEmpty) return '';
    if (parts.length == 1) return parts.first;
    return '${parts.take(parts.length - 1).join(', ')} or ${parts.last}';
  }

  String _capitalise(String value) {
    final words = _words(value);
    if (words.isEmpty) return words;
    return '${words[0].toUpperCase()}${words.substring(1)}';
  }

  String _sentence(String text) {
    if (text.isEmpty) return text;
    final capitalised = '${text[0].toUpperCase()}${text.substring(1)}';
    return capitalised.endsWith('.') ? capitalised : '$capitalised.';
  }
}

class _Ctx {
  final Set<String> phases = {};
  final Set<String> unrendered = {};
}
