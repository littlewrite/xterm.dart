import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:xterm/src/ui/painter.dart';
import 'package:xterm/xterm.dart';

TerminalPainter _painter() => TerminalPainter(
      theme: TerminalThemes.defaultTheme,
      textStyle: const TerminalStyle(),
      textScaler: TextScaler.noScaling,
    );

const _webUrl = 'http://localhost:5173/';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  test('web OSC 8 links decorate only while armed', () {
    final terminal = Terminal();
    terminal.write('\x1b]8;;https://example.com\x1b\\link\x1b]8;;\x1b\\');
    final line = terminal.buffer.lines[0];
    final painter = _painter();
    final link = line.getLink(0)!;

    // iTerm2 semantics: at rest nothing is underlined, not even with the
    // modifier alone — the pointer has to be on the link too.
    expect(
      painter.resolveLinkDecorations(
        line,
        lineIndex: 0,
        underlineFileLinks: true,
      ),
      isEmpty,
    );

    final armed = painter.resolveLinkDecorations(
      line,
      lineIndex: 0,
      armedLineIndex: 0,
      underlineFileLinks: true,
      armedLink: link,
    );
    expect(armed, hasLength(1));
    expect(armed.single.dashed, isFalse);
    expect(armed.single.startColumn, 0);
    expect(armed.single.endColumn, 4);
  });

  test('plain-text URLs decorate when their hit-test link is armed', () {
    final terminal = Terminal();
    terminal.write('Local: $_webUrl ok');
    final line = terminal.buffer.lines[0];
    final painter = _painter();
    // The view hands over a freshly built link; equality is by uri + id.
    final armedLink = TerminalHyperlink(uri: _webUrl);
    const start = 'Local: '.length;

    final decorations = painter.resolveLinkDecorations(
      line,
      lineIndex: 0,
      armedLineIndex: 0,
      armedLink: armedLink,
    );
    expect(decorations, hasLength(1));
    expect(decorations.single.dashed, isFalse);
    expect(decorations.single.startColumn, start);
    expect(decorations.single.endColumn, start + _webUrl.length);

    // A URL on another row is neither scanned nor decorated.
    expect(
      painter.resolveLinkDecorations(
        line,
        lineIndex: 3,
        armedLineIndex: 0,
        armedLink: armedLink,
      ),
      isEmpty,
    );
  });

  test('file links are dashed at rest and solid while armed', () {
    final terminal = Terminal();
    terminal.write('\x1b]8;;file:///tmp/report.txt\x1b\\file\x1b]8;;\x1b\\');
    final line = terminal.buffer.lines[0];
    final painter = _painter();
    final link = line.getLink(0)!;

    final resting = painter.resolveLinkDecorations(
      line,
      lineIndex: 0,
      underlineFileLinks: true,
    );
    expect(resting, hasLength(1));
    expect(resting.single.dashed, isTrue);

    final armed = painter.resolveLinkDecorations(
      line,
      lineIndex: 0,
      armedLineIndex: 0,
      underlineFileLinks: true,
      armedLink: link,
    );
    expect(armed, hasLength(1));
    expect(armed.single.dashed, isFalse);

    // Desktop can opt out of file links entirely (they stay invisible).
    expect(
      painter.resolveLinkDecorations(line, lineIndex: 0),
      isEmpty,
    );
  });

  test('mobile underlines web links and skips file links', () {
    final web = Terminal();
    web.write('\x1b]8;;https://example.com\x1b\\x\x1b]8;;\x1b\\');
    final url = Terminal()..write(_webUrl);
    final file = Terminal();
    file.write('\x1b]8;;file:///tmp/report.txt\x1b\\f\x1b]8;;\x1b\\');
    final painter = _painter();

    expect(
      painter.resolveLinkDecorations(
        web.buffer.lines[0],
        lineIndex: 0,
        underlineAllWebLinks: true,
      ),
      hasLength(1),
    );
    expect(
      painter.resolveLinkDecorations(
        url.buffer.lines[0],
        lineIndex: 0,
        underlineAllWebLinks: true,
      ),
      hasLength(1),
    );
    // A file:// marker points at the host's disk; mobile cannot open it, so it
    // is not advertised either.
    expect(
      painter.resolveLinkDecorations(
        file.buffer.lines[0],
        lineIndex: 0,
        underlineAllWebLinks: true,
      ),
      isEmpty,
    );
  });
}
