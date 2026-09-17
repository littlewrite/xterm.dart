import 'package:flutter_test/flutter_test.dart';
import 'package:xterm/src/core/buffer/line.dart';
import 'package:xterm/src/core/cell.dart';
import 'package:xterm/src/core/cursor.dart';
import 'package:xterm/src/terminal.dart';

/// N4a (perf-plan-v2): BufferLine.revision 与写路径一致性。
///
/// 不测 N4b 显式 dirty 区间 API。
void main() {
  group('BufferLine.revision write-path audit', () {
    test('setCell / erase / reset only bump when cells change', () {
      final line = BufferLine(4);
      final r0 = line.revision;

      line.setCell(0, 65, 1, CursorStyle.empty);
      expect(line.revision, greaterThan(r0));
      final r1 = line.revision;

      line.setCell(0, 65, 1, CursorStyle.empty);
      expect(line.revision, r1);

      line.eraseCell(0, CursorStyle.empty);
      expect(line.revision, greaterThan(r1));
      final r2 = line.revision;

      line.eraseCell(0, CursorStyle.empty);
      expect(line.revision, r2);

      line.resetCell(1); // already empty
      expect(line.revision, r2);
    });

    test('createCellData is read-only and does not bump revision', () {
      final line = BufferLine(4);
      line.setCell(0, 65, 1, CursorStyle.empty);
      final r = line.revision;

      final snap = line.createCellData(0);
      expect(snap.content & CellContent.codepointMask, 65);
      expect(line.revision, r);
      expect(line.getCodePoint(0), 65);
    });

    test('insertCells/removeCells count==0 does not bump revision', () {
      final line = BufferLine(8);
      line.setCell(0, 65, 1, CursorStyle.empty);
      final r = line.revision;

      line.insertCells(1, 0);
      expect(line.revision, r);

      line.removeCells(1, 0);
      expect(line.revision, r);
    });

    test('insertCells/removeCells with work bumps revision', () {
      final line = BufferLine(8);
      line.setCell(0, 65, 1, CursorStyle.empty);
      line.setCell(1, 66, 1, CursorStyle.empty);
      final r = line.revision;

      line.insertCells(1, 1);
      expect(line.revision, greaterThan(r));
      final r2 = line.revision;

      line.removeCells(1, 1);
      expect(line.revision, greaterThan(r2));
    });

    test('copyFrom identical payload does not bump revision', () {
      final src = BufferLine(4);
      final dst = BufferLine(4);
      src.setCell(0, 65, 1, CursorStyle.empty);
      dst.setCell(0, 65, 1, CursorStyle.empty);
      final r = dst.revision;

      dst.copyFrom(src, 0, 0, 1);
      expect(dst.revision, r);
    });

    test('copyFrom changed payload bumps revision', () {
      final src = BufferLine(4);
      final dst = BufferLine(4);
      src.setCell(0, 66, 1, CursorStyle.empty);
      dst.setCell(0, 65, 1, CursorStyle.empty);
      final r = dst.revision;

      dst.copyFrom(src, 0, 0, 1);
      expect(dst.revision, greaterThan(r));
      expect(dst.getCodePoint(0), 66);
    });

    test('resize same length is a no-op for revision', () {
      final line = BufferLine(4);
      line.setCell(0, 65, 1, CursorStyle.empty);
      final r = line.revision;
      line.resize(4);
      expect(line.revision, r);
    });

    test('eraseRange empty span does not bump revision', () {
      final line = BufferLine(4);
      line.setCell(0, 65, 1, CursorStyle.empty);
      final r = line.revision;
      line.eraseRange(2, 2, CursorStyle.empty);
      expect(line.revision, r);
    });

    test('isWrapped is not part of paint revision (documented)', () {
      // paintLine keys on revision + cell bytes; isWrapped only affects
      // selection/search text topology. Changing wrap alone must not force
      // line Picture rebuild — and today isWrapped does not call _markDirty.
      final line = BufferLine(4);
      line.setCell(0, 65, 1, CursorStyle.empty);
      final r = line.revision;
      line.isWrapped = true;
      expect(line.revision, r);
      line.isWrapped = false;
      expect(line.revision, r);
    });
  });

  group('Terminal write path bumps current line revision', () {
    test('sparse writeChar bumps only the written line', () {
      final terminal = Terminal(maxLines: 100);
      // Fill first line.
      terminal.write('hello');
      final line0 = terminal.buffer.lines[0];
      final r0 = line0.revision;
      final line1Before =
          terminal.buffer.lines.length > 1 ? terminal.buffer.lines[1].revision : null;

      terminal.write('!');
      expect(line0.revision, greaterThan(r0));
      if (line1Before != null) {
        expect(terminal.buffer.lines[1].revision, line1Before);
      }
    });

    test('erase line sequence bumps revision when cells change', () {
      final terminal = Terminal(maxLines: 100);
      terminal.write('abc');
      final line = terminal.buffer.lines[0];
      final r = line.revision;
      // EL0 erase from cursor to end — cursor after 'abc'
      terminal.write('\x1b[0K');
      // cursor is after c; erase from cursor may no-op if already empty to the right
      // Use EL2 full line erase.
      terminal.write('\x1b[2K');
      expect(line.revision, greaterThan(r));
    });
  });
}
