import 'package:flutter_test/flutter_test.dart';
import 'package:xterm/src/core/buffer/line.dart';
import 'package:xterm/src/core/cursor.dart';

void main() {
  test('BufferLine revision changes only when visual cells change', () {
    final line = BufferLine(4);
    final initialRevision = line.revision;

    line.setCell(0, 65, 1, CursorStyle.empty);
    final changedRevision = line.revision;

    expect(changedRevision, greaterThan(initialRevision));

    line.setCell(0, 65, 1, CursorStyle.empty);
    expect(line.revision, changedRevision);

    line.setCell(0, 66, 1, CursorStyle.empty);
    expect(line.revision, greaterThan(changedRevision));
  });
}
