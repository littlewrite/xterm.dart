import 'dart:collection';
import 'package:xterm/src/utils/debugger.dart';

class ByteConsumer {
  final _queue = ListQueue<List<int>>();

  final _consumed = ListQueue<List<int>>();

  var _currentOffset = 0;

  var _length = 0;

  var _totalConsumed = 0;

  void add(String data) {
    if (data.isEmpty) return;
    // 允许增长：[prepend] 要在当前读取位置插入字节，块必须能 insertAll。
    final runes = data.runes.toList();
    // print("term:【${formatIntList(runes)}】"); // TODO
    // for (var i = 0; i < _queue.length; i++) {
    //   print("_queue get runes [[${formatIntList(_queue.elementAt(i))}]]");
    // }
    _queue.addLast(runes);
    _length += runes.length;
  }

  /// 把 [data] 插到当前读取位置之前，下一次 [consume] 会先返回它。
  ///
  /// 用在 tmux 透传上：还原出的内层序列必须比同一批里它后面的字节先解析，
  /// 否则正文先写屏、链接后开，文字就挂不上链接（追加到队尾做不到这一点）。
  /// 插进当前块而 `_currentOffset` 不动，字节数只加进未消费的 [_length]，
  /// [rollback] 的记账不受影响。
  void prepend(String data) {
    if (data.isEmpty) return;
    final runes = data.runes.toList(growable: false);
    if (_queue.isEmpty) {
      _queue.addFirst(runes);
    } else {
      _queue.first.insertAll(_currentOffset, runes);
    }
    _length += runes.length;
  }

  int peek() {
    final data = _queue.first;
    if (_currentOffset < data.length) {
      return data[_currentOffset];
    } else {
      final result = consume();
      rollback();
      return result;
    }
  }

  int consume() {
    final data = _queue.first;

    if (_currentOffset >= data.length) {
      _consumed.add(_queue.removeFirst());
      _currentOffset -= data.length;
      return consume();
    }

    _length--;
    _totalConsumed++;
    return data[_currentOffset++];
  }

  /// Rolls back the last [n] call.
  void rollback([int n = 1]) {
    _currentOffset -= n;
    _totalConsumed -= n;
    _length += n;
    while (_currentOffset < 0) {
      final rollback = _consumed.removeLast();
      _queue.addFirst(rollback);
      _currentOffset += rollback.length;
    }
  }

  /// Rolls back to the state when this consumer had [length] bytes.
  void rollbackTo(int length) {
    rollback(length - _length);
  }

  int get length => _length;

  int get totalConsumed => _totalConsumed;

  bool get isEmpty => _length == 0;

  bool get isNotEmpty => _length != 0;

  /// Unreferences data blocks that have been consumed. After calling this
  /// method, the consumer will not be able to roll back to consumed blocks.
  void unrefConsumedBlocks() {
    _consumed.clear();
  }

  /// Resets the consumer to its initial state.
  void reset() {
    _queue.clear();
    _consumed.clear();
    _currentOffset = 0;
    _totalConsumed = 0;
    _length = 0;
  }
}

// void main() {
//   final consumer = ByteConsumer();
//   consumer.add(Uint8List.fromList([1, 2, 3]));
//   consumer.add(Uint8List.fromList([4, 5, 6]));

//   while (consumer.isNotEmpty) {
//     print(consumer.consume());
//   }

//   consumer.rollback(5);

//   while (consumer.isNotEmpty) {
//     print(consumer.consume());
//   }

//   consumer.rollbackTo(3);

//   while (consumer.isNotEmpty) {
//     print(consumer.consume());
//   }
// }
