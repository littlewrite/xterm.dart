import 'dart:math' as math;

import 'package:flutter/painting.dart';

enum TerminalCustomGlyphType {
  solidOctantBlockVector,
  blockPattern,
  vectorShape,
}

enum TerminalCustomGlyphVectorType {
  fill,
  stroke,
}

class TerminalCustomGlyph {
  const TerminalCustomGlyph.solidOctantBlockVector(
    this.blocks,
  )   : type = TerminalCustomGlyphType.solidOctantBlockVector,
        pattern = const [],
        path = '',
        vectorType = TerminalCustomGlyphVectorType.fill,
        leftPadding = 0,
        rightPadding = 0;

  const TerminalCustomGlyph.blockPattern(
    this.pattern,
  )   : type = TerminalCustomGlyphType.blockPattern,
        blocks = const [],
        path = '',
        vectorType = TerminalCustomGlyphVectorType.fill,
        leftPadding = 0,
        rightPadding = 0;

  const TerminalCustomGlyph.vectorShape({
    required this.path,
    required this.vectorType,
    this.leftPadding = 0,
    this.rightPadding = 0,
  })  : type = TerminalCustomGlyphType.vectorShape,
        blocks = const [],
        pattern = const [];

  final TerminalCustomGlyphType type;
  final List<TerminalCustomGlyphBlock> blocks;
  final List<List<int>> pattern;
  final String path;
  final TerminalCustomGlyphVectorType vectorType;
  final double leftPadding;
  final double rightPadding;
}

class TerminalCustomGlyphBlock {
  const TerminalCustomGlyphBlock({
    required this.x,
    required this.y,
    required this.w,
    required this.h,
  });

  final int x;
  final int y;
  final int w;
  final int h;

  @override
  bool operator ==(Object other) {
    return other is TerminalCustomGlyphBlock &&
        other.x == x &&
        other.y == y &&
        other.w == w &&
        other.h == h;
  }

  @override
  int get hashCode => Object.hash(x, y, w, h);
}

class TerminalCustomGlyphRasterizer {
  const TerminalCustomGlyphRasterizer({
    required this.canvas,
    required this.offset,
    required this.cellSize,
    required this.color,
    required this.fontSize,
    required this.devicePixelRatio,
  });

  final Canvas canvas;
  final Offset offset;
  final Size cellSize;
  final Color color;
  final double fontSize;
  final double devicePixelRatio;

  void paint(TerminalCustomGlyph glyph) {
    switch (glyph.type) {
      case TerminalCustomGlyphType.solidOctantBlockVector:
        _paintSolidOctantBlocks(glyph.blocks);
        return;
      case TerminalCustomGlyphType.blockPattern:
        _paintBlockPattern(glyph.pattern);
        return;
      case TerminalCustomGlyphType.vectorShape:
        _paintVectorShape(glyph);
        return;
    }
  }

  void _paintSolidOctantBlocks(List<TerminalCustomGlyphBlock> blocks) {
    final xEighth = cellSize.width / 8;
    final yEighth = cellSize.height / 8;
    final paint = Paint()
      ..color = color
      ..isAntiAlias = false;

    for (final block in blocks) {
      canvas.drawRect(
        Rect.fromLTWH(
          offset.dx + block.x * xEighth,
          offset.dy + block.y * yEighth,
          block.w * xEighth,
          block.h * yEighth,
        ),
        paint,
      );
    }
  }

  void _paintBlockPattern(List<List<int>> pattern) {
    if (pattern.isEmpty || pattern.first.isEmpty) {
      return;
    }

    final rows = pattern.length;
    final columns = pattern.first.length;
    final paint = Paint()
      ..color = color
      ..isAntiAlias = false;
    final deviceLeft = (offset.dx * devicePixelRatio).floor();
    final deviceTop = (offset.dy * devicePixelRatio).floor();
    final deviceRight =
        ((offset.dx + cellSize.width) * devicePixelRatio).ceil();
    final deviceBottom =
        ((offset.dy + cellSize.height) * devicePixelRatio).ceil();
    final deviceWidth = math.max(1, deviceRight - deviceLeft);
    final deviceHeight = math.max(1, deviceBottom - deviceTop);
    final pixelSize = 1 / devicePixelRatio;

    canvas.save();
    canvas.clipRect(offset & cellSize);

    for (var y = 0; y < deviceHeight; y++) {
      int? runStart;
      for (var x = 0; x < deviceWidth; x++) {
        final patternX = (deviceLeft + x) % columns;
        final patternY = (deviceTop + y) % rows;
        final isFilled = pattern[patternY][patternX] != 0;

        if (isFilled) {
          runStart ??= x;
          continue;
        }

        if (runStart != null) {
          _paintPatternRun(
            paint,
            y: y,
            xStart: runStart,
            xEnd: x,
            deviceLeft: deviceLeft,
            deviceTop: deviceTop,
            pixelSize: pixelSize,
          );
          runStart = null;
        }
      }

      if (runStart != null) {
        _paintPatternRun(
          paint,
          y: y,
          xStart: runStart,
          xEnd: deviceWidth,
          deviceLeft: deviceLeft,
          deviceTop: deviceTop,
          pixelSize: pixelSize,
        );
      }
    }

    canvas.restore();
  }

