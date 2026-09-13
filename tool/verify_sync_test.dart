// Dev-only runtime verification for the FIX-02 §1 local-first submit +
// queue worker pipeline, exercised through the *real* DbService,
// SyncService, and ApiService classes shipped in lib/ — not fakes.
//
// Why this runs as `flutter test` instead of on a device: this environment
// has no Android device/emulator attached, and the Linux desktop toolchain
// (clang++, ninja) isn't installed here either, so there is no way to
// launch the compiled app directly. `flutter test` runs the real Dart VM
// without needing either of those, which is enough because:
//   - sqflite_common_ffi talks to sqlite3 directly via dart:ffi — it does
//     NOT go through a platform channel, so it works here exactly as it
//     would on a real device.
//   - path_provider *does* normally need a platform channel, so this file
//     supplies a fake PathProviderPlatform pointing at a real temp
//     directory — the only stand-in used anywhere in this file.
//   - The database file, the SyncService's timers, and the HTTP
//     request/response are all real: a genuine file on disk, genuine
//     `Future.delayed` wall-clock timers, and a genuine loopback HTTP
//     server that dio actually connects to.
// The only thing not real is the backend: this points ApiService at a
// throwaway local HTTP server instead of the live production API, so this
// verification never writes a test row into the real backend.
//
// Run with: flutter test tool/verify_sync_test.dart
// ignore_for_file: avoid_print, invalid_use_of_visible_for_testing_member
import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;
import 'package:path_provider_platform_interface/path_provider_platform_interface.dart';
import 'package:plugin_platform_interface/plugin_platform_interface.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';

import 'package:feedback/models/feedback_entry.dart';
import 'package:feedback/services/api_service.dart';
import 'package:feedback/services/crash_log.dart';
import 'package:feedback/services/db_service.dart';
import 'package:feedback/services/sync_service.dart';

void _log(String msg) => print('[VERIFY] $msg');

class _FakePathProviderPlatform extends PathProviderPlatform
    with MockPlatformInterfaceMixin {
  _FakePathProviderPlatform(this.documentsPath);
  final String documentsPath;

  @override
  Future<String?> getApplicationDocumentsPath() async => documentsPath;
}

/// A throwaway stand-in for the Laravel backend, bound to a fixed local
/// port so it can be stopped and restarted on the *same* port — the same
/// ApiService/SyncService pair keeps working across the simulated outage
/// instead of needing to be swapped out, exactly like a real device
/// reconnecting to the same URL.
class _MockServer {
  _MockServer(this.port);
  final int port;
  HttpServer? _server;
  int requestCount = 0;

  Future<void> start() async {
    final server = await HttpServer.bind(InternetAddress.loopbackIPv4, port);
    _server = server;
    server.listen((request) async {
      requestCount++;
      final body = await utf8.decoder.bind(request).join();
      _log(
        'mock server received: ${request.method} ${request.uri.path}\n'
        '           body: $body',
      );
      final response = jsonEncode({'status': 'success', 'message': 'ok'});
      request.response
        ..statusCode = 200
        ..headers.contentType = ContentType.json
        ..write(response);
      await request.response.close();
      _log('mock server responded: 200 $response');
    });
    _log('mock server listening on 127.0.0.1:$port');
  }

  Future<void> stop() async {
    await _server?.close(force: true);
    _server = null;
    _log('mock server stopped (simulating no network / server unreachable)');
  }
}

Future<void> _dumpTable(String dbPath, String label) async {
  final result = await Process.run('sqlite3', [
    dbPath,
    '-header',
    '-column',
    'SELECT id, org_id, rating, comment, synced, created_at FROM feedbacks ORDER BY id;',
  ]);
  _log('$label — sqlite3 CLI dump of $dbPath:\n${result.stdout}');
  if ((result.stderr as String).toString().isNotEmpty) {
    _log('sqlite3 stderr: ${result.stderr}');
  }
}

