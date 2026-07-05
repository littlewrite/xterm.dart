import 'package:flutter_test/flutter_test.dart';
import 'package:xterm/xterm.dart';

/// 验证 TerminalStyle 的值相等。
///
/// 背景：RenderTerminal.textStyle setter 用相等检查决定是否清空整个内容
/// Picture 缓存。上层（TerminalView）每次 rebuild 都用 copyWith 生成新实例，
/// 若 TerminalStyle 用默认身份相等，内容相同的新实例会被判不等，导致缓存
/// 反复清空、下一帧被迫全屏重画（实测浪费 ~73 行/帧）。
void main() {
  group('TerminalStyle 值相等', () {
    test('内容相同的不同实例应相等', () {
      const a = TerminalStyle(fontSize: 14, height: 1.2);
      const b = TerminalStyle(fontSize: 14, height: 1.2);
      expect(a == b, isTrue);
      expect(a.hashCode, b.hashCode);
    });

    test('copyWith 不改字段时与原对象相等', () {
      const a = TerminalStyle(fontSize: 14, fontFamily: 'monospace');
      final b = a.copyWith(); // 无参数 copyWith
      expect(a == b, isTrue);
    });

    test('copyWith 改字段后不等', () {
      const a = TerminalStyle(fontSize: 14);
      final b = a.copyWith(fontSize: 16);
      expect(a == b, isFalse);
    });

    test('fontFamilyFallback 内容相同时相等', () {
      const a = TerminalStyle(fontFamilyFallback: ['A', 'B']);
      const b = TerminalStyle(fontFamilyFallback: ['A', 'B']);
      expect(a == b, isTrue);
    });

    test('fontFamilyFallback 内容不同时不等', () {
      const a = TerminalStyle(fontFamilyFallback: ['A', 'B']);
      const b = TerminalStyle(fontFamilyFallback: ['A', 'C']);
      expect(a == b, isFalse);
    });
  });
}