  void _paintVectorShape(TerminalCustomGlyph glyph) {
    canvas.save();
    try {
      canvas.clipRect(offset & cellSize);

      final path = _buildPath(
        glyph.path,
        _vectorPadding(glyph.leftPadding),
        _vectorPadding(glyph.rightPadding),
      );
      final paint = Paint()
        ..color = color
        ..isAntiAlias = true;

      if (glyph.vectorType == TerminalCustomGlyphVectorType.stroke) {
        paint
          ..style = PaintingStyle.stroke
          ..strokeWidth = _cssLineWidth
          ..strokeCap = StrokeCap.butt
          ..strokeJoin = StrokeJoin.miter;
        canvas.drawPath(path, paint);
      } else {
        canvas.drawPath(path, paint);
      }
    } finally {
      canvas.restore();
    }
  }

  void _paintPatternRun(
    Paint paint, {
    required int y,
    required int xStart,
    required int xEnd,
    required int deviceLeft,
    required int deviceTop,
    required double pixelSize,
  }) {
    canvas.drawRect(
      Rect.fromLTWH(
        (deviceLeft + xStart) / devicePixelRatio,
        (deviceTop + y) / devicePixelRatio,
        (xEnd - xStart) * pixelSize,
        pixelSize,
      ),
      paint,
    );
  }

  double get _cssLineWidth => fontSize / 12;

  double _vectorPadding(double padding) {
    return padding * (_cssLineWidth / 2);
  }

  Path _buildPath(
    String instructions,
    double leftPadding,
    double rightPadding,
  ) {
    final path = Path();
    double currentX = 0;
    double currentY = 0;
    double lastControlX = 0;
    double lastControlY = 0;
    var lastCommand = '';

    for (final instruction in instructions.split(' ')) {
      if (instruction.isEmpty) {
        continue;
      }

      final type = instruction[0];
      if (type == 'Z') {
        path.close();
        lastCommand = type;
        continue;
      }

      final args = instruction.substring(1).split(',');
      final translatedArgs = _translateArgs(args, leftPadding, rightPadding);
      final requiredArgs = _requiredArgsForCommand(type);

      if (requiredArgs == null || translatedArgs.length < requiredArgs) {
        continue;
      }

      if (type == 'H') {
        final x = translatedArgs[0];
        path.lineTo(x, currentY);
        currentX = x;
        lastControlX = currentX;
        lastControlY = currentY;
        lastCommand = type;
        continue;
      }

      if (type == 'V') {
        final y = translatedArgs[0];
        path.lineTo(currentX, y);
        currentY = y;
        lastControlX = currentX;
        lastControlY = currentY;
        lastCommand = type;
        continue;
      }

      switch (type) {
        case 'M':
          path.moveTo(translatedArgs[0], translatedArgs[1]);
          currentX = translatedArgs[0];
          currentY = translatedArgs[1];
          lastControlX = currentX;
          lastControlY = currentY;
          break;
        case 'L':
          path.lineTo(translatedArgs[0], translatedArgs[1]);
          currentX = translatedArgs[0];
          currentY = translatedArgs[1];
          lastControlX = currentX;
          lastControlY = currentY;
          break;
        case 'Q':
          path.quadraticBezierTo(
            translatedArgs[0],
            translatedArgs[1],
            translatedArgs[2],
            translatedArgs[3],
          );
          lastControlX = translatedArgs[0];
          lastControlY = translatedArgs[1];
          currentX = translatedArgs[2];
          currentY = translatedArgs[3];
          break;
        case 'T':
          final cpX = (lastCommand == 'Q' || lastCommand == 'T')
              ? 2 * currentX - lastControlX
              : currentX;
          final cpY = (lastCommand == 'Q' || lastCommand == 'T')
              ? 2 * currentY - lastControlY
              : currentY;
          path.quadraticBezierTo(
            cpX,
            cpY,
            translatedArgs[0],
            translatedArgs[1],
          );
          lastControlX = cpX;
          lastControlY = cpY;
          currentX = translatedArgs[0];
          currentY = translatedArgs[1];
          break;
        case 'C':
          path.cubicTo(
            translatedArgs[0],
            translatedArgs[1],
            translatedArgs[2],
            translatedArgs[3],
            translatedArgs[4],
            translatedArgs[5],
          );
          lastControlX = translatedArgs[2];
          lastControlY = translatedArgs[3];
          currentX = translatedArgs[4];
          currentY = translatedArgs[5];
          break;
      }

      lastCommand = type;
    }

    return path;
  }

