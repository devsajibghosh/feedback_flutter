/// A tiny in-memory record of the last error the queue worker swallowed and
/// the last time it synced successfully, surfaced by the long-press debug
/// dump on the marquee bar (FIX-02 §1's "never throws" and this are the same
/// contract — this just makes the swallowed error visible instead of
/// silent). Resets on app restart; that's fine, it's a diagnostic aid, not a
/// persisted log.
class DebugLog {
  DebugLog._();

  static String? lastError;

  static void record(String context, Object error, [StackTrace? stackTrace]) {
    lastError = '${DateTime.now().toIso8601String()} [$context] '
        '${error.runtimeType}: $error';
  }
}
