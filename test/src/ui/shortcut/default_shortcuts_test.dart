import 'package:flutter/foundation.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:flutter/services.dart';
import 'package:flutter/widgets.dart';
import 'package:xterm/src/ui/shortcut/shortcuts.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  tearDown(() {
    debugDefaultTargetPlatformOverride = null;
  });

  test('desktop shortcuts leave bare control keys to the terminal', () {
    debugDefaultTargetPlatformOverride = TargetPlatform.windows;

    final shortcuts = defaultTerminalShortcuts;

    bool hasActivator(bool Function(SingleActivator) predicate) {
      return shortcuts.keys.whereType<SingleActivator>().any(predicate);
    }

    // Copy / paste / select-all need Shift on Windows and Linux: bare Ctrl+C
    // must stay SIGINT for the foreground program.
    expect(
      hasActivator(
        (activator) =>
            activator.trigger == LogicalKeyboardKey.keyC &&
            activator.control &&
            activator.shift,
      ),
      isTrue,
    );

    expect(
      hasActivator(
        (activator) =>
            activator.trigger == LogicalKeyboardKey.keyC &&
            activator.control &&
            !activator.shift,
      ),
      isFalse,
    );

    expect(
      hasActivator(
        (activator) =>
            activator.trigger == LogicalKeyboardKey.keyV &&
            activator.control &&
            activator.shift,
      ),
      isTrue,
    );

    expect(
      hasActivator(
        (activator) =>
            activator.trigger == LogicalKeyboardKey.keyV &&
            activator.control &&
            !activator.shift,
      ),
      isFalse,
    );

    expect(
      hasActivator(
        (activator) =>
            activator.trigger == LogicalKeyboardKey.keyA &&
            activator.control &&
            activator.shift,
      ),
      isTrue,
    );

    expect(
      hasActivator(
        (activator) =>
            activator.trigger == LogicalKeyboardKey.keyA &&
            activator.control &&
            !activator.shift,
      ),
      isFalse,
    );

    expect(
      hasActivator(
        (activator) =>
            activator.trigger == LogicalKeyboardKey.keyX && activator.control,
      ),
      isFalse,
    );

    expect(
      hasActivator(
        (activator) =>
            activator.trigger == LogicalKeyboardKey.insert && activator.control,
      ),
      isTrue,
    );

    expect(
      hasActivator(
        (activator) =>
            activator.trigger == LogicalKeyboardKey.insert && activator.shift,
      ),
      isTrue,
    );
  });

  test('linux shortcuts preserve terminal control keys', () {
    debugDefaultTargetPlatformOverride = TargetPlatform.linux;

    final shortcuts = defaultTerminalShortcuts;

    bool hasActivator(bool Function(SingleActivator) predicate) {
      return shortcuts.keys.whereType<SingleActivator>().any(predicate);
    }

    expect(
      hasActivator(
        (activator) =>
            activator.trigger == LogicalKeyboardKey.keyC &&
            activator.control &&
            activator.shift,
      ),
      isTrue,
    );
    expect(
      hasActivator(
        (activator) =>
            activator.trigger == LogicalKeyboardKey.keyC &&
            activator.control &&
            !activator.shift,
      ),
      isFalse,
    );
    expect(
      hasActivator(
        (activator) =>
            activator.trigger == LogicalKeyboardKey.keyA &&
            activator.control &&
            !activator.shift,
      ),
      isFalse,
    );
  });

  test('macOS shortcuts use command+v for paste', () {
    debugDefaultTargetPlatformOverride = TargetPlatform.macOS;

    final shortcuts = defaultTerminalShortcuts;

    bool hasActivator(bool Function(SingleActivator) predicate) {
      return shortcuts.keys.whereType<SingleActivator>().any(predicate);
    }

    expect(
      hasActivator(
        (activator) =>
            activator.trigger == LogicalKeyboardKey.keyV &&
            activator.meta &&
            !activator.control,
      ),
      isTrue,
    );

    expect(
      hasActivator(
        (activator) =>
            activator.trigger == LogicalKeyboardKey.keyV && activator.control,
      ),
      isFalse,
    );
  });
}
