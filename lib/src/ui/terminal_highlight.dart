import 'dart:ui';

import 'package:flutter/foundation.dart';
import 'package:xterm/src/core/buffer/line.dart';

/// A paint-only style overlay for a range of terminal cells.
///
/// The overlay never changes the [CellData] stored by the terminal. A null
/// color leaves the corresponding ANSI color untouched; flags are applied as
/// additions/removals to the cell's existing flags.
class TerminalHighlightSpan {
  const TerminalHighlightSpan({
    required this.startColumn,
    required this.endColumn,
    this.foreground,
    this.background,
    this.addFlags = 0,
    this.removeFlags = 0,
    this.preserveAnsiColors = true,
  });

  final int startColumn;
  final int endColumn;
  final Color? foreground;
  final Color? background;
  final int addFlags;
  final int removeFlags;
  final bool preserveAnsiColors;

  bool contains(int column) => column >= startColumn && column < endColumn;
}

/// Supplies paint overlays to [RenderTerminal].
///
/// Implementations should return already sorted, non-overlapping spans. The
/// viewport callback is deliberately optional so xterm remains independent of
/// any parsing implementation; a highlighter can use it to schedule work for
/// the visible range plus its own overscan.
abstract class TerminalHighlightSource extends ChangeNotifier {
  int get revision;

  /// Revision for the overlay on one physical line. Implementations can use
  /// this to keep unrelated line pictures cached after a local update.
  int revisionForLine(BufferLine line, int lineIndex) => revision;

  List<TerminalHighlightSpan> spansForLine(BufferLine line, int lineIndex);

  void updateVisibleRange(int firstLine, int lastLine) {}
}
