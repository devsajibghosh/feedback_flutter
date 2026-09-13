import 'dart:async';
import 'dart:math' as math;

import 'package:connectivity_plus/connectivity_plus.dart';
import 'package:dio/dio.dart';
import 'package:meta/meta.dart';

import '../models/feedback_entry.dart';
import 'api_service.dart';
import 'crash_log.dart';
import 'db_service.dart';

/// Local-first submit plus a background queue worker (FIX-02 §1 — this
/// supersedes SPEC.md §4.7 and §4.8 entirely).
///
/// Submitting a feedback is a single SQLite insert. The network is never in
/// that path: [submit] returns as soon as the row is written, whether the
/// device is online, offline, or on a terrible connection. A single
/// long-lived instance of this class is created once in `main()` and
/// [start]ed once — it must never be owned by a widget, since it has to
/// keep draining the queue for the life of the app regardless of which
/// screen is on top.
class SyncService {
  SyncService({ApiService? api, DbService? db})
      : _api = api ?? ApiService(),
        _db = db ?? DbService();

  static const _firstAttemptDelay = Duration(seconds: 5);
  static const _regularInterval = Duration(seconds: 30);
  static const _maxBackoff = Duration(minutes: 15);
  static const _retention = Duration(days: 7);

  /// FIX-06 §1: negative feedback (`poor`, `very_poor`) is time-sensitive
  /// and drains in full every tick; positive feedback is throttled to one
  /// row per tick regardless of how many are waiting, since it carries no
  /// urgency and is the higher-volume side on a working ward.
  static const _negativeRatings = ['poor', 'very_poor'];
  static const _positiveRatings = ['very_good', 'good', 'satisfactory'];

  /// Gap between consecutive negative-row uploads within one tick, so a
  /// large backlog doesn't arrive at the server as one burst.
  static const _interRowGap = Duration(milliseconds: 400);

  final ApiService _api;
  final DbService _db;

  bool _started = false;
  bool _draining = false;
  Timer? _tickTimer;
  StreamSubscription<List<ConnectivityResult>>? _connectivitySub;

  Duration _backoff = _regularInterval;
  int _consecutiveFailures = 0;
  DateTime? _lastSuccessfulSync;

  /// In-memory only, for [debugSummary]'s internal-diagnostic consumers
  /// (the dev verification harness under `tool/`) — the persistent record
  /// of failures now lives in [CrashLog]'s rolling file (FIX-03 §6/§7).
  String? _lastError;

  /// Writes the row and returns immediately — no `await` on anything
  /// network. If even the local write fails, the exception propagates so
  /// the caller can show the real error (FIX-01 §3) instead of failing
  /// silently; that is the only way this can fail.
  Future<SubmitResult> submit({
    required int orgId,
    required String rating,
    String comment = '',
    List<int> categoryIds = const [],
  }) async {
    await _db.insert(
      FeedbackEntry(
        orgId: orgId,
        rating: rating,
        comment: comment,
        categoryIds: categoryIds,
        createdAt: DateTime.now(),
        synced: 0,
      ),
    );

    // First attempt for this row: 5s from now, independent of the regular
    // tick schedule. If several rows land within the same 5s window (a
    // visitor tapping more than once), each schedules its own timer, but
    // _drain() is re-entrant-safe (_draining) so overlapping triggers just
    // find nothing new to do beyond what the first one already picked up.
    Timer(_firstAttemptDelay, _drain);

    return const SubmitSuccess('আপনার মূল্যবান মতামতের জন্য ধন্যবাদ! 👏');
  }

  /// Starts the queue worker: the 30s (backing off on failure) tick, the
  /// connectivity-regained trigger, and the one-time startup retention
  /// cleanup. Safe to call more than once — only the first call does
  /// anything.
  void start() {
    if (_started) return;
    _started = true;

    _db.deleteOldSyncedRows(olderThan: _retention).catchError((
      Object error,
      StackTrace stackTrace,
    ) {
      _recordError('retention cleanup', error, stackTrace);
    });

    _scheduleNext(_regularInterval);

    try {
      _connectivitySub = Connectivity().onConnectivityChanged.listen((
        results,
      ) {
        if (results.any((r) => r != ConnectivityResult.none)) {
          _drain();
        }
      });
    } catch (_) {
      // No platform implementation available (e.g. tests) — the tick timer
      // still covers retrying.
    }
  }

  void _scheduleNext(Duration delay) {
    _tickTimer?.cancel();
    _tickTimer = Timer(delay, () async {
      await _drain();
      _scheduleNext(_backoff);
    });
  }

