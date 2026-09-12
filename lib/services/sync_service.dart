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
  static const _regularInterval = Duration(seconds: 45);
  static const _maxBackoff = Duration(minutes: 15);
  static const _retention = Duration(days: 7);

  /// FIX-03 §1: at most one row uploaded every 30 seconds, regardless of
  /// how many are pending or how many triggers fire in that window — 50
  /// queued rows drain over roughly 25 minutes, which is intentional. This
  /// is invisible to the user by construction: submit was already a local
  /// write with no network in its path (FIX-02 §1), so nothing about how
  /// fast the queue drains is ever something a person waits on or sees.
  static const _uploadThrottle = Duration(seconds: 30);

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

  /// When the most recent upload *attempt* (success, rejection, or
  /// failure) finished — measured from completion, not from when the tick
  /// that triggered it fired, so a slow upload can't cause two to overlap.
  DateTime? _lastUploadCompletion;

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
    // _drain only ever sends the single oldest pending row and is subject
    // to the 30s upload throttle (FIX-03 §1) — the rest just find either
    // nothing left to do, or the throttle still active, and the regular
    // tick or a later row's own timer picks them up in turn.
    Timer(_firstAttemptDelay, _drain);

    return const SubmitSuccess('আপনার মূল্যবান মতামতের জন্য ধন্যবাদ! 👏');
  }

  /// Starts the queue worker: the 45s (backing off on failure) tick, the
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

  /// Uploads at most the single oldest pending row, then stops — FIX-03 §1
  /// replaces the old "3 rows per tick" batching with a hard one-row-per-30s
  /// throttle, measured from this method's own last completion so a slow
  /// upload can't let two overlap. Where the 5s first-attempt timer and the
  /// 30s throttle disagree, the throttle wins: this simply does nothing and
  /// waits for whichever trigger (the regular tick, a new row's own 5s
  /// timer, or connectivity coming back) fires next.
  ///
  /// Never throws — every path here is diagnostic-only. Skips entirely if a
  /// drain is already running, so the 5s-after-insert timer, the
  /// connectivity trigger, and the regular tick never race each other.
  Future<void> _drain() async {
    if (_draining) return;
    _draining = true;
    try {
      final lastCompletion = _lastUploadCompletion;
      if (lastCompletion != null &&
          DateTime.now().difference(lastCompletion) < _uploadThrottle) {
        return;
      }

      final rows = await _db.getUnsyncedBatch(limit: 1);
      if (rows.isEmpty) return;
      final id = rows.single.id;
      if (id == null) return;
      final row = rows.single;

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

      _lastUploadCompletion = DateTime.now();

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
    } catch (error, stackTrace) {
      // A sync tick must never crash the app or surface anything to the
      // user — just log it internally and wait for the next one.
      _recordError('drain', error, stackTrace);
    } finally {
      _draining = false;
    }
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
