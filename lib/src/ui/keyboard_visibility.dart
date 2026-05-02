import 'package:flutter/widgets.dart';

/// Legacy misspelled keyboard visibility widget kept for public API
/// compatibility.
class KeyboardVisibilty extends StatefulWidget {
  const KeyboardVisibilty({
    super.key,
    required this.child,
    this.onKeyboardShow,
    this.onKeyboardHide,
  });

  final Widget child;
  final VoidCallback? onKeyboardShow;
  final VoidCallback? onKeyboardHide;

  @override
  KeyboardVisibiltyState createState() => KeyboardVisibiltyState();
}

class KeyboardVisibiltyState extends State<KeyboardVisibilty>
    with WidgetsBindingObserver {
  double _lastBottomInset = 0.0;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    super.dispose();
  }

  @override
  void didChangeMetrics() {
    final bottomInset = View.of(context).viewInsets.bottom;
    if (bottomInset != _lastBottomInset) {
      if (bottomInset > 0) {
        widget.onKeyboardShow?.call();
      } else {
        widget.onKeyboardHide?.call();
      }
    }

    _lastBottomInset = bottomInset;
    super.didChangeMetrics();
  }

  @override
  Widget build(BuildContext context) {
    return widget.child;
  }
}

typedef KeyboardVisibility = KeyboardVisibilty;
