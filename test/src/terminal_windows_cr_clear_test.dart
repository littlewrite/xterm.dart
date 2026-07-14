import 'package:flutter/foundation.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:xterm/xterm.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  test('Windows CR then shorter text overwrites but preserves suffix', () {
    final terminal = Terminal(platform: TerminalTargetPlatform.windows);
    terminal.resize(80, 24, 10, 16);

    terminal.write('branch List create delete branches');
    expect(
      terminal.buffer.lines[terminal.buffer.absoluteCursorY].getText(),
      contains('branches'),
    );

    // Bare CR then a shorter rewrite — standard VT: CR moves home,
    // subsequent text overwrites cell-by-cell. Un-overwritten cells
    // persist. This matches real Windows console behavior.
    terminal.write('\rd----- 2025/6/18');

    final text =
        terminal.buffer.lines[terminal.buffer.absoluteCursorY].getText();
    // Overwritten prefix is the new text; suffix from the old line remains.
    expect(text.trimRight(), 'd----- 2025/6/18te delete branches');
  });

  test('Windows CRLF must keep the line that just ended', () {
    final terminal = Terminal(platform: TerminalTargetPlatform.windows);
    terminal.resize(80, 24, 10, 16);

    terminal.write('Hello World\r\n');
    terminal.write('Next');

    final text = terminal.buffer.getText();
    expect(text, contains('Hello World'));
    expect(text, contains('Next'));
  });

  test('macOS carriage return preserves suffix after overwrite', () {
    debugDefaultTargetPlatformOverride = TargetPlatform.macOS;
    addTearDown(() => debugDefaultTargetPlatformOverride = null);

    final terminal = Terminal(platform: TerminalTargetPlatform.macos);
    terminal.resize(80, 24, 10, 16);

    terminal.write('AAAAAAAAAAAA');
    terminal.write('\rBBB');

    final text =
        terminal.buffer.lines[terminal.buffer.absoluteCursorY].getText();
    // Standard VT: CR moves home without EL, suffix remains.
    expect(text.trimRight(), 'BBBAAAAAAAAA');
  });

  test('wrapped output stays reconstructable without a raw shadow buffer', () {
    final terminal = Terminal(platform: TerminalTargetPlatform.windows);
    terminal.resize(10, 6, 10, 16);

    const longLine = '1234567890ABCDEFGHIJklmnop';
    terminal.write(longLine);

    expect(terminal.buffer.lines[0].isWrapped, isTrue);
    expect(terminal.buffer.lines[1].isWrapped, isTrue);
    expect(terminal.buffer.getText().trimRight(), longLine);
  });

  test('Windows prompt-style cursor jump follows absolute repositioning', () {
    final terminal = Terminal(platform: TerminalTargetPlatform.windows);
    terminal.resize(10, 6, 10, 16);

    // 40 chars on a 10-col terminal: 4 full rows (0-3), cursor ends on row 3.
    terminal.write('1111111111222222222233333333334444444444');
    expect(terminal.buffer.cursorY, 3);

    // CUP row 2 (1-based) = row 1 (0-based), then overwrite with prompt.
    terminal.write('\x1b[2;1H');
    terminal.write('PS> ');

    expect(terminal.buffer.cursorY, 1);
    expect(terminal.buffer.lines[1].getText().trimRight(), 'PS> 222222');
    expect(terminal.buffer.lines[3].getText().trimRight(), '4444444444');
  });

  test('explicit lineFeed clears isWrapped (aligns with Windows Terminal '
      '_DoLineFeed SetWrapForced(false))', () {
    final terminal = Terminal(platform: TerminalTargetPlatform.windows);
    terminal.resize(20, 6, 10, 16);

    // viewWidth+1 chars: 20 fill row 0, 21st triggers auto-wrap to row 1.
    terminal.write('A' * 21);
    expect(terminal.buffer.lines[0].isWrapped, isTrue);

    // Move back to row 0, then send explicit LF. The LF should clear
    // isWrapped on the line being left (row 0).
    terminal.write('\x1b[1;1H');
    terminal.write('\n');
    expect(terminal.buffer.lines[0].isWrapped, isFalse);
  });

  test(
      'explicit IND (ESC D) clears isWrapped and auto-wrap via writeChar does not',
      () {
    final terminal = Terminal(platform: TerminalTargetPlatform.windows);
    terminal.resize(20, 6, 10, 16);

    // Auto-wrap: 21 chars on 20-col terminal triggers wrap.
    terminal.write('X' * 21);
    expect(terminal.buffer.lines[0].isWrapped, isTrue);

    // Move cursor back to row 0, write 21 more chars → second auto-wrap.
    terminal.write('\x1b[1;1H');
    terminal.write('Y' * 21);
    expect(terminal.buffer.lines[0].isWrapped, isTrue);

    // Move back again, then send explicit IND (ESC D). This should clear
    // isWrapped on the line being left, per Windows Terminal _DoLineFeed.
    terminal.write('\x1b[1;1H');
    terminal.write('\x1bD');
    expect(terminal.buffer.lines[0].isWrapped, isFalse);
  });

  test('nextLine (NEL / ESC E) clears isWrapped', () {
    final terminal = Terminal(platform: TerminalTargetPlatform.windows);
    terminal.resize(20, 6, 10, 16);

    terminal.write('Z' * 21); // auto-wrap
    expect(terminal.buffer.lines[0].isWrapped, isTrue);

    // Move back to row 0, then NEL (\x1bE = ESC E) moves to next line.
    // In Windows Terminal NEL calls _DoLineFeed(wrapForced=false),
    // clearing the wrap flag on the line being left.
    terminal.write('\x1b[1;1H');
    terminal.write('\x1bE');
    expect(terminal.buffer.lines[0].isWrapped, isFalse);
  });
}
