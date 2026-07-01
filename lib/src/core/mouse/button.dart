enum TerminalMouseButton {
  left(id: 0),

  middle(id: 1),

  right(id: 2),

  wheelUp(id: 64, isWheel: true),

  wheelDown(id: 65, isWheel: true),

  wheelLeft(id: 66, isWheel: true),

  wheelRight(id: 67, isWheel: true),
  ;

  /// The id that is used to report a button press or release to the terminal.
  ///
  /// Mouse wheel buttons use SGR button codes 64-67 for up, down, left, right.
  final int id;

  /// Whether this button is a mouse wheel button.
  final bool isWheel;

  const TerminalMouseButton({required this.id, this.isWheel = false});
}
