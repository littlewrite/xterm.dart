import 'package:flutter/rendering.dart';
import 'package:flutter/widgets.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:xterm/src/terminal.dart';
import 'package:xterm/src/ui/controller.dart';
import 'package:xterm/src/ui/cursor_type.dart';
import 'package:xterm/src/ui/render.dart';
import 'package:xterm/src/ui/terminal_text_style.dart';
import 'package:xterm/src/ui/themes.dart';

/// N4b gate profile (perf-plan-v2).
///
/// Question: after N4a, is **traversing clean rows** (cache-hit drawPicture)
/// still expensive enough to justify an explicit dirty-range paint API?
///
/// Method: compare headless paint μs for
/// - static full viewport (all cache hits)
/// - sparse 1-char dirty among filled rows (1 miss + rest hits)
/// - full-screen miss
/// and report hit/miss counts.
///
/// Gate: implement dirty-range API only if clean-row traversal dominates the
/// sparse frame (e.g. sparse ≈ static * visibleRows/(visibleRows) with little
/// room left — i.e. miss cost is small vs hit wall-clock, OR sparse ≫ static
/// *and* profiling attributes the gap to hit-loop not miss). Prefer **not**
/// shipping N4b if sparse is already ~1 build/frame and μs is near static +
/// one-line rebuild budget.
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  const cols = 80;
  const rows = 24;
  const cellW = 9.0;
  const cellH = 18.0;
  final viewport = Size(cols * cellW, rows * cellH);

  (RenderTerminal, Terminal) makeFilled() {
    final terminal = Terminal(maxLines: 1000);
    final fill = StringBuffer();
    for (var r = 0; r < rows; r++) {
      fill.writeln('row $r ${'x' * (cols - 10)}');
    }
    terminal.write(fill.toString());

    final controller = TerminalController();
    final focusNode = FocusNode();
    final render = RenderTerminal(
      terminal: terminal,
      controller: controller,
      offset: ViewportOffset.fixed(0),
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
    return (render, terminal);
  }

  void paintOnce(RenderTerminal render) {
    final layer = ContainerLayer();
    final context = PaintingContext(
      layer,
      Rect.fromLTWH(0, 0, viewport.width, viewport.height),
    );
    render.paint(context, Offset.zero);
  }

  (double usPerFrame, int builds, int hits) measure({
    required void Function(int frame, Terminal terminal) advance,
    int warmup = 20,
    int frames = 200,
  }) {
    final (render, terminal) = makeFilled();
    for (var i = 0; i < warmup; i++) {
      advance(i, terminal);
      paintOnce(render);
    }
    render.debugPainter.resetLinePictureBuildCount();
    final sw = Stopwatch()..start();
    for (var i = 0; i < frames; i++) {
      advance(warmup + i, terminal);
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
      '  [N4b-GATE] $name: ${us.toStringAsFixed(1)} μs/frame, '
      'builds=$builds hits=$hits '
      '(~${(hits / 200).toStringAsFixed(1)} hits/frame)',
    );
  }

  test('N4b gate profile: static vs sparse vs full among filled viewport', () {
    final staticM = measure(advance: (frame, terminal) {});
    report('static-all-hits', staticM.$1, staticM.$2, staticM.$3);

    final sparseM = measure(
      advance: (frame, terminal) {
        // Keep dirty work on a visible row (home + one char).
        terminal.write('\x1b[1;1H');
        terminal.write(String.fromCharCode(33 + frame % 90));
      },
    );
    report('sparse-one-dirty', sparseM.$1, sparseM.$2, sparseM.$3);

    final fullM = measure(
      advance: (frame, terminal) {
        final buf = StringBuffer('\x1b[H');
        for (var i = 0; i < cols * rows; i++) {
          buf.writeCharCode(33 + (frame * 7 + i) % 90);
        }
        terminal.write(buf.toString());
      },
    );
    report('full-all-miss', fullM.$1, fullM.$2, fullM.$3);

    // --- Gate heuristics ---
    // Sparse should rebuild about one line/frame when dirty is on-screen.
    final buildsPerFrame = sparseM.$2 / 200.0;
    expect(buildsPerFrame, lessThan(3.0));
    expect(buildsPerFrame, greaterThan(0.5));

    // Static: zero builds; hits ≈ visible lines per frame (allow pad/rounding).
    expect(staticM.$2, 0);
    expect(staticM.$3 / 200.0, greaterThan(rows - 2));
    expect(staticM.$3 / 200.0, lessThan(rows + 6));

    final staticUs = staticM.$1;
    final sparseUs = sparseM.$1;
    final fullUs = fullM.$1;
    final missPremium = sparseUs - staticUs;
    final hitShareOfSparse =
        staticUs <= 0 ? 0.0 : (staticUs / sparseUs).clamp(0.0, 1.0);

    // ignore: avoid_print
    print(
      '  [N4b-GATE] derived: missPremium=${missPremium.toStringAsFixed(1)} μs, '
      'hitShareOfSparse=${(hitShareOfSparse * 100).toStringAsFixed(0)}%, '
      'full/static=${(fullUs / (staticUs <= 0 ? 1 : staticUs)).toStringAsFixed(1)}x, '
      'builds/frame=${buildsPerFrame.toStringAsFixed(2)}',
    );

    expect(fullUs, greaterThan(sparseUs));
    expect(sparseUs, greaterThan(0));

    // Decision aid (not a hard fail on μs noise): if hitShare is high and
    // missPremium is small vs full, dirty-range skip of clean drawPicture
    // cannot pay for itself under Flutter's "skip = blank" rule without N5.
  });
}
