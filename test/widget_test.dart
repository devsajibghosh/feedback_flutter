import 'dart:convert';

import 'package:dio/dio.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:feedback/main.dart';
import 'package:feedback/models/category.dart';
import 'package:feedback/models/feedback_entry.dart';
import 'package:feedback/screens/feedback_screen.dart';
import 'package:feedback/screens/login_screen.dart';
import 'package:feedback/services/api_service.dart';
import 'package:feedback/services/db_service.dart';
import 'package:feedback/services/sync_service.dart';
import 'package:feedback/widgets/blurred_background.dart';
import 'package:feedback/widgets/category_pill.dart';
import 'package:feedback/widgets/feedback_dialog.dart';
import 'package:feedback/widgets/positive_dialog.dart';
import 'package:feedback/widgets/rating_button.dart';

/// Never touches the network — every test using this treats the org as
/// offline so no real HTTP call ever leaves the test process.
class _OfflineApiService extends ApiService {
  @override
  Future<String?> getOrgLogo(int orgId) async => null;

  @override
  Future<MarqueeData?> getMarqueeText(int orgId) async => null;

  @override
  Future<List<Category>?> getCategories(int orgId) async => null;
}

/// Same as [_OfflineApiService], but lets a test script the submit outcome
/// and the categories returned.
class _FakeApiService extends _OfflineApiService {
  SubmitResult submitResult = const SubmitSuccess('ধন্যবাদ বার্তা');
  List<Category>? categories;

  /// Submit is local-first now (FIX-02 §1) — this stays at 0 in every test
  /// that only exercises the dialog's direct submit path, proving the
  /// network is genuinely never touched by it.
  int submitCalls = 0;

  @override
  Future<List<Category>?> getCategories(int orgId) async => categories;

  @override
  Future<SubmitResult> submitFeedback({
    required int orgId,
    required String rating,
    String comment = '',
    List<int> categoryIds = const [],
  }) async {
    submitCalls++;
    return submitResult;
  }
}

/// An in-memory stand-in for [DbService] — sqflite has no platform
/// implementation under `flutter test`, so any test that lets a submission
/// reach [SyncService] must supply one of these instead of the real thing.
class _FakeDbService extends DbService {
  final List<FeedbackEntry> rows = [];
  int _nextId = 1;

  @override
  Future<int> insert(FeedbackEntry entry) async {
    final id = _nextId++;
    rows.add(
      FeedbackEntry(
        id: id,
        orgId: entry.orgId,
        rating: entry.rating,
        comment: entry.comment,
        categoryIds: entry.categoryIds,
        createdAt: entry.createdAt,
        synced: entry.synced,
      ),
    );
    return id;
  }

  @override
  Future<List<FeedbackEntry>> getUnsyncedBatch({int limit = 3}) async {
    return rows.where((r) => r.synced == 0).take(limit).toList();
  }

  @override
  Future<void> markSynced(int id) async => _setSynced(id, 1);

  @override
  Future<void> markRejected(int id) async => _setSynced(id, -1);

  void _setSynced(int id, int synced) {
    final index = rows.indexWhere((r) => r.id == id);
    if (index == -1) return;
    final row = rows[index];
    rows[index] = FeedbackEntry(
      id: row.id,
      orgId: row.orgId,
      rating: row.rating,
      comment: row.comment,
      categoryIds: row.categoryIds,
      createdAt: row.createdAt,
      synced: synced,
    );
  }

  /// Overridden so tests can call [SyncService.debugSummary] without
  /// touching the real sqflite/path_provider plugins, which have no
  /// implementation under `flutter test`.
  @override
  Future<DbDebugSummary> debugSummary() async {
    final bySynced = <int, int>{};
    for (final row in rows) {
      bySynced[row.synced] = (bySynced[row.synced] ?? 0) + 1;
    }
    final pending = rows.where((r) => r.synced == 0).toList()
      ..sort((a, b) => a.createdAt.compareTo(b.createdAt));
    return DbDebugSummary(
      total: rows.length,
      bySynced: bySynced,
      oldestPending: pending.isEmpty ? null : pending.first.createdAt,
      dbPath: '(fake db)',
    );
  }
}

/// Lets a test script exactly what `submitFeedback` returns or throws, to
/// exercise [SyncService]'s own §4.7/§4.8 branching directly.
class _ScriptedApiService extends ApiService {
  Future<SubmitResult> Function()? onSubmit;

  @override
  Future<SubmitResult> submitFeedback({
    required int orgId,
    required String rating,
    String comment = '',
    List<int> categoryIds = const [],
  }) {
    return onSubmit!();
  }
}

