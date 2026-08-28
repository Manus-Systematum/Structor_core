/// The loose intermediate representation every importer produces
/// (DESIGN.md §6.1).
///
/// Deliberately **untyped**: a node is a counted name with children, and
/// nothing more. War Organ's text export puts *wargear* at depth 1 for uniform
/// units and *models* at depth 1 for mixed ones, with nothing syntactic to
/// tell them apart — only the catalogue knows that `Crisis Shas'vre` is a model
/// and `Battlesuit fists` is a weapon. Classifying here would leak catalogue
/// knowledge into every parser; the resolver does it once instead.
library;

/// A counted, named node. `2x Crisis Shas'ui` with weapons beneath it.
class ParsedNode {
  final int count;
  final String name;
  final List<ParsedNode> children;

  /// 1-based line number in the source, for error reporting.
  final int line;

  const ParsedNode({
    required this.count,
    required this.name,
    this.children = const [],
    this.line = 0,
  });

  bool get hasChildren => children.isNotEmpty;

  @override
  String toString() => '${count}x $name'
      '${hasChildren ? ' (${children.length} children)' : ''}';
}

/// A datasheet entry as it appeared in the source.
class ParsedUnit {
  final String name;

  /// Points as printed. Used to cross-check the computed cost, never to
  /// replace it — the printed figure is the *source's* arithmetic.
  final int? printedPoints;

  final List<ParsedNode> nodes;

  /// Group label for units the source bracketed together, e.g. War Organ's
  /// `Attached Unit 1`. This is how leader attachment survives import, and it
  /// is the relationship most other formats lose (§6.5).
  final String? attachmentGroup;

  final bool isWarlord;
  final int line;

  const ParsedUnit({
    required this.name,
    required this.nodes,
    this.printedPoints,
    this.attachmentGroup,
    this.isWarlord = false,
    this.line = 0,
  });
}

class ParsedList {
  final String? name;
  final int? printedPoints;
  final String? factionName;
  final List<String> detachmentNames;
  final int? detachmentPoints;
  final String? disposition;
  final String? battleSizeName;
  final List<ParsedUnit> units;

  /// Lines the parser did not understand. Surfaced rather than dropped: an
  /// import that silently ignores input is how a unit goes missing.
  final List<String> unparsedLines;

  const ParsedList({
    required this.units,
    this.name,
    this.printedPoints,
    this.factionName,
    this.detachmentNames = const [],
    this.detachmentPoints,
    this.disposition,
    this.battleSizeName,
    this.unparsedLines = const [],
  });
}