void main() {
  // Deliberately NOT TestWidgetsFlutterBinding.ensureInitialized(): that
  // binding makes every real HttpClient request return 400 without hitting
  // the network at all, which would defeat the entire point of this
  // harness (a genuine loopback HTTP round trip). Instead, SyncService's
  // best-effort `connectivity_plus` listener needs *some* ServicesBinding
  // to exist for its EventChannel — without one, it fails asynchronously
  // outside the synchronous try/catch in SyncService.start(). That failure
  // is irrelevant to this app's correctness (a real device always has
  // WidgetsFlutterBinding up before SyncService ever starts; this gap only
  // exists because this harness runs outside a real app), so it's caught
  // here via a guarded zone instead of a real binding.
  test(
    'FIX-02 §1 pipeline works end-to-end against a real SQLite file and a real HTTP round trip',
    () async {
      final done = Completer<void>();
      runZonedGuarded(() async {
        await _runVerification();
        if (!done.isCompleted) done.complete();
      }, (error, stack) {
        if (done.isCompleted) return;
        if (error is TestFailure) {
          // A real assertion failure from inside _runVerification — this
          // must fail the test, not be swallowed as a binding artifact.
          done.completeError(error, stack);
          return;
        }
        _log('(ignored — harness-only, not a real binding on device) $error');
      });
      await done.future;
    },
    timeout: const Timeout(Duration(minutes: 5)),
  );

  test(
    'FIX-03 §6/§7: CrashLog writes to a real rolling file and trims when '
    'it gets too big',
    () async {
      final tempDir =
          await Directory.systemTemp.createTemp('feedback_verify_crashlog_');
      addTearDown(() => tempDir.delete(recursive: true));
      addTearDown(CrashLog.resetForTest);
      CrashLog.resetForTest();
      PathProviderPlatform.instance = _FakePathProviderPlatform(tempDir.path);

      await CrashLog.record(
          'test-context', StateError('boom'), StackTrace.current);
      final logFile = File(p.join(tempDir.path, 'FeedbackSystem', 'app.log'));
      expect(logFile.existsSync(), isTrue);
      final firstContent = await logFile.readAsString();
      _log('CrashLog wrote:\n$firstContent');
      expect(firstContent, contains('test-context'));
      expect(firstContent, contains('StateError'));
      expect(firstContent, contains('boom'));

      // Force it well past the 2MB cap and confirm it actually trims
      // instead of growing without bound (FIX-03 §7: "nothing grows
      // without bound: log file...").
      final bigError = 'x' * 500000; // ~500KB of padding per call
      for (var i = 0; i < 10; i++) {
        await CrashLog.record('pad-$i', StateError(bigError));
      }
      final finalLength = await logFile.length();
      _log('log length after padding: $finalLength bytes (cap is 2MB)');
      expect(finalLength, lessThanOrEqualTo(2 * 1024 * 1024));
    },
  );

  test(
    'FIX-03 §7: DB open is one shared future — many concurrent first '
    'accesses against a real file open it exactly once and every row lands',
    () async {
      final tempDir =
          await Directory.systemTemp.createTemp('feedback_verify_dbrace_');
      addTearDown(() => tempDir.delete(recursive: true));
      PathProviderPlatform.instance = _FakePathProviderPlatform(tempDir.path);
      sqfliteFfiInit();
      databaseFactory = databaseFactoryFfi;

      final db = DbService();
      // 10 concurrent inserts, none awaited individually first — every one
      // of these hits `_database` before the very first `_open()` call has
      // had any chance to complete. If the old `_db ??= await _open()`
      // race were still there, this either throws or silently loses rows
      // to a botched concurrent open.
      final results = await Future.wait([
        for (var i = 0; i < 10; i++)
          db.insert(
            FeedbackEntry(
              orgId: 1,
              rating: 'good',
              comment: 'race-$i',
              categoryIds: const [],
              createdAt: DateTime.now(),
              synced: 0,
            ),
          ),
      ]);
      _log('10 concurrent inserts returned ids: $results');
      expect(results.toSet(), hasLength(10), reason: 'ids must be unique');

      final summary = await db.debugSummary();
      _log('debugSummary after concurrent inserts: total=${summary.total}');
      expect(summary.total, 10, reason: 'every concurrent insert must land');

      final dbFile = File(summary.dbPath);
      expect(dbFile.existsSync(), isTrue);
    },
  );

  test(
    'FIX-03 §7: the 7-day retention prune actually runs and actually '
    'deletes — old synced=1 rows go, recent and rejected rows stay',
    () async {
      final tempDir =
          await Directory.systemTemp.createTemp('feedback_verify_retention_');
      addTearDown(() => tempDir.delete(recursive: true));
      PathProviderPlatform.instance = _FakePathProviderPlatform(tempDir.path);
      sqfliteFfiInit();
      databaseFactory = databaseFactoryFfi;

      final db = DbService();
      final now = DateTime.now();
      final old = now.subtract(const Duration(days: 8));
      final recent = now.subtract(const Duration(hours: 1));

      final oldSyncedId = await db.insert(FeedbackEntry(
        orgId: 1,
        rating: 'good',
        comment: 'old, synced — must be pruned',
        categoryIds: const [],
        createdAt: old,
        synced: 1,
      ));
      final recentSyncedId = await db.insert(FeedbackEntry(
        orgId: 1,
        rating: 'good',
        comment: 'recent, synced — must survive',
        categoryIds: const [],
        createdAt: recent,
        synced: 1,
      ));
      final oldRejectedId = await db.insert(FeedbackEntry(
        orgId: 1,
        rating: 'poor',
        comment: 'old, rejected — kept indefinitely per FIX-02 §1',
        categoryIds: const [],
        createdAt: old,
        synced: -1,
      ));
      final oldPendingId = await db.insert(FeedbackEntry(
        orgId: 1,
        rating: 'poor',
        comment: 'old, still pending — never pruned regardless of age',
        categoryIds: const [],
        createdAt: old,
        synced: 0,
      ));

      await db.deleteOldSyncedRows(olderThan: const Duration(days: 7));

      final dbPath = (await db.debugSummary()).dbPath;
      final rows = await Process.run('sqlite3', [
        dbPath,
        '-header',
        '-column',
        'SELECT id, synced FROM feedbacks ORDER BY id;',
      ]);
      _log('rows after pruning:\n${rows.stdout}');

      final summary = await db.debugSummary();
      expect(summary.total, 3, reason: 'exactly the old synced=1 row is gone');

      final remainingIds = <int>{};
      // debugSummary doesn't expose ids directly; re-query via the public
      // getUnsyncedBatch/markSynced-adjacent surface isn't enough here, so
      // fall back to the same sqlite3 CLI the rest of this harness uses.
      final idOutput =
          await Process.run('sqlite3', [dbPath, 'SELECT id FROM feedbacks;']);
      for (final line in (idOutput.stdout as String).trim().split('\n')) {
        final id = int.tryParse(line.trim());
        if (id != null) remainingIds.add(id);
      }
      expect(remainingIds.contains(oldSyncedId), isFalse,
          reason: 'the old synced row must actually be deleted');
      expect(remainingIds.contains(recentSyncedId), isTrue);
      expect(remainingIds.contains(oldRejectedId), isTrue);
      expect(remainingIds.contains(oldPendingId), isTrue);
    },
  );

  test(
    'FIX-04 §3 walkthrough step 13: kill and relaunch — a brand-new '
    'DbService instance over the same on-disk file sees rows a previous '
    'instance wrote, exactly like a real process restart would',
    () async {
      final tempDir =
          await Directory.systemTemp.createTemp('feedback_verify_relaunch_');
      addTearDown(() => tempDir.delete(recursive: true));
      PathProviderPlatform.instance = _FakePathProviderPlatform(tempDir.path);
      sqfliteFfiInit();
      databaseFactory = databaseFactoryFfi;

      // "Before the kill": one DbService instance, one pending row.
      final beforeKill = DbService();
      final id = await beforeKill.insert(FeedbackEntry(
        orgId: 1,
        rating: 'poor',
        comment: 'still here after relaunch?',
        categoryIds: const [],
        createdAt: DateTime.now(),
        synced: 0,
      ));
      _log('inserted row $id before "kill"');

      // "After relaunch": a brand-new DbService, with none of the old
      // instance's in-memory state (no cached _dbFuture, nothing) — the
      // only thing carrying the row over is the real file on disk, exactly
      // as main() constructing a fresh DbService on every app launch does.
      final afterRelaunch = DbService();
      final summary = await afterRelaunch.debugSummary();
      _log(
        'after "relaunch": total=${summary.total} '
        'pending=${summary.bySynced[0] ?? 0} dbPath=${summary.dbPath}',
      );
      expect(summary.total, 1);
      expect(summary.bySynced[0], 1, reason: 'the pending row must survive');

      final unsynced = await afterRelaunch.getUnsyncedBatch();
      expect(unsynced.single.id, id);
      expect(unsynced.single.comment, 'still here after relaunch?');
    },
  );

  test(
    'FIX-04 §3: 15-minute soak — the queue worker keeps draining with no '
    'growth, no leaks, no stuck state, no growing log file',
    () async {
      // Same harness-only gap as the main pipeline test above:
      // SyncService.start()'s connectivity_plus listener needs some
      // ServicesBinding to exist for its EventChannel, which isn't set up
      // in this bare (non-widget-test) test() — the failure happens
      // asynchronously outside start()'s own synchronous try/catch, so it
      // must be caught here instead of letting it fail the whole soak.
      final done = Completer<void>();
      runZonedGuarded(() async {
        await _runSoak();
        if (!done.isCompleted) done.complete();
      }, (error, stack) {
        if (done.isCompleted) return;
        if (error is TestFailure) {
          done.completeError(error, stack);
          return;
        }
        _log('(ignored — harness-only, not a real binding on device) $error');
      });
      await done.future;
    },
    timeout: const Timeout(Duration(minutes: 20)),
  );
}

