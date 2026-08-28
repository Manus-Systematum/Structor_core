/// Parses the plain-text army export produced by War Organ and tools like it
/// (DESIGN.md §6.7).
///
/// Far more structured than "plain text" suggests, and it preserves the one
/// thing structured formats tend to lose: **leader attachment**, via its
/// `ATTACHED UNITS` / `Attached Unit N` grouping.
///
/// The parser stays strictly syntactic. It produces counted named nodes and
/// never decides whether a node is a model or a weapon — see [ParsedList].
library;

import 'parsed_list.dart';

class TextListParser {
  const TextListParser();

  static final _header = RegExp(r'^(.*?)\s*\((\d+)\s*points?\)\s*$',
      caseSensitive: false);
  static final _bullet = RegExp(r'^(\s*)[•\-\*]\s*(?:(\d+)\s*x\s*)?(.+?)\s*$',
      caseSensitive: false);
  static final _detachments =
      RegExp(r'^(.*?)\s*\((\d+)\s*Detachment Points?\)\s*$', caseSensitive: false);
  static final _battleSize =
      RegExp(r'^(.*?)\s*\((\d+)\s*Points?\s*(?:limit)?\)\s*$', caseSensitive: false);
  static final _attachedGroup =
      RegExp(r'^Attached Unit\s+(\S+)\s*$', caseSensitive: false);

  static const _sections = {
    'ATTACHED UNITS',
    'CHARACTER',
    'CHARACTERS',
    'OTHER DATASHEETS',
    'OTHER DATASHEET',
  };

  ParsedList parse(String source) {
    final lines = source.split('\n');

    String? listName;
    int? listPoints;
    String? faction;
    var detachments = <String>[];
    int? detachmentPoints;
    String? disposition;
    String? battleSize;

    final units = <ParsedUnit>[];
    final unparsed = <String>[];

    String? currentSection;
    String? currentGroup;
    ParsedUnit? current;
    var currentNodes = <ParsedNode>[];
    // Indent width of the shallowest bullet seen in this unit, so nesting is
    // measured relative to the unit rather than assuming two spaces.
    int? baseIndent;

    void flush() {
      if (current == null) return;
      units.add(ParsedUnit(
        name: current!.name,
        printedPoints: current!.printedPoints,
        nodes: List.of(currentNodes),
        attachmentGroup: current!.attachmentGroup,
        isWarlord: currentNodes.any((n) => n.name.toLowerCase() == 'warlord'),
        line: current!.line,
      ));
      current = null;
      currentNodes = [];
      baseIndent = null;
    }

    for (var i = 0; i < lines.length; i++) {
      final raw = lines[i].replaceAll('\t', '    ');
      final line = raw.trimRight();
      if (line.trim().isEmpty) continue;

      final bullet = _bullet.firstMatch(line);
      if (bullet != null && current != null) {
        final indent = bullet.group(1)!.length;
        final count = int.tryParse(bullet.group(2) ?? '') ?? 1;
        final name = bullet.group(3)!.trim();

        baseIndent ??= indent;
        if (indent <= baseIndent!) {
          currentNodes.add(
              ParsedNode(count: count, name: name, line: i + 1, children: []));
        } else {
          // Nested under the last top-level node. Depth-2 counts are group
          // totals for that model group, not per-model (§6.7).
          if (currentNodes.isEmpty) {
            unparsed.add(line);
            continue;
          }
          final parent = currentNodes.removeLast();
          currentNodes.add(ParsedNode(
            count: parent.count,
            name: parent.name,
            line: parent.line,
            children: [
              ...parent.children,
              ParsedNode(count: count, name: name, line: i + 1),
            ],
          ));
        }
        continue;
      }

      final upper = line.trim().toUpperCase();
      if (_sections.contains(upper)) {
        flush();
        currentSection = upper;
        currentGroup = null;
        continue;
      }

      final group = _attachedGroup.firstMatch(line.trim());
      if (group != null) {
        flush();
        currentGroup = line.trim();
        continue;
      }

      final header = _header.firstMatch(line);

      // The very first `Name (N points)` is the roster itself.
      if (header != null && listName == null && currentSection == null) {
        listName = header.group(1)!.trim();
        listPoints = int.parse(header.group(2)!);
        continue;
      }

      // Preamble: faction, detachments, disposition, battle size. It ends at
      // the first section header, or once the battle size is known.
      //
      // Order matters. `Strike Force (2000 Point)` also matches the unit
      // header pattern, so the preamble must claim it first — otherwise the
      // battle size is imported as a datasheet.
      final inPreamble = currentSection == null && battleSize == null;
      if (inPreamble && current == null) {
        final det = _detachments.firstMatch(line);
        if (det != null) {
          detachments = det
              .group(1)!
              .split(',')
              .map((s) => s.trim())
              .where((s) => s.isNotEmpty)
              .toList();
          detachmentPoints = int.parse(det.group(2)!);
          continue;
        }
        final size = _battleSize.firstMatch(line);
        if (size != null) {
          battleSize = size.group(1)!.trim();
          continue;
        }
        if (header == null && faction == null) {
          faction = line.trim();
          continue;
        }
        if (header == null && disposition == null) {
          disposition = line.trim();
          continue;
        }
      }

      if (header != null) {
        flush();
        current = ParsedUnit(
          name: header.group(1)!.trim(),
          printedPoints: int.parse(header.group(2)!),
          nodes: const [],
          attachmentGroup:
              currentSection == 'ATTACHED UNITS' ? currentGroup : null,
          line: i + 1,
        );
        continue;
      }

      unparsed.add(line);
    }
    flush();

    return ParsedList(
      name: listName,
      printedPoints: listPoints,
      factionName: faction,
      detachmentNames: detachments,
      detachmentPoints: detachmentPoints,
      disposition: disposition,
      battleSizeName: battleSize,
      units: units,
      unparsedLines: unparsed,
    );
  }
}
