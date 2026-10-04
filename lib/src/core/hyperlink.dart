/// An OSC 8 hyperlink attached to a run of terminal cells.
///
/// The same instance is shared by every cell of one hyperlink, including cells
/// on later rows that continue a link with the same `id=` parameter. That makes
/// identity comparison enough for hover/selection code.
class TerminalHyperlink {
  TerminalHyperlink({required this.uri, this.id}) : scheme = _schemeOf(uri);

  /// Target URI exactly as it arrived on the wire (never normalized).
  final String uri;

  /// The optional `id=` parameter of the opening OSC 8 sequence.
  final String? id;

  /// Lowercased URI scheme, or an empty string when the URI has none.
  final String scheme;

  /// Schemes that get the visible link affordance (underline, pointer cursor,
  /// hover tooltip). Other links can still be activated by a tap/⌘-click — they
  /// just are not advertised, which keeps files from looking like web links.
  static const _affordanceSchemes = {'http', 'https', 'mailto'};

  bool get hasVisibleAffordance => _affordanceSchemes.contains(scheme);

  /// Links whose scheme has no advertised handler (`file:`, `ssh:`, …).
  ///
  /// They are always drawn as a dashed underline so a program that emitted a
  /// real hyperlink stays discoverable without holding the modifier; only the
  /// underline style differs from web links.
  bool get hasPersistentAffordance => !hasVisibleAffordance;

  static String _schemeOf(String uri) {
    final colon = uri.indexOf(':');
    if (colon <= 0) {
      return '';
    }
    return uri.substring(0, colon).toLowerCase();
  }

  @override
  bool operator ==(Object other) {
    return other is TerminalHyperlink && other.uri == uri && other.id == id;
  }

  @override
  int get hashCode => Object.hash(uri, id);

  @override
  String toString() => 'TerminalHyperlink(${id == null ? '' : 'id=$id, '}$uri)';
}
