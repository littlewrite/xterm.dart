import 'package:collection/collection.dart';
import 'package:flutter/widgets.dart';

const _kDefaultFontSize = 13.0;

const _kDefaultHeight = 1.2;

const _kDefaultFontFamily = 'monospace';

const _kDefaultFontFamilyFallback = [
  'MesloLGS NF',
  'MesloLGM NF',
  'MesloLGS NF',
  'MesloLGM DZ for Powerline',
  'MesloLGS DZ for Powerline',
  'Hack Nerd Font Mono',
  'Hack Nerd Font',
  'JetBrainsMono Nerd Font Mono',
  'JetBrainsMono Nerd Font',
  'CaskaydiaMono Nerd Font Mono',
  'CaskaydiaMono Nerd Font',
  'CaskaydiaCove Nerd Font Mono',
  'CaskaydiaCove Nerd Font',
  'SauceCodePro Nerd Font Mono',
  'SauceCodePro Nerd Font',
  'Symbols Nerd Font Mono',
  'Symbols Nerd Font',
  'PowerlineSymbols',
  'Menlo',
  'Monaco',
  'Consolas',
  'Liberation Mono',
  'Courier New',
  'Noto Sans Mono CJK SC',
  'Noto Sans Mono CJK TC',
  'Noto Sans Mono CJK KR',
  'Noto Sans Mono CJK JP',
  'Noto Sans Mono CJK HK',
  'Noto Color Emoji',
  'Noto Sans Symbols',
  'monospace',
  'sans-serif',
];

class TerminalStyle {
  const TerminalStyle({
    this.fontSize = _kDefaultFontSize,
    this.height = _kDefaultHeight,
    this.fontFamily = _kDefaultFontFamily,
    this.fontFamilyFallback = _kDefaultFontFamilyFallback,
    this.letterSpacing = 0,
  });

  factory TerminalStyle.fromTextStyle(TextStyle textStyle) {
    return TerminalStyle(
      fontSize: textStyle.fontSize ?? _kDefaultFontSize,
      height: textStyle.height ?? _kDefaultHeight,
      fontFamily:
          textStyle.fontFamily ??
          textStyle.fontFamilyFallback?.first ??
          _kDefaultFontFamily,
      fontFamilyFallback:
          textStyle.fontFamilyFallback ?? _kDefaultFontFamilyFallback,
      letterSpacing: textStyle.letterSpacing ?? 0,
    );
  }

  final double fontSize;

  final double height;

  final String fontFamily;

  final List<String> fontFamilyFallback;

  final double letterSpacing;

  TextStyle toTextStyle({
    Color? color,
    Color? backgroundColor,
    bool bold = false,
    bool italic = false,
    bool underline = false,
  }) {
    return TextStyle(
      fontSize: fontSize,
      height: height,
      fontFamily: fontFamily,
      fontFamilyFallback: fontFamilyFallback,
      color: color,
      backgroundColor: backgroundColor,
      fontWeight: bold ? FontWeight.bold : FontWeight.normal,
      fontStyle: italic ? FontStyle.italic : FontStyle.normal,
      decoration: underline ? TextDecoration.underline : TextDecoration.none,
      letterSpacing: letterSpacing,
    );
  }

  TerminalStyle copyWith({
    double? fontSize,
    double? height,
    String? fontFamily,
    List<String>? fontFamilyFallback,
    double? letterSpacing,
  }) {
    return TerminalStyle(
      fontSize: fontSize ?? this.fontSize,
      height: height ?? this.height,
      fontFamily: fontFamily ?? this.fontFamily,
      fontFamilyFallback: fontFamilyFallback ?? this.fontFamilyFallback,
      letterSpacing: letterSpacing ?? this.letterSpacing,
    );
  }

  /// 值相等。重要：RenderTerminal.textStyle setter 用相等检查决定是否清空
  /// 整个内容 Picture 缓存。若不做值相等，上层每次 rebuild 用 copyWith 生成
  /// 的新实例（内容相同）会被判不等，导致缓存反复被清，下一帧被迫全屏重画。
  @override
  bool operator ==(Object other) {
    if (identical(this, other)) return true;
    return other is TerminalStyle &&
        other.fontSize == fontSize &&
        other.height == height &&
        other.fontFamily == fontFamily &&
        other.letterSpacing == letterSpacing &&
        const ListEquality<String>().equals(other.fontFamilyFallback, fontFamilyFallback);
  }

  @override
  int get hashCode => Object.hash(
        fontSize,
        height,
        fontFamily,
        letterSpacing,
        Object.hashAll(fontFamilyFallback),
      );
}