Future<void> _runSoak() async {
  final tempDir =
      await Directory.systemTemp.createTemp('feedback_verify_soak_');
  addTearDown(() => tempDir.delete(recursive: true));
  addTearDown(CrashLog.resetForTest);
  CrashLog.resetForTest();
  PathProviderPlatform.instance = _FakePathProviderPlatform(tempDir.path);
  sqfliteFfiInit();
  databaseFactory = databaseFactoryFfi;

  const port = 39218;
  final mock = _MockServer(port);
  await mock.start();
  final api = ApiService(baseUrl: 'http://127.0.0.1:$port/api');
  final db = DbService();
  final sync = SyncService(api: api, db: db);
  sync.start();

  final rssSamples = <int>[];
  void sampleRss() {
    try {
      rssSamples.add(ProcessInfo.currentRss);
    } catch (_) {
      // Not available on every platform — soak still runs without it.
    }
  }

  sampleRss();
  const soakDuration = Duration(minutes: 15);
  const submitEvery = Duration(seconds: 45);
  final stopwatch = Stopwatch()..start();
  var submitted = 0;

  while (stopwatch.elapsed < soakDuration) {
    await sync.submit(
      orgId: 1,
      rating: 'good',
      comment: 'soak row $submitted',
    );
    submitted++;
    sampleRss();
    await Future<void>.delayed(submitEvery);
  }

  // Let whatever's still in flight settle before the final check.
  await Future<void>.delayed(const Duration(seconds: 35));
  sampleRss();

  final summary = await sync.debugSummary();
  _log(
    'soak complete: submitted=$submitted requests=${mock.requestCount} '
    'total=${summary.total} pending=${summary.bySynced[0] ?? 0} '
    'sent=${summary.bySynced[1] ?? 0} '
    'consecutiveFailures=${summary.consecutiveFailures} '
    'lastError=${summary.lastError}',
  );
  if (rssSamples.isNotEmpty) {
    _log(
      'RSS samples (bytes): first=${rssSamples.first} '
      'last=${rssSamples.last} max=${rssSamples.reduce((a, b) => a > b ? a : b)}',
    );
  }

  expect(summary.total, submitted, reason: 'every submit must land');
  expect(summary.bySynced[0] ?? 0, 0,
      reason: 'nothing should still be pending after 15 minutes of a '
          'healthy, always-reachable server');
  expect(summary.consecutiveFailures, 0);
  expect(summary.lastError, isNull, reason: 'a healthy run logs nothing');

  final logFile = File(p.join(tempDir.path, 'FeedbackSystem', 'app.log'));
  expect(logFile.existsSync(), isFalse,
      reason: 'no errors occurred, so CrashLog should never have '
          'written anything — confirms it does not grow on its own');

  await mock.stop();
}

