import 'package:flutter_test/flutter_test.dart';
import 'package:xterm/src/core/buffer/cell_offset.dart';
import 'package:xterm/src/core/buffer/range_line.dart';
import 'package:xterm/src/terminal.dart';
import 'package:xterm/src/ui/controller.dart';

void main() {
  test('TerminalController can manage selection without vsync', () {
    final terminal = Terminal();
    terminal.resize(10, 4, 0, 0);
    terminal.write('hello');

    final controller = TerminalController();
    final base = terminal.buffer.createAnchor(0, 0);
    final extent = terminal.buffer.createAnchor(5, 0);

    controller.setSelection(base, extent);

    expect(
      controller.selection,
      BufferRangeLine(
        CellOffset(0, 0),
        CellOffset(5, 0),
      ),
    );
    expect(controller.selectionAnimation, isNull);

    controller.dispose();
  });
}
