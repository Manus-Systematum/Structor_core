/// Pure-Dart domain core for the 40k 11th edition companion app.
///
/// No Flutter dependency: the same code runs in the ETL, the app and the
/// server (DESIGN.md §2).
library;

export 'src/battle/battle_event.dart';
export 'src/battle/battle_state.dart';
export 'src/content/bundle.dart';
export 'src/crosscheck/crosscheck.dart';
export 'src/crosscheck/mfm.dart';
export 'src/content/content_hash.dart';
export 'src/content/dataset.dart';
export 'src/content/patch.dart';
export 'src/content/roster_snapshot.dart';
export 'src/import/faction_match.dart';
export 'src/import/name_match.dart';
export 'src/import/parsed_list.dart';
export 'src/import/roster_resolver.dart';
export 'src/import/text_parser.dart';
export 'src/missions/mission_pack.dart';
export 'src/missions/mission_setup.dart';
export 'src/missions/secondary_deck.dart';
export 'src/missions/terrain_layout.dart';
export 'src/play/army_rules.dart';
export 'src/play/attacks.dart';
export 'src/play/reference_index.dart';
export 'src/play/rule_text.dart';
export 'src/play/rules_renderer.dart';
export 'src/play/stratagem_book.dart';
export 'src/play/weapon_aggregator.dart';
export 'src/report/coverage_report.dart';
export 'src/source/corrections.dart';
export 'src/source/dataset_loader.dart';
export 'src/source/source_models.dart';
export 'src/roster/points.dart';
export 'src/roster/roster_editor.dart';
export 'src/rules/catalogue.dart';
export 'src/rules/validator.dart';
export 'src/roster/roster.dart';
export 'src/roster/unit_loadout.dart';
export 'src/rules/battle_size.dart';
