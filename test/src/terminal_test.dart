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

  group('Terminal.titles', () {
    test('OSC 0 clears the title when the separator is present', () {
      final titles = <String>[];
      final terminal = Terminal(onTitleChange: titles.add);

      terminal.write('\x1b]0;Build\x07');
      terminal.write('\x1b]0;\x07');

      expect(titles, ['Build', '']);
    });

    test('OSC 0 without a separator is not a title set', () {
      // `ESC ] 0 BEL` 少了分隔符，按切分规则它不是一条 0 序列 —— 清标题要写
      // `ESC ] 0 ; BEL`（也就是 `printf '\033]0;\a'`）。
      final titles = <String>[];
      final codes = <String>[];
      final terminal = Terminal(
        onTitleChange: titles.add,
        onPrivateOSC: (code, _) => codes.add(code),
      );

      terminal.write('\x1b]0\x07');

      expect(titles, isEmpty);
      expect(codes, ['0']);
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

  group('Terminal capability replies', () {
    late Terminal terminal;
    late List<String> replies;
    late List<String> output;

    setUp(() {
      output = [];
      terminal = Terminal(onOutput: output.add);
      replies = [];
      terminal.onTerminalReply = replies.add;
    });

    test('DECRPM reports the live state of an implemented mode', () {
      terminal.write('\x1b[?2004\$p');
      expect(replies, ['\x1b[?2004;2\$y']);

      replies.clear();
      terminal.write('\x1b[?2004h\x1b[?2004\$p');
      expect(replies, ['\x1b[?2004;1\$y']);
    });

    test('DECRPM reports an unimplemented mode as not recognized', () {
      terminal.write('\x1b[?2027\$p');
      expect(replies, ['\x1b[?2027;0\$y']);
    });

    test('DECRPM reports mouse tracking modes it can tell apart', () {
      terminal.write('\x1b[?1002\$p');
      expect(replies, ['\x1b[?1002;2\$y']);

      replies.clear();
      terminal.write('\x1b[?1002h\x1b[?1002\$p\x1b[?1003\$p');
      expect(replies, ['\x1b[?1002;1\$y', '\x1b[?1003;2\$y']);

      replies.clear();
      // 1000 与 1001 共用 upDownScroll：分不出是哪一个被置位，继续回未识别。
      terminal.write('\x1b[?1000h\x1b[?1000\$p\x1b[?1001\$p');
      expect(replies, ['\x1b[?1000;0\$y', '\x1b[?1001;0\$y']);
    });

    test('DECRPM reports mouse report encoding and autowrap', () {
      terminal.write('\x1b[?1006\$p');
      expect(replies, ['\x1b[?1006;2\$y']);

      replies.clear();
      terminal.write('\x1b[?1006h\x1b[?1006\$p\x1b[?1005\$p\x1b[?1015\$p');
      expect(replies, [
        '\x1b[?1006;1\$y',
        '\x1b[?1005;2\$y',
        '\x1b[?1015;2\$y',
      ]);

      replies.clear();
      terminal.write('\x1b[?7h\x1b[?7\$p');
      expect(replies, ['\x1b[?7;1\$y']);

      replies.clear();
      terminal.write('\x1b[?7l\x1b[?7\$p');
      expect(replies, ['\x1b[?7;2\$y']);
    });

    test('DECRPM needs the \$ intermediate', () {
      // Without it this is a different, unknown sequence. Answering would tell
      // a program it had queried a mode it never asked about.
      terminal.write('\x1b[?2027p');
      expect(replies, isEmpty);
    });

    test('XTVERSION answers with the reported name and version', () {
      terminal.write('\x1b[>0q');
      expect(replies, ['\x1bP>|${terminal.terminalName} 0\x1b\\']);

      replies.clear();
      terminal.terminalName = 'FaTerm';
      terminal.terminalVersion = '1.0.9';
      terminal.write('\x1b[>0q');
      expect(replies, ['\x1bP>|FaTerm 1.0.9\x1b\\']);
    });

    test('DECSCUSR (CSI Ps SP q) is not mistaken for XTVERSION', () {
      terminal.write('\x1b[5 q');
      expect(replies, isEmpty);
    });

    test('pixel-size queries go unanswered until a cell size is known', () {
      terminal.resize(40, 10);
      terminal.write('\x1b[14t\x1b[16t');
      expect(replies, isEmpty);
    });

    test('pixel-size queries report the measured cell size', () {
      terminal.resize(40, 10, 8, 16);
      terminal.write('\x1b[16t');
      expect(replies, ['\x1b[6;16;8t']);

      replies.clear();
      terminal.write('\x1b[14t');
      expect(replies, ['\x1b[4;160;320t']);
    });

    test('a zero cell size counts as unmeasured', () {
      terminal.resize(40, 10, 0, 0);
      terminal.write('\x1b[16t');
      expect(replies, isEmpty);
    });

    test('answerCapabilityQueries=false silences every new reply', () {
      terminal.resize(40, 10, 8, 16);
      terminal.answerCapabilityQueries = false;

      terminal.write('\x1b[?2004\$p\x1b[>0q\x1b[14t\x1b[16t');

      expect(replies, isEmpty);
    });

    test('capability replies never land on the user-input channel', () {
      terminal.resize(40, 10, 8, 16);
      terminal.write('\x1b[?2004\$p\x1b[>0q\x1b[14t\x1b[16t');

      expect(replies, hasLength(4));
      expect(output, isEmpty);
    });
  });

  group('Terminal DCS / APC', () {
    late Terminal terminal;
    late List<(String, List<String>)> oscCalls;

    setUp(() {
      oscCalls = [];
      terminal = Terminal(
        onPrivateOSC: (code, args) => oscCalls.add((code, args)),
      );
    });

    test('tmux passthrough is unwrapped and reaches the OSC handler', () {
      // Codex inside tmux: the OSC 9 is doubled-ESC wrapped in a DCS.
      terminal.write('\x1bPtmux;\x1b\x1b]9;Build done\x07\x1b\\');

      expect(oscCalls, hasLength(1));
      expect(oscCalls.single.$1, '9');
      expect(oscCalls.single.$2, ['Build done']);
      // 载荷不能泄漏成屏幕上的文本。
      expect(terminal.buffer.lines[0].toString(), isEmpty);
    });

    test('passthrough split across chunks still unwraps', () {
      terminal.write('\x1bPtmux;\x1b\x1b]9;Build');
      expect(oscCalls, isEmpty);

      terminal.write(' done\x07\x1b\\');

      expect(oscCalls, hasLength(1));
      expect(oscCalls.single.$2, ['Build done']);
      expect(terminal.buffer.lines[0].toString(), isEmpty);
    });

    test('passthrough with a doubled inner ST still reaches the handler', () {
      // 内层用 ST 结尾时透传写法是 `ESC ESC \`（每个字面 ESC 双写）：tmux 剥掉
      // 一个 ESC，外层终端拿到的才是真正的 ST，后面那个单 `ESC \` 才是透传本体
      // 的结束符。旧状态机会把 `ESC ESC \` 当成结束符，把整条序列截断。
      terminal.write('\x1bPtmux;\x1b\x1b]9;Build done\x1b\x1b\\\x1b\\');

      expect(oscCalls, hasLength(1));
      expect(oscCalls.single.$1, '9');
      expect(oscCalls.single.$2, ['Build done']);
      expect(terminal.buffer.lines[0].toString(), isEmpty);
    });

    test('passthrough unwraps an ST-terminated OSC 8 into a real link', () {
      // 透传里包着 OSC 8 开链/关链，正文夹在中间。内层序列必须比它后面的正文
      // 先解析，否则文字先写屏、链接后开，一个格子都挂不上。
      terminal.write(
        '\x1bPtmux;\x1b\x1b]8;;https://example.com\x1b\x1b\\\x1b\\'
        'link'
        '\x1bPtmux;\x1b\x1b]8;;\x1b\x1b\\\x1b\\',
      );

      final line = terminal.buffer.lines[0];
      expect(line.toString(), 'link');
      expect(line.getLink(0)?.uri, 'https://example.com');
      expect(line.getLink(3)?.uri, 'https://example.com');
    });

    test('a passthrough does not disturb the text around it', () {
      terminal.write('A\x1bPtmux;\x1b\x1b]9;hi\x07\x1b\\B');

      expect(terminal.buffer.lines[0].toString(), 'AB');
      expect(oscCalls, hasLength(1));
      expect(oscCalls.single.$2, ['hi']);
    });

    test('other DCS payloads are swallowed instead of printed', () {
      terminal.write('A\x1bP1\$r0m\x1b\\B');

      expect(terminal.buffer.lines[0].toString(), 'AB');
    });

    test('APC payloads are swallowed instead of printed', () {
      // Kitty graphics: unsupported, but the payload must not hit the screen.
      terminal.write('A\x1b_Ga=T,f=100;AAAA\x1b\\B');

      expect(terminal.buffer.lines[0].toString(), 'AB');
    });

    test('an over-long DCS is swallowed up to its ST, not printed', () {
      // 载荷超过收集上限之后不能交还给正文解析：那样剩下的内容会整段喷到屏幕上。
      terminal.write('A\x1bP${'x' * 20000}still-payload\x1b\\B');

      expect(terminal.buffer.lines[0].toString(), 'AB');
      expect(oscCalls, isEmpty);
    });

    test('an unterminated DCS does not stall the terminal forever', () {
      // 回滚式解析会让残缺的序列挡住后面的输出，所以扫够长度就得放弃。
      terminal.write('\x1bP${'x' * 20000}');
      expect(oscCalls, isEmpty);

      // 放弃之后继续吞到 ST：收尾被吞掉，后面的正文要恢复正常。
      terminal.write('tail\x1b\\after');

      // 会折行，所以在整块缓冲里找。
      final text = StringBuffer();
      for (var i = 0; i < terminal.buffer.lines.length; i++) {
        text.write(terminal.buffer.lines[i]);
      }
      expect(text.toString(), contains('after'));
      expect(text.toString(), isNot(contains('tail')));
    });

    test('a plain OSC 9 is unaffected', () {
      terminal.write('\x1b]9;Build done\x07');

      expect(oscCalls, hasLength(1));
      expect(oscCalls.single.$1, '9');
      expect(oscCalls.single.$2, ['Build done']);
    });
  });

  group('erase at column 0', () {
    // Regression: `Buffer.eraseLineToCursor()` passes end == 0 when the cursor
    // sits in column 0, and `eraseRange()` used to read cell `end - 1` without
    // checking `end > 0`, throwing
    // `RangeError (index): Index out of range: index must not be negative: -1`.
    test('EL 1 (erase to the left) in column 0 does not throw', () {
      final terminal = Terminal();
      terminal.write('abc\r');

      expect(() => terminal.write('\x1b[1K'), returnsNormally);
    });

    // The erase span is empty here, so nothing may be erased: the `end > 0`
    // guard only stops the wide-char look-ahead from reading index -1.
    test('EL 1 in column 0 keeps a wide char at the line start', () {
      final terminal = Terminal();
      terminal.write('切\r\x1b[1K');

      expect(terminal.buffer.lines[0].getText(), '切');
    });

    test('ED 1 (erase above + left) at the home position does not throw', () {
      final terminal = Terminal();
      terminal.write('\x1b[2J\x1b[1;1H');

      expect(() => terminal.write('\x1b[1J'), returnsNormally);
    });

    test('ECH 0 in column 0 does not throw', () {
      final terminal = Terminal();
      terminal.write('abc\r');

      expect(() => terminal.write('\x1b[0X'), returnsNormally);
    });

    test('EL 1 with the cursor after column 0 still erases to the left', () {
      final terminal = Terminal();
      terminal.write('abc\x1b[1K');

      expect(terminal.buffer.lines[0].getText(), '');
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
