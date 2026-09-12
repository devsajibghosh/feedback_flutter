import 'dart:convert';
import 'dart:io';

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
import 'package:feedback/widgets/marquee_bar.dart';
import 'package:feedback/widgets/negative_dialog.dart';
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

      expect(find.text('কেন সন্তুষ্ট হন নি?'), findsOneWidget);
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
        : 'কেন সন্তুষ্ট হন নি?';

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
      'FIX-03 §1: drainForTest() uploads only the single oldest pending row, '
      'even with several queued',
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
        var calls = 0;
        final api = _ScriptedApiService()
          ..onSubmit = () async {
            calls++;
            return const SubmitSuccess('ok');
          };
        final sync = SyncService(api: api, db: db);

        await sync.drainForTest();

        expect(calls, 1);
        expect(db.rows.firstWhere((r) => r.id == 1).synced, 1);
        expect(db.rows.firstWhere((r) => r.id == 2).synced, 0);
        expect(db.rows.firstWhere((r) => r.id == 3).synced, 0);
      },
    );

    test(
      'FIX-03 §1: the 30s upload throttle blocks a second drain immediately '
      'after the first, even with a row still pending',
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
          ]);
        var calls = 0;
        final api = _ScriptedApiService()
          ..onSubmit = () async {
            calls++;
            return const SubmitSuccess('ok');
          };
        final sync = SyncService(api: api, db: db);

        await sync.drainForTest();
        expect(calls, 1);

        // Immediately again — well within the 30s throttle window. This is
        // the "5s first-attempt timer and the 30s throttle disagree" case;
        // the throttle must win.
        await sync.drainForTest();
        expect(calls, 1);
        expect(db.rows.firstWhere((r) => r.id == 2).synced, 0);
      },
    );

    test(
      'a 422 marks the row rejected without counting as a hard failure',
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
          ..onSubmit = () async => throw DioException(
                requestOptions: RequestOptions(path: '/feedback/store'),
                response: Response(
                  requestOptions: RequestOptions(path: '/feedback/store'),
                  statusCode: 422,
                ),
              );
        final sync = SyncService(api: api, db: db);

        await sync.drainForTest();

        expect(db.rows.single.synced, -1);
        final summary = await sync.debugSummary();
        expect(summary.consecutiveFailures, 0);
        expect(summary.currentBackoff, const Duration(seconds: 45));
      },
    );

    test(
      'a hard failure (non-422 network/HTTP error) leaves the row pending '
      'and backs off',
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
          ..onSubmit = () async => throw DioException(
                requestOptions: RequestOptions(path: '/feedback/store'),
              );
        final sync = SyncService(api: api, db: db);

        await sync.drainForTest();

        expect(db.rows.single.synced, 0);
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
    'a plain generic message instead of leaving the button stuck '
    '(FIX-01 §2/§3, message genericised by FIX-03 §6)',
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

      // FIX-03 §6: no raw exception text or "(ডিবাগ)" label any more —
      // the real error goes to the internal log only, and the user sees
      // the same plain, calm copy every other alert uses.
      expect(find.textContaining('StateError'), findsNothing);
      expect(find.textContaining('boom'), findsNothing);
      expect(
        find.text('দুঃখিত, একটি সমস্যা হয়েছে। আবার চেষ্টা করুন।'),
        findsOneWidget,
      );

      // Dismiss the error alert — the button must be usable again, not
      // stuck showing the spinner forever.
      await tester.tap(find.text('ঠিক আছে'));
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
      const Size(800, 1280), // 7" tablet, portrait
      const Size(1280, 800), // 7" tablet, landscape
      const Size(1200, 1920), // 10" tablet, portrait
      const Size(1920, 1200), // 10" tablet, landscape
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

        expect(find.text('কেন সন্তুষ্ট হন নি?'), findsNothing);
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

        expect(find.text('কেন সন্তুষ্ট হন নি?'), findsOneWidget);
      },
    );
  });

  group('FIX-03 §6: debug surfaces removed', () {
    testWidgets('long-pressing the marquee bar does nothing any more',
        (WidgetTester tester) async {
      _useTabletSize(tester);
      SharedPreferences.setMockInitialValues({'org_id': 7});
      final api = _FakeApiService();

      await tester.pumpWidget(
        MaterialApp(home: AppRoot(api: api, sync: _fakeSync(api))),
      );
      await tester.pump();
      await tester.pump();

      await tester.longPress(find.byType(MarqueeBar));
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 350));

      expect(tester.takeException(), isNull);
      expect(find.byType(AlertDialog), findsNothing);
      expect(find.textContaining('Debug dump'), findsNothing);
    });

    testWidgets(
      'a local-write failure shows the plain generic message, not the old '
      '"অপ্রত্যাশিত ত্রুটি (ডিবাগ)" debug label',
      (WidgetTester tester) async {
        _useTabletSize(tester);
        SharedPreferences.setMockInitialValues({'org_id': 7});
        final api = _FakeApiService();

        await tester.pumpWidget(
          MaterialApp(
            home: AppRoot(
              api: api,
              sync: _ThrowingSyncService(),
            ),
          ),
        );
        await tester.pump();
        await tester.pump();

        await tester.tap(find.byType(RatingButton).first);
        await tester.pump();
        await tester.pump(const Duration(milliseconds: 350));
        await tester.tap(find.text('জমা দিন'));
        await tester.pump();
        await tester.pump();

        expect(find.textContaining('ডিবাগ'), findsNothing);
        expect(
          find.text('দুঃখিত, একটি সমস্যা হয়েছে। আবার চেষ্টা করুন।'),
          findsOneWidget,
        );
      },
    );
  });

  group('FIX-03 §5: card typography — emoji leads, text confirms', () {
    testWidgets(
      'emoji is ~2.2x the Bengali label and all five cards stay the same '
      'height — at compact, medium, and expanded',
      (WidgetTester tester) async {
        SharedPreferences.setMockInitialValues({'org_id': 7});
        final api = _FakeApiService();

        for (final size in [
          const Size(500, 900), // compact: shortestSide < 600
          const Size(700, 1000), // medium: 600-840
          const Size(1280, 800), // expanded: >= 840
        ]) {
          tester.view.physicalSize = size;
          tester.view.devicePixelRatio = 1.0;
          addTearDown(tester.view.resetPhysicalSize);

          await tester.pumpWidget(
            MaterialApp(home: AppRoot(api: api, sync: _fakeSync(api))),
          );
          await tester.pump();
          await tester.pump();

          final spec = kRatingSpecs.first; // very_good
          final emojiSize =
              tester.widget<Text>(find.text(spec.emoji)).style!.fontSize!;
          final labelSize =
              tester.widget<Text>(find.text(spec.label)).style!.fontSize!;

          expect(
            emojiSize / labelSize,
            closeTo(2.2, 0.15),
            reason: 'at ${size.width.toInt()}x${size.height.toInt()}: '
                'emoji=$emojiSize label=$labelSize',
          );

          final cardHeights = tester
              .renderObjectList<RenderBox>(find.byType(RatingButton))
              .map((r) => r.size.height)
              .toSet();
          expect(cardHeights, hasLength(1),
              reason: 'all five rating cards must be exactly the same height');

          expect(tester.takeException(), isNull);
        }
      },
    );
  });

  group('FIX-05 §5: English sub-labels removed', () {
    testWidgets(
      'none of Excellent/Good/Satisfactory/Poor/Very poor appear anywhere '
      'on the rating screen',
      (WidgetTester tester) async {
        SharedPreferences.setMockInitialValues({'org_id': 7});
        final api = _FakeApiService();

        await tester.pumpWidget(
          MaterialApp(home: AppRoot(api: api, sync: _fakeSync(api))),
        );
        await tester.pump();
        await tester.pump();

        for (final english in [
          'Excellent',
          'Good',
          'Satisfactory',
          'Poor',
          'Very poor',
        ]) {
          expect(find.text(english), findsNothing);
        }
      },
    );
  });

  group('FIX-03 §4: helper text under the rating cards', () {
    const helperText =
        'খারাপ বা খুব খারাপ নির্বাচন করলে সমস্যার বিস্তারিত জানানোর সুযোগ থাকবে।';

    testWidgets('shown below the rating grid on a normal-height screen',
        (WidgetTester tester) async {
      _useTabletSize(tester);
      SharedPreferences.setMockInitialValues({'org_id': 7});
      final api = _FakeApiService();

      await tester.pumpWidget(
        MaterialApp(home: AppRoot(api: api, sync: _fakeSync(api))),
      );
      await tester.pump();
      await tester.pump();

      expect(find.text(helperText), findsOneWidget);
      final text = tester.widget<Text>(find.text(helperText));
      expect(text.textAlign, TextAlign.center);
      expect(text.maxLines, isNull, reason: 'must never truncate');

      // Below the rating row, not above or beside it.
      final rowBottom = tester.getBottomLeft(find.byType(RatingButton).first).dy;
      final helperTop = tester.getTopLeft(find.text(helperText)).dy;
      expect(helperTop, greaterThanOrEqualTo(rowBottom));
    });

    testWidgets('hidden on a short-height (phone-landscape) screen',
        (WidgetTester tester) async {
      tester.view.physicalSize = const Size(915, 412);
      tester.view.devicePixelRatio = 1.0;
      addTearDown(tester.view.resetPhysicalSize);
      SharedPreferences.setMockInitialValues({'org_id': 7});
      final api = _FakeApiService();

      await tester.pumpWidget(
        MaterialApp(home: AppRoot(api: api, sync: _fakeSync(api))),
      );
      await tester.pump();
      await tester.pump();

      expect(find.text(helperText), findsNothing);
    });

    testWidgets('is plain informational text, not a tappable control',
        (WidgetTester tester) async {
      _useTabletSize(tester);
      SharedPreferences.setMockInitialValues({'org_id': 7});
      final api = _FakeApiService();

      await tester.pumpWidget(
        MaterialApp(home: AppRoot(api: api, sync: _fakeSync(api))),
      );
      await tester.pump();
      await tester.pump();

      // Tapping it must do nothing — no dialog opens, nothing throws.
      await tester.tap(find.text(helperText));
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 350));

      expect(tester.takeException(), isNull);
      expect(find.text('আপনার ইতিবাচক মতামতের\nজন্য ধন্যবাদ!'), findsNothing);
      expect(find.text('কেন সন্তুষ্ট হন নি?'), findsNothing);
    });
  });

  group('FIX-03 §2: success message — 4s, non-blocking', () {
    testWidgets('the message auto-dismisses at 4s, not the old 1500ms',
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
      await tester.tap(find.text('জমা দিন'));
      await tester.pump();
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 350));
      await tester.pump();

      expect(find.text('ধন্যবাদ!'), findsOneWidget);

      // Still up well after the old 1500ms cutoff.
      await tester.pump(const Duration(milliseconds: 2000));
      expect(find.text('ধন্যবাদ!'), findsOneWidget);

      // Gone by 4s.
      await tester.pump(const Duration(milliseconds: 2100));
      expect(find.text('ধন্যবাদ!'), findsNothing);

      // Let the row's own 5s-after-insert queue-worker timer fire too, so
      // no pending timer remains at teardown.
      await tester.pump(const Duration(seconds: 2));
    });

    testWidgets('tapping the message dismisses it early',
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
      await tester.tap(find.text('জমা দিন'));
      await tester.pump();
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 350));
      await tester.pump();

      expect(find.text('ধন্যবাদ!'), findsOneWidget);
      await tester.tap(find.text('ধন্যবাদ!'));
      await tester.pump();

      expect(find.text('ধন্যবাদ!'), findsNothing);
      await tester.pump(const Duration(seconds: 6));
    });

    testWidgets(
      'tapping a new rating while the message is up closes it immediately '
      'and opens the new dialog — the message never blocks the next tap',
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
        await tester.tap(find.text('জমা দিন'));
        await tester.pump();
        await tester.pump();
        await tester.pump(const Duration(milliseconds: 350));
        await tester.pump();

        expect(find.text('ধন্যবাদ!'), findsOneWidget);

        // A second person walks up immediately, well inside the 4s window —
        // this must work right away, not after the message finishes.
        await tester.tap(find.byType(RatingButton).last);
        await tester.pump();
        await tester.pump(const Duration(milliseconds: 350));
        await tester.pump();

        expect(find.text('ধন্যবাদ!'), findsNothing);
        expect(find.text('কেন সন্তুষ্ট হন নি?'), findsOneWidget);

        // Close the second dialog and let both its 60s idle timer and the
        // first row's 5s queue-worker timer resolve, so nothing is pending
        // at teardown.
        await tester.tap(find.text('বাতিল'));
        await tester.pump();
        await tester.pump(const Duration(milliseconds: 350));
        await tester.pump(const Duration(seconds: 6));
      },
    );

    testWidgets(
      'backgrounding the app while the message is up removes it, with no '
      'stale timer resuming later',
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
        await tester.tap(find.text('জমা দিন'));
        await tester.pump();
        await tester.pump();
        await tester.pump(const Duration(milliseconds: 350));
        await tester.pump();

        expect(find.text('ধন্যবাদ!'), findsOneWidget);

        tester.binding
            .handleAppLifecycleStateChanged(AppLifecycleState.paused);
        await tester.pump();
        expect(find.text('ধন্যবাদ!'), findsNothing);

        tester.binding
            .handleAppLifecycleStateChanged(AppLifecycleState.resumed);
        await tester.pump();
        await tester.pump(const Duration(seconds: 5));
        expect(find.text('ধন্যবাদ!'), findsNothing);
        await tester.pump(const Duration(seconds: 2));
      },
    );
  });

  group('FIX-03 §8: interaction hardening', () {
    testWidgets('double-tapping a rating opens only one dialog',
        (WidgetTester tester) async {
      _useTabletSize(tester);
      SharedPreferences.setMockInitialValues({'org_id': 7});
      final api = _FakeApiService();

      await tester.pumpWidget(
        MaterialApp(home: AppRoot(api: api, sync: _fakeSync(api))),
      );
      await tester.pump();
      await tester.pump();

      // Back-to-back, before the first tap's async dialog-open work has a
      // chance to complete. The second tap's coordinate may already land
      // on the opening dialog rather than the button underneath it — that
      // is the realistic scenario this test exists to cover, so the
      // harness's "didn't hit the widget you searched for" warning is
      // expected here, not a sign of anything wrong.
      await tester.tap(find.byType(RatingButton).first);
      await tester.tap(find.byType(RatingButton).first, warnIfMissed: false);
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 350));

      expect(find.text('আপনার ইতিবাচক মতামতের\nজন্য ধন্যবাদ!'), findsOneWidget);
    });

    testWidgets('rapid taps across different ratings do not queue up dialogs',
        (WidgetTester tester) async {
      _useTabletSize(tester);
      SharedPreferences.setMockInitialValues({'org_id': 7});
      final api = _FakeApiService();

      await tester.pumpWidget(
        MaterialApp(home: AppRoot(api: api, sync: _fakeSync(api))),
      );
      await tester.pump();
      await tester.pump();

      // The first tap starts opening a dialog, so the later taps' target
      // buttons are realistically already covered by it by the time they
      // land — expected here, not a sign of anything wrong (same as the
      // double-tap test above).
      await tester.tap(find.byType(RatingButton).at(0));
      await tester.tap(find.byType(RatingButton).at(1), warnIfMissed: false);
      await tester.tap(find.byType(RatingButton).at(4), warnIfMissed: false);
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 350));

      // Only the very first tap's dialog exists — cancelling it must reveal
      // a plain rating screen, not a second dialog waiting behind it.
      await tester.tap(find.text('বাতিল'));
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 350));

      expect(find.text('আপনার ইতিবাচক মতামতের\nজন্য ধন্যবাদ!'), findsNothing);
      expect(find.text('কেন সন্তুষ্ট হন নি?'), findsNothing);
    });

    testWidgets('tapping the barrier does nothing', (WidgetTester tester) async {
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
      expect(find.text('আপনার ইতিবাচক মতামতের\nজন্য ধন্যবাদ!'), findsOneWidget);

      // Far corner, outside the centred dialog card.
      await tester.tapAt(const Offset(5, 5));
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 350));

      expect(find.text('আপনার ইতিবাচক মতামতের\nজন্য ধন্যবাদ!'), findsOneWidget);
    });

    testWidgets('the back button does nothing at the root',
        (WidgetTester tester) async {
      _useTabletSize(tester);
      SharedPreferences.setMockInitialValues({'org_id': 7});
      final api = _FakeApiService();

      await tester.pumpWidget(
        MaterialApp(home: AppRoot(api: api, sync: _fakeSync(api))),
      );
      await tester.pump();
      await tester.pump();

      expect(find.byType(FeedbackScreen), findsOneWidget);
      await tester.binding.handlePopRoute();
      await tester.pump();

      expect(find.byType(FeedbackScreen), findsOneWidget);
    });

    testWidgets('the back button inside an open dialog closes it and nothing more',
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
      expect(find.text('আপনার ইতিবাচক মতামতের\nজন্য ধন্যবাদ!'), findsOneWidget);

      await tester.binding.handlePopRoute();
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 300));

      expect(find.text('আপনার ইতিবাচক মতামতের\nজন্য ধন্যবাদ!'), findsNothing);
      expect(find.byType(FeedbackScreen), findsOneWidget);
    });

    testWidgets(
      'FeedbackDialogGuard can force-close whatever dialog is open — the '
      'mechanism main.dart\'s global error handlers use so a stuck dialog '
      'is never unrecoverable',
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
        expect(find.text('আপনার ইতিবাচক মতামতের\nজন্য ধন্যবাদ!'), findsOneWidget);

        FeedbackDialogGuard.closeActiveDialog();
        await tester.pump();
        await tester.pump(const Duration(milliseconds: 300));

        expect(find.text('আপনার ইতিবাচক মতামতের\nজন্য ধন্যবাদ!'), findsNothing);
        expect(find.byType(FeedbackScreen), findsOneWidget);
      },
    );

    test('FeedbackDialogGuard.closeActiveDialog() is a no-op with no dialog open',
        () {
      expect(FeedbackDialogGuard.closeActiveDialog, returnsNormally);
    });

    testWidgets('system text scale is clamped to 1.3x max at the root',
        (WidgetTester tester) async {
      _useTabletSize(tester);
      tester.platformDispatcher.textScaleFactorTestValue = 3.0;
      addTearDown(tester.platformDispatcher.clearTextScaleFactorTestValue);

      await tester.pumpWidget(const FeedbackApp());
      await tester.pump();
      await tester.pump();

      final context = tester.element(find.byType(LoginScreen));
      expect(MediaQuery.textScalerOf(context).scale(100.0), 130.0);
    });

    testWidgets('system text scale is clamped to 0.85x min at the root',
        (WidgetTester tester) async {
      _useTabletSize(tester);
      tester.platformDispatcher.textScaleFactorTestValue = 0.3;
      addTearDown(tester.platformDispatcher.clearTextScaleFactorTestValue);

      await tester.pumpWidget(const FeedbackApp());
      await tester.pump();
      await tester.pump();

      final context = tester.element(find.byType(LoginScreen));
      expect(MediaQuery.textScalerOf(context).scale(100.0), 85.0);
    });

    testWidgets('a 40-character category name wraps instead of clipping',
        (WidgetTester tester) async {
      _useTabletSize(tester);
      SharedPreferences.setMockInitialValues({'org_id': 7});
      const longName =
          'এটি একটি অত্যন্ত দীর্ঘ ক্যাটেগরির নাম যা চল্লিশটি অক্ষরের বেশি দীর্ঘ';
      final api = _FakeApiService()
        ..categories = const [Category(id: 1, name: longName)];

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
      final label = tester.widget<Text>(find.text(longName));
      expect(label.overflow, isNot(TextOverflow.ellipsis));
      expect(label.maxLines, isNull);
    });

    testWidgets('10+ categories scroll within the dialog instead of overflowing',
        (WidgetTester tester) async {
      tester.view.physicalSize = const Size(412, 915);
      tester.view.devicePixelRatio = 1.0;
      addTearDown(tester.view.resetPhysicalSize);
      SharedPreferences.setMockInitialValues({'org_id': 7});
      final api = _FakeApiService()
        ..categories = [
          for (var i = 1; i <= 14; i++) Category(id: i, name: 'কারণ নম্বর $i'),
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
      expect(find.byType(CategoryPill), findsNWidgets(14));

      await tester.ensureVisible(find.text('কারণ নম্বর 14'));
      await tester.pump();
      expect(tester.takeException(), isNull);
    });
  });

  group('FIX-04 §1: negative dialog header mirrors the tapped rating', () {
    testWidgets('poor shows 🙁, not a generic icon and not 😞',
        (WidgetTester tester) async {
      _useTabletSize(tester);
      SharedPreferences.setMockInitialValues({'org_id': 7});
      final api = _FakeApiService();

      await tester.pumpWidget(
        MaterialApp(home: AppRoot(api: api, sync: _fakeSync(api))),
      );
      await tester.pump();
      await tester.pump();

      // kRatingSpecs[3] is 'poor'.
      await tester.tap(find.byType(RatingButton).at(3));
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 350));
      await tester.pump();

      // Scoped to the dialog content — the rating screen behind it still
      // has its own "😞"/"🙁" RatingButton emoji mounted (just visually
      // covered by the modal), which a bare find.text would also match.
      final dialog = find.byType(NegativeDialogContent);
      expect(
        find.descendant(of: dialog, matching: find.text('🙁')),
        findsOneWidget,
      );
      expect(
        find.descendant(of: dialog, matching: find.text('😞')),
        findsNothing,
      );
    });

    testWidgets('very_poor shows 😞, not 🙁', (WidgetTester tester) async {
      _useTabletSize(tester);
      SharedPreferences.setMockInitialValues({'org_id': 7});
      final api = _FakeApiService();

      await tester.pumpWidget(
        MaterialApp(home: AppRoot(api: api, sync: _fakeSync(api))),
      );
      await tester.pump();
      await tester.pump();

      // kRatingSpecs[4] is 'very_poor'.
      await tester.tap(find.byType(RatingButton).at(4));
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 350));
      await tester.pump();

      final dialog = find.byType(NegativeDialogContent);
      expect(
        find.descendant(of: dialog, matching: find.text('😞')),
        findsOneWidget,
      );
      expect(
        find.descendant(of: dialog, matching: find.text('🙁')),
        findsNothing,
      );
    });

    testWidgets(
      'the old badge, old title, and old category section label are gone',
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

        expect(find.text('খারাপ — মন্তব্য জানান'), findsNothing);
        expect(find.text('কারণ নির্বাচন করুন'), findsNothing);
        expect(find.text('কেন সন্তুষ্ট হন নি?'), findsOneWidget);
      },
    );

    testWidgets(
      'FIX-05 §1: the rating\'s own Bengali name renders under the emoji',
      (WidgetTester tester) async {
        _useTabletSize(tester);
        SharedPreferences.setMockInitialValues({'org_id': 7});
        final api = _FakeApiService();

        await tester.pumpWidget(
          MaterialApp(home: AppRoot(api: api, sync: _fakeSync(api))),
        );
        await tester.pump();
        await tester.pump();

        // kRatingSpecs[3] is 'poor'.
        await tester.tap(find.byType(RatingButton).at(3));
        await tester.pump();
        await tester.pump(const Duration(milliseconds: 350));
        await tester.pump();

        final dialog = find.byType(NegativeDialogContent);
        expect(
          find.descendant(of: dialog, matching: find.text('খারাপ')),
          findsOneWidget,
        );
        expect(
          find.descendant(of: dialog, matching: find.text('খুব খারাপ')),
          findsNothing,
        );
      },
    );

    testWidgets(
      'FIX-05 §1: very_poor renders খুব খারাপ, not খারাপ',
      (WidgetTester tester) async {
        _useTabletSize(tester);
        SharedPreferences.setMockInitialValues({'org_id': 7});
        final api = _FakeApiService();

        await tester.pumpWidget(
          MaterialApp(home: AppRoot(api: api, sync: _fakeSync(api))),
        );
        await tester.pump();
        await tester.pump();

        // kRatingSpecs[4] is 'very_poor'.
        await tester.tap(find.byType(RatingButton).at(4));
        await tester.pump();
        await tester.pump(const Duration(milliseconds: 350));
        await tester.pump();

        final dialog = find.byType(NegativeDialogContent);
        expect(
          find.descendant(of: dialog, matching: find.text('খুব খারাপ')),
          findsOneWidget,
        );
      },
    );

    testWidgets(
      'the head collapses when the keyboard opens and restores when it '
      'closes (simulated viewInsets — a real device keyboard was not '
      'available to test this against)',
      (WidgetTester tester) async {
        _useTabletSize(tester);
        SharedPreferences.setMockInitialValues({'org_id': 7});
        final api = _FakeApiService();

        await tester.pumpWidget(
          MaterialApp(home: AppRoot(api: api, sync: _fakeSync(api))),
        );
        await tester.pump();
        await tester.pump();

        await tester.tap(find.byType(RatingButton).last);
        await tester.pump();
        await tester.pump(const Duration(milliseconds: 350));
        await tester.pump();

        // Scoped to the dialog: the rating screen behind it still has its
        // own same-emoji, same-label RatingButton mounted, which would
        // double-count an unscoped find.
        final dialog = find.byType(NegativeDialogContent);

        expect(find.text('কেন সন্তুষ্ট হন নি?'), findsOneWidget);
        expect(
          find.descendant(of: dialog, matching: find.text('খুব খারাপ')),
          findsOneWidget,
        );

        tester.view.viewInsets = const FakeViewPadding(bottom: 500);
        addTearDown(tester.view.resetViewInsets);
        await tester.pump();
        await tester.pump(const Duration(milliseconds: 160));

        expect(find.text('কেন সন্তুষ্ট হন নি?'), findsNothing);
        expect(
          find.descendant(of: dialog, matching: find.text('খুব খারাপ')),
          findsNothing,
        );
        // The notice strip is unaffected — only the head collapses.
        expect(
          find.text('আপনার সেবা দিতে না পারার জন্য আমরা আন্তরিকভাবে দুঃখিত।'),
          findsOneWidget,
        );

        tester.view.viewInsets = FakeViewPadding.zero;
        await tester.pump();
        await tester.pump(const Duration(milliseconds: 160));

        expect(find.text('কেন সন্তুষ্ট হন নি?'), findsOneWidget);
        expect(
          find.descendant(of: dialog, matching: find.text('খুব খারাপ')),
          findsOneWidget,
        );
      },
    );
  });

  group('FIX-04 §2: comment label is a larger prompt', () {
    testWidgets(
      'no pen icon, ink at weight 600, optional marker stays secondary',
      (WidgetTester tester) async {
        _useTabletSize(tester);
        SharedPreferences.setMockInitialValues({'org_id': 7});
        final api = _FakeApiService();

        await tester.pumpWidget(
          MaterialApp(home: AppRoot(api: api, sync: _fakeSync(api))),
        );
        await tester.pump();
        await tester.pump();

        await tester.tap(find.byType(RatingButton).last);
        await tester.pump();
        await tester.pump(const Duration(milliseconds: 350));
        await tester.pump();

        expect(find.byIcon(Icons.edit), findsNothing);

        final label = tester.widget<Text>(
          find.text('অন্য কারণ থাকলে এখানে লিখুন'),
        );
        expect(label.style?.color, const Color(0xFF1C1C1A)); // AppTokens.ink
        expect(label.style?.fontWeight, FontWeight.w600);

        final optional = tester.widget<Text>(find.text('(ঐচ্ছিক)'));
        expect(optional.style?.fontWeight, FontWeight.w400);
        expect(
          optional.style!.fontSize! < label.style!.fontSize!,
          isTrue,
          reason: 'the optional marker must stay visually secondary',
        );
      },
    );

    testWidgets(
      'the notice strip now matches the comment label size (same tier of '
      'text)',
      (WidgetTester tester) async {
        _useTabletSize(tester);
        SharedPreferences.setMockInitialValues({'org_id': 7});
        final api = _FakeApiService();

        await tester.pumpWidget(
          MaterialApp(home: AppRoot(api: api, sync: _fakeSync(api))),
        );
        await tester.pump();
        await tester.pump();

        await tester.tap(find.byType(RatingButton).last);
        await tester.pump();
        await tester.pump(const Duration(milliseconds: 350));
        await tester.pump();

        final label = tester.widget<Text>(
          find.text('অন্য কারণ থাকলে এখানে লিখুন'),
        );
        final notice = tester.widget<Text>(
          find.text('আপনার সেবা দিতে না পারার জন্য আমরা আন্তরিকভাবে দুঃখিত।'),
        );
        expect(notice.style?.fontSize, label.style?.fontSize);
      },
    );
  });

  group('FIX-03 §7: stability audit', () {
    test(
      'a malformed/non-JSON response (a captive-portal page, say) is '
      'treated as a failure, never parsed as success',
      () async {
        final server =
            await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
        addTearDown(() => server.close(force: true));
        server.listen((request) async {
          request.response
            ..statusCode = 200
            ..headers.contentType = ContentType.html
            ..write('<html><body>Please log in to the wifi</body></html>');
          await request.response.close();
        });

        final api = ApiService(
          baseUrl: 'http://127.0.0.1:${server.port}',
        );

        SubmitResult? result;
        Object? error;
        try {
          result = await api.submitFeedback(orgId: 1, rating: 'poor');
        } catch (e) {
          error = e;
        }

        // Either outcome is acceptable — a thrown DioException (the JSON
        // transformer rejecting non-JSON content) or a SubmitFailure — as
        // long as it is never SubmitSuccess.
        expect(result, isNot(isA<SubmitSuccess>()));
        if (error != null) {
          expect(error, isA<DioException>());
        }
      },
    );

    testWidgets(
      'rotating 20 times with a dialog open, text typed, and a category '
      'selected leaks nothing and loses nothing',
      (WidgetTester tester) async {
        SharedPreferences.setMockInitialValues({'org_id': 7});
        final api = _FakeApiService()
          ..categories = const [Category(id: 1, name: 'দেরি')];

        const portrait = Size(800, 1280);
        const landscape = Size(1280, 800);
        tester.view.physicalSize = portrait;
        tester.view.devicePixelRatio = 1.0;
        addTearDown(tester.view.resetPhysicalSize);

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
        await tester.enterText(find.byType(TextField), 'ঘূর্ণন পরীক্ষা');
        await tester.pump();

        for (var i = 0; i < 20; i++) {
          tester.view.physicalSize = i.isEven ? landscape : portrait;
          await tester.pump();
          expect(tester.takeException(), isNull);
        }

        // State survived 20 rotations.
        expect(find.text('ঘূর্ণন পরীক্ষা'), findsOneWidget);
        final labelStyle = tester.widget<Text>(find.text('দেরি')).style;
        expect(labelStyle?.color, const Color(0xFFFFFFFF));

        // Close cleanly so nothing (the 60s idle timer, the dialog's
        // AnimationController) is left pending — if anything leaked, the
        // test framework's own teardown invariant check catches it.
        await tester.tap(find.text('বাতিল'));
        await tester.pump();
        await tester.pump(const Duration(milliseconds: 350));
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
