import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:flutter/widgets.dart';

import 'package:xterm/src/ui/shortcut/intents.dart';

export 'intents.dart' show ShowSearchIntent;

Map<ShortcutActivator, Intent> get defaultTerminalShortcuts {
  switch (defaultTargetPlatform) {
    case TargetPlatform.android:
    case TargetPlatform.fuchsia:
    case TargetPlatform.linux:
    case TargetPlatform.windows:
      return _defaultShortcuts;
    case TargetPlatform.iOS:
    case TargetPlatform.macOS:
      return _defaultAppleShortcuts;
  }
}

final Map<ShortcutActivator, Intent> _defaultShortcuts = {
  SingleActivator(LogicalKeyboardKey.keyF, control: true):
      const ShowSearchIntent(),
  SingleActivator(LogicalKeyboardKey.keyC, control: true, shift: true):
      CopySelectionTextIntent.copy,
  SingleActivator(LogicalKeyboardKey.keyV, control: true):
      const PasteTextIntent(SelectionChangedCause.keyboard),
  SingleActivator(LogicalKeyboardKey.keyV, control: true, shift: true):
      const PasteTextIntent(SelectionChangedCause.keyboard),
  SingleActivator(LogicalKeyboardKey.keyA, control: true):
      const SelectAllTextIntent(SelectionChangedCause.keyboard),
  SingleActivator(LogicalKeyboardKey.keyX, control: true):
      CopySelectionTextIntent.cut(SelectionChangedCause.keyboard),
  SingleActivator(LogicalKeyboardKey.insert, control: true):
      CopySelectionTextIntent.copy,
  SingleActivator(LogicalKeyboardKey.insert, shift: true):
      const PasteTextIntent(SelectionChangedCause.keyboard),
  SingleActivator(LogicalKeyboardKey.delete, shift: true):
      CopySelectionTextIntent.cut(SelectionChangedCause.keyboard),
};

final Map<ShortcutActivator, Intent> _defaultAppleShortcuts = {
  SingleActivator(LogicalKeyboardKey.keyF, meta: true):
      const ShowSearchIntent(),
  SingleActivator(LogicalKeyboardKey.keyC, meta: true):
      CopySelectionTextIntent.copy,
  SingleActivator(LogicalKeyboardKey.keyV, meta: true): const PasteTextIntent(
    SelectionChangedCause.keyboard,
  ),
  SingleActivator(LogicalKeyboardKey.keyA, meta: true):
      const SelectAllTextIntent(SelectionChangedCause.keyboard),
  SingleActivator(LogicalKeyboardKey.keyX, meta: true):
      CopySelectionTextIntent.cut(SelectionChangedCause.keyboard),
};