  int? _requiredArgsForCommand(String type) {
    switch (type) {
      case 'M':
      case 'L':
      case 'T':
        return 2;
      case 'Q':
        return 4;
      case 'C':
        return 6;
      case 'H':
      case 'V':
        return 1;
      default:
        return null;
    }
  }

  List<double> _translateArgs(
    List<String> args,
    double leftPadding,
    double rightPadding,
  ) {
    final translatedArgs = <double>[];

    for (var i = 0; i < args.length; i++) {
      final rawValue = args[i];
      if (rawValue.isEmpty) {
        continue;
      }

      final value = double.tryParse(rawValue);
      if (value == null) {
        continue;
      }

      translatedArgs.add(
        i.isEven
            ? _translateX(value, leftPadding, rightPadding)
            : _translateY(value),
      );
    }

    return translatedArgs;
  }

  double _translateX(
    double value,
    double leftPadding,
    double rightPadding,
  ) {
    final width = cellSize.width - leftPadding - rightPadding;
    final translated = value * width;
    return offset.dx + translated + leftPadding;
  }

  double _translateY(double value) {
    return offset.dy + value * cellSize.height;
  }
}

abstract class TerminalCustomGlyphs {
  static TerminalCustomGlyph? forCodePoint(int codePoint) {
    return _glyphs[codePoint];
  }

