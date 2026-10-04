import 'package:flutter/foundation.dart';
import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:xterm/xterm.dart';

const _openLink = '\x1b]8;;https://example.com/link\x1b\\';
const _closeLink = '\x1b]8;;\x1b\\';

Future<TerminalViewState> _pumpTerminal(
  WidgetTester tester, {
  required Terminal terminal,
  required TerminalLinkInteraction interaction,
  TerminalController? controller,
  void Function(TapUpDetails, CellOffset)? onTapUp,
  void Function(TerminalHyperlink)? onLinkTap,
  void Function(TerminalHyperlink?, Offset)? onLinkHover,
}) async {
  final key = GlobalKey<TerminalViewState>();
  await tester.pumpWidget(
    MaterialApp(
      home: Scaffold(
        body: TerminalView(
          terminal,
          key: key,
          controller: controller,
          linkInteraction: interaction,
          onTapUp: onTapUp,
          onLinkTap: onLinkTap,
          onLinkHover: onLinkHover,
        ),
      ),
    ),
  );
  await tester.pump();
  return key.currentState!;
}

Offset _cellCenter(WidgetTester tester, TerminalViewState state, int column) {
  final cellSize = state.renderTerminal.cellSize;
  final rect = tester.getRect(find.byType(TerminalView));
  return rect.topLeft +
      Offset(cellSize.width * (column + 0.5), cellSize.height * 0.5);
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  testWidgets('modifier click opens the link and does not reach onTapUp',
      (tester) async {
    final terminal = Terminal();
    terminal.write('$_openLink${'link'}$_closeLink');
    final taps = <CellOffset>[];
    TerminalHyperlink? opened;

    final state = await _pumpTerminal(
      tester,
      terminal: terminal,
      interaction: TerminalLinkInteraction.modifier,
      onTapUp: (_, offset) => taps.add(offset),
      onLinkTap: (link) => opened = link,
    );

    await tester.sendKeyDownEvent(LogicalKeyboardKey.meta);
    await tester.pump();
    await tester.tapAt(_cellCenter(tester, state, 1));
    // A single tap must outlive the double-tap disambiguation timer before
    // GestureDetector reports onTapUp.
    await tester.pump(const Duration(milliseconds: 400));
    await tester.sendKeyUpEvent(LogicalKeyboardKey.meta);

    expect(opened?.uri, 'https://example.com/link');
    expect(taps, isEmpty);
  }, variant: TargetPlatformVariant.only(TargetPlatform.macOS));

  testWidgets('plain click without the modifier keeps normal behaviour',
      (tester) async {
    final terminal = Terminal();
    terminal.write('$_openLink${'link'}$_closeLink');
    final taps = <CellOffset>[];
    TerminalHyperlink? opened;

    final state = await _pumpTerminal(
      tester,
      terminal: terminal,
      interaction: TerminalLinkInteraction.modifier,
      onTapUp: (_, offset) => taps.add(offset),
      onLinkTap: (link) => opened = link,
    );

    await tester.tapAt(_cellCenter(tester, state, 1));
    await tester.pump(const Duration(milliseconds: 400));

    expect(opened, isNull);
    expect(taps, hasLength(1));
  }, variant: TargetPlatformVariant.only(TargetPlatform.macOS));

  testWidgets('tap mode opens links without a modifier', (tester) async {
    final terminal = Terminal();
    terminal.write('$_openLink${'link'}$_closeLink');
    TerminalHyperlink? opened;

    final state = await _pumpTerminal(
      tester,
      terminal: terminal,
      interaction: TerminalLinkInteraction.always,
      onLinkTap: (link) => opened = link,
    );

    await tester.tapAt(_cellCenter(tester, state, 2));
    await tester.pump(const Duration(milliseconds: 400));

    expect(opened?.uri, 'https://example.com/link');
  }, variant: TargetPlatformVariant.only(TargetPlatform.macOS));

  testWidgets('a link drag hands back the press with a matching release', (
    tester,
  ) async {
    final output = <String>[];
    final terminal = Terminal(onOutput: output.add);
    terminal.write('$_openLink${'link'}$_closeLink');
    // 按键事件上报 + SGR 编码：程序会分别看到按下（…M）与抬起（…m）。
    terminal.write('\x1b[?1002h\x1b[?1006h');

    // tap 允许、drag 不允许：拖动不会被终端接住，于是手势在 tap 取消时把按下
    // 补发给程序 —— 松手也必须补上抬起，否则程序里的鼠标键会一直按着。
    final controller = TerminalController(
      pointerInputs: const PointerInputs({PointerInput.tap}),
    );
    final state = await _pumpTerminal(
      tester,
      terminal: terminal,
      interaction: TerminalLinkInteraction.always,
      controller: controller,
    );

    final start = _cellCenter(tester, state, 1);
    // 触摸拖拽：移动不会交给程序（没有 motion），也不会起本地选区，于是
    // tap 取消时会把按下补发给程序 —— 这是漏抬起的真实路径。
    final gesture = await tester.createGesture(kind: PointerDeviceKind.touch);
    await gesture.down(start);
    // 双击消歧计时器过去之后 onTapDown 才会拿到链接，所以先等一拍。
    await tester.pump(const Duration(milliseconds: 400));
    // 拖出 tap 的 slop（默认 18 逻辑像素），横竖都走一段。
    final cell = state.renderTerminal.cellSize;
    await gesture.moveTo(start + Offset(cell.width * 6, cell.height * 2));
    await tester.pump();
    await gesture.up();
    await tester.pump();

    final joined = output.join();
    expect(
      RegExp(r'\x1b\[<0;\d+;\d+M').hasMatch(joined),
      isTrue,
      reason: '按下应交给程序：$joined',
    );
    expect(
      RegExp(r'\x1b\[<0;\d+;\d+m').hasMatch(joined),
      isTrue,
      reason: '松手应补上抬起：$joined',
    );
  });

  testWidgets('hover reports the link only while the modifier is held',
      (tester) async {
    final terminal = Terminal();
    terminal.write('$_openLink${'link'}$_closeLink');
    final hovered = <String?>[];

    final state = await _pumpTerminal(
      tester,
      terminal: terminal,
      interaction: TerminalLinkInteraction.modifier,
      onLinkHover: (link, _) => hovered.add(link?.uri),
    );

    final gesture = await tester.createGesture(kind: PointerDeviceKind.mouse);
    final rect = tester.getRect(find.byType(TerminalView));
    final target = _cellCenter(tester, state, 1);
    await gesture.addPointer(location: rect.topLeft + const Offset(1, 1));
    await tester.pump();

    // Without the modifier the link is inert.
    await gesture.moveTo(target);
    await tester.pump();
    expect(hovered, isEmpty);

    await tester.sendKeyDownEvent(LogicalKeyboardKey.meta);
    await tester.pump();
    expect(hovered, ['https://example.com/link']);

    await tester.sendKeyUpEvent(LogicalKeyboardKey.meta);
    await tester.pump();
    expect(hovered, ['https://example.com/link', null]);

    await gesture.removePointer();
  }, variant: TargetPlatformVariant.only(TargetPlatform.macOS));

  testWidgets('output under a stationary pointer refreshes the hover',
      (tester) async {
    final terminal = Terminal();
    final hovered = <String?>[];

    final state = await _pumpTerminal(
      tester,
      terminal: terminal,
      interaction: TerminalLinkInteraction.modifier,
      onLinkHover: (link, _) => hovered.add(link?.uri),
    );

    final gesture = await tester.createGesture(kind: PointerDeviceKind.mouse);
    final rect = tester.getRect(find.byType(TerminalView));
    final target = _cellCenter(tester, state, 1);
    await gesture.addPointer(location: rect.topLeft + const Offset(1, 1));
    await tester.pump();
    await gesture.moveTo(target);
    await tester.pump();
    await tester.sendKeyDownEvent(LogicalKeyboardKey.meta);
    await tester.pump();

    terminal.write('$_openLink${'link'}$_closeLink');
    await tester.pump();
    expect(hovered, ['https://example.com/link']);

    terminal.write('\r\x1b[2Kplain');
    await tester.pump();
    expect(hovered.last, isNull);

    await tester.sendKeyUpEvent(LogicalKeyboardKey.meta);
    await gesture.removePointer();
  }, variant: TargetPlatformVariant.only(TargetPlatform.macOS));

  testWidgets('file links arm on hover and stay tappable with the modifier',
      (tester) async {
    final terminal = Terminal();
    terminal.write('\x1b]8;;file:///tmp/report.txt\x1b\\file\x1b]8;;\x1b\\');
    final hovered = <String?>[];
    TerminalHyperlink? opened;

    final state = await _pumpTerminal(
      tester,
      terminal: terminal,
      interaction: TerminalLinkInteraction.modifier,
      onLinkHover: (link, _) => hovered.add(link?.uri),
      onLinkTap: (link) => opened = link,
    );

    final gesture = await tester.createGesture(kind: PointerDeviceKind.mouse);
    final rect = tester.getRect(find.byType(TerminalView));
    await gesture.addPointer(location: rect.topLeft + const Offset(1, 1));
    await tester.pump();
    // Dashed at rest: hovering without the modifier does not arm the link.
    await gesture.moveTo(_cellCenter(tester, state, 1));
    await tester.pump();
    expect(hovered, isEmpty);

    await tester.sendKeyDownEvent(LogicalKeyboardKey.meta);
    await tester.pump();
    expect(hovered, ['file:///tmp/report.txt']);
    await gesture.removePointer();

    await tester.tapAt(_cellCenter(tester, state, 1));
    await tester.pump(const Duration(milliseconds: 400));
    expect(opened?.uri, 'file:///tmp/report.txt');
    await tester.sendKeyUpEvent(LogicalKeyboardKey.meta);
  }, variant: TargetPlatformVariant.only(TargetPlatform.macOS));

  testWidgets('plain-text URLs hover and open like OSC 8 links',
      (tester) async {
    final terminal = Terminal();
    terminal.write('  ➜  Local:   http://localhost:5173/');
    final hovered = <String?>[];
    TerminalHyperlink? opened;

    final state = await _pumpTerminal(
      tester,
      terminal: terminal,
      interaction: TerminalLinkInteraction.modifier,
      onLinkHover: (link, _) => hovered.add(link?.uri),
      onLinkTap: (link) => opened = link,
    );

    final gesture = await tester.createGesture(kind: PointerDeviceKind.mouse);
    final rect = tester.getRect(find.byType(TerminalView));
    await gesture.addPointer(location: rect.topLeft + const Offset(1, 1));
    await tester.pump();
    await tester.sendKeyDownEvent(LogicalKeyboardKey.meta);
    await tester.pump();
    // Locate the URL instead of guessing: the decorative arrow may be wide.
    final line = terminal.buffer.lines[0];
    var urlColumn = 0;
    for (var column = 0; column < line.length; column++) {
      if (line.getCodePoint(column) == 'h'.codeUnitAt(0)) {
        urlColumn = column;
        break;
      }
    }
    await gesture.moveTo(_cellCenter(tester, state, urlColumn + 5));
    await tester.pump();
    expect(hovered, ['http://localhost:5173/']);
    await gesture.removePointer();

    await tester.tapAt(_cellCenter(tester, state, urlColumn + 5));
    await tester.pump(const Duration(milliseconds: 400));
    expect(opened?.uri, 'http://localhost:5173/');
    await tester.sendKeyUpEvent(LogicalKeyboardKey.meta);
  }, variant: TargetPlatformVariant.only(TargetPlatform.macOS));
}
