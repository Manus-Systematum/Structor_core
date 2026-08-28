/// 11th edition battle sizes.
///
/// This is the **hand-maintained rules table** DESIGN.md §3.3 step 5 requires:
/// derived limits are asserted against it and the build fails on mismatch.
/// It exists because the source data is not authoritative on every value —
/// BSData grants 4 enhancement slots at Strike Force where the rules grant 3
/// (DESIGN.md §3.2), so "read the limits from the data" is the right default
/// and the wrong absolute.
///
/// Values confirmed against the rulebook, not inferred.
library;

class BattleSize {
  final String id;
  final String name;
  final int points;
  final int detachmentPoints;
  final int enhancementSlots;

  /// Copies of a single datasheet permitted in one army.
  final int maxCopies;

  /// Copies permitted for **Battleline** and **Dedicated Transport**
  /// datasheets, which receive a doubled cap.
  final int maxCopiesBattleline;

  const BattleSize({
    required this.id,
    required this.name,
    required this.points,
    required this.detachmentPoints,
    required this.enhancementSlots,
    required this.maxCopies,
    required this.maxCopiesBattleline,
  });

  static const incursion = BattleSize(
    id: 'incursion',
    name: 'Incursion',
    points: 1000,
    detachmentPoints: 2,
    enhancementSlots: 2,
    maxCopies: 2,
    maxCopiesBattleline: 4,
  );

  static const strikeForce = BattleSize(
    id: 'strike-force',
    name: 'Strike Force',
    points: 2000,
    detachmentPoints: 3,
    enhancementSlots: 3,
    maxCopies: 3,
    maxCopiesBattleline: 6,
  );

  static const onslaught = BattleSize(
    id: 'onslaught',
    name: 'Onslaught',
    points: 3000,
    detachmentPoints: 4,
    enhancementSlots: 4,
    maxCopies: 3,
    maxCopiesBattleline: 6,
  );

  static const all = [incursion, strikeForce, onslaught];

  static BattleSize? byId(String id) {
    for (final size in all) {
      if (size.id == id) return size;
    }
    return null;
  }

  /// The Detachment Points budget available given the detachments taken.
  ///
  /// At Incursion the budget rises from 2 to 3 **if** a 3 DP detachment is
  /// taken, so a single large detachment is always legal — it simply leaves no
  /// change. A plain `sum(dp) <= detachmentPoints` check gets this wrong in
  /// both directions (DESIGN.md §4.4).
  int budgetFor({required bool includesThreeDpDetachment}) {
    if (this == incursion && includesThreeDpDetachment) return 3;
    return detachmentPoints;
  }

  int capFor({required bool isBattlelineOrTransport}) =>
      isBattlelineOrTransport ? maxCopiesBattleline : maxCopies;
}
