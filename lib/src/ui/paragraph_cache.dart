import 'dart:ui';

import 'package:flutter/widgets.dart';
import 'package:quiver/collection.dart';

/// Lays [text] out with [style] at [textScaler], unconstrained.
///
/// Separate from [ParagraphCache] so a caller can inspect a paragraph before
/// deciding whether to keep it. The run painter measures one against the cell
/// grid and throws it away if the font did not advance uniformly.
Paragraph buildParagraph(
  String text,
  TextStyle style,
  TextScaler textScaler,
) {
  final builder = ParagraphBuilder(style.getParagraphStyle());
  builder.pushStyle(style.getTextStyle(textScaler: textScaler));
  builder.addText(text);

  final paragraph = builder.build();
  paragraph.layout(const ParagraphConstraints(width: double.infinity));
  return paragraph;
}

/// A cache of laid out [Paragraph]s. This is used to avoid laying out the same
/// text multiple times, which is expensive.
class ParagraphCache<K extends Object> {
  ParagraphCache(int maximumSize)
      : _cache = LruMap<K, Paragraph>(maximumSize: maximumSize);

  final LruMap<K, Paragraph> _cache;

  /// Returns a [Paragraph] for the given [key]. [key] is the same as the
  /// key argument to [performAndCacheLayout].
  Paragraph? getLayoutFromCache(K key) {
    return _cache[key];
  }

  /// Applies [style] and [textScaler] to [text] and lays it out to create
  /// a [Paragraph]. The [Paragraph] is cached and can be retrieved with the
  /// same [key] by calling [getLayoutFromCache].
  Paragraph performAndCacheLayout(
    String text,
    TextStyle style,
    TextScaler textScaler,
    K key,
  ) {
    final paragraph = buildParagraph(text, style, textScaler);
    _cache[key] = paragraph;
    return paragraph;
  }

  /// Stores an already built [paragraph] under [key].
  void put(K key, Paragraph paragraph) {
    _cache[key] = paragraph;
  }

  /// Clears the cache. This should be called when the same text and style
  /// pair no longer produces the same layout. For example, when a font is
  /// loaded.
  void clear() {
    _cache.clear();
  }

  /// Returns the number of [Paragraph]s in the cache.
  int get length {
    return _cache.length;
  }
}
