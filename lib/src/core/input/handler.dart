import 'package:xterm/src/core/input/keys.dart';
import 'package:xterm/src/core/input/keytab/keytab.dart';
import 'package:xterm/src/core/state.dart';
import 'package:xterm/src/core/platform.dart';
import 'package:xterm/src/utils/ascii.dart';

/// The key event received from the keyboard, along with the state of the
/// modifier keys and state of the terminal. Typically consumed by the
/// [TerminalInputHandler] to produce a escape sequence that can be recognized
/// by the terminal.
///
/// See also:
/// - [TerminalInputHandler]
class TerminalKeyboardEvent {
  final TerminalKey key;

  final String? character;

  final bool shift;

  final bool ctrl;

  final bool alt;

  final TerminalState state;

  final bool altBuffer;

  final TerminalTargetPlatform platform;

  TerminalKeyboardEvent({
    required this.key,
    this.character,
    required this.shift,
    required this.ctrl,
    required this.alt,
    required this.state,
    required this.altBuffer,
    required this.platform,
  });

  TerminalKeyboardEvent copyWith({
    TerminalKey? key,
    String? character,
    bool? shift,
    bool? ctrl,
    bool? alt,
    TerminalState? state,
    bool? altBuffer,
    TerminalTargetPlatform? platform,
  }) {
    return TerminalKeyboardEvent(
      key: key ?? this.key,
      character: character ?? this.character,
      shift: shift ?? this.shift,
      ctrl: ctrl ?? this.ctrl,
      alt: alt ?? this.alt,
      state: state ?? this.state,
      altBuffer: altBuffer ?? this.altBuffer,
      platform: platform ?? this.platform,
    );
  }

  @override
  String toString() {
    return 'TerminalKeyboardEvent(key: $key, character: $character, shift: $shift, ctrl: $ctrl, alt: $alt, state: $state, altBuffer: $altBuffer, platform: $platform)';
  }
}

/// TerminalInputHandler contains the logic for translating a [TerminalKeyboardEvent]
/// into escape sequences that can be recognized by the terminal.
abstract class TerminalInputHandler {
  /// Translates a [TerminalKeyboardEvent] into an escape sequence. If the event
  /// cannot be translated, null is returned.
  String? call(TerminalKeyboardEvent event);
}

/// A [TerminalInputHandler] that chains multiple handlers together. If any
/// handler returns a non-null value, it is returned. Otherwise, null is
/// returned.
class CascadeInputHandler implements TerminalInputHandler {
  final List<TerminalInputHandler> _handlers;

  const CascadeInputHandler(this._handlers);

  @override
  String? call(TerminalKeyboardEvent event) {
    for (var handler in _handlers) {
      final result = handler(event);
      if (result != null) {
        return result;
      }
    }
    return null;
  }
}

/// The default input handler for the terminal. That is composed of a
/// [KeytabInputHandler], a [CtrlInputHandler], and a [AltInputHandler].
///
/// It's possible to override the default input handler behavior by chaining
/// another input handler before or after the default input handler using
/// [CascadeInputHandler].
///
/// See also:
///  * [CascadeInputHandler]
const defaultInputHandler = CascadeInputHandler([
  ModifyOtherKeysInputHandler(),
  KeytabInputHandler(),
  CtrlInputHandler(),
  AltInputHandler(),
]);

class ModifyOtherKeysInputHandler implements TerminalInputHandler {
  const ModifyOtherKeysInputHandler();

  @override
  String? call(TerminalKeyboardEvent event) {
    final level = event.state.modifyOtherKeys;
    if (level <= 0) {
      return null;
    }

    if (!_shouldEncode(event, level)) {
      return null;
    }

    final codePoint = _codePointFor(event);
    if (codePoint == null) {
      return null;
    }

    final modifier = _modifierValue(event);

    // xterm supports two output styles for "other keys":
    // - default: CSI 27 ; modifier ; codepoint ~
    // - alternate (formatOtherKeys): CSI codepoint ; modifier u
    if (event.state.formatOtherKeys == 1) {
      return '\x1b[$codePoint;${modifier}u';
    }

    return '\x1b[27;$modifier;$codePoint~';
  }

  bool _shouldEncode(TerminalKeyboardEvent event, int level) {
    if (level == 1) {
      return _isPlainTextCharacter(event.character) &&
          (event.shift || event.ctrl);
    }

    if (level == 2 && _isPlainTextCharacter(event.character)) {
      return _hasModifiers(event);
    }

    return true;
  }

  bool _hasModifiers(TerminalKeyboardEvent event) {
    return event.shift || event.alt || event.ctrl;
  }

  int _modifierValue(TerminalKeyboardEvent event) {
    var value = 1;
    if (event.shift) value += 1;
    if (event.alt) value += 2;
    if (event.ctrl) value += 4;
    return value;
  }

  int? _codePointFor(TerminalKeyboardEvent event) {
    final character = event.character;
    if (character != null && _isPlainTextCharacter(character)) {
      return character.runes.first;
    }

    final keyCodePoint = _codePointForKey(event.key, event.shift);
    if (keyCodePoint != null) {
      return keyCodePoint;
    }

    switch (event.key) {
      case TerminalKey.enter:
      case TerminalKey.returnKey:
      case TerminalKey.numpadEnter:
        return 13;
      case TerminalKey.tab:
      case TerminalKey.backtab:
        return 9;
      case TerminalKey.escape:
        return 27;
      case TerminalKey.backspace:
      case TerminalKey.numpadBackspace:
        return 127;
      case TerminalKey.space:
        return 32;
      default:
        return null;
    }
  }

