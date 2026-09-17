import 'package:flutter/rendering.dart';
import 'package:flutter/widgets.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:xterm/src/terminal.dart';
import 'package:xterm/src/ui/controller.dart';
import 'package:xterm/src/ui/cursor_type.dart';
import 'package:xterm/src/ui/render.dart';
import 'package:xterm/src/ui/terminal_text_style.dart';
import 'package:xterm/src/ui/themes.dart';

/// N5 gate profile (perf-plan-v2).
///
/// After N4a, is scroll-output / tail-f still expensive enough to justify a
/// whole-viewport scroll Picture reuse path?
///
/// Compare static (all hits) vs scroll-output (new lines + stick layout) vs
/// full-screen miss. Implement N5 only if scroll-output is a large fraction of
/// full-miss **and** builds/frame show multi-line thrash. Otherwise reject.
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  const cols = 80;
  const rows = 24;
  const cellW = 9.0;
  const cellH = 18.0;
  final viewport = Size(cols * cellW, rows * cellH);

  (RenderTerminal, Terminal, PipelineOwner) makeFilled() {
    final terminal = Terminal(maxLines: 1000);
    final fill = StringBuffer();
    for (var r = 0; r < rows * 4; r++) {
      fill.writeln('row $r ${'x' * (cols - 10)}');
    }
    terminal.write(fill.toString());

    final controller = TerminalController();
    final focusNode = FocusNode();
    // fixed(0) still accepts correctBy from stick-to-bottom during layout.
    final offset = ViewportOffset.fixed(0);
    final render = RenderTerminal(
      terminal: terminal,
      controller: controller,
      offset: offset,
      padding: EdgeInsets.zero,
      autoResize: false,
      textStyle: const TerminalStyle(),
      textScaler: TextScaler.noScaling,
      theme: TerminalThemes.defaultTheme,
      focusNode: focusNode,
      cursorType: TerminalCursorType.block,
      cursorBlinkEnabled: false,
      cursorBlinkVisible: true,
      alwaysShowCursor: false,
      paintCursor: false,
    );
    final owner = PipelineOwner();
    render.attach(owner);
    render.layout(BoxConstraints.tight(viewport), parentUsesSize: true);
    owner.flushLayout();

    addTearDown(() {
      render.detach();
      controller.dispose();
      focusNode.dispose();
    });
    return (render, terminal, owner);
  }

  void paintOnce(RenderTerminal render) {
    final layer = ContainerLayer();
    final context = PaintingContext(
      layer,
      Rect.fromLTWH(0, 0, viewport.width, viewport.height),
    );
    render.paint(context, Offset.zero);
  }

  (double us, int builds, int hits) measure({
    required void Function(
      int frame,
      RenderTerminal render,
      Terminal terminal,
      PipelineOwner owner,
    ) advance,
    int warmup = 20,
    int frames = 200,
  }) {
    final (render, terminal, owner) = makeFilled();
    for (var i = 0; i < warmup; i++) {
      advance(i, render, terminal, owner);
      paintOnce(render);
    }
    render.debugPainter.resetLinePictureBuildCount();
    final sw = Stopwatch()..start();
    for (var i = 0; i < frames; i++) {
      advance(warmup + i, render, terminal, owner);
      paintOnce(render);
    }
    sw.stop();
    return (
      sw.elapsedMicroseconds / frames,
      render.debugPainter.linePictureBuildCount,
      render.debugPainter.linePictureCacheHitCount,
    );
  }

  void report(String name, double us, int builds, int hits) {
    // ignore: avoid_print
    print(
      '  [N5-GATE] $name: ${us.toStringAsFixed(1)} μs/frame, '
      'builds=$builds hits=$hits '
      '(~${(builds / 200).toStringAsFixed(2)} builds/frame, '
      '~${(hits / 200).toStringAsFixed(1)} hits/frame)',
    );
  }

  test('N5 gate profile: static vs scroll-output vs full', () {
    final staticM = measure(
      advance: (frame, render, terminal, owner) {},
    );
    report('static-filled', staticM.$1, staticM.$2, staticM.$3);

    final scrollOutM = measure(
      advance: (frame, render, terminal, owner) {
        // Same shape as render_benchmark_test scroll-output.
        terminal.write('line $frame: the quick brown fox jumps\r\n');
        render.markNeedsLayout();
        owner.flushLayout();
      },
    );
    report('scroll-output', scrollOutM.$1, scrollOutM.$2, scrollOutM.$3);

    final fullM = measure(
      advance: (frame, render, terminal, owner) {
        final buf = StringBuffer('\x1b[H');
        for (var i = 0; i < cols * rows; i++) {
          buf.writeCharCode(33 + (frame * 7 + i) % 90);
        }
        terminal.write(buf.toString());
      },
    );
    report('full-all-miss', fullM.$1, fullM.$2, fullM.$3);

    final buildsPerFrame = scrollOutM.$2 / 200.0;
    final scrollUs = scrollOutM.$1;
    final staticUs = staticM.$1;
    final fullUs = fullM.$1;
    final scrollPremium = scrollUs - staticUs;
    final scrollShareOfFull =
        fullUs <= 0 ? 0.0 : (scrollUs / fullUs).clamp(0.0, 1.0);

    // ignore: avoid_print
    print(
      '  [N5-GATE] derived: scrollPremium=${scrollPremium.toStringAsFixed(1)} μs, '
      'scroll/full=${(scrollShareOfFull * 100).toStringAsFixed(0)}%, '
      'builds/frame=${buildsPerFrame.toStringAsFixed(2)}, '
      'full/static=${(fullUs / (staticUs <= 0 ? 1 : staticUs)).toStringAsFixed(1)}x',
    );

    // Scroll should not thrash like full-screen (revision + line cache).
    expect(buildsPerFrame, lessThan(rows.toDouble()));
    expect(scrollUs, greaterThan(0));
    expect(fullUs, greaterThan(scrollUs * 0.5));
  });
}
