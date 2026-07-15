import 'package:xterm/src/core/buffer/line.dart';
import 'package:xterm/src/utils/circular_buffer.dart';

class _LineBuilder {
  _LineBuilder([this._capacity = 80]) {
    _result = BufferLine(_capacity);
  }

  final int _capacity;

  late BufferLine _result;

  int _length = 0;

  int get length => _length;

  bool get isEmpty => _length == 0;

  bool get isNotEmpty => _length != 0;

  /// Adds a range of cells from [src] to the builder. Anchors within the range
  /// will be reparented to the new line returned by [take].
  void add(BufferLine src, int start, int length) {
    _result.copyFrom(src, start, _length, length);
    _length += length;
  }

  /// Reuses [line] as the first output row of a logical line.
  void setBuffer(BufferLine line, int length) {
    _result = line;
    _length = length;
  }

  void addAnchor(CellAnchor anchor, int offset) {
    anchor.reparent(_result, _length + offset);
  }

  BufferLine take() {
    final result = _result;

    _result = BufferLine(_capacity);
    _length = 0;

    return result;
  }
}

/// Holds a the state of reflow operation of a single logical line.
class _LineReflow {
  final int oldWidth;

  final int newWidth;

  _LineReflow(this.oldWidth, this.newWidth);

  final _lines = <BufferLine>[];

  late final _builder = _LineBuilder(newWidth);

  /// Adds a line to the reflow operation. This method will try to reuse the
  /// given line if possible.
  void add(BufferLine line) {
    final trimmedLength = line.getTrimmedLength(oldWidth);

    // A fast path for empty lines
    if (trimmedLength == 0) {
      _lines.add(line);
      return;
    }

    if (_lines.isNotEmpty || _builder.isNotEmpty) {
      _addPart(line, from: 0, to: trimmedLength);
      return;
    }

    if (newWidth >= oldWidth) {
      _builder.setBuffer(line, trimmedLength);
      return;
    }

    _lines.add(line);

    var overflowStart = newWidth;
    if (trimmedLength > newWidth) {
      if (line.getWidth(newWidth - 1) == 2) {
        overflowStart--;
      }
      _addPart(line, from: overflowStart, to: trimmedLength);
    }

    // resize() intentionally preserves hidden cells. They must be cleared
    // after moving the overflow, otherwise selection text can expose the same
    // suffix both on this row and on its wrapped continuation.
    for (var i = overflowStart; i < trimmedLength; i++) {
      line.resetCell(i);
    }
    line.resize(newWidth);
  }

  /// Adds part of [line] from [from] to [to] to the reflow operation.
  /// Anchors within the range will be removed from [line] and reparented to
  /// the new line(s) returned by [finish].
  void _addPart(BufferLine line, {required int from, required int to}) {
    var cellsLeft = to - from;

    while (cellsLeft > 0) {
      final bufferRemainingCells = newWidth - _builder.length;

      // How many cells we should copy in this iteration.
      var cellsToCopy = cellsLeft;

      // Whether the buffer is filled up in this iteration.
      var lineFilled = false;

      if (cellsToCopy >= bufferRemainingCells) {
        cellsToCopy = bufferRemainingCells;
        lineFilled = true;
      }

      // Leave the last cell to the next iteration if it's a wide char.
      if (lineFilled && line.getWidth(from + cellsToCopy - 1) == 2) {
        cellsToCopy--;
      }

      for (var anchor in line.anchors.toList()) {
        if (anchor.x >= from && anchor.x <= from + cellsToCopy) {
          _builder.addAnchor(anchor, anchor.x - from);
        }
      }

      _builder.add(line, from, cellsToCopy);

      from += cellsToCopy;
      cellsLeft -= cellsToCopy;

      // Create a new line if the buffer is filled up.
      if (lineFilled) {
        _lines.add(_builder.take());
      }
    }

    if (line.anchors.isNotEmpty) {
      for (var anchor in line.anchors.toList()) {
        if (anchor.x >= to) {
          _builder.addAnchor(anchor, anchor.x - to);
        }
      }
    }
  }

  /// Finalizes the reflow operation and returns the result.
  List<BufferLine> finish() {
    if (_builder.isNotEmpty) {
      _lines.add(_builder.take());
    }

    for (var i = 0; i < _lines.length; i++) {
      _lines[i].isWrapped = i < _lines.length - 1;
    }

    return _lines;
  }
}

List<BufferLine> reflow(
  IndexAwareCircularBuffer<BufferLine> lines,
  int oldWidth,
  int newWidth,
) {
  final result = <BufferLine>[];

  for (var i = 0; i < lines.length; i++) {
    var line = lines[i];

    final reflow = _LineReflow(oldWidth, newWidth);

    var wrapsToNextLine = line.isWrapped;
    reflow.add(line);

    while (wrapsToNextLine && i + 1 < lines.length) {
      i++;
      line = lines[i];
      wrapsToNextLine = line.isWrapped;
      reflow.add(line);
    }

    result.addAll(reflow.finish());
  }

  for (var line in result) {
    line.resize(newWidth);
  }

  return result;
}