  int? _codePointForKey(TerminalKey key, bool shift) {
    if (key.index >= TerminalKey.keyA.index &&
        key.index <= TerminalKey.keyZ.index) {
      return (shift ? Ascii.A : Ascii.a) + key.index - TerminalKey.keyA.index;
    }

    if (key.index >= TerminalKey.digit1.index &&
        key.index <= TerminalKey.digit9.index) {
      return Ascii.num1 + key.index - TerminalKey.digit1.index;
    }

    if (key == TerminalKey.digit0) {
      return Ascii.num0;
    }

    return switch (key) {
      TerminalKey.minus => Ascii.minus,
      TerminalKey.equal => Ascii.equal,
      TerminalKey.bracketLeft => Ascii.openBracket,
      TerminalKey.bracketRight => Ascii.closeBracket,
      TerminalKey.backslash => Ascii.backslash,
      TerminalKey.semicolon => Ascii.semicolon,
      TerminalKey.quote => Ascii.singleQuote,
      TerminalKey.backquote => Ascii.graveAccent,
      TerminalKey.comma => Ascii.comma,
      TerminalKey.period => Ascii.dot,
      TerminalKey.slash => Ascii.slash,
      TerminalKey.numpadDivide => Ascii.slash,
      TerminalKey.numpadMultiply => Ascii.asterisk,
      TerminalKey.numpadSubtract => Ascii.minus,
      TerminalKey.numpadAdd => Ascii.plus,
      TerminalKey.numpadDecimal => Ascii.dot,
      TerminalKey.numpadEqual => Ascii.equal,
      TerminalKey.numpad0 => Ascii.num0,
      TerminalKey.numpad1 => Ascii.num1,
      TerminalKey.numpad2 => Ascii.num2,
      TerminalKey.numpad3 => Ascii.num3,
      TerminalKey.numpad4 => Ascii.num4,
      TerminalKey.numpad5 => Ascii.num5,
      TerminalKey.numpad6 => Ascii.num6,
      TerminalKey.numpad7 => Ascii.num7,
      TerminalKey.numpad8 => Ascii.num8,
      TerminalKey.numpad9 => Ascii.num9,
      _ => null,
    };
  }

  bool _isPlainTextCharacter(String? character) {
    if (character == null || character.isEmpty) {
      return false;
    }

    if (character.runes.length != 1) {
      return false;
    }

    final rune = character.runes.first;
    if (rune < 0x20 || rune == 0x7f) {
      return false;
    }

    return true;
  }
}

/// A [TerminalInputHandler] that translates key events according to a keytab
/// file. If no keytab is provided, [Keytab.defaultKeytab] is used.
class KeytabInputHandler implements TerminalInputHandler {
  const KeytabInputHandler([this.keytab]);

  final Keytab? keytab;

  @override
  String? call(TerminalKeyboardEvent event) {
    final keytab = this.keytab ?? Keytab.defaultKeytab;

    final record = keytab.find(
      event.key,
      ctrl: event.ctrl,
      alt: event.alt,
      shift: event.shift,
      ansiMode: event.state.ansiMode,
      newLineMode: event.state.lineFeedMode,
      appCursorKeys: event.state.cursorKeysMode,
      appKeyPad: event.state.appKeypadMode,
      appScreen: event.altBuffer,
      macos: event.platform == TerminalTargetPlatform.macos,
    );

    if (record == null) {
      return null;
    }

    var result = record.action.unescapedValue();
    result = insertModifiers(event, result);
    return result;
  }

  String insertModifiers(TerminalKeyboardEvent event, String action) {
    String? code;

    if (event.shift && event.alt && event.ctrl) {
      code = '8';
    } else if (event.ctrl && event.alt) {
      code = '7';
    } else if (event.shift && event.ctrl) {
      code = '6';
    } else if (event.ctrl) {
      code = '5';
    } else if (event.shift && event.alt) {
      code = '4';
    } else if (event.alt) {
      code = '3';
    } else if (event.shift) {
      code = '2';
    }

    if (code != null) {
      return action.replaceAll('*', code);
    }

    return action;
  }
}

/// A [TerminalInputHandler] that translates ctrl + key events into escape
/// sequences. For example, ctrl + a becomes ^A.
class CtrlInputHandler implements TerminalInputHandler {
  const CtrlInputHandler();

  @override
  String? call(TerminalKeyboardEvent event) {
    if (!event.ctrl || event.shift || event.alt) {
      return null;
    }

    final key = event.key;

    if (key.index >= TerminalKey.keyA.index &&
        key.index <= TerminalKey.keyZ.index) {
      final input = key.index - TerminalKey.keyA.index + 1;
      return String.fromCharCode(input);
    }

    return null;
  }
}

/// A [TerminalInputHandler] that translates alt + key events into escape
/// sequences. For example, alt + a becomes ^[a.
class AltInputHandler implements TerminalInputHandler {
  const AltInputHandler();

  @override
  String? call(TerminalKeyboardEvent event) {
    if (!event.alt || event.ctrl || event.shift) {
      return null;
    }

    if (event.platform == TerminalTargetPlatform.macos) {
      return null;
    }

    final key = event.key;

    if (key.index >= TerminalKey.keyA.index &&
        key.index <= TerminalKey.keyZ.index) {
      final charCode = key.index - TerminalKey.keyA.index + 65;
      final input = [0x1b, charCode];
      return String.fromCharCodes(input);
    }

    return null;
  }
}
