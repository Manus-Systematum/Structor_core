/// The Munitorum Field Manual points, as parsed by `BSData/wh40k-11e-mfm`.
///
/// This is the **cross-check source** of DESIGN.md §3.0, not a second primary.
/// Its value is independence: it is parsed from Games Workshop's own published
/// points page, so where it and `40kdc-data` disagree, one of them is wrong
/// and a human should look. Nothing from here is shipped.
///
/// MIT licensed, unlike the main BSData catalogue repository.
library;

import 'package:yaml/yaml.dart';

import '../source/json.dart';

/// A copy-count range, written `[1,2]` or `[3,)` in the source — the same idea
/// as `unit_count_min`/`unit_count_max` in the primary data (§2.1).
class CopyRange {
  final int min;
  final int? max;

  const CopyRange(this.min, this.max);

  static final _pattern = RegExp(r'^\[(\d+)\s*,\s*(\d*)\s*[\])]$');

  factory CopyRange.parse(String value) {
    final match = _pattern.firstMatch(value.trim());
    if (match == null) return const CopyRange(1, null);
    return CopyRange(
      int.tryParse(match.group(1)!) ?? 1,
      int.tryParse(match.group(2) ?? '') ,
    );
  }

  @override
  String toString() => max == null ? '$min+' : '$min-$max';
}

class MfmCost {
  final int models;
  final int points;

  /// An optional extra priced alongside the unit — a Tidewall Defence
  /// Platform, say — rather than the unit's own cost. Excluded from
  /// comparison: it shares a model count with the base entry and is not
  /// something the primary data carries as a bracket.
  final bool isAddon;

  final String? description;

  const MfmCost({
    required this.models,
    required this.points,
    this.isAddon = false,
    this.description,
  });
}

class MfmUnit {
  final String name;
  final Map<CopyRange, List<MfmCost>> pricing;
  final String? role;
  final List<String> attachTo;
  final bool isLegends;

  const MfmUnit({
    required this.name,
    required this.pricing,
    this.role,
    this.attachTo = const [],
    this.isLegends = false,
  });

  /// Flattened as `(copyMin, models) -> points`, which is directly comparable
  /// with the primary data's points brackets.
  Map<(int, int), int> get costTable => {
        for (final entry in pricing.entries)
          for (final cost in entry.value)
            if (!cost.isAddon) (entry.key.min, cost.models): cost.points,
      };

  /// Optional extras, kept out of [costTable] but available for display.
  List<MfmCost> get addons => [
        for (final costs in pricing.values)
          for (final cost in costs)
            if (cost.isAddon) cost,
      ];
}

class MfmEnhancement {
  final String name;
  final int points;

  const MfmEnhancement({required this.name, required this.points});
}

class MfmDetachment {
  final String name;
  final int dp;
  final String? objective;
  final String? unique;
  final List<MfmEnhancement> enhancements;

  const MfmDetachment({
    required this.name,
    required this.dp,
    this.objective,
    this.unique,
    this.enhancements = const [],
  });
}

class MfmFaction {
  final String name;
  final String slug;
  final String version;
  final List<MfmUnit> units;
  final List<MfmDetachment> detachments;

  const MfmFaction({
    required this.name,
    required this.slug,
    required this.version,
    required this.units,
    required this.detachments,
  });

  static MfmFaction parse(String yamlSource) {
    final root = loadYaml(yamlSource);
    final map = _map(root);

    return MfmFaction(
      name: strOr(map['name'], ''),
      slug: strOr(map['slug'], ''),
      version: strOr(map['version'], ''),
      units: [
        for (final raw in _list(map['units'])) _unit(_map(raw)),
      ],
      detachments: [
        for (final raw in _list(map['detachments'])) _detachment(_map(raw)),
      ],
    );
  }

  static MfmUnit _unit(Map<String, Object?> u) {
    final pricing = <CopyRange, List<MfmCost>>{};
    for (final raw in _list(u['pricing'])) {
      final band = _map(raw);
      final range = CopyRange.parse(strOr(band['range'], '[1,)'));
      pricing[range] = [
        for (final rawCost in _list(band['costs']))
          if (_map(rawCost) case final c)
            MfmCost(
              models: intOr(c['models'], 1),
              points: intOr(c['points'], 0),
              isAddon: c['addon'] == true,
              description: str(c['desc']),
            ),
      ];
    }
    return MfmUnit(
      name: strOr(u['name'], ''),
      pricing: pricing,
      role: str(u['role']),
      attachTo: [for (final t in _list(u['attachTo'])) strOr(t, '')],
      isLegends: u['legends'] == true,
    );
  }

  static MfmDetachment _detachment(Map<String, Object?> d) => MfmDetachment(
        name: strOr(d['name'], ''),
        dp: intOr(d['dp'], 0),
        objective: str(d['objective']),
        unique: str(d['unique']),
        enhancements: [
          for (final raw in _list(d['enhancements']))
            if (_map(raw) case final e)
              MfmEnhancement(
                name: strOr(e['name'], ''),
                points: intOr(e['points'], 0),
              ),
        ],
      );

  static Map<String, Object?> _map(Object? value) => value is Map
      ? {for (final e in value.entries) e.key.toString(): e.value}
      : const {};

  static List<Object?> _list(Object? value) =>
      value is List ? value.toList() : const [];
}
