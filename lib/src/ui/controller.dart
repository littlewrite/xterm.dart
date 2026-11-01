import 'package:flutter/material.dart';
import 'package:meta/meta.dart';
import 'package:xterm/src/base/disposable.dart';
import 'package:xterm/src/core/buffer/cell_offset.dart';
import 'package:xterm/src/core/buffer/line.dart';
import 'package:xterm/src/core/buffer/range.dart';
import 'package:xterm/src/core/buffer/range_block.dart';
import 'package:xterm/src/core/buffer/range_line.dart';
import 'package:xterm/src/ui/pointer_input.dart';
import 'package:xterm/src/ui/selection_mode.dart';

class TerminalController with ChangeNotifier {
  TerminalController({
    SelectionMode selectionMode = SelectionMode.line,
    PointerInputs pointerInputs = const PointerInputs({PointerInput.tap}),
    bool suspendPointerInput = false,
    @Deprecated(
      'The selection-handle animation was removed and this parameter is no '
      'longer used. It is kept only to avoid breaking existing call sites.',
    )
    TickerProvider? vsync,
  })  : _selectionMode = selectionMode,
        _pointerInputs = pointerInputs,
        _suspendPointerInputs = suspendPointerInput;

  CellAnchor? _selectionBase;
  CellAnchor? _selectionExtent;

  SelectionMode get selectionMode => _selectionMode;
  SelectionMode _selectionMode;

  PointerInputs get pointerInput => _pointerInputs;
  PointerInputs _pointerInputs;

  bool get suspendedPointerInputs => _suspendPointerInputs;
  bool _suspendPointerInputs;

  List<TerminalHighlight> get highlights => _highlights;
  final _highlights = <TerminalHighlight>[];

  bool _showSearchBox = false;

  bool get showSearchBox => _showSearchBox;

  void setShowSearchBox(bool show) {
    _showSearchBox = show;
    notifyListeners();
  }

  BufferRange? get selection {
    final base = _selectionBase;
    final extent = _selectionExtent;

    if (base == null || extent == null) {
      return null;
    }

    if (!base.attached || !extent.attached) {
      return null;
    }

    return _createRange(base.offset, extent.offset);
  }

  void setSelection(CellAnchor base, CellAnchor extent, {SelectionMode? mode}) {
    _selectionBase?.dispose();
    _selectionBase = base;

    _selectionExtent?.dispose();
    _selectionExtent = extent;

    if (mode != null) {
      _selectionMode = mode;
    }

    notifyListeners();
  }

  BufferRange _createRange(CellOffset begin, CellOffset end) {
    switch (selectionMode) {
      case SelectionMode.line:
        return BufferRangeLine(begin, end);
      case SelectionMode.block:
        return BufferRangeBlock(begin, end);
    }
  }

  void setSelectionMode(SelectionMode newSelectionMode) {
    if (_selectionMode == newSelectionMode) {
      return;
    }
    _selectionMode = newSelectionMode;
    notifyListeners();
  }

  void clearSelection() {
    _selectionBase?.dispose();
    _selectionBase = null;
    _selectionExtent?.dispose();
    _selectionExtent = null;

    notifyListeners();
  }

  void setPointerInputs(PointerInputs pointerInput) {
    _pointerInputs = pointerInput;
    notifyListeners();
  }

  void setSuspendPointerInput(bool suspend) {
    _suspendPointerInputs = suspend;
    notifyListeners();
  }

  @internal
  bool shouldSendPointerInput(PointerInput pointerInput) {
    return _suspendPointerInputs
        ? false
        : _pointerInputs.inputs.contains(pointerInput);
  }

  bool _batchingHighlightChanges = false;
  int _highlightRevision = 0;
  bool _disposed = false;

  /// 批量增删高亮，期间的通知合并成结束时的一次。
  ///
  /// 渲染层每次收到通知都会重算整份高亮指纹，逐条加 n 条第 n 次就是 O(n²)；
  /// 搜索框每敲一个键都要重建整份高亮，命中上千条时会明显卡。
  void batchHighlightChanges(void Function() action) {
    if (_batchingHighlightChanges) {
      action();
      return;
    }
    final before = _highlightRevision;
    _batchingHighlightChanges = true;
    try {
      action();
    } finally {
      _batchingHighlightChanges = false;
      if (_highlightRevision != before) {
        notifyListeners();
      }
    }
  }

  @override
  void notifyListeners() {
    // 视图 dispose 时还会来清空搜索高亮，此时 controller 可能已经先一步销毁。
    if (_disposed || _batchingHighlightChanges) return;
    super.notifyListeners();
  }

  @override
  void dispose() {
    _disposed = true;
    super.dispose();
  }

  TerminalHighlight highlight({
    required CellAnchor p1,
    required CellAnchor p2,
    required Color color,
  }) {
    final highlight = TerminalHighlight(
      this,
      p1: p1,
      p2: p2,
      color: color,
    );

    _highlights.add(highlight);
    _highlightRevision++;
    notifyListeners();

    highlight.registerCallback(() {
      _highlights.remove(highlight);
      _highlightRevision++;
      notifyListeners();
    });

    return highlight;
  }
}

class TerminalHighlight with Disposable {
  final TerminalController owner;
  final CellAnchor p1;
  final CellAnchor p2;
  final Color color;

  TerminalHighlight(
    this.owner, {
    required this.p1,
    required this.p2,
    required this.color,
  });

  BufferRange? get range {
    if (!p1.attached || !p2.attached) {
      return null;
    }
    return BufferRangeLine(p1.offset, p2.offset);
  }
}
