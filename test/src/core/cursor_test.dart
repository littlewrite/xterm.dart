import 'package:test/test.dart';
import 'package:xterm/src/core/cell.dart';
import 'package:xterm/src/core/cursor.dart';

void main() {
  test('256-colour setters clamp indices to the palette', () {
    final style = CursorStyle()
      ..setForegroundColor256(300)
      ..setBackgroundColor256(-1)
      ..setUnderlineColor256(999);

    expect(style.foreground & CellColor.valueMask, 255);
    expect(style.background & CellColor.valueMask, 0);
    expect(style.underlineColor & CellColor.valueMask, 255);
    expect(style.foreground & CellColor.typeMask, CellColor.palette);
    expect(style.background & CellColor.typeMask, CellColor.palette);
    expect(style.underlineColor & CellColor.typeMask, CellColor.palette);
  });
}
