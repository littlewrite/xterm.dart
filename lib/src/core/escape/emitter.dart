class EscapeEmitter {
  const EscapeEmitter();

  String primaryDeviceAttributes() {
    return '\x1b[?1;2c';
  }

  String secondaryDeviceAttributes() {
    const model = 0;
    const version = 0;
    return '\x1b[>$model;$version;0c';
  }

  String tertiaryDeviceAttributes() {
    return '\x1bP!|00000000\x1b\\';
  }

  String operatingStatus() {
    return '\x1b[0n';
  }

  String cursorPosition(int x, int y) {
    return '\x1b[$y;${x}R';
  }

  String bracketedPaste(String text) {
    return '\x1b[200~$text\x1b[201~';
  }

  String size(int rows, int cols) {
    return '\x1b[8;$rows;${cols}t';
  }

  /// `CSI ? Ps ; Pv $ y` —— 对 `CSI ? Ps $ p` 的 DECRPM 应答。
  ///
  /// [value] 按 DEC 规范：0 未识别 / 1 已置位 / 2 已复位。
  String modeReport(int mode, int value) {
    return '\x1b[?$mode;${value}\$y';
  }

  /// `DCS > | name version ST` —— 对 `CSI > Ps q` 的 XTVERSION 应答。
  String xtermVersion(String name, String version) {
    return '\x1bP>|$name $version\x1b\\';
  }

  /// `CSI 4 ; height ; width t` —— 窗口像素尺寸。
  String windowPixelSize(int height, int width) {
    return '\x1b[4;$height;${width}t';
  }

  /// `CSI 6 ; height ; width t` —— 单个单元格的像素尺寸。
  String cellPixelSize(int height, int width) {
    return '\x1b[6;$height;${width}t';
  }
}
