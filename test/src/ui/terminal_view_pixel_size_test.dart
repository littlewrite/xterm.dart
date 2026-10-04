import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:xterm/src/terminal.dart';
import 'package:xterm/src/terminal_view.dart';

/// 程序通过 `CSI 14 t` / `CSI 16 t` 问的是**设备**像素；视图把逻辑单元格尺寸
/// 乘上 devicePixelRatio 之后才交给 [Terminal.resize]，macOS 的 Retina 与
/// Windows 的 125% / 150% 缩放才报得出屏幕上真实的单元格大小。
void main() {
  Future<void> pumpView(
    WidgetTester tester,
    Terminal terminal,
    double devicePixelRatio,
  ) async {
    await tester.pumpWidget(
      MaterialApp(
        builder: (context, child) => MediaQuery(
          data: MediaQuery.of(context).copyWith(
            devicePixelRatio: devicePixelRatio,
          ),
          child: child!,
        ),
        home: Scaffold(body: TerminalView(terminal)),
      ),
    );
    await tester.pump();
  }

  testWidgets('reported cell pixel size follows devicePixelRatio', (
    tester,
  ) async {
    final resizes = <({int width, int pixelWidth, int pixelHeight})>[];
    final terminal = Terminal();
    terminal.onResize = (width, height, pixelWidth, pixelHeight) {
      resizes.add((
        width: width,
        pixelWidth: pixelWidth,
        pixelHeight: pixelHeight,
      ));
    };

    await pumpView(tester, terminal, 1.0);
    expect(resizes, isNotEmpty);
    final atOne = resizes.last;
    expect(atOne.pixelWidth, greaterThan(0));
    expect(atOne.pixelHeight, greaterThan(0));

    await pumpView(tester, terminal, 2.0);

    final atTwo = resizes.last;
    expect(atTwo.width, atOne.width, reason: '网格是逻辑尺寸，不随缩放变');
    expect(atTwo.pixelWidth, atOne.pixelWidth * 2);
    expect(atTwo.pixelHeight, atOne.pixelHeight * 2);
  });

  testWidgets('fractional display scaling keeps the grid and scales pixels', (
    tester,
  ) async {
    final resizes = <({
      int width,
      int height,
      int pixelWidth,
      int pixelHeight,
    })>[];
    final terminal = Terminal();
    terminal.onResize = (width, height, pixelWidth, pixelHeight) {
      resizes.add((
        width: width,
        height: height,
        pixelWidth: pixelWidth,
        pixelHeight: pixelHeight,
      ));
    };

    // 1.0 拿来当基准（逻辑单元格尺寸不随缩放变）。
    await pumpView(tester, terminal, 1.0);
    final base = resizes.last;

    // Windows 的 125% / 150%、以及 2.75 这种非整数倍：只允许单元格尺寸
    // 取整带来的 ±1px 误差，网格（行列数）必须一动不动。
    for (final ratio in <double>[1.25, 1.5, 2.0, 2.75]) {
      await pumpView(tester, terminal, ratio);
      final last = resizes.last;
      expect(last.width, base.width, reason: 'dpr=$ratio 网格不该变');
      expect(last.height, base.height, reason: 'dpr=$ratio 网格不该变');
      expect(
        last.pixelWidth,
        closeTo(base.pixelWidth * ratio, 1.0),
        reason: 'dpr=$ratio 单元格像素宽按缩放走',
      );
      expect(
        last.pixelHeight,
        closeTo(base.pixelHeight * ratio, 1.0),
        reason: 'dpr=$ratio 单元格像素高按缩放走',
      );

      // 报出去的文本区像素尺寸不能超过真实窗口：网格是向下取整的，最多差一格。
      final viewSize = tester.getSize(find.byType(TerminalView));
      expect(
        last.height * last.pixelHeight,
        lessThanOrEqualTo(viewSize.height * ratio + last.pixelHeight),
        reason: 'dpr=$ratio 文本区像素高不该超过窗口',
      );
      expect(
        last.width * last.pixelWidth,
        lessThanOrEqualTo(viewSize.width * ratio + last.pixelWidth),
        reason: 'dpr=$ratio 文本区像素宽不该超过窗口',
      );
    }
  });
}
