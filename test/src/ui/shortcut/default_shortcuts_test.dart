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

  test('windows shortcuts expose common clipboard aliases', () {
    debugDefaultTargetPlatformOverride = TargetPlatform.windows;

    final shortcuts = defaultTerminalShortcuts;

    bool hasActivator(bool Function(SingleActivator) predicate) {
      return shortcuts.keys.whereType<SingleActivator>().any(predicate);
    }

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

    expect(
      hasActivator(
        (activator) =>
            activator.trigger == LogicalKeyboardKey.delete && activator.shift,
      ),
      isTrue,
    );
  });
}
