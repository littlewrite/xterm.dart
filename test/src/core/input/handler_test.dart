import 'package:test/test.dart';
import 'package:xterm/src/core/input/keytab/keytab.dart';
import 'package:xterm/xterm.dart';

void main() {
  group('defaultInputHandler', () {
    test('supports numpad enter', () {
      final output = <String>[];
      final terminal = Terminal(onOutput: output.add);
      terminal.keyInput(TerminalKey.numpadEnter);
      expect(output, ['\r']);
    });

    test('keeps enter as carriage return by default', () {
      final output = <String>[];
      final terminal = Terminal(onOutput: output.add);

      terminal.keyInput(TerminalKey.enter, shift: true);

      expect(output, ['\r']);
    });

    test('encodes shift enter when modifyOtherKeys is enabled', () {
      final output = <String>[];
      final terminal = Terminal(onOutput: output.add);
      terminal.setModifyOtherKeys(2);

      terminal.keyInput(TerminalKey.enter, shift: true);

      expect(output, ['\x1b[27;2;13~']);
    });

    test('clamps xterm other key resource values', () {
      final terminal = Terminal();

      terminal.setModifyOtherKeys(99);
      terminal.setFormatOtherKeys(99);

      expect(terminal.modifyOtherKeys, 3);
      expect(terminal.formatOtherKeys, 1);

      terminal.setModifyOtherKeys(-1);
      terminal.setFormatOtherKeys(-1);

      expect(terminal.modifyOtherKeys, 0);
      expect(terminal.formatOtherKeys, 0);
    });

    test('uses base key codepoint for ctrl letters', () {
      final output = <String>[];
      final terminal = Terminal(onOutput: output.add);
      terminal.setModifyOtherKeys(2);

      terminal.keyInput(TerminalKey.keyA, character: '\x01', ctrl: true);
      terminal.keyInput(
        TerminalKey.keyA,
        character: '\x01',
        ctrl: true,
        shift: true,
      );

      expect(output, ['\x1b[27;5;97~', '\x1b[27;6;65~']);
    });

    test('uses base key codepoint for ctrl punctuation', () {
      final output = <String>[];
      final terminal = Terminal(onOutput: output.add);
      terminal.setModifyOtherKeys(2);

      terminal.keyInput(TerminalKey.space, character: '\x00', ctrl: true);
      terminal.keyInput(TerminalKey.digit3, character: '\x1b', ctrl: true);

      expect(output, ['\x1b[27;5;32~', '\x1b[27;5;51~']);
    });

    test('encodes ctrl letters at modifyOtherKeys level 1', () {
      final output = <String>[];
      final terminal = Terminal(onOutput: output.add);
      terminal.setModifyOtherKeys(1);

      terminal.keyInput(TerminalKey.keyC, character: 'c', ctrl: true);

      expect(output, ['\x1b[27;5;99~']);
    });

    test('does not encode x11 ctrl exceptions at modifyOtherKeys level 1', () {
      final output = <String>[];
      final terminal = Terminal(onOutput: output.add);
      terminal.setModifyOtherKeys(1);

      terminal.keyInput(TerminalKey.space, character: '\x00', ctrl: true);

      expect(output, ['\x00']);
    });

    test('does not encode alt letters at modifyOtherKeys level 1', () {
      final output = <String>[];
      final terminal = Terminal(onOutput: output.add);
      terminal.setModifyOtherKeys(1);

      terminal.keyInput(TerminalKey.keyA, character: 'a', alt: true);

      expect(output, ['\x1ba']);
    });

    test('preserves alt letter case', () {
      final output = <String>[];
      final terminal = Terminal(onOutput: output.add);

      terminal.keyInput(TerminalKey.keyV, character: 'v', alt: true);
      terminal.keyInput(
        TerminalKey.keyV,
        character: 'V',
        alt: true,
        shift: true,
      );

      expect(output, ['\x1bv', '\x1bV']);
    });

    test('keeps arrow keys on the keytab path', () {
      final output = <String>[];
      final terminal = Terminal(onOutput: output.add);
      terminal.setModifyOtherKeys(2);

      terminal.keyInput(TerminalKey.arrowUp, ctrl: true);

      expect(output, ['\x1b[1;5A']);
    });

    test('does not steal plain text characters at level 2', () {
      final output = <String>[];
      final terminal = Terminal(onOutput: output.add);
      terminal.setModifyOtherKeys(2);

      terminal.keyInput(TerminalKey.keyA, character: 'a');

      expect(output, isEmpty);
    });

    test('encodes plain text characters at level 3', () {
      final output = <String>[];
      final terminal = Terminal(onOutput: output.add);
      terminal.setModifyOtherKeys(3);

      terminal.keyInput(TerminalKey.keyA, character: 'a');

      expect(output, ['\x1b[27;1;97~']);
    });
  });

  group('KeytabInputHandler', () {
    test('can insert modifier code', () {
      final handler = KeytabInputHandler(
        Keytab.parse(r'key Home +AnyMod : "\E[1;*H"'),
      );

      final terminal = Terminal(inputHandler: handler);

      late String output;

      terminal.onOutput = (data) {
        output = data;
      };

      terminal.keyInput(TerminalKey.home, ctrl: true);

      expect(output, '\x1b[1;5H');

      terminal.keyInput(TerminalKey.home, shift: true);

      expect(output, '\x1b[1;2H');
    });

    test('uses VT52 mappings when ANSI mode is disabled', () {
      final outputs = <String>[];
      final terminal = Terminal(onOutput: outputs.add);

      terminal.keyInput(TerminalKey.arrowUp);
      expect(outputs.removeLast(), '\x1b[A');

      terminal.write('\x1b[?2l'); // DECANM reset -> enter VT52 mode.

      terminal.keyInput(TerminalKey.arrowUp);
      expect(outputs.removeLast(), '\x1bA');

      terminal.write('\x1b[?2h'); // DECANM set -> return to ANSI.

      terminal.keyInput(TerminalKey.arrowUp);
      expect(outputs.removeLast(), '\x1b[A');
    });
  });
}
