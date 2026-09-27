/// Bridges the feed app-bar refresh button to the feed body's pull-to-refresh.
///
/// The body's [RefreshIndicator] registers a callback that shows its spinner and
/// runs the reload; the app-bar button invokes [refresh] to trigger that exact
/// same callback. This keeps both refresh entry points on a single code path.
class FeedRefreshController {
  /// The shell's reload listener key, as registered with `SubscriptionsModel`/`GroupsModel`.
  /// A change made from inside the feed passes it back so every other feed reloads while this
  /// one stays mounted.
  final String feedKey;

  Future<void> Function()? _handler;

  FeedRefreshController(this.feedKey);

  void register(Future<void> Function() handler) {
    _handler = handler;
  }

  void unregister(Future<void> Function() handler) {
    if (identical(_handler, handler)) {
      _handler = null;
    }
  }

  Future<void> refresh() async {
    await _handler?.call();
  }
}
