import 'package:flutter_test/flutter_test.dart';
import 'package:xterm/src/core/buffer/buffer.dart';
import 'package:xterm/src/terminal.dart';

/// 行级 dirty 追踪的正确性测试。
///
/// 这些测试验证：buffer 层在各类写入操作后，正确标记哪些行变了。
/// 渲染层（render.dart）依赖这些标记决定只重画哪些行——**漏标 = 画面
/// 不更新（用户可见 bug）**，所以这里覆盖所有写入路径。
///
/// 注意：dirty 以相对索引（lines[i] 的 i）记录。
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  late Terminal terminal;
  late Buffer buffer;

  setUp(() {
    // viewWidth=80, viewHeight=24（Terminal 默认）
    terminal = Terminal(maxLines: 1000);
    buffer = terminal.buffer;
    // 首次构造时 dirty 应是全脏（_allDirty=true），清掉以便测试。
    buffer.clearDirty();
  });

  /// 取当前 dirty 集合并清空，便于断言。
  Set<int> consumeDirty() {
    final r = buffer.takeDirtyLines();
    buffer.clearDirty();
    if (r.allDirty) {
      // 用哨兵表示"全脏"。测试里明确断言 allDirty。
      return {for (var i = 0; i < buffer.height; i++) i};
    }
    return r.lines;
  }

  group('单行写入', () {
    test('writeChar 标脏光标所在行', () {
      // 初始光标在 (0,0)，写入应标脏第 scrollBack+0 行（绝对索引）
      // 但相对索引下，初始 height==viewHeight==24，scrollBack=0，
      // absoluteCursorY=0。
      terminal.write('A');
      final dirty = consumeDirty();
      // 写 'A' 在行 0
      expect(dirty, contains(0));
      // 不应全脏
      expect(dirty.length, lessThan(buffer.height));
    });

    test('连续 writeChar 同行只标该行', () {
      terminal.write('hello');
      final dirty = consumeDirty();
      expect(dirty, contains(0));
      // 全在同一行
      expect(dirty.every((i) => i == 0), isTrue);
    });

    test('换行后写入标脏新行', () {
      terminal.write('abc\n');
      // \n → lineFeed → index 移到行1（main buffer 非底部，moveCursorY(1)）
      terminal.write('d');
      final dirty = consumeDirty();
      expect(dirty, contains(0)); // 'abc' 在行0
      expect(dirty, contains(1)); // 'd' 在行1
    });
  });

  group('erase 操作', () {
    test('eraseLine (CSI 2K) 只标脏当前行', () {
      terminal.write('hello\n');
      terminal.write('world\n');
      buffer.clearDirty(); // 清掉前面写入的脏

      // 光标现在在第2行，CSI 2K = eraseLine
      terminal.write('\x1b[2K');
      final dirty = consumeDirty();
      // 只标脏光标行
      expect(dirty.length, equals(1));
    });

    test('eraseLineFromCursor (CSI K) 标脏当前行', () {
      terminal.write('hello world\n');
      buffer.clearDirty();
      // CSI K = eraseLineFromCursor
      terminal.write('\x1b[K');
      final dirty = consumeDirty();
      expect(dirty.length, equals(1));
    });

    test('eraseDisplay (CSI 2J) 标范围（多行，非全脏）', () {
      terminal.write('line1\nline2\nline3\n');
      buffer.clearDirty();
      // CSI 2J = eraseDisplay
      terminal.write('\x1b[2J');
      final r = buffer.takeDirtyLines();
      expect(r.allDirty, isFalse); // eraseDisplay 标范围非全脏
      buffer.clearDirty();
      // 至少覆盖视口多行
      expect(r.lines.length, greaterThan(1));
    });
  });

  group('结构变化（应全脏）', () {
    test('clear 全脏', () {
      terminal.write('something');
      buffer.clearDirty();
      buffer.clear();
      final r = buffer.takeDirtyLines();
      expect(r.allDirty, isTrue);
      buffer.clearDirty();
    });

    test('resize 全脏', () {
      terminal.write('something');
      buffer.clearDirty();
      terminal.resize(100, 30);
      final r = buffer.takeDirtyLines();
      expect(r.allDirty, isTrue);
      buffer.clearDirty();
    });
  });

  group('滚屏（alt buffer 全脏）', () {
    test('alt buffer 滚屏全脏', () {
      // 进入 alt buffer（许多程序如 vim 用）
      terminal.write('\x1b[?1049h'); // 切到 alt buffer
      // 重新拿 alt buffer 引用
      final altBuffer = terminal.buffer;
      altBuffer.clearDirty();

      // 填满屏幕后继续写，触发 scrollUp
      for (var i = 0; i < 30; i++) {
        terminal.write('line $i\n');
      }
      final r = altBuffer.takeDirtyLines();
      expect(r.allDirty, isTrue);
      altBuffer.clearDirty();
    });
  });

  group('消费语义', () {
    test('clearDirty 后 dirty 为空', () {
      terminal.write('x');
      buffer.clearDirty();
      final r = buffer.takeDirtyLines();
      expect(r.allDirty, isFalse);
      expect(r.lines, isEmpty);
    });

    test('takeDirtyLines 后 dirty 状态保留直到 clearDirty', () {
      terminal.write('x');
      final r1 = buffer.takeDirtyLines();
      final r2 = buffer.takeDirtyLines();
      // 未 clearDirty 前，两次 take 应一致（paint 失败时不会丢标记）
      expect(r2.allDirty, equals(r1.allDirty));
      expect(r2.lines, equals(r1.lines));
    });
  });
}
