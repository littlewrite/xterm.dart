import 'package:test/test.dart';
import 'package:xterm/core.dart';

void main() {
  group('Terminal.inputHandler', () {
    test('can be set to null', () {
      final terminal = Terminal(inputHandler: null);
      expect(() => terminal.keyInput(TerminalKey.keyA), returnsNormally);
    });

    test('can be changed', () {
      final handler1 = _TestInputHandler();
      final handler2 = _TestInputHandler();
      final terminal = Terminal(inputHandler: handler1);

      terminal.keyInput(TerminalKey.keyA);
      expect(handler1.events, isNotEmpty);

      terminal.inputHandler = handler2;

      terminal.keyInput(TerminalKey.keyA);
      expect(handler2.events, isNotEmpty);
    });
  });

  group('Terminal.mouseInput', () {
    test('can handle mouse events', () {
      final output = <String>[];

      final terminal = Terminal(onOutput: output.add);

      terminal.mouseInput(
        TerminalMouseButton.left,
        TerminalMouseButtonState.down,
        CellOffset(10, 10),
      );

      expect(output, isEmpty);

      // enable mouse reporting
      terminal.write('\x1b[?1000h');

      terminal.mouseInput(
        TerminalMouseButton.left,
        TerminalMouseButtonState.down,
        CellOffset(10, 10),
      );

      expect(output, ['\x1B[M ++']);
    });

    test('supports sgr mouse reporting after combined mode sequence', () {
      final output = <String>[];

      final terminal = Terminal(onOutput: output.add);

      terminal.write('\x1b[?1006;1000h');

      terminal.mouseInput(
        TerminalMouseButton.left,
        TerminalMouseButtonState.down,
        CellOffset(0, 0),
      );
      terminal.mouseInput(
        TerminalMouseButton.left,
        TerminalMouseButtonState.up,
        CellOffset(0, 0),
      );

      expect(output, ['\x1B[<0;1;1M', '\x1B[<0;1;1m']);
    });

    test('reports sgr mouse wheel buttons with standard button codes', () {
      final output = <String>[];

      final terminal = Terminal(onOutput: output.add);

      terminal.write('\x1b[?1006;1000h');

      terminal.mouseInput(
        TerminalMouseButton.wheelUp,
        TerminalMouseButtonState.down,
        CellOffset(57, 20),
      );
      terminal.mouseInput(
        TerminalMouseButton.wheelDown,
        TerminalMouseButtonState.down,
        CellOffset(57, 20),
      );

      expect(output, ['\x1B[<64;58;21M', '\x1B[<65;58;21M']);
    });

    test('reports sgr horizontal wheel buttons with standard button codes', () {
      final output = <String>[];

      final terminal = Terminal(onOutput: output.add);

      terminal.write('\x1b[?1006;1000h');

      terminal.mouseInput(
        TerminalMouseButton.wheelLeft,
        TerminalMouseButtonState.down,
        CellOffset(57, 20),
      );
      terminal.mouseInput(
        TerminalMouseButton.wheelRight,
        TerminalMouseButtonState.down,
        CellOffset(57, 20),
      );

      expect(output, ['\x1B[<66;58;21M', '\x1B[<67;58;21M']);
    });

    test('reports up events in normal tracking mode', () {
      final output = <String>[];

      final terminal = Terminal(onOutput: output.add);

      terminal.write('\x1b[?1000h');

      terminal.mouseInput(
        TerminalMouseButton.left,
        TerminalMouseButtonState.down,
        CellOffset(0, 0),
      );
      terminal.mouseInput(
        TerminalMouseButton.left,
        TerminalMouseButtonState.up,
        CellOffset(0, 0),
      );

      expect(output, ['\x1B[M !!', '\x1B[M#!!']);
    });

    test('reports drag motion events in sgr drag tracking mode', () {
      final output = <String>[];

      final terminal = Terminal(onOutput: output.add);

      terminal.write('\x1b[?1006;1002h');

      terminal.mouseInput(
        TerminalMouseButton.left,
        TerminalMouseButtonState.down,
        CellOffset(0, 0),
      );
      terminal.mouseInput(
        TerminalMouseButton.left,
        TerminalMouseButtonState.down,
        CellOffset(1, 0),
        motion: true,
      );

      expect(output, ['\x1B[<0;1;1M', '\x1B[<32;2;1M']);
    });

    test('reports hover motion events in sgr any-event tracking mode', () {
      final output = <String>[];

      final terminal = Terminal(onOutput: output.add);

      terminal.write('\x1b[?1006;1003h');

      terminal.mouseInput(
        TerminalMouseButton.left,
        TerminalMouseButtonState.up,
        CellOffset(2, 3),
        motion: true,
      );

      expect(output, ['\x1B[<35;3;4M']);
    });
  });

  group('Terminal.reflowEnabled', () {
    test('prevents reflow when set to false', () {
      final terminal = Terminal(reflowEnabled: false);

      terminal.write('Hello World');
      terminal.resize(5, 5);

      expect(terminal.buffer.lines[0].toString(), 'Hello');
      expect(terminal.buffer.lines[1].toString(), isEmpty);
    });

    test('preserves hidden cells when reflow is disabled', () {
      final terminal = Terminal(reflowEnabled: false);

      terminal.write('Hello World');
      terminal.resize(5, 5);
      terminal.resize(20, 5);

      expect(terminal.buffer.lines[0].toString(), 'Hello World');
      expect(terminal.buffer.lines[1].toString(), isEmpty);
    });

    test('can be set at runtime', () {
      final terminal = Terminal(reflowEnabled: true);

      terminal.resize(5, 5);
      terminal.write('Hello World');
      terminal.reflowEnabled = false;
      terminal.resize(20, 5);

      expect(terminal.buffer.lines[0].toString(), 'Hello');
      expect(terminal.buffer.lines[1].toString(), ' Worl');
      expect(terminal.buffer.lines[2].toString(), 'd');
    });

    test('keeps the line order when reflowing a wrapped buffer', () {
      final terminal = Terminal(maxLines: 30);
      for (var i = 0; i < 60; i++) {
        terminal.write('L${i.toString().padLeft(2, '0')}\r\n');
      }

      terminal.resize(15, 24);

      final lines = terminal.buffer.lines;
      expect(lines.length, 30);
      for (var i = 0; i < 29; i++) {
        expect(lines[i].toString().trimRight(), 'L${i + 31}');
      }
      expect(lines[29].toString().trimRight(), isEmpty);
    });
  });

  group('Terminal.windowResizeRequests', () {
    test('is refused by default', () {
      final terminal = Terminal();

      terminal.resize(40, 10);
      terminal.write('\x1b[8;30;100t');

      expect(terminal.viewWidth, 40);
      expect(terminal.viewHeight, 10);
    });

    test('defaults the opt-in to off', () {
      expect(Terminal().allowCsiWindowResize, isFalse);
    });

    test('is honored when the host opts in', () {
      final terminal = Terminal(allowCsiWindowResize: true);

      terminal.resize(40, 10);
      terminal.write('\x1b[8;30;100t');

      expect(terminal.viewWidth, 100);
      expect(terminal.viewHeight, 30);
    });

    test('reports the host-owned size to the application', () {
      // The terminal answers `CSI 18 t` with `CSI 8 ; rows ; cols t` — the very
      // sequence an application uses to ask for a resize. A granted request is
      // therefore indistinguishable from a report, which is why the grid may
      // only ever follow the host.
      final terminal = Terminal();
      terminal.resize(40, 10);

      final output = <String>[];
      terminal.onOutput = output.add;

      terminal.write('\x1b[18t');

      expect(output, ['\x1b[8;10;40t']);
    });

    test('an honored request reaches the host as a resize it never asked for',
        () {
      // This is the hazard the opt-in buys: nothing on the host side changed,
      // yet the grid did, and the host is told to follow. A host that forwards
      // onResize to its pty then holds a pty, a grid and a viewport at three
      // different sizes until the next real layout.
      final terminal = Terminal(allowCsiWindowResize: true);
      terminal.resize(40, 10);

      final requested = <(int, int)>[];
      terminal.onResize =
          (width, height, _, __) => requested.add((width, height));

      terminal.write('\x1b[8;30;100t');

      expect(requested, [(100, 30)]);
    });

    test('no escape sequence moves the grid without the host asking', () {
      final terminal = Terminal();
      terminal.resize(40, 10);

      final requested = <(int, int)>[];
      terminal.onResize =
          (width, height, _, __) => requested.add((width, height));

      for (final sequence in const [
        '\x1b[8;30;100t', // Set Terminal Window Size (in characters)
        '\x1b[4;800;600t', // Set Terminal Window Size in Pixels
        '\x1b[3;10;10t', // Set Terminal Window Position
        '\x1b[9t', '\x1b[10t', '\x1b[11t', '\x1b[13t', '\x1b[14t',
        '\x1b[15t', '\x1b[16t', '\x1b[19t', '\x1b[20t', '\x1b[21t',
        '\x1b[18t', // Report Terminal Size: a query, not a resize
        '\x1b[?3h', // DECCOLM: a real xterm switches to 132 columns here
        '\x1b[?3l',
      ]) {
        terminal.write(sequence);
      }

      expect(requested, isEmpty);
      expect(terminal.viewWidth, 40);
      expect(terminal.viewHeight, 10);
    });
  });

  group('Terminal.mouseInput', () {
    test('applys to the main buffer', () {
      final terminal = Terminal(
        wordSeparators: {
          'z'.codeUnitAt(0),
        },
      );

      expect(
        terminal.mainBuffer.wordSeparators,
        contains('z'.codeUnitAt(0)),
      );
    });

    test('applys to the alternate buffer', () {
      final terminal = Terminal(
        wordSeparators: {
          'z'.codeUnitAt(0),
        },
      );

      expect(
        terminal.altBuffer.wordSeparators,
        contains('z'.codeUnitAt(0)),
      );
    });
  });

  group('Terminal.onPrivateOSC', () {
    test(r'works with \a end', () {
      String? lastCode;
      List<String>? lastData;

      final terminal = Terminal(
        onPrivateOSC: (String code, List<String> data) {
          lastCode = code;
          lastData = data;
        },
      );

      terminal.write('\x1b]6\x07');

      expect(lastCode, '6');
      expect(lastData, []);

      terminal.write('\x1b]66;hello world\x07');

      expect(lastCode, '66');
      expect(lastData, ['hello world']);

      terminal.write('\x1b]666;hello;world\x07');

      expect(lastCode, '666');
      expect(lastData, ['hello', 'world']);

      terminal.write('\x1b]hello;world\x07');

      expect(lastCode, 'hello');
      expect(lastData, ['world']);
    });

    test(r'works with \x1b\ end', () {
      String? lastCode;
      List<String>? lastData;

      final terminal = Terminal(
        onPrivateOSC: (String code, List<String> data) {
          lastCode = code;
          lastData = data;
        },
      );

      terminal.write('\x1b]6\x1b\\');

      expect(lastCode, '6');
      expect(lastData, []);

      terminal.write('\x1b]66;hello world\x1b\\');

      expect(lastCode, '66');
      expect(lastData, ['hello world']);

      terminal.write('\x1b]666;hello;world\x1b\\');

      expect(lastCode, '666');
      expect(lastData, ['hello', 'world']);

      terminal.write('\x1b]hello;world\x1b\\');

      expect(lastCode, 'hello');
      expect(lastData, ['world']);
    });

    test('do not receive common osc', () {
      String? lastCode;
      List<String>? lastData;

      final terminal = Terminal(
        onPrivateOSC: (String code, List<String> data) {
          lastCode = code;
          lastData = data;
        },
      );

      terminal.write('\x1b]0;hello world\x07');

      expect(lastCode, isNull);
      expect(lastData, isNull);
    });
  });

  group('Terminal.sgr', () {
    test('does not treat underline subparameters as background colors', () {
      final terminal = Terminal(maxLines: 10);

      terminal.write('\x1b[4:3mA');

      final line = terminal.buffer.lines[0];
      expect(line.getAttributes(0) & CellAttr.underline, isNot(0));
      expect(line.getBackground(0), 0);
    });

    test('supports disabling underline via sgr subparameters', () {
      final terminal = Terminal(maxLines: 10);

      terminal.write('\x1b[4mA\x1b[4:0mB');

      final line = terminal.buffer.lines[0];
      expect(line.getAttributes(0) & CellAttr.underline, isNot(0));
      expect(line.getAttributes(1) & CellAttr.underline, 0);
    });

    test('resets bold and faint intensity with sgr 22', () {
      final terminal = Terminal();

      terminal.write('\x1b[1mA\x1b[2mB\x1b[22mC');

      final line = terminal.buffer.lines[0];
      expect(line.getAttributes(0) & CellAttr.bold, isNot(0));
      expect(line.getAttributes(1) & CellAttr.bold, isNot(0));
      expect(line.getAttributes(1) & CellAttr.faint, isNot(0));
      expect(line.getAttributes(2) & CellAttr.bold, 0);
      expect(line.getAttributes(2) & CellAttr.faint, 0);
    });
  });

  group('Terminal.osc52', () {
    test('routes OSC 52 clipboard payloads to onClipboard', () {
      String? selection;
      String? payload;

      final terminal = Terminal(
        onClipboard: (oscSelection, oscData) {
          selection = oscSelection;
          payload = oscData;
        },
      );

      terminal.write('\x1b]52;c;aGVsbG8=\x07');

      expect(selection, 'c');
      expect(payload, 'aGVsbG8=');
      expect(Terminal.decodeOsc52Payload(payload!), 'hello');
    });
  });
}

class _TestInputHandler implements TerminalInputHandler {
  final events = <TerminalKeyboardEvent>[];

  @override
  String? call(TerminalKeyboardEvent event) {
    events.add(event);
    return null;
  }
}
