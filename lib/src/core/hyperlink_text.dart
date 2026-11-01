import 'package:xterm/src/core/buffer/line.dart';
import 'package:xterm/src/core/hyperlink.dart';

/// A plain-text URL found in terminal output (Vite, VitePress, test runners…).
///
/// Detected on demand from the cells of one row; nothing is stored on the
/// line, so scrolling, reflow and overwrites cannot leave stale links behind.
class TerminalUrlMatch {
  const TerminalUrlMatch({
    required this.uri,
    required this.startColumn,
    required this.endColumn,
  });

  final String uri;

  /// First column of the match, inclusive.
  final int startColumn;

  /// Column just past the match, exclusive.
  final int endColumn;

  bool contains(int column) => column >= startColumn && column < endColumn;
}

/// One hyperlink range on a row: either OSC 8 cells or a plain-text URL.
class TerminalLinkSpan {
  const TerminalLinkSpan({
    required this.link,
    required this.startColumn,
    required this.endColumn,
  });

  final TerminalHyperlink link;

  /// First column of the span, inclusive.
  final int startColumn;

  /// Column just past the span, exclusive.
  final int endColumn;

  bool overlaps(int start, int end) =>
      startColumn < end && start < endColumn;
}

/// Every hyperlink on [line], in column order.
///
/// OSC 8 cells are grouped into runs and win over plain-text detection, so a
/// program-provided link is never shadowed by the URL printed inside it.
List<TerminalLinkSpan> linkSpansInLine(
  BufferLine line, {
  bool includePlainUrls = true,
}) {
  final spans = <TerminalLinkSpan>[];
  final length = line.length;
  if (line.hasLinks) {
    var current = line.getLink(0);
    var start = current == null ? -1 : 0;
    for (var column = 1; column <= length; column++) {
      final link = column < length ? line.getLink(column) : null;
      if (link == current) {
        continue;
      }
      if (current != null && start >= 0) {
        spans.add(TerminalLinkSpan(
          link: current,
          startColumn: start,
          endColumn: column,
        ));
      }
      current = link;
      start = link == null ? -1 : column;
    }
  }
  if (includePlainUrls) {
    for (final match in findTerminalUrlsInLine(line)) {
      final overlaps = spans.any(
        (span) => span.overlaps(match.startColumn, match.endColumn),
      );
      if (overlaps) {
        continue;
      }
      spans.add(TerminalLinkSpan(
        link: TerminalHyperlink(uri: match.uri),
        startColumn: match.startColumn,
        endColumn: match.endColumn,
      ));
    }
  }
  return spans;
}

/// Scheme URLs in terminal output.
///
/// Scheme list and character class are ported from ghostty's `url.zig` default
/// matcher (`scheme_url_branch`): schemes without `//` (mailto/tel/news/magnet)
/// are included, and the match stops at the characters that end prose.
final _urlPattern = RegExp(
  // 前面不能紧挨词字符：`profile:production` 里的 `file:` 不是链接。
  r"(?<![\w@.\-])(?:https?://|ftp://|file:|ssh://|ssh:|git://|tel:|"
  r'magnet:|ipfs://|ipns://|gemini://|gopher://|news:|mailto:)'
  // 除空白/控制字符和引号外都算 URL 正文：IPv6 的 `[::1]`、括号片名、中文
  // 路径都在里面，尾部的标点交给 [_urlEnd] 按配对规则裁。
  r'''[^\s\x00-\x1f<>"'`]+''',
  caseSensitive: false,
);

const _trailingProse = '.,;:!?)]}\'"';

/// Trim prose punctuation from the end of a scheme URL.
///
/// A trailing `)` or `]` survives when the URL opens a matching bracket — the
/// same rule as ghostty's `url.zig`, so `…/Rust_(video_game)` keeps its
/// parenthesis while `(https://example.com)` does not.
int _urlEnd(String text, int start, int end) {
  while (end > start) {
    final char = text[end - 1];
    if (char == ')' || char == ']') {
      final slice = text.substring(start, end);
      final open = char == ')' ? '(' : '[';
      if (open.allMatches(slice).length >= char.allMatches(slice).length) {
        break;
      }
    } else if (!_trailingProse.contains(char)) {
      break;
    }
    end--;
  }
  return end;
}

/// Longest URL accepted from plain text; a dumped blob must not become a link.
const _maxUrlLength = 2048;

/// URLs visible on [line], in column order.
///
/// Every terminal column maps to exactly one code unit of the scanned text, so
/// a match can be converted back to cell columns without any guessing. Wide
/// characters get a filler for their continuation column.
List<TerminalUrlMatch> findTerminalUrlsInLine(BufferLine line) {
  final length = line.getTrimmedLength();
  if (length <= 0) {
    return const [];
  }

  final builder = StringBuffer();
  final columns = <int>[];
  for (var column = 0; column < length; column++) {
    final codePoint = line.getCodePoint(column);
    final chunk = codePoint == 0
        ? ' '
        : String.fromCharCode(codePoint);
    for (var i = 0; i < chunk.length; i++) {
      columns.add(column);
    }
    builder.write(chunk);
  }

  final text = builder.toString();
  if (!text.contains(':')) {
    return const [];
  }

  final matches = <TerminalUrlMatch>[];
  for (final match in _urlPattern.allMatches(text)) {
    final end = _urlEnd(text, match.start, match.end);
    if (end <= match.start) {
      continue;
    }
    final uri = text.substring(match.start, end);
    if (uri.length > _maxUrlLength) {
      continue;
    }
    matches.add(TerminalUrlMatch(
      uri: uri,
      startColumn: columns[match.start],
      endColumn: columns[end - 1] + 1,
    ));
  }
  return matches;
}

/// URL covering [column], or null when that column is not inside one.
TerminalUrlMatch? terminalUrlMatchAtColumn(
  BufferLine line,
  int column, {
  List<TerminalUrlMatch>? matches,
}) {
  if (column < 0 || column >= line.length) {
    return null;
  }
  for (final match in matches ?? findTerminalUrlsInLine(line)) {
    if (match.contains(column)) {
      return match;
    }
  }
  return null;
}
