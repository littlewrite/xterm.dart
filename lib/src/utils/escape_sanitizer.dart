/// Strips ECMA-48 escape sequences from text before it is handed to another
/// program (see `Terminal.paste`).
///
/// A naive regex for `ESC [ ... letter` plus "keep ESC in case the user pasted
/// something useful" leaves whole families of sequences intact (`OSC`, `DCS`,
/// `SS3`, single-shift character sets, lone `ESC`), and removing the `BEL` that
/// terminates an `OSC` leaves the string unterminated so the following
/// keystrokes are swallowed by it.
///
/// This scanner walks the text sequence-aware and drops entire sequences, so a
/// paste can never move the remote cursor, hide it, switch the character set,
/// or open an unterminated string. Text that is not part of a sequence is
/// copied through unchanged, including tabs and newlines.
///
/// Escape strings (`OSC`, `DCS`, `SOS`, `PM`, `APC`) are dropped up to their
/// terminator, `BEL` or `ST` (`ESC \`). A paste with an unterminated string
/// stops at the next `ESC` or C0 control instead of eating the rest of the
/// paste. The 8-bit C1 forms of these introducers (`0x9b` CSI, `0x9d` OSC, ...)
/// are dropped the same way.
String stripEscapeSequences(String text) {
  // Escaping bytes are all ASCII, so scanning UTF-16 code units is safe: a
  // surrogate pair (0xD800-0xDFFF) can never look like one.
  final buffer = StringBuffer();

  for (var i = 0; i < text.length;) {
    final lead = text.codeUnitAt(i);
    // 8-bit C1 controls are ECMA-48 introducers too (U+009B CSI, U+009D OSC,
    // ...). They are not ESC and are outside the C0 range stripped by
    // Terminal.paste, so drop them here before they reach the program.
    if (lead >= 0x80 && lead <= 0x9f) {
      i = _skipC1(text, i);
      continue;
    }
    if (lead != 0x1b) {
      buffer.writeCharCode(lead);
      i++;
      continue;
    }

    if (i + 1 >= text.length) {
      i++; // lone trailing ESC
      continue;
    }

    final intro = text.codeUnitAt(i + 1);

    // CSI: ESC [ parameter-bytes intermediate-bytes final-byte
    if (intro == 0x5b) {
      var j = i + 2;
      while (j < text.length &&
          (_isCsiParameter(text.codeUnitAt(j)) ||
              _isCsiIntermediate(text.codeUnitAt(j)))) {
        j++;
      }
      // When no final byte follows, only the ESC, `[` and the bytes that could
      // have been part of the sequence are dropped.
      if (j < text.length && _isCsiFinal(text.codeUnitAt(j))) {
        i = j + 1;
      } else {
        i = j;
      }
      continue;
    }

    // Escape strings: OSC, and the DCS / SOS / PM / APC string types.
    if (intro == 0x5d ||
        intro == 0x50 ||
        intro == 0x58 ||
        intro == 0x5e ||
        intro == 0x5f) {
      i = _skipString(text, i + 2);
      continue;
    }

    // Single-shift character selection: ESC ( , ESC ) , ESC * , ESC +
    if (intro == 0x28 || intro == 0x29 || intro == 0x2a || intro == 0x2b) {
      var j = i + 2;
      if (j < text.length) {
        // Skip the designation as a code point, not a code unit: a malformed
        // pair must not leak a lone surrogate into the paste.
        j += _isSurrogatePairAt(text, j) ? 2 : 1;
      }
      i = j;
      continue;
    }

    // Single shift (SS2/SS3): the final byte after them selects which key or
    // graphic character is meant, so it belongs to the sequence.
    if (intro == 0x4e || intro == 0x4f) {
      var j = i + 2;
      final follow = j < text.length ? text.codeUnitAt(j) : 0;
      if (follow >= 0x20 && follow <= 0x7e) {
        j++;
      }
      i = j;
      continue;
    }

    // Remaining Fe escapes (ESC 0 … ESC ~): save/restore cursor, DECOM, RIS,
    // index, ST itself, and so on. Anything that is not a valid Fe final byte
    // is treated as a stray ESC.
    if (intro >= 0x30 && intro <= 0x7e) {
      i += 2;
    } else {
      i += 1;
    }
  }

  return buffer.toString();
}

bool _isCsiParameter(int codeUnit) => codeUnit >= 0x30 && codeUnit <= 0x3f;

bool _isCsiIntermediate(int codeUnit) => codeUnit >= 0x20 && codeUnit <= 0x2f;

bool _isCsiFinal(int codeUnit) => codeUnit >= 0x40 && codeUnit <= 0x7e;

bool _isHighSurrogate(int codeUnit) => codeUnit >= 0xd800 && codeUnit <= 0xdbff;

bool _isLowSurrogate(int codeUnit) => codeUnit >= 0xdc00 && codeUnit <= 0xdfff;

bool _isSurrogatePairAt(String text, int index) =>
    _isHighSurrogate(text.codeUnitAt(index)) &&
    index + 1 < text.length &&
    _isLowSurrogate(text.codeUnitAt(index + 1));

/// Drops one 8-bit C1 control sequence. CSI (`0x9b`) consumes its parameters
/// and final byte; the string introducers consume up to `BEL` or `ST`;
/// everything else is a single control byte.
int _skipC1(String text, int index) {
  final lead = text.codeUnitAt(index);
  if (lead == 0x9b) {
    var j = index + 1;
    while (j < text.length &&
        (_isCsiParameter(text.codeUnitAt(j)) ||
            _isCsiIntermediate(text.codeUnitAt(j)))) {
      j++;
    }
    if (j < text.length && _isCsiFinal(text.codeUnitAt(j))) {
      return j + 1;
    }
    return j;
  }
  if (lead == 0x9d ||
      lead == 0x90 ||
      lead == 0x98 ||
      lead == 0x9e ||
      lead == 0x9f) {
    return _skipString(text, index + 1);
  }
  return index + 1;
}

/// Returns the index just past the escape string that starts before [start]:
/// past its `BEL` or `ST` terminator, or, when it is never terminated, just
/// past its introducer, at the next `ESC` or C0 control.
int _skipString(String text, int start) {
  for (var i = start; i < text.length; i++) {
    final codeUnit = text.codeUnitAt(i);
    if (codeUnit == 0x07) return i + 1; // BEL
    if (codeUnit == 0x9c) return i + 1; // 8-bit ST
    if (codeUnit == 0x1b) {
      if (i + 1 < text.length && text.codeUnitAt(i + 1) == 0x5c) {
        return i + 2; // ST: ESC \
      }
      return i; // a new sequence starts; leave it to the caller
    }
    if (codeUnit < 0x20) {
      return i; // unterminated: stop before the control character
    }
  }
  return text.length;
}