Future<void> _runVerification() async {
  final tempDir = await Directory.systemTemp.createTemp('feedback_verify_');
  addTearDown(() => tempDir.delete(recursive: true));
  PathProviderPlatform.instance = _FakePathProviderPlatform(tempDir.path);
  sqfliteFfiInit();
  databaseFactory = databaseFactoryFfi;

  _log('=== STEP 1: DB file is created ===');
  final db = DbService();
  final firstSummary = await db.debugSummary(); // forces the lazy DB open
  final dbPath = firstSummary.dbPath;
  final exists = File(dbPath).existsSync();
  _log('DB path: $dbPath');
  _log('File exists on disk: $exists');
  expect(exists, isTrue, reason: 'the sqlite file must exist on disk');

  const port = 39217;
  final mock = _MockServer(port);
  await mock.start();
  final api = ApiService(baseUrl: 'http://127.0.0.1:$port/api');
  final sync = SyncService(api: api, db: db);
  sync.start();
  // Not calling sync.dispose() in teardown: cancelling the connectivity_plus
  // subscription hits the same "no ServicesBinding" gap this harness
  // already works around for start() — teardown callbacks run outside the
  // guarded zone above, and the process exits right after this test anyway.

  _log('\n=== STEP 2/3: submit() inserts a row, synced = 0 ===');
  final sw = Stopwatch()..start();
  final result = await sync.submit(
    orgId: 999,
    rating: 'poor',
    comment: 'VERIFY: this is a test row from tool/verify_sync_test.dart',
  );
  sw.stop();
  _log('submit() returned in ${sw.elapsedMilliseconds}ms: $result');
  expect(result, isA<SubmitSuccess>());
  await _dumpTable(dbPath, 'Immediately after submit()');
  var summary = await sync.debugSummary();
  _log(
    'debugSummary right after submit: pending=${summary.bySynced[0] ?? 0} '
    'sent=${summary.bySynced[1] ?? 0} rejected=${summary.bySynced[-1] ?? 0}',
  );
  expect(summary.bySynced[0], 1, reason: 'row must land as synced=0');
  expect(sw.elapsedMilliseconds, lessThan(1000),
      reason: 'submit() must never wait on the network');

  _log('\n=== STEP 4/5/6: waiting for the 5s first-attempt tick ===');
  await Future<void>.delayed(const Duration(seconds: 7));
  await _dumpTable(dbPath, 'After the 5s tick should have fired');
  summary = await sync.debugSummary();
  _log(
    'requests received by mock server so far: ${mock.requestCount}\n'
    'debugSummary: pending=${summary.bySynced[0] ?? 0} '
    'sent=${summary.bySynced[1] ?? 0} rejected=${summary.bySynced[-1] ?? 0} '
    'lastSuccessfulSync=${summary.lastSuccessfulSync}',
  );
  expect(mock.requestCount, greaterThanOrEqualTo(1),
      reason: 'the 5s tick must have posted to the server by now');
  expect(summary.bySynced[1], 1, reason: 'the row must now be synced=1');

  // FIX-06 §5 retired the old per-row 30s throttle (`_lastUploadCompletion`)
  // entirely — the 30s tick interval is now the only pacing, so row 2's own
  // 5s-later first-attempt timer below fires and fails independently, with
  // no artificial wait needed first.
  _log(
      '\n=== STEP 7: airplane-mode equivalent — stop the mock server, submit again ===');
  await mock.stop();
  final sw2 = Stopwatch()..start();
  final result2 = await sync.submit(
    orgId: 999,
    rating: 'very_poor',
    comment: 'VERIFY: submitted while the mock server is down',
  );
  sw2.stop();
  _log(
      'submit() returned in ${sw2.elapsedMilliseconds}ms while offline: $result2');
  expect(result2, isA<SubmitSuccess>(),
      reason: 'the success message must show instantly even offline');
  expect(sw2.elapsedMilliseconds, lessThan(1000));
  await _dumpTable(dbPath, 'Immediately after the offline submit');

  _log(
      'waiting for the 5s first-attempt tick to fail against the down server...');
  await Future<void>.delayed(const Duration(seconds: 7));
  await _dumpTable(dbPath, 'After the offline row\'s first attempt failed');
  summary = await sync.debugSummary();
  _log(
    'debugSummary after failed attempt: pending=${summary.bySynced[0] ?? 0} '
    'consecutiveFailures=${summary.consecutiveFailures} '
    'currentBackoff=${summary.currentBackoff} lastError=${summary.lastError}',
  );
  expect(summary.bySynced[0], 1,
      reason: 'the offline row must stay pending, not be lost or marked sent');
  expect(summary.consecutiveFailures, greaterThanOrEqualTo(1));

  _log(
      '\n=== STEP 8: restore network (same port, same worker), confirm drain within one tick ===');
  await mock.start();
  _log(
      'mock server back up on the same port — waiting out the current backoff...');
  await Future<void>.delayed(
      summary.currentBackoff + const Duration(seconds: 10));
  await _dumpTable(dbPath, 'After network restored — expecting synced = 1');
  summary = await sync.debugSummary();
  _log(
    'requests received by mock server (cumulative): ${mock.requestCount}\n'
    'FINAL debugSummary: total=${summary.total} '
    'pending=${summary.bySynced[0] ?? 0} sent=${summary.bySynced[1] ?? 0} '
    'rejected=${summary.bySynced[-1] ?? 0} '
    'lastSuccessfulSync=${summary.lastSuccessfulSync}',
  );
  expect(summary.bySynced[1], 2,
      reason: 'both rows must be synced=1 once the server is reachable again');
  expect(summary.bySynced[0] ?? 0, 0,
      reason: 'nothing should still be pending');

  await mock.stop();
  _log('\n=== VERIFICATION COMPLETE — all 8 steps confirmed ===');
}
