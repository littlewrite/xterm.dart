import 'package:flutter/widgets.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:xterm/ui.dart';

void main() {
  testWidgets('KeyboardVisibilty reports keyboard show and hide',
      (tester) async {
    var showCount = 0;
    var hideCount = 0;

    addTearDown(tester.view.resetViewInsets);

    await tester.pumpWidget(
      Directionality(
        textDirection: TextDirection.ltr,
        child: KeyboardVisibilty(
          onKeyboardShow: () => showCount++,
          onKeyboardHide: () => hideCount++,
          child: const SizedBox(),
        ),
      ),
    );

    tester.view.viewInsets = const FakeViewPadding(bottom: 300);
    await tester.pump();
    expect(showCount, 1);
    expect(hideCount, 0);

    tester.view.viewInsets = FakeViewPadding.zero;
    await tester.pump();
    expect(showCount, 1);
    expect(hideCount, 1);
  });
}
