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
      final tempDir = await Directory.systemTemp.createTemp('feedback_verify_crashlog_');
      addTearDown(() => tempDir.delete(recursive: true));
      addTearDown(CrashLog.resetForTest);
      CrashLog.resetForTest();
      PathProviderPlatform.instance = _FakePathProviderPlatform(tempDir.path);

      await CrashLog.record('test-context', StateError('boom'), StackTrace.current);
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

  // FIX-03 §1: at most one upload every 30s, measured from the previous
  // upload's completion. Row 1 just completed a few seconds ago — without
  // waiting out that window first, row 2's own 5s-later attempt below would
  // be silently throttled (no request, no failure recorded), which is
  // exactly what happened the first time this harness ran after §1 landed.
  _log(
      '\nwaiting out the 30s upload throttle before testing the offline row...');
  await Future<void>.delayed(const Duration(seconds: 31));

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
