import 'dart:convert';

/// Decodes UTF-8 chunks while holding back a character split across reads.
/// Invalid bytes become U+FFFD rather than throwing.
class Utf8StreamDecoder {
  /// The bytes of a character whose remaining bytes have not arrived yet, at
  /// most three of them.
  final List<int> _tail = [];

  /// Whether bytes of a character are being held back for the next call.
  bool get hasPending => _tail.isNotEmpty;

  /// Decodes [bytes], which continue the input of the previous call.
  String decode(List<int> bytes) {
    if (bytes.isEmpty && _tail.isEmpty) return '';

    final input = _tail.isEmpty ? bytes : <int>[..._tail, ...bytes];
    _tail.clear();

    final end = _completeLength(input);
    if (end < input.length) {
      _tail.addAll(input.getRange(end, input.length));
    }
    if (end == 0) return '';

    return utf8.decode(
      end == input.length ? input : input.sublist(0, end),
      allowMalformed: true,
    );
  }

  /// Ends the input, emitting held-back bytes as malformed data.
  String flush() {
    if (_tail.isEmpty) return '';
    final input = List<int>.of(_tail);
    _tail.clear();
    return utf8.decode(input, allowMalformed: true);
  }

  /// Where the last complete UTF-8 sequence ends.
  static int _completeLength(List<int> input) {
    final length = input.length;
    for (var back = 1; back <= 3 && back <= length; back++) {
      final byte = input[length - back];
      if (byte < 0x80) return length; // ASCII: the tail is complete
      // A continuation byte means the lead byte is further back.
      if (byte < 0xC0) continue;
      final need = _sequenceLength(byte);
      // A byte that cannot lead a sequence is malformed, not partial.
      return need == 0 || back >= need ? length : length - back;
    }
    return length;
  }

  /// Length of a sequence starting with [lead], or 0 for an invalid lead.
  static int _sequenceLength(int lead) {
    if (lead < 0xC2) return 0;
    if (lead < 0xE0) return 2;
    if (lead < 0xF0) return 3;
    if (lead <= 0xF4) return 4;
    return 0;
  }
}