  /// One tick: every pending negative row in full, then one pending
  /// positive row (FIX-06 §1). A complaint is time-sensitive; praise is
  /// not, and is also the higher-volume side on a working ward, so
  /// throttling it protects the backend while the negative stream always
  /// clears.
  ///
  /// If any upload fails, the tick stops immediately — the remaining
  /// negative rows (and the positive row, if the failure happened during
  /// the negative pass) are left for the next successful tick to resume
  /// from the oldest pending negative row. A down server must not turn a
  /// negative backlog into a hammer.
  ///
  /// Never throws — every path here is diagnostic-only. Skips entirely if a
  /// drain is already running, so the 5s-after-insert timer, the
  /// connectivity trigger, and the regular tick never race each other.
  Future<void> _drain() async {
    if (_draining) return;
    _draining = true;
    try {
      final negatives = await _db.getUnsyncedBatch(ratings: _negativeRatings);
      for (var i = 0; i < negatives.length; i++) {
        final hardFailure = await _uploadRow(negatives[i]);
        if (hardFailure) return;
        if (i != negatives.length - 1) {
          await Future<void>.delayed(_interRowGap);
        }
      }

      final positives = await _db.getUnsyncedBatch(
        limit: 1,
        ratings: _positiveRatings,
      );
      if (positives.isNotEmpty) {
        await _uploadRow(positives.single);
      }
    } catch (error, stackTrace) {
      // A sync tick must never crash the app or surface anything to the
      // user — just log it internally and wait for the next one.
      _recordError('drain', error, stackTrace);
    } finally {
      _draining = false;
    }
  }

  /// Uploads a single row and updates backoff/failure state. Returns `true`
  /// if this was a hard failure, telling [_drain] to stop the tick rather
  /// than continue to the next row.
  Future<bool> _uploadRow(FeedbackEntry row) async {
    final id = row.id;
    if (id == null) return false;

    var hardFailure = false;
    var succeeded = false;
    try {
      final result = await _api.submitFeedback(
        orgId: row.orgId,
        rating: row.rating,
        comment: row.comment,
        categoryIds: row.categoryIds,
      );
      if (result is SubmitSuccess) {
        await _db.markSynced(id);
        succeeded = true;
      } else {
        // A 2xx whose body doesn't actually claim success. Not a 422,
        // so it isn't a permanent rejection, but it also isn't a
        // network/HTTP error — treat it the same as "any other
        // outcome": back off rather than guessing.
        hardFailure = true;
      }
    } on DioException catch (e) {
      if (e.response?.statusCode == 422) {
        await _db.markRejected(id);
      } else {
        _recordError('sync row $id', e);
        hardFailure = true;
      }
    }

    if (hardFailure) {
      _consecutiveFailures++;
      final scaled =
          _regularInterval.inSeconds * math.pow(2, _consecutiveFailures);
      _backoff = Duration(
        seconds: math.min(scaled.toInt(), _maxBackoff.inSeconds),
      );
    } else {
      _consecutiveFailures = 0;
      _backoff = _regularInterval;
      if (succeeded) {
        _lastSuccessfulSync = DateTime.now();
      }
    }

    return hardFailure;
  }

  /// Records both the in-memory summary (for [debugSummary]'s internal
  /// consumers) and the persistent rolling log (FIX-03 §6/§7's "keep
  /// internal capture") — never surfaced to the user either way.
  void _recordError(String context, Object error, [StackTrace? stackTrace]) {
    _lastError = '${DateTime.now().toIso8601String()} [$context] '
        '${error.runtimeType}: $error';
    unawaited(CrashLog.record(context, error, stackTrace));
  }

  /// Runs one drain cycle immediately, without waiting for a timer. Tests
  /// only — production code paces itself entirely through [start] and
  /// [submit]'s own 5s trigger.
  @visibleForTesting
  Future<void> drainForTest() => _drain();

  /// The long-press debug dump (FIX-01 §5, extended by FIX-02 §1).
  Future<SyncDebugSummary> debugSummary() async {
    final db = await _db.debugSummary();
    return SyncDebugSummary(
      total: db.total,
      bySynced: db.bySynced,
      oldestPending: db.oldestPending,
      dbPath: db.dbPath,
      currentBackoff: _backoff,
      consecutiveFailures: _consecutiveFailures,
      lastError: _lastError,
      lastSuccessfulSync: _lastSuccessfulSync,
    );
  }

  void dispose() {
    _tickTimer?.cancel();
    _connectivitySub?.cancel();
  }
}

/// See [SyncService.debugSummary].
class SyncDebugSummary {
  const SyncDebugSummary({
    required this.total,
    required this.bySynced,
    required this.oldestPending,
    required this.dbPath,
    required this.currentBackoff,
    required this.consecutiveFailures,
    required this.lastError,
    required this.lastSuccessfulSync,
  });

  final int total;

  /// Keyed by the `synced` column's value: 0 pending, 1 sent, -1 rejected.
  final Map<int, int> bySynced;

  final DateTime? oldestPending;
  final String dbPath;
  final Duration currentBackoff;
  final int consecutiveFailures;
  final String? lastError;
  final DateTime? lastSuccessfulSync;
}
