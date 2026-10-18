import 'package:flutter_test/flutter_test.dart';
import 'package:xterm/src/terminal.dart';

/// DECRQM: `CSI ? Ps $ p` asks whether a DEC private mode is set, and the
/// terminal answers with `CSI ? Ps ; Pv $ y`, where Pv is 0 (not recognised),
/// 1 (set) or 2 (reset).
void main() {
  (Terminal, List<String>) make() {
    final replies = <String>[];
    final terminal = Terminal(onTerminalReply: replies.add);
    return (terminal, replies);
  }

  String report(int mode, int value) => '\x1b[?$mode;$value\$y';

  test('reports synchronized output as reset until it is set', () {
    final (terminal, replies) = make();

    terminal.write('\x1b[?2026\$p');
    expect(replies, [report(2026, 2)]);

    terminal.write('\x1b[?2026h');
    replies.clear();
    terminal.write('\x1b[?2026\$p');
    expect(replies, [report(2026, 1)]);

    terminal.write('\x1b[?2026l');
    replies.clear();
    terminal.write('\x1b[?2026\$p');
    expect(replies, [report(2026, 2)]);
  });

  test('reports the other modes it actually honours', () {
    final (terminal, replies) = make();

    // Mode -> the sequences that turn it off and on. Both directions are driven
    // because some of them (25) start out on.
    const modes = <int, (String on, String off)>{
      1: ('\x1b[?1h', '\x1b[?1l'),
      6: ('\x1b[?6h', '\x1b[?6l'),
      9: ('\x1b[?9h', '\x1b[?9l'),
      12: ('\x1b[?12h', '\x1b[?12l'),
      25: ('\x1b[?25h', '\x1b[?25l'),
      1002: ('\x1b[?1002h', '\x1b[?1002l'),
      1003: ('\x1b[?1003h', '\x1b[?1003l'),
      1004: ('\x1b[?1004h', '\x1b[?1004l'),
      1005: ('\x1b[?1005h', '\x1b[?1005l'),
      1006: ('\x1b[?1006h', '\x1b[?1006l'),
      1015: ('\x1b[?1015h', '\x1b[?1015l'),
      2004: ('\x1b[?2004h', '\x1b[?2004l'),
      2026: ('\x1b[?2026h', '\x1b[?2026l'),
    };

    for (final entry in modes.entries) {
      terminal.write(entry.value.$2);
      replies.clear();
      terminal.write('\x1b[?${entry.key}\$p');
      expect(replies, [report(entry.key, 2)], reason: '${entry.key} reset');

      terminal.write(entry.value.$1);
      replies.clear();
      terminal.write('\x1b[?${entry.key}\$p');
      expect(replies, [report(entry.key, 1)], reason: '${entry.key} set');
    }
  });

  test('an implemented mode that shares its state reports unrecognised', () {
    final (terminal, replies) = make();

    // 1000 and 1001 both land on MouseMode.upDownScroll, so afterwards there is
    // no way to tell which one the program set. Answering 1 would make the
    // program think the other one is on too.
    terminal.write('\x1b[?1000h');
    terminal.write('\x1b[?1000\$p');
    terminal.write('\x1b[?1001\$p');
    expect(replies, [report(1000, 0), report(1001, 0)]);
  });

  test('an unimplemented mode reports unrecognised', () {
    final (terminal, replies) = make();

    for (final mode in [2, 3, 4, 5, 8, 40, 1049, 2027, 9999]) {
      replies.clear();
      terminal.write('\x1b[?$mode\$p');
      expect(replies, [report(mode, 0)], reason: 'mode $mode');
    }
  });

  test('answers every mode in one request', () {
    final (terminal, replies) = make();

    terminal.write('\x1b[?1;2026;9999\$p');
    expect(replies, [
      report(1, 2),
      report(2026, 2),
      report(9999, 0),
    ]);
  });

  test('needs the dollar intermediate to be a request', () {
    final (terminal, replies) = make();

    // Without `$` this is not DECRQM; it must not be answered as one.
    terminal.write('\x1b[?2026p');
    expect(replies, isEmpty);
  });

  test('a non-private request is not answered', () {
    final (terminal, replies) = make();

    terminal.write('\x1b[2026\$p');
    expect(replies, isEmpty);
  });

  test('stays silent when capability queries are turned off', () {
    final (terminal, replies) = make();
    terminal.answerCapabilityQueries = false;

    terminal.write('\x1b[?2026\$p');
    expect(replies, isEmpty);

    terminal.answerCapabilityQueries = true;
    terminal.write('\x1b[?2026\$p');
    expect(replies, [report(2026, 2)]);
  });
}