/// A [SyncService] backed by an in-memory [_FakeDbService], for tests that
/// render [FeedbackScreen]/[AppRoot] and just need submissions to work
/// without touching real sqflite.
SyncService _fakeSync(ApiService api) => SyncService(api: api, db: _FakeDbService());

/// Runs the test at roughly the app's real target size (a landscape
/// tablet) instead of the default 800x600 test surface, so dialog content
/// that only overflows on a short/narrow window doesn't force every test
/// to scroll to reach it.
void _useTabletSize(WidgetTester tester) {
  tester.view.physicalSize = const Size(1280, 800);
  tester.view.devicePixelRatio = 1.0;
  addTearDown(tester.view.resetPhysicalSize);
}

void main() {
  setUp(() {
    SharedPreferences.setMockInitialValues({});
  });

  testWidgets(
    'shows the login screen over the blurred background on a fresh install',
    (WidgetTester tester) async {
      _useTabletSize(tester);
      await tester.pumpWidget(const FeedbackApp());
      await tester.pump(); // blank verdant frame while storage is checked
      await tester.pump(); // storage future resolves, no saved org id

      expect(find.byType(BlurredBackground), findsOneWidget);
      expect(find.byType(LoginScreen), findsOneWidget);
      expect(find.text('অ্যাডমিন প্যানেল'), findsOneWidget);
      expect(find.textContaining('Code Station 23'), findsOneWidget);
    },
  );

  testWidgets(
    'skips the login screen and shows the feedback screen when an org id is already saved',
    (WidgetTester tester) async {
      _useTabletSize(tester);
      SharedPreferences.setMockInitialValues({'org_id': 7});

      await tester.pumpWidget(
        MaterialApp(
          home: AppRoot(
            api: _OfflineApiService(),
            sync: _fakeSync(_OfflineApiService()),
          ),
        ),
      );
      await tester.pump();
      await tester.pump();

      expect(find.byType(LoginScreen), findsNothing);
      expect(find.byType(FeedbackScreen), findsOneWidget);
      expect(find.byType(BlurredBackground), findsOneWidget);
      expect(find.byType(RatingButton), findsNWidgets(5));
      // Logo and marquee both failed with no cache, so both the heading
      // and the marquee bar fall back to the same offline message (§4.2).
      expect(
        find.text('ইন্টারনেট সংযোগ দিন, যাতে ফিডব্যাকগুলো sync হতে পারে।'),
        findsNWidgets(2),
      );
    },
  );

  testWidgets(
    'tapping a positive rating opens the dialog and submit is local-first: '
    'instant success toast, row saved synced=0, network never touched',
    (WidgetTester tester) async {
      _useTabletSize(tester);
      SharedPreferences.setMockInitialValues({'org_id': 7});
      final api = _FakeApiService();
      final db = _FakeDbService();

      await tester.pumpWidget(
        MaterialApp(
          home: AppRoot(api: api, sync: SyncService(api: api, db: db)),
        ),
      );
      await tester.pump();
      await tester.pump();

      // kRatingSpecs[0] is very_good, a positive rating.
      await tester.tap(find.byType(RatingButton).first);
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 350));

      expect(find.text('আপনার ইতিবাচক মতামতের\nজন্য ধন্যবাদ!'), findsOneWidget);

      await tester.tap(find.text('জমা দিন'));
      await tester.pump();
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 350));
      await tester.pump();

      expect(find.text('ধন্যবাদ!'), findsOneWidget);
      expect(
        find.text('আপনার মূল্যবান মতামতের জন্য ধন্যবাদ! 👏'),
        findsOneWidget,
      );
      expect(find.text('আপনার ইতিবাচক মতামতের\nজন্য ধন্যবাদ!'), findsNothing);

      // The row landed locally, pending — and the network was never called
      // to get there (FIX-02 §1: submit is a local insert, full stop).
      expect(db.rows, hasLength(1));
      expect(db.rows.single.synced, 0);
      expect(api.submitCalls, 0);

      // Let the success alert's 1500ms auto-dismiss timer AND submit()'s
      // 5s-after-insert queue-worker timer (FIX-02 §1) both fire, so no
      // pending timer remains when the test tears down.
      await tester.pump(const Duration(seconds: 6));
    },
  );

  testWidgets(
    'cancelling the positive dialog closes it without submitting',
    (WidgetTester tester) async {
      _useTabletSize(tester);
      SharedPreferences.setMockInitialValues({'org_id': 7});
      final api = _FakeApiService();

      await tester.pumpWidget(
        MaterialApp(home: AppRoot(api: api, sync: _fakeSync(api))),
      );
      await tester.pump();
      await tester.pump();

      await tester.tap(find.byType(RatingButton).first);
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 350));

      await tester.tap(find.text('বাতিল'));
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 350));

      expect(find.text('আপনার ইতিবাচক মতামতের\nজন্য ধন্যবাদ!'), findsNothing);
    },
  );

  testWidgets(
    'a negative rating opens the dialog, renders cached categories, and an empty submit warns',
    (WidgetTester tester) async {
      _useTabletSize(tester);
      SharedPreferences.setMockInitialValues({'org_id': 7});
      final api = _FakeApiService()
        ..categories = const [
          Category(id: 1, name: 'দেরি'),
          Category(id: 2, name: 'ব্যবহার'),
        ];

      await tester.pumpWidget(
        MaterialApp(home: AppRoot(api: api, sync: _fakeSync(api))),
      );
      await tester.pump();
      await tester.pump();

      // kRatingSpecs[4] is very_poor, a negative rating.
      await tester.tap(find.byType(RatingButton).last);
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 350));
      await tester.pump(); // categories fetch resolves

      expect(find.text('কোথায় সমস্যা হয়েছে জানান'), findsOneWidget);
      expect(find.byType(CategoryPill), findsNWidgets(2));
      expect(find.text('দেরি'), findsOneWidget);

      // Submitting with nothing selected and no comment should warn, not send.
      await tester.ensureVisible(find.text('ফিডব্যাক জমা দিন'));
      await tester.pump();
      await tester.tap(find.text('ফিডব্যাক জমা দিন'));
      await tester.pump();

      expect(
        find.text('দয়া করে কারণ সিলেক্ট করুন অথবা আপনার অভিজ্ঞতা লিখুন।'),
        findsOneWidget,
      );
      await tester.tap(find.text('ঠিক আছে'));
      await tester.pump();

      // Selecting a category then submitting should succeed.
      await tester.tap(find.text('দেরি'));
      await tester.pump();
      await tester.ensureVisible(find.text('ফিডব্যাক জমা দিন'));
      await tester.pump();
      await tester.tap(find.text('ফিডব্যাক জমা দিন'));
      await tester.pump();
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 350));
      await tester.pump();

      expect(find.text('ধন্যবাদ!'), findsOneWidget);
      await tester.pump(const Duration(seconds: 6));
    },
  );

  for (var i = 0; i < kRatingSpecs.length; i++) {
    final spec = kRatingSpecs[i];
    final expectedTitle = i < 3
        ? 'আপনার ইতিবাচক মতামতের\nজন্য ধন্যবাদ!'
        : 'কোথায় সমস্যা হয়েছে জানান';

    testWidgets(
      'rating "${spec.value}" opens the ${i < 3 ? "positive" : "negative"} dialog',
      (WidgetTester tester) async {
        _useTabletSize(tester);
        SharedPreferences.setMockInitialValues({'org_id': 7});
        final api = _FakeApiService();

        await tester.pumpWidget(
          MaterialApp(home: AppRoot(api: api, sync: _fakeSync(api))),
        );
        await tester.pump();
        await tester.pump();

        await tester.tap(find.byType(RatingButton).at(i));
        await tester.pump();
        await tester.pump(const Duration(milliseconds: 350));
        await tester.pump();

        expect(find.text(expectedTitle), findsOneWidget);
      },
    );
  }

  testWidgets(
    'negative submit succeeds with only a comment (no category, no voice)',
    (WidgetTester tester) async {
      _useTabletSize(tester);
      SharedPreferences.setMockInitialValues({'org_id': 7});
      final api = _FakeApiService()
        ..categories = const [Category(id: 1, name: 'দেরি')];

      await tester.pumpWidget(
        MaterialApp(home: AppRoot(api: api, sync: _fakeSync(api))),
      );
      await tester.pump();
      await tester.pump();

      await tester.tap(find.byType(RatingButton).last);
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 350));
      await tester.pump();

      await tester.enterText(find.byType(TextField), 'সেবা খুব ধীর ছিল');
      await tester.pump();

      await tester.ensureVisible(find.text('ফিডব্যাক জমা দিন'));
      await tester.pump();
      await tester.tap(find.text('ফিডব্যাক জমা দিন'));
      await tester.pump();
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 350));
      await tester.pump();

      expect(find.text('ধন্যবাদ!'), findsOneWidget);
      await tester.pump(const Duration(seconds: 6));
    },
  );

  testWidgets(
    'categories render instantly from cache on a cold offline start (§4.3)',
    (WidgetTester tester) async {
      _useTabletSize(tester);
      SharedPreferences.setMockInitialValues({
        'org_id': 7,
        'categories_7': jsonEncode([
          {'id': 1, 'name': 'দেরি'},
          {'id': 2, 'name': 'ব্যবহার'},
        ]),
      });
      final api = _OfflineApiService(); // getCategories -> null (offline)

      await tester.pumpWidget(
        MaterialApp(home: AppRoot(api: api, sync: _fakeSync(api))),
      );
      await tester.pump();
      await tester.pump();

      await tester.tap(find.byType(RatingButton).last);
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 350));
      await tester.pump();

      // Rendered from cache even though the (failed) network fetch is the
      // only other thing that could have supplied them.
      expect(find.byType(CategoryPill), findsNWidgets(2));
      expect(
        find.text('ইন্টারনেট সংযোগ না থাকায় ক্যাটেগরি লোড হয়নি।'),
        findsNothing,
      );
      expect(find.text('লোড হচ্ছে...'), findsNothing);
    },
  );

  testWidgets(
    'an org with zero configured categories and no cache stops loading '
    'instead of spinning forever',
    (WidgetTester tester) async {
      // Discovered live against the real API (WORK 3): several orgs
      // (including nonexistent ones) return `{success: true, categories:
      // []}` — a successful-but-empty response §4.3 doesn't spell out
      // handling for. Before the fix, neither the "non-empty fetch" nor the
      // "failed fetch" branch fired, so `_categories` stayed null forever.
      _useTabletSize(tester);
      SharedPreferences.setMockInitialValues({'org_id': 7});
      final api = _FakeApiService()..categories = const [];

      await tester.pumpWidget(
        MaterialApp(home: AppRoot(api: api, sync: _fakeSync(api))),
      );
      await tester.pump();
      await tester.pump();

      await tester.tap(find.byType(RatingButton).last);
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 350));
      await tester.pump();

      expect(find.byType(CategoryPill), findsNothing);
      expect(find.text('লোড হচ্ছে...'), findsNothing);
      expect(
        find.text('ইন্টারনেট সংযোগ না থাকায় ক্যাটেগরি লোড হয়নি।'),
        findsNothing,
      );
    },
  );

  group('SyncService (FIX-02 §1: local-first submit + queue worker)', () {
    test(
      'submit() is local-first: inserts synced=0 immediately, returns the '
      'fixed success message, and never touches the network',
      () async {
        final db = _FakeDbService();
        final api = _ScriptedApiService()
          ..onSubmit = () async =>
              throw StateError('submit() must never call the network');
        final sync = SyncService(api: api, db: db);

        final result = await sync.submit(
          orgId: 7,
          rating: 'poor',
          comment: 'বাজে সেবা',
        );

        expect(result, isA<SubmitSuccess>());
        expect(
          (result as SubmitSuccess).message,
          'আপনার মূল্যবান মতামতের জন্য ধন্যবাদ! 👏',
        );
        expect(db.rows, hasLength(1));
        expect(db.rows.single.synced, 0);
        expect(db.rows.single.comment, 'বাজে সেবা');
      },
    );

    test(
      'submit() propagates a local insert failure instead of swallowing it',
      () async {
        final api = _ScriptedApiService()
          ..onSubmit = () async =>
              throw StateError('submit() must never call the network');
        final sync = SyncService(api: api, db: _InsertThrowingDbService());

        await expectLater(
          sync.submit(orgId: 7, rating: 'poor'),
          throwsA(isA<Exception>()),
        );
      },
    );

    test(
      'drainForTest() marks a success synced, a 422 rejected, stops the '
      'batch on any other error, and backs off',
      () async {
        final db = _FakeDbService()
          ..rows.addAll([
            FeedbackEntry(
              id: 1,
              orgId: 7,
              rating: 'poor',
              comment: 'first',
              categoryIds: const [],
              createdAt: DateTime(2024, 1, 1),
              synced: 0,
            ),
            FeedbackEntry(
              id: 2,
              orgId: 7,
              rating: 'poor',
              comment: 'second',
              categoryIds: const [],
              createdAt: DateTime(2024, 1, 2),
              synced: 0,
            ),
            FeedbackEntry(
              id: 3,
              orgId: 7,
              rating: 'poor',
              comment: 'third',
              categoryIds: const [],
              createdAt: DateTime(2024, 1, 3),
              synced: 0,
            ),
          ]);

        var call = 0;
        final api = _ScriptedApiService()
          ..onSubmit = () async {
            call++;
            if (call == 1) return const SubmitSuccess('ok');
            if (call == 2) {
              throw DioException(
                requestOptions: RequestOptions(path: '/feedback/store'),
                response: Response(
                  requestOptions: RequestOptions(path: '/feedback/store'),
                  statusCode: 422,
                ),
              );
            }
            // Third row: network failure — must stop the batch, not mark
            // anything, and never reach a fourth call.
            throw DioException(
              requestOptions: RequestOptions(path: '/feedback/store'),
            );
          };
        final sync = SyncService(api: api, db: db);

        await sync.drainForTest();

        expect(db.rows.firstWhere((r) => r.id == 1).synced, 1);
        expect(db.rows.firstWhere((r) => r.id == 2).synced, -1);
        expect(db.rows.firstWhere((r) => r.id == 3).synced, 0);
        expect(call, 3);

        // The batch stopped on a hard failure (the third row) — the next
        // attempt backs off from the regular 45s interval instead of
        // retrying immediately.
        final summary = await sync.debugSummary();
        expect(summary.consecutiveFailures, 1);
        expect(summary.currentBackoff, const Duration(seconds: 90));
      },
    );

    test('drainForTest() never throws even if the db itself fails', () async {
      final api = _ScriptedApiService()
        ..onSubmit = () async => const SubmitSuccess('ok');
      final sync = SyncService(api: api, db: _ThrowingDbService());

      await expectLater(sync.drainForTest(), completes);
    });

    test(
      'a successful drain resets the backoff back to the regular 45s interval',
      () async {
        final db = _FakeDbService()
          ..rows.add(
            FeedbackEntry(
              id: 1,
              orgId: 7,
              rating: 'poor',
              comment: '',
              categoryIds: const [],
              createdAt: DateTime(2024, 1, 1),
              synced: 0,
            ),
          );
        final api = _ScriptedApiService()
          ..onSubmit = () async => const SubmitSuccess('ok');
        final sync = SyncService(api: api, db: db);

        await sync.drainForTest();

        expect(db.rows.single.synced, 1);
        final summary = await sync.debugSummary();
        expect(summary.consecutiveFailures, 0);
        expect(summary.currentBackoff, const Duration(seconds: 45));
        expect(summary.lastSuccessfulSync, isNotNull);
      },
    );

    test(
      'FIX-03 §6: reproduces the "Sent=19 / last successful sync: never" '
      'report — lastSuccessfulSync is in-memory only and resets on every '
      'app launch, while the synced=1 count is a persisted DB fact; a fresh '
      'SyncService instance over a DB that already has synced rows from a '
      'previous run shows exactly this combination, with no data loss',
      () async {
        // Rows already synced=1 from a *previous* run, as if the app had
        // been restarted after successfully syncing 19 rows in an earlier
        // process.
        final db = _FakeDbService()
          ..rows.addAll(
            List.generate(
              19,
              (i) => FeedbackEntry(
                id: i + 1,
                orgId: 7,
                rating: 'good',
                comment: '',
                categoryIds: const [],
                createdAt: DateTime(2024, 1, 1).add(Duration(hours: i)),
                synced: 1,
              ),
            ),
          );
        final api = _ScriptedApiService()
          ..onSubmit = () async =>
              throw StateError('no drain has run in this fresh process yet');

        // A brand-new SyncService, as main() creates on every launch --
        // never told about the previous process's successful syncs.
        final sync = SyncService(api: api, db: db);
        final summary = await sync.debugSummary();

        expect(summary.total, 19);
        expect(summary.bySynced[1], 19, reason: 'the 19 sent rows are real, persisted DB rows');
        expect(summary.bySynced[0] ?? 0, 0, reason: 'nothing is stuck pending — no feedback was lost');
        expect(
          summary.lastSuccessfulSync,
          isNull,
          reason: 'this is the reported contradiction: reproduced exactly, '
              'and it is cosmetic — lastSuccessfulSync simply has not been '
              'set in *this* process yet, not evidence rows were marked '
              'synced without the server accepting them',
        );
      },
    );
  });

  testWidgets(
    'a non-DioException from sync.submit() resets isSubmitting and shows '
    'the real error instead of leaving the button stuck (FIX-01 §2/§3)',
    (WidgetTester tester) async {
      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: Builder(
              builder: (context) => ElevatedButton(
                onPressed: () => showFeedbackDialog<SubmitResult>(
                  context,
                  isPositive: true,
                  builder: (context, close) => PositiveDialogContent(
                    orgId: 1,
                    rating: 'very_good',
                    close: close,
                    sync: _ThrowingSyncService(),
                  ),
                ),
                child: const Text('open'),
              ),
            ),
          ),
        ),
      );

      await tester.tap(find.text('open'));
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 350));

      await tester.tap(find.text('জমা দিন'));
      await tester.pump();
      await tester.pump();

      // No uncaught exception reaches the framework — the dialog's own
      // broad catch handled it.
      expect(tester.takeException(), isNull);

      // The real exception is shown, not a generic string.
      expect(find.textContaining('StateError'), findsOneWidget);
      expect(find.textContaining('boom'), findsOneWidget);

      // Dismiss the error alert — the button must be usable again, not
      // stuck showing the spinner forever.
      await tester.tap(find.text('OK'));
      await tester.pump();

      expect(find.byType(CircularProgressIndicator), findsNothing);
      expect(find.byIcon(Icons.send), findsOneWidget);
    },
  );

  group('Responsive layout (SPEC-RESPONSIVE.md §9)', () {
    const sizes = [
      Size(360, 640), // small phone, portrait
      Size(640, 360), // small phone, landscape
      Size(412, 915), // large phone, portrait
      Size(915, 412), // large phone, landscape
      Size(800, 1280), // 7" tablet, portrait
      Size(1280, 800), // 7" tablet, landscape
      Size(1200, 1920), // 10" tablet, portrait
      Size(1920, 1200), // 10" tablet, landscape
    ];

    for (final size in sizes) {
      testWidgets(
        'feedback screen: no overflow at ${size.width.toInt()}x${size.height.toInt()}',
        (WidgetTester tester) async {
          tester.view.physicalSize = size;
          tester.view.devicePixelRatio = 1.0;
          addTearDown(tester.view.resetPhysicalSize);
          SharedPreferences.setMockInitialValues({'org_id': 7});
          final api = _FakeApiService()
            ..categories = const [
              Category(id: 1, name: 'দেরি'),
              Category(id: 2, name: 'দীর্ঘ ক্যাটেগরির নাম যা জায়গা নিতে পারে'),
            ];

          await tester.pumpWidget(
            MaterialApp(home: AppRoot(api: api, sync: _fakeSync(api))),
          );
          await tester.pump();
          await tester.pump();

          expect(tester.takeException(), isNull);
          expect(find.byType(RatingButton), findsNWidgets(5));
        },
      );

      testWidgets(
        'login screen: no overflow at ${size.width.toInt()}x${size.height.toInt()}',
        (WidgetTester tester) async {
          tester.view.physicalSize = size;
          tester.view.devicePixelRatio = 1.0;
          addTearDown(tester.view.resetPhysicalSize);

          await tester.pumpWidget(const FeedbackApp());
          await tester.pump();
          await tester.pump();

          expect(tester.takeException(), isNull);
          expect(find.byType(LoginScreen), findsOneWidget);
        },
      );
    }

    for (final size in sizes) {
      testWidgets(
        'negative dialog: no overflow at ${size.width.toInt()}x${size.height.toInt()}, with categories and comment',
        (WidgetTester tester) async {
          tester.view.physicalSize = size;
          tester.view.devicePixelRatio = 1.0;
          addTearDown(tester.view.resetPhysicalSize);
          SharedPreferences.setMockInitialValues({'org_id': 7});
          final api = _FakeApiService()
            ..categories = const [
              Category(id: 1, name: 'দেরি'),
              Category(id: 2, name: 'ব্যবহার'),
            ];

          await tester.pumpWidget(
            MaterialApp(home: AppRoot(api: api, sync: _fakeSync(api))),
          );
          await tester.pump();
          await tester.pump();

          await tester.tap(find.byType(RatingButton).last);
          await tester.pump();
          await tester.pump(const Duration(milliseconds: 350));
          await tester.pump();

          expect(tester.takeException(), isNull);
          expect(find.byType(CategoryPill), findsNWidgets(2));
        },
      );
    }

    testWidgets(
      'rotating with a dialog open keeps selected category and typed comment',
      (WidgetTester tester) async {
        tester.view.physicalSize = const Size(800, 1280);
        tester.view.devicePixelRatio = 1.0;
        addTearDown(tester.view.resetPhysicalSize);
        SharedPreferences.setMockInitialValues({'org_id': 7});
        final api = _FakeApiService()
          ..categories = const [Category(id: 1, name: 'দেরি')];

        await tester.pumpWidget(
          MaterialApp(home: AppRoot(api: api, sync: _fakeSync(api))),
        );
        await tester.pump();
        await tester.pump();

        await tester.tap(find.byType(RatingButton).last);
        await tester.pump();
        await tester.pump(const Duration(milliseconds: 350));
        await tester.pump();

        await tester.tap(find.text('দেরি'));
        await tester.pump();
        await tester.enterText(find.byType(TextField), 'আমার মন্তব্য');
        await tester.pump();

        // Rotate: portrait tablet -> landscape tablet.
        tester.view.physicalSize = const Size(1280, 800);
        await tester.pump();

        expect(tester.takeException(), isNull);
        expect(find.text('আমার মন্তব্য'), findsOneWidget);
        // The category pill is still selected — its label is now white.
        final labelFinder = find.text('দেরি');
        expect(labelFinder, findsOneWidget);
        final labelStyle = tester.widget<Text>(labelFinder).style;
        expect(labelStyle?.color, const Color(0xFFFFFFFF));
      },
    );
  });

  group('FIX-03 §3: dialog scroll + keyboard', () {
    // Widget tests never raise a real on-screen keyboard just by focusing a
    // field — that's exactly the gap that let the original bug through 44
    // passing tests. `tester.view.viewInsets` simulates the one thing that
    // actually matters here: MediaQuery.viewInsets.bottom becoming nonzero,
    // which is the real mechanism the fix reacts to.
    testWidgets(
      'phone landscape with keyboard open (~150px available): comment field '
      'and Submit are both reachable by scrolling, no overflow',
      (WidgetTester tester) async {
        tester.view.physicalSize = const Size(915, 412);
        tester.view.devicePixelRatio = 1.0;
        addTearDown(tester.view.resetPhysicalSize);
        addTearDown(tester.view.resetViewInsets);
        SharedPreferences.setMockInitialValues({'org_id': 7});
        final api = _FakeApiService()
          ..categories = const [Category(id: 1, name: 'দেরি')];

        await tester.pumpWidget(
          MaterialApp(home: AppRoot(api: api, sync: _fakeSync(api))),
        );
        await tester.pump();
        await tester.pump();

        await tester.tap(find.byType(RatingButton).last);
        await tester.pump();
        await tester.pump(const Duration(milliseconds: 350));
        await tester.pump();

        // Leaves ~150 logical px above the keyboard — FIX-03 §3's explicit
        // worst case.
        tester.view.viewInsets = const FakeViewPadding(bottom: 262);
        await tester.pump();
        await tester.pump();

        expect(tester.takeException(), isNull);

        await tester.ensureVisible(find.byType(TextField));
        await tester.pump();
        await tester.enterText(find.byType(TextField), 'কষ্ট করে লিখছি');
        await tester.pump();
        expect(find.text('কষ্ট করে লিখছি'), findsOneWidget);

        await tester.ensureVisible(find.text('ফিডব্যাক জমা দিন'));
        await tester.pump();
        expect(tester.takeException(), isNull);
        await tester.tap(find.text('ফিডব্যাক জমা দিন'));
        await tester.pump();
        await tester.pump();
        await tester.pump(const Duration(milliseconds: 350));
        await tester.pump();

        expect(find.text('ধন্যবাদ!'), findsOneWidget);
        await tester.pump(const Duration(seconds: 5));
      },
    );

    for (final size in [
      const Size(360, 640), // small phone, portrait
      const Size(640, 360), // small phone, landscape
      const Size(412, 915), // large phone, portrait
      const Size(915, 412), // large phone, landscape
    ]) {
      testWidgets(
        'negative dialog with keyboard open at '
        '${size.width.toInt()}x${size.height.toInt()}: no overflow, Submit reachable',
        (WidgetTester tester) async {
          tester.view.physicalSize = size;
          tester.view.devicePixelRatio = 1.0;
          addTearDown(tester.view.resetPhysicalSize);
          addTearDown(tester.view.resetViewInsets);
          SharedPreferences.setMockInitialValues({'org_id': 7});
          final api = _FakeApiService()
            ..categories = const [
              Category(id: 1, name: 'দেরি'),
              Category(id: 2, name: 'ব্যবহার'),
            ];

          await tester.pumpWidget(
            MaterialApp(home: AppRoot(api: api, sync: _fakeSync(api))),
          );
          await tester.pump();
          await tester.pump();

          await tester.tap(find.byType(RatingButton).last);
          await tester.pump();
          await tester.pump(const Duration(milliseconds: 350));
          await tester.pump();

          // A software keyboard covers roughly 40% of the screen on a real
          // device.
          tester.view.viewInsets = FakeViewPadding(bottom: size.height * 0.4);
          await tester.pump();
          await tester.pump();

          expect(tester.takeException(), isNull);
          await tester.ensureVisible(find.text('ফিডব্যাক জমা দিন'));
          await tester.pump();
          expect(tester.takeException(), isNull);
        },
      );
    }

    testWidgets(
      'rotating with the keyboard open, text typed, and a category selected '
      'loses nothing',
      (WidgetTester tester) async {
        tester.view.physicalSize = const Size(800, 1280);
        tester.view.devicePixelRatio = 1.0;
        addTearDown(tester.view.resetPhysicalSize);
        addTearDown(tester.view.resetViewInsets);
        SharedPreferences.setMockInitialValues({'org_id': 7});
        final api = _FakeApiService()
          ..categories = const [Category(id: 1, name: 'দেরি')];

        await tester.pumpWidget(
          MaterialApp(home: AppRoot(api: api, sync: _fakeSync(api))),
        );
        await tester.pump();
        await tester.pump();

        await tester.tap(find.byType(RatingButton).last);
        await tester.pump();
        await tester.pump(const Duration(milliseconds: 350));
        await tester.pump();

        await tester.tap(find.text('দেরি'));
        await tester.pump();
        await tester.enterText(find.byType(TextField), 'আমার মন্তব্য');
        await tester.pump();

        tester.view.viewInsets = const FakeViewPadding(bottom: 500);
        await tester.pump();

        tester.view.physicalSize = const Size(1280, 800);
        tester.view.viewInsets = const FakeViewPadding(bottom: 350);
        await tester.pump();

        expect(tester.takeException(), isNull);
        expect(find.text('আমার মন্তব্য'), findsOneWidget);
        final labelStyle = tester.widget<Text>(find.text('দেরি')).style;
        expect(labelStyle?.color, const Color(0xFFFFFFFF));
      },
    );
  });

  group('FIX-03 §9: idle reset', () {
    testWidgets(
      '60s with no interaction silently closes the dialog and discards state',
      (WidgetTester tester) async {
        _useTabletSize(tester);
        SharedPreferences.setMockInitialValues({'org_id': 7});
        final api = _FakeApiService()
          ..categories = const [Category(id: 1, name: 'দেরি')];

        await tester.pumpWidget(
          MaterialApp(home: AppRoot(api: api, sync: _fakeSync(api))),
        );
        await tester.pump();
        await tester.pump();

        await tester.tap(find.byType(RatingButton).last);
        await tester.pump();
        await tester.pump(const Duration(milliseconds: 350));
        await tester.pump();

        await tester.enterText(find.byType(TextField), 'অসম্পূর্ণ মন্তব্য');
        await tester.pump();

        await tester.pump(const Duration(seconds: 60));
        await tester.pump(const Duration(milliseconds: 300));
        await tester.pump();

        expect(find.text('কোথায় সমস্যা হয়েছে জানান'), findsNothing);
        // Discarded silently, not submitted.
        expect(find.text('ধন্যবাদ!'), findsNothing);
      },
    );

    testWidgets(
      'interaction resets the idle timer so a genuine in-progress comment '
      'is not cut off mid-sentence',
      (WidgetTester tester) async {
        _useTabletSize(tester);
        SharedPreferences.setMockInitialValues({'org_id': 7});
        final api = _FakeApiService()
          ..categories = const [Category(id: 1, name: 'দেরি')];

        await tester.pumpWidget(
          MaterialApp(home: AppRoot(api: api, sync: _fakeSync(api))),
        );
        await tester.pump();
        await tester.pump();

        await tester.tap(find.byType(RatingButton).last);
        await tester.pump();
        await tester.pump(const Duration(milliseconds: 350));
        await tester.pump();

        // Two windows that individually stay under 60s but together exceed
        // it — only possible to still be open if each keystroke really did
        // reset the clock.
        await tester.pump(const Duration(seconds: 45));
        await tester.enterText(find.byType(TextField), 'আমি একটি দীর্ঘ');
        await tester.pump();
        await tester.pump(const Duration(seconds: 45));
        await tester.enterText(
          find.byType(TextField),
          'আমি একটি দীর্ঘ মন্তব্য লিখছি',
        );
        await tester.pump();

        expect(find.text('কোথায় সমস্যা হয়েছে জানান'), findsOneWidget);
      },
    );
  });
}

/// Simulates the db layer itself failing (e.g. disk error) to prove a sync
/// tick can never crash the app (§4.8).
class _ThrowingDbService extends DbService {
  @override
  Future<List<FeedbackEntry>> getUnsyncedBatch({int limit = 5}) async {
    throw Exception('disk is on fire');
  }
}

/// FIX-01 §2/§5: simulates the local insert itself failing — a db error
/// after the network call already succeeded (or after deciding to save
/// offline) must never turn that outcome into an uncaught error.
class _InsertThrowingDbService extends DbService {
  @override
  Future<int> insert(FeedbackEntry entry) async {
    throw Exception('local insert failed');
  }
}

/// FIX-01 §2/§3: stands in for any non-DioException SyncService.submit()
/// might throw (a local db error, or anything else) — proves the dialogs'
/// broad catch resets isSubmitting and surfaces the real error instead of
/// leaving the button stuck with no explanation.
class _ThrowingSyncService extends SyncService {
  @override
  Future<SubmitResult> submit({
    required int orgId,
    required String rating,
    String comment = '',
    List<int> categoryIds = const [],
  }) async {
    throw StateError('boom: something other than a DioException');
  }
}