  static const _glyphs = <int, TerminalCustomGlyph>{
    0x2580: TerminalCustomGlyph.solidOctantBlockVector([
      TerminalCustomGlyphBlock(x: 0, y: 0, w: 8, h: 4),
    ]),
    0x2581: TerminalCustomGlyph.solidOctantBlockVector([
      TerminalCustomGlyphBlock(x: 0, y: 7, w: 8, h: 1),
    ]),
    0x2582: TerminalCustomGlyph.solidOctantBlockVector([
      TerminalCustomGlyphBlock(x: 0, y: 6, w: 8, h: 2),
    ]),
    0x2583: TerminalCustomGlyph.solidOctantBlockVector([
      TerminalCustomGlyphBlock(x: 0, y: 5, w: 8, h: 3),
    ]),
    0x2584: TerminalCustomGlyph.solidOctantBlockVector([
      TerminalCustomGlyphBlock(x: 0, y: 4, w: 8, h: 4),
    ]),
    0x2585: TerminalCustomGlyph.solidOctantBlockVector([
      TerminalCustomGlyphBlock(x: 0, y: 3, w: 8, h: 5),
    ]),
    0x2586: TerminalCustomGlyph.solidOctantBlockVector([
      TerminalCustomGlyphBlock(x: 0, y: 2, w: 8, h: 6),
    ]),
    0x2587: TerminalCustomGlyph.solidOctantBlockVector([
      TerminalCustomGlyphBlock(x: 0, y: 1, w: 8, h: 7),
    ]),
    0x2588: TerminalCustomGlyph.solidOctantBlockVector([
      TerminalCustomGlyphBlock(x: 0, y: 0, w: 8, h: 8),
    ]),
    0x2589: TerminalCustomGlyph.solidOctantBlockVector([
      TerminalCustomGlyphBlock(x: 0, y: 0, w: 7, h: 8),
    ]),
    0x258A: TerminalCustomGlyph.solidOctantBlockVector([
      TerminalCustomGlyphBlock(x: 0, y: 0, w: 6, h: 8),
    ]),
    0x258B: TerminalCustomGlyph.solidOctantBlockVector([
      TerminalCustomGlyphBlock(x: 0, y: 0, w: 5, h: 8),
    ]),
    0x258C: TerminalCustomGlyph.solidOctantBlockVector([
      TerminalCustomGlyphBlock(x: 0, y: 0, w: 4, h: 8),
    ]),
    0x258D: TerminalCustomGlyph.solidOctantBlockVector([
      TerminalCustomGlyphBlock(x: 0, y: 0, w: 3, h: 8),
    ]),
    0x258E: TerminalCustomGlyph.solidOctantBlockVector([
      TerminalCustomGlyphBlock(x: 0, y: 0, w: 2, h: 8),
    ]),
    0x258F: TerminalCustomGlyph.solidOctantBlockVector([
      TerminalCustomGlyphBlock(x: 0, y: 0, w: 1, h: 8),
    ]),
    0x2590: TerminalCustomGlyph.solidOctantBlockVector([
      TerminalCustomGlyphBlock(x: 4, y: 0, w: 4, h: 8),
    ]),
    0x2591: TerminalCustomGlyph.blockPattern([
      [1, 0],
      [0, 0],
    ]),
    0x2592: TerminalCustomGlyph.blockPattern([
      [1, 0],
      [0, 1],
    ]),
    0x2593: TerminalCustomGlyph.blockPattern([
      [1, 1],
      [1, 0],
    ]),
    0x2594: TerminalCustomGlyph.solidOctantBlockVector([
      TerminalCustomGlyphBlock(x: 0, y: 0, w: 8, h: 1),
    ]),
    0x2595: TerminalCustomGlyph.solidOctantBlockVector([
      TerminalCustomGlyphBlock(x: 7, y: 0, w: 1, h: 8),
    ]),
    0x2596: TerminalCustomGlyph.solidOctantBlockVector([
      TerminalCustomGlyphBlock(x: 0, y: 4, w: 4, h: 4),
    ]),
    0x2597: TerminalCustomGlyph.solidOctantBlockVector([
      TerminalCustomGlyphBlock(x: 4, y: 4, w: 4, h: 4),
    ]),
    0x2598: TerminalCustomGlyph.solidOctantBlockVector([
      TerminalCustomGlyphBlock(x: 0, y: 0, w: 4, h: 4),
    ]),
    0x2599: TerminalCustomGlyph.solidOctantBlockVector([
      TerminalCustomGlyphBlock(x: 0, y: 0, w: 4, h: 8),
      TerminalCustomGlyphBlock(x: 0, y: 4, w: 8, h: 4),
    ]),
    0x259A: TerminalCustomGlyph.solidOctantBlockVector([
      TerminalCustomGlyphBlock(x: 0, y: 0, w: 4, h: 4),
      TerminalCustomGlyphBlock(x: 4, y: 4, w: 4, h: 4),
    ]),
    0x259B: TerminalCustomGlyph.solidOctantBlockVector([
      TerminalCustomGlyphBlock(x: 0, y: 0, w: 4, h: 8),
      TerminalCustomGlyphBlock(x: 4, y: 0, w: 4, h: 4),
    ]),
    0x259C: TerminalCustomGlyph.solidOctantBlockVector([
      TerminalCustomGlyphBlock(x: 0, y: 0, w: 8, h: 4),
      TerminalCustomGlyphBlock(x: 4, y: 0, w: 4, h: 8),
    ]),
    0x259D: TerminalCustomGlyph.solidOctantBlockVector([
      TerminalCustomGlyphBlock(x: 4, y: 0, w: 4, h: 4),
    ]),
    0x259E: TerminalCustomGlyph.solidOctantBlockVector([
      TerminalCustomGlyphBlock(x: 4, y: 0, w: 4, h: 4),
      TerminalCustomGlyphBlock(x: 0, y: 4, w: 4, h: 4),
    ]),
    0x259F: TerminalCustomGlyph.solidOctantBlockVector([
      TerminalCustomGlyphBlock(x: 4, y: 0, w: 4, h: 8),
      TerminalCustomGlyphBlock(x: 0, y: 4, w: 8, h: 4),
    ]),
    0xE0B0: TerminalCustomGlyph.vectorShape(
      path: 'M0,0 L1,.5 L0,1',
      vectorType: TerminalCustomGlyphVectorType.fill,
      rightPadding: 2,
    ),
    0xE0B1: TerminalCustomGlyph.vectorShape(
      path: 'M-1,-.5 L1,.5 L-1,1.5',
      vectorType: TerminalCustomGlyphVectorType.stroke,
      leftPadding: 1,
      rightPadding: 1,
    ),
    0xE0B2: TerminalCustomGlyph.vectorShape(
      path: 'M1,0 L0,.5 L1,1',
      vectorType: TerminalCustomGlyphVectorType.fill,
      leftPadding: 2,
    ),
    0xE0B3: TerminalCustomGlyph.vectorShape(
      path: 'M2,-.5 L0,.5 L2,1.5',
      vectorType: TerminalCustomGlyphVectorType.stroke,
      leftPadding: 1,
      rightPadding: 1,
    ),
  };
}
