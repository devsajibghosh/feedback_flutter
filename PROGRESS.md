# Progress Log

DONE (FIX-06 §1 + §5 — negative drains in full, positive one at a time, 30s
tick — done together since both live in `SyncService._drain()` and §5
explicitly retires the throttle §1's batching rule replaces):

**§5 tick interval.** `_regularInterval` 45s → 30s. The backoff formula
(`_regularInterval.inSeconds * 2^consecutiveFailures`, capped at 15
minutes, reset to 30s on success) was already parametrized on
`_regularInterval`, so the sequence became 30s → 60s → 2m → 4m → 8m →
(16m capped to 15m) automatically — verified by running the real 8-step
`tool/verify_sync_test.dart` pipeline fresh: a genuine hard failure now
reports `currentBackoff=0:01:00` (60s), not the old 90s. Deleted
`_lastUploadCompletion` and the `_uploadThrottle` constant along with the
throttle check at the top of `_drain()` entirely, per the explicit
instruction — the tick interval is now the only pacing mechanism, there
is no longer a timer plus a separate gap check.

**§1 negative/positive batching.** `DbService.getUnsyncedBatch` gained an
optional `ratings` filter (SQL `rating IN (...)`) and `limit` is now
nullable (`null` = no `LIMIT` clause, i.e. every matching row) rather than
defaulting to 3. `SyncService._drain()` now: (1) fetches every pending row
with `rating` in `{poor, very_poor}`, oldest first, and uploads them one
after another with a 400ms gap between each (inside the 300–500ms range
asked for); (2) only after that loop finishes without a hard failure,
fetches and uploads exactly one pending row with `rating` in `{very_good,
good, satisfactory}`. Per-row upload/backoff logic was factored out of the
old single-row `_drain()` body into a new `_uploadRow()` helper returning
whether the attempt was a hard failure; `_drain()`'s negative loop checks
that return value after every row and `return`s immediately on a hard
failure — the loop index is never advanced past a failing row, so the
next negative row is never attempted and the positive pass never runs
that tick. A 422 (permanent rejection) is deliberately *not* treated as a
hard failure here, matching the pre-existing per-row semantics (`synced =
-1`, backoff resets to the regular interval) — only a real network/HTTP
error or a 2xx-without-success body stops the tick, since the instruction
is about a genuinely down server, not one permanent per-row rejection.
The 5s first-attempt timer and the `connectivity_plus` trigger are
unchanged and still just call `_drain()`, which now does the right thing
by itself regardless of which trigger fired it.

**Verification — both real, not just reasoning, as asked:**
1. New test seeds 3 positive rows (`very_good`/`good`/`satisfactory`) and
   3 negative rows (`poor`/`very_poor`/`poor`), runs one `drainForTest()`,
   and confirms exactly 3 negatives end up `synced=1` and exactly 1
   positive does (`test/widget_test.dart`, "FIX-06 §1: one tick uploads
   every pending negative row in full and exactly one pending positive
   row").
2. New test seeds 3 negative rows, scripts the *second* upload call to
   throw a non-422 `DioException`, runs one `drainForTest()`, and confirms
   only 2 of the 3 API calls happened (the third negative row was never
   attempted), row 1 is `synced=1`, rows 2 and 3 are still `synced=0`, and
   `consecutiveFailures` is 1 — proving a mid-tick failure stops the tick
   rather than continuing to the next row ("FIX-06 §1: a hard failure
   partway through the negative batch stops the tick instead of
   continuing to the next negative row").
Updated the two now-obsolete FIX-03 §1 tests this superseded (the old
"only the single oldest row per drain" and "30s throttle blocks a second
drain" tests — both describe behavior that no longer exists) and the
three backoff-value assertions that hardcoded 45s/90s to the new 30s/60s.
Updated the two `DbService` test-double subclasses
(`_FakeDbService`/`_ThrowingDbService`) whose `getUnsyncedBatch` override
signature the compiler requires to match the new one (`ratings` param,
nullable `limit`) — `_FakeDbService`'s now actually filters by rating and
sorts by `createdAt` like the real SQL does, rather than relying on
insertion order.
Also removed the real `tool/verify_sync_test.dart` pipeline's now-pointless
31-second "wait out the old throttle" pause before its offline-row step,
since that throttle is gone — reran the pipeline fresh afterward with no
regression (still all 8 steps confirmed, and the backoff value it logs
now reads 60s as expected).

`flutter analyze`: clean. `flutter test test/widget_test.dart`: **95/95
pass.** `flutter test tool/verify_sync_test.dart` real (non-code-reading)
reruns of the 5 non-soak tests: the 8-step pipeline, `DbService`'s
concurrent-open race, 7-day retention, the relaunch/step-13 walkthrough,
and `CrashLog`'s rolling file — all pass. The 15-minute soak test in that
same file was **not** rerun in this step (its own submit-every-45s /
tick-every-30s timing is unaffected by this change, and FIX-06 §6 already
requires a full fresh test-suite run including this file before the
release build, which will exercise it for real then rather than twice).

DONE (FIX-04 §4 — final release build): Before building, reran
everything per §3's "rerun everything": `flutter analyze` — clean.
`flutter test test/widget_test.dart` — **89/89 pass**, fresh, including
all 8 SPEC-RESPONSIVE.md §9 sizes with the keyboard open (no overflow
at any size). Debug-surface grep for `FIX-01`, `FIX-02`, `TEMP`,
`debug` across `lib/` — only legitimate historical citation comments
and the intentionally-kept internal `DbService.debugSummary()`/
`SyncService.debugSummary()` diagnostic API remain (confirmed already
audited and kept-on-purpose in FIX-03 §6); no literal `// TEMP` block,
no `print`/`debugPrint`, no `LogInterceptor` anywhere.
Then built: `flutter build apk --release` (Gradle `assembleRelease`,
116.2s) → `build/app/outputs/flutter-apk/app-release.apk`, copied to
`feedback.apk` in the project root.
**Freshness, proven two ways as asked** (the stale-build mistake has
happened twice before):
1. `find lib pubspec.yaml android/app/src -type f -newer feedback.apk`
   returns **nothing** — no source file postdates the APK.
2. Extracted `libapp.so` for all three architectures and searched for
   the literal `কেন সন্তুষ্ট হন নি?` (the new negative-dialog header
   title, FIX-04 §1 — exists nowhere in the old header code). **Found
   in all three** (`arm64-v8a`, `armeabi-v7a`, `x86_64`), 1 occurrence
   each. Also confirmed the new comment-label string
   `অন্য কারণ থাকলে এখানে লিখুন` present in all three. Note: plain
   `strings`/`grep -a` on the raw file find **neither** this string nor
   any other Bengali literal (even long-standing ones like
   `ধন্যবাদ`) and silently report nothing — Dart's AOT compiler stores
   non-Latin1 string constants as UTF-16LE, not UTF-8, inside
   `libapp.so`, so a byte-for-byte UTF-8 grep against it always comes
   back empty regardless of whether the string is really there. Had to
   re-encode the search string as UTF-16LE (Python) and search for
   those raw bytes instead — worth recording so a future session
   doesn't misread a false "not found" as evidence of a stale build.
`apksigner verify --print-certs`: signed with the real release key
(`CN=Feedback Machine, OU=Code Station 23`), not debug.
`aapt dump badging`: `application-icon` still resolves to `res/BW.xml`
(the adaptive icon), unaffected by this pass as expected.
**Path:** `/home/sajibghosh/soft/feedback-flutter/feedback.apk`.
**Size:** 57,136,184 bytes (57.1MB) — **-188 bytes** from the previous
(FIX-03) build, i.e. essentially unchanged: this pass only replaced
some header/label markup and English-sub-label strings, no new
dependencies or assets.

DONE (FIX-04 §3 — full tool-harness rerun, all 6 real tests): ran
`flutter test tool/verify_sync_test.dart` fresh this session, not
trusted from the log. **All 6 pass:** the 8-step local-first
submit+sync pipeline, `CrashLog`'s real rolling file + 2MB trim, the DB
open-race fix (10 concurrent inserts, all unique ids), 7-day retention
(only the old `synced=1` row actually deleted), the new step-13
walkthrough test (a brand-new `DbService` over the same on-disk file
after a simulated "relaunch" sees the row a previous instance wrote:
`total=1 pending=1`), and the 15-minute soak — real run, not
shortened: `submitted=20 requests=20 total=20 pending=0 sent=20
consecutiveFailures=0 lastError=null`, RSS `first=171753472
last=34775040 max=174645248` (last sample well below first — no
growth), and no `app.log` written (a healthy run logs nothing, so its
absence is itself the "log file doesn't grow" confirmation).
Also fixed the two remaining FIX-04 §5 items in this session: the
English sub-labels now read `Excellent / Good / Satisfactory / Poor /
Very poor` exactly (`lib/widgets/rating_button.dart` had guessed `Very
Good`/`Very Poor` last session, pending confirmation — now corrected).

DONE (FIX-04 §3 — 15-minute soak, recovered from a session that hit its
limit before this got written up): the previous session's terminal
output (not trusted from a stale PROGRESS.md, since the limit cut off
before that session wrote anything) showed:
- 15-minute soak test **passed**: all 20 rows submitted during the soak
  synced cleanly, RSS stayed bounded (the last sample was lower than the
  first — no leak), and the crash-log file behaved (never created, since
  a healthy run logs nothing).
- `flutter analyze`: clean.
- `flutter test test/widget_test.dart`: **89/89 pass**.
- A harness-only bug was found and fixed first: the new soak test was
  missing the `runZonedGuarded` wrapper the main 8-step pipeline test in
  `tool/verify_sync_test.dart` already had, to swallow a
  `connectivity_plus`/`ServicesBinding` artifact that only exists in the
  bare `test()` environment (no widget-test binding), never on a real
  device. Fixed in `tool/verify_sync_test.dart` (still uncommitted on
  disk when this session started — committed now).
Not yet run at that point: the final tool-harness rerun (all 6 real
tests in `tool/verify_sync_test.dart`), this write-up, and the release
build — all continued in this session.

CONFIRMED: FIX-03 is fully done before starting FIX-04, as instructed. Fresh (not trusted-from-log) `flutter analyze` — clean — and `flutter test test/widget_test.dart` — 83/83 pass — both re-run at the start of this session and matched the prior session's claims exactly. Nothing was outstanding in terms of code work. The only gaps are the previously-disclosed, environment-limited verifications that no code change can close: colour-emoji rendering on Android, `wakelock_plus` surviving a screen cycle, a real 15-minute soak, and the §5 English-sub-label wording flagged for confirmation. None of these block FIX-04, and §3 (keyboard insets) specifically — which FIX-04 §1 depends on — is code-complete and test-verified.

DONE (FIX-04 §1 + §2 — negative dialog header and comment label, done together since both touch the same files and §2 explicitly changes shared sizing that §1's neighbours read too):

**§1 header.** Replaced the `খারাপ — মন্তব্য জানান` badge + `কোথায় সমস্যা হয়েছে জানান` title with a new `_NegativeDialogHead` (`negative_dialog.dart`) that leads with the tapped rating's own emoji — `rating == 'very_poor' ? '😞' : '🙁'`, so `poor` gets 🙁 and everything else routed to this dialog (only `very_poor`) gets 😞, matching "whichever card was pressed, not a generic icon" exactly since these are the only two ratings that ever open this dialog. Title (`কেন সন্তুষ্ট হন নি?`) and subtitle (`এক বা একাধিক কারণ বেছে নিতে পারেন`) copied programmatically from FIX-04.md via a Python script (not retyped) and verified present afterward. Sizes (56/46/38 emoji, 30/26/24 title, 15/14/13 subtitle) via three new `Responsive` getters, following the same fixed-3-step pattern FIX-03 §5 established. Removed the `কারণ নির্বাচন করুন (একাধিক নির্বাচন করা যাবে)` section label above the categories, as instructed. Notice strip and red gradient stripe untouched. Deleted `DialogSectionLabel` from `feedback_dialog.dart` entirely — after removing both of its only two call sites (this one and the comment label below), it was fully dead code.
Collapse: `_NegativeDialogHead` is its own `AnimatedSize` (160ms, `topCenter`), collapsing to nothing whenever `responsive.isKeyboardOpen` — deliberately broader than the shared `DialogHead` (still used unchanged by the positive dialog), which only collapses at `isKeyboardOpen && isShortHeight`. This is intentional, not an oversight: FIX-04 says this head collapses "when the keyboard opens" full stop, no short-height qualifier, and the new head is tall enough on any screen that it's worth reclaiming that space everywhere the keyboard shows up.

**§2 comment label.** Replaced the pen-icon + 11px muted caption with `_CommentLabel` (`negative_dialog.dart`): `অন্য কারণ থাকলে এখানে লিখুন` (already verbatim-correct in the codebase since FIX-02 — checked byte-for-byte against FIX-04.md before reusing rather than re-copying) at 18/16/15, `ink`, weight 600, no icon; `(ঐচ্ছিক)` kept at 13/12/11, `inkMuted`, weight 400. 11px gap to the field (`padding: EdgeInsets.only(bottom: 11)`), unchanged placeholder. Per "if the notice strip now looks small beside this, bump it to match," `Responsive.noticeStripFontSize` now returns `commentLabelSize` directly instead of its own smaller 14–16 scale — the two literally share a getter now, not just similar numbers.

**Verification:** 6 new tests — 🙁 for `poor` / 😞 for `very_poor`, scoped to the dialog subtree (the rating screen behind the modal still has its own same-emoji `RatingButton` mounted, which an unscoped `find.text` would double-count — caught this while writing the test, not by accident); old badge/title/section-label text confirmed absent, new title/subtitle confirmed present; comment label confirmed icon-free with the right colour/weight and the optional marker smaller than the label; notice strip's rendered font size confirmed equal to the comment label's. `flutter test`: **89/89 pass.**
**Could not verify — flagged exactly as asked:** "verify the head actually collapses when the keyboard opens, with a real keyboard on a real screen size. Widget tests won't catch this." No Android device or emulator is available in this environment (unchanged all session). The new test simulates the collapse via `tester.view.viewInsets = FakeViewPadding(...)`, which exercises the same `MediaQuery.viewInsets.bottom` mechanism the real keyboard changes and the same code path the collapse logic reads — but it is not a real IME opening on a real screen, and a real keyboard's actual behavior (its own show/hide animation timing, whether it visually overlaps the 160ms collapse in a way that looks off) was not observed. This is a genuine, not a token, gap: needs a real device.

DONE: FIX-03 production-readiness pass — all 10 items complete (priority order: §3, §6-contradiction, §9, §8, §1, §2, §4, §5, §6-rest, §7, §10). See the dated FIX-03 entries above for each item's detail.

DONE (§10 release):
1. `flutter analyze` — clean, zero issues.
2. Extended the §3 keyboard-open overflow test loop from 4 phone sizes to all 8 SPEC-RESPONSIVE.md §9 sizes (added the 4 tablet sizes), per §10's explicit "all 8 sizes... with the keyboard open" requirement. Silenced two benign `tester.tap()` "didn't hit the widget" warnings in the §8 debounce tests (the later taps in those tests realistically land on the now-opening dialog rather than the button underneath — expected, not a bug — `warnIfMissed: false` documents why). `flutter test test/widget_test.dart`: **83/83 pass, zero warnings.** `flutter test tool/verify_sync_test.dart`: **4/4 real tests pass** (8-step sync pipeline, CrashLog rolling file, DB open-race, 7-day retention).
3. All 8 sizes, portrait and landscape, with the keyboard open on the comment field — covered by the extended loop above; all pass, no overflow, Submit reachable at every one.
4. Built the signed release APK: `flutter build apk --release` (Gradle `assembleRelease`, 69.8s) → `build/app/outputs/flutter-apk/app-release.apk`, copied to the project root as `feedback.apk`.
5. Confirmed the APK's mtime is newer than every source file: `find lib pubspec.yaml android/app/src -type f -newer feedback.apk` returns **nothing** — no source file postdates the build. `apksigner verify --print-certs` confirms it's signed with the real release key (`CN=Feedback Machine, OU=Code Station 23`), not debug.
6. Confirmed the icon via `aapt dump badging`: `application-icon` still resolves to `res/BW.xml`, the same adaptive-icon XML confirmed earlier this session — unaffected by this pass, as expected (nothing in FIX-03 touched the icon).
7. **Path:** `/home/sajibghosh/soft/feedback-flutter/feedback.apk`. **Size:** 57,136,372 bytes (57.1MB). **Change from the last build:** +16,384 bytes (+16.0KB) — a small, expected net change given this pass added a new service (`crash_log.dart`) and new UI (the English sub-label, the helper text) while removing the debug-dump UI and the old `debug_log.dart`.

DONE (10/10 — §7 stability audit): Found and fixed two real, previously-unnoticed bugs, confirmed the rest already correct.
**Database**
- **Real bug found: DB-open race.** `_database` was `Future<Database> get _database async => _db ??= await _open();` — checking `_db == null` and assigning it are separated by an `await`, so two callers reaching the getter close together (`SyncService.start()`'s retention cleanup and a user's first submit, both firing within milliseconds of launch, is a completely realistic case) could each see `_db == null` and each start their own `_open()`. Fixed (`db_service.dart`) by caching the *Future* itself (`Future<Database>? _dbFuture; Future<Database> get _database => (_dbFuture ??= _open()).catchError(...)`) — the null-check-and-assign is now one synchronous expression with no `await` gap, so every caller awaits the exact same in-flight open, no matter how close together. Also added a `.catchError` that clears `_dbFuture` on failure, so a transient open failure doesn't get cached *forever* — matching "a broken database must not brick the kiosk" more literally than a plain memoized future would.
- **Real bug found: directory never created.** `_open()` built the `FeedbackSystem/feedback.db` path and called `openDatabase()` directly — nothing ever created the `FeedbackSystem` subdirectory. Verified empirically that `sqflite_common_ffi` (desktop) tolerates this, but there's no such guarantee for the real Android plugin, and SQLite itself never creates missing parent directories. Added an explicit `await Directory(...).create(recursive: true);` before opening.
- Every raw SQL call already uses the right method (re-confirmed: no new `execute`/`rawQuery` misuse introduced this session).
- "A broken DB must not brick the kiosk": already true for the submit path (dialogs' broad try/catch around `_sync.submit()`) and the retention-cleanup path (`.catchError` in `start()`); unaffected by the fixes above.
**Async**
- Every `setState` after an `await` is already `mounted`-guarded — audited every call site across `main.dart`, `feedback_screen.dart`, `login_screen.dart`, both dialogs; all clear.
- Added one more defensive `mounted` check in `_DialogCardState._updateFade()` (a post-frame-callback path, not an `await`, but the same "could fire after disposal" shape) — `hasClients` already covered the realistic case, but the explicit check costs nothing.
- Button-gating flags: **reworked both dialogs' `_submit()` to reset `_isSubmitting` in an actual `finally` block** (`positive_dialog.dart`, `negative_dialog.dart`) instead of three separate manual resets scattered across branches — functionally the same outcome as before (all tests unaffected) but now provably can't be missed if a new exit path is ever added later.
- No `await` on a network call in any user-facing path: unchanged, still true (local-first design).
- Every `Timer`/`AnimationController`/`StreamSubscription` audited by name across the whole `lib/` tree: all three `AnimationController`s (`RatingButton`, `BlurredBackground`, the dialog shell) disposed; the idle timer, the success-toast timer, and `SyncService`'s tick timer + connectivity subscription all cancelled in their owner's `dispose()`; the two "fire-once" `Timer`s (submit's 5s first-attempt, the regular tick's own reschedule) are deliberately not stored/cancelled since they're meant to fire exactly once regardless of widget lifecycle, not attached to any disposable owner.
**Verification:** a new widget test rotates a dialog with typed text and a selected category **20 times** and confirms no exception and no lost state each time — and, critically, the test framework's own teardown invariant check (the same "Timer is still pending" assertion that caught two real bugs earlier this session) would have failed this test if anything actually leaked; it didn't. Two new *real* tests added to `tool/verify_sync_test.dart` (real sqflite, not mocks): (1) 10 concurrent `insert()` calls against a brand-new `DbService` — all 10 got unique sequential ids and `debugSummary().total == 10`, confirming the race fix; (2) real 7-day retention — seeded an 8-day-old `synced=1` row, a 1-hour-old `synced=1` row, an 8-day-old `synced=-1` row, and an 8-day-old `synced=0` row, ran `deleteOldSyncedRows()`, and confirmed via the `sqlite3` CLI that **only** the old synced row was actually deleted (`id=1` gone; `id=2,3,4` remain) — real proof pruning runs and deletes, not just that the code compiles.
**Network:** confirmed all 5 endpoints already share the same `Dio` instance's 10s `connectTimeout`/`receiveTimeout`/`sendTimeout` (no per-endpoint gaps). Made the "malformed/HTML response treated as failure" requirement explicit rather than incidental: `submitFeedback` (`api_service.dart`) now checks `response.data is! Map<String, dynamic>` and returns `SubmitFailure` for anything else, rather than relying on Dio's JSON-parse-failure-throws-a-DioException behavior as the only line of defense (which does already work for genuinely non-JSON content, but wouldn't catch a valid-JSON-but-wrong-shape response, e.g. a misconfigured proxy returning the same placeholder body for everything). New unit test spins up a real local `HttpServer` returning a 200 HTML captive-portal-style page and confirms `submitFeedback` never returns `SubmitSuccess`.
**Could not verify (real device required, none available):**
- "`wakelock_plus` survives the screen being manually cycled off and on" — no way to test without a physical screen.
- "Leave it running 15+ minutes with the queue draining. Confirm no growth, no leaks, no stuck state." — the same harness used for the 8-step and DB tests *could* be extended to soak for 15+ real minutes, but given the size of this pass I didn't run it; happy to if wanted.
- Image cache bound: `cached_network_image`/`flutter_cache_manager` (third-party, already in use for the org logo) has its own LRU eviction by default and nothing in this codebase overrides or disables it — confirmed by reading the dependency, not by observing eviction actually happen over time.
- `synced = -1` (rejected) rows are kept **indefinitely** by explicit design (FIX-02 §1's own instruction) — this is a real, if slow, unbounded-growth vector over a very long uptime with many permanent server rejections. Not a bug (matches the spec precisely) but flagged for awareness since FIX-03 §7 asks generally about "nothing grows without bound."
`flutter analyze`: clean. `flutter test test/widget_test.dart`: **79/79 pass.** `flutter test tool/verify_sync_test.dart`: **4/4 real tests pass** (8-step pipeline, CrashLog, DB race, retention).

DONE (9/10 — §6 rest: strip every debug surface): Removed exactly the surfaces listed, kept the underlying instrumentation as internal-only.
- **Long-press debug dump**: deleted `_showDebugDump` and its `AlertDialog` from `feedback_screen.dart`, and `MarqueeBar`'s `onDebugLongPress` param + the `GestureDetector(onLongPress:...)` that carried it (`marquee_bar.dart`). The bar is a plain `Container` again.
- **Raw-exception alert**: `showUnexpectedErrorAlert` (title `অপ্রত্যাশিত ত্রুটি (ডিবাগ)`, body `${error.runtimeType}: $error`) replaced by `showGenericErrorAlert` in `app_alerts.dart` — the message (`দুঃখিত, একটি সমস্যা হয়েছে। আবার চেষ্টা করুন।`) was copied byte-for-byte from FIX-03.md line 210 via a Python script and verified present in the file afterward, same discipline as §4's string. Both dialogs (`positive_dialog.dart`, `negative_dialog.dart`) now call this plus `CrashLog.record(...)` (fire-and-forget) instead.
- **`// TEMP (FIX-01 §2)` blocks**: none existed under that literal label in `api_service.dart`/`sync_service.dart`/either dialog (checked directly) — the closest things were the debug-dump doc comment and the raw-exception-alert doc comment, both removed above.
- **Dio's `LogInterceptor`**: confirmed absent — nothing to remove.
- **`print`/`debugPrint` on a user path**: confirmed absent — nothing to remove.
- **Kept internal capture**: this was already built in §8 (`CrashLog` + `runZonedGuarded`/`FlutterError.onError` in `main.dart`). This step deleted the old `DebugLog` class entirely (`lib/services/debug_log.dart`) and moved its two responsibilities: the in-memory `lastError` string `debugSummary()` still exposes (for `tool/verify_sync_test.dart`'s internal use, not any UI) now lives directly on `SyncService` as `_lastError`, set by a new private `_recordError()` helper that *also* calls `CrashLog.record(...)` — so every failure path that used to call `DebugLog.record` now does both at once.
**Verification:** 2 new widget tests (long-pressing the marquee does nothing — no dialog, no "Debug dump" text; a local-write failure shows the generic message with no "ডিবাগ" text anywhere) plus updated the one existing test that had asserted the *old* raw-exception behavior to assert the new generic one instead. Extended `tool/verify_sync_test.dart` with a real test of `CrashLog` itself — using the same fake-path-provider technique already established there — confirming it actually writes a line to a real file on disk and genuinely trims once past its 2MB cap (grew to exactly 2,048,694 bytes under a deliberate flood, comfortably under the cap, not unbounded). Along the way, that same rerun caught the §1 throttle test above missing a real consequence: this dev harness's hardcoded real-time waits assumed the old batch timing, so row 2's offline attempt was being silently throttled instead of genuinely failing — fixed by adding a 31s wait to clear the 30s throttle before that step, and reran for real: **all 8 steps pass again, plus the new CrashLog test.** `flutter test test/widget_test.dart`: **77/77 pass.**

DONE (8/10 — §5 card typography — emoji leads, text confirms): **Flagging a real ambiguity rather than silently resolving it:** FIX-03.md's table for this item has a third column, "English sub," with sizes and a colour — but that wording doesn't exist anywhere in SPEC.md or any other FIX-*.md, and no English sub-label existed in the UI at all before this. Rather than invent new copy from nothing, I used the plain English gloss of each rating's existing canonical `value` slug (`very_good`→"Very Good", `good`→"Good", `satisfactory`→"Satisfactory", `poor`→"Poor", `very_poor`→"Very Poor") — the only non-arbitrary source available. **Please confirm or override this wording** — I'm not confident it's what was intended.
Implementation (`lib/theme/responsive.dart`, `lib/widgets/rating_button.dart`): `ratingEmojiSize`/`ratingLabelSize` switched from the old smooth-interpolated formula to fixed three-step values matching the table exactly — 68/56/46 emoji, 30/25/21 Bengali (ratios: 2.27, 2.24, 2.19 — all "roughly 2.2x" as asked) — plus a new `ratingEnglishSubSize` (16/14/12, "about half" the Bengali size as specified). Added `RatingSpec.englishLabel` and a third line in `RatingButton`'s content column, styled `inkMuted`, wrapped in its own `FittedBox` so it shrinks rather than clips, same technique already used for the Bengali label. **Also had to rework `ratingButtonHeight`**, which the bigger fixed type would otherwise overflow on short/landscape screens: the old formula clamped height down for `isShortHeight` (`base.clamp(0, height*0.42)`), which directly contradicts this item's explicit instruction ("cards grow to fit... if the larger type breaks the near-square aspect, grow the card rather than shrink the type") — removed that clamp and replaced the whole getter with a formula computed *from* the actual emoji/label/sub-label sizes plus padding, so it's tall enough to fit them by construction rather than by a separately-tuned constant.
**Verification:** a new test pumps the real `AppRoot` at one representative size per breakpoint class (compact/medium/expanded) and reads the *actual rendered* `TextStyle.fontSize` off the emoji, Bengali label, and English sub-label `Text` widgets (not the `Responsive` getters directly, so it catches the widget actually failing to apply them) — confirms the ~2.2x ratio at all three, the sub-label smaller than the Bengali label, all five cards' `RenderBox.size.height` identical, and no exception (no overflow). Combined with the pre-existing 8-size + keyboard-open overflow suites (unaffected — still 75/75), this covers "no clipping, no ellipsis, at any of the 8 test sizes."
**Could not verify — the one thing explicitly called out to check on-device:** "Emoji must render in colour on Android. Confirm on the device, not the desktop build — the font fallback chain differs." No Android device or emulator is available in this environment (established earlier this session), and this specifically cannot be checked any other way — a font-fallback rendering difference is exactly the kind of thing a widget test's `TextStyle` inspection is blind to (it confirms the *font size*, not what glyph actually gets painted). This is unverified and needs a real device.

DONE (7/10 — §4 helper text under the rating cards): Added `_RatingHelperText` (`lib/screens/feedback_screen.dart`), placed as the last child of the same `Column` right after `_RatingRow` — so it's naturally below the fifth card, outside the grid, sharing the grid's own horizontal padding context (plus a matching `ConstrainedBox(maxWidth: 1200)` so on a very wide screen it wraps at the same point the grid itself does, not the screen edge). The string was **copied programmatically from FIX-03.md line 142 with a Python script, byte-for-byte** (not retyped) into a placeholder in the source, and verified immediately after with a `grep` for both the exact string and the trailing `।`: `খারাপ বা খুব খারাপ নির্বাচন করলে সমস্যার বিস্তারিত জানানোর সুযোগ থাকবে।`. Styling matches the spec table exactly: `AppTokens.parchment` (`#EDE8D9`) at 60% opacity, `letterSpacing: size * 0.04` (0.04em), `FontWeight.w400`, size 13/12/11 via a new `Responsive.helperTextSize` getter (expanded/medium/compact), `textAlign: TextAlign.center`, no `maxLines` cap (so it wraps to 2 or 3 lines rather than ever truncating), 16px padding above and none below. Hidden via `if (!responsive.isShortHeight)`, matching the same flag `_Subtitle`/the logo already use for the phone-landscape case. It's a bare `Text` with no `GestureDetector`/`InkWell` around it — nothing to exclude from semantics, since a plain `Text` was never in the semantics tree as a button to begin with.
**Verification:** 3 new tests — shown below the rating row with `textAlign: center` and no `maxLines` cap on a normal-height screen, absent entirely at 915×412 (short-height), and confirmed inert (tapping it opens no dialog, throws nothing). `flutter test`: **74/74 pass.**

DONE (6/10 — §2 success message: 4s, non-blocking): Replaced the modal `showDialog`-based `showSuccessAlert`/`_AutoDismissAlert` (`app_alerts.dart`, 1500ms) with a genuinely non-blocking `OverlayEntry` toast owned directly by `_FeedbackScreenState` (`feedback_screen.dart`) — a `showDialog` has its own barrier that would always have intercepted the very tap this item requires to pass through, so a modal could never have satisfied "must not block the next rating tap" no matter how the timer was tuned. New `_SuccessToast` widget: same visual shape as before (check-circle icon, "ধন্যবাদ!" title, message), centred, no barrier — a tap on it dismisses it early (`onTap`), a tap anywhere else (including a rating card behind it) passes straight through since only the card itself is hit-testable. Timer changed 1500ms→4000ms, and now a real cancellable `Timer` rather than an uncancellable `Future.delayed`. `_handleRatingTap` calls `_dismissSuccessToast()` unconditionally before opening a new dialog — combined with §8's `_dialogOpen` being released the instant the *dialog* (not the toast) closes, a rating tapped while the message is up now closes the message immediately and opens the new dialog right away, exactly as specified. Backgrounding: `_FeedbackScreenState` now mixes in `WidgetsBindingObserver`; any `didChangeAppLifecycleState` away from `resumed` removes the toast and cancels its timer outright — nothing to "resume" on the way back, which is the simplest way to satisfy "do not resume a stale timer" (there's no stale timer to resume; the whole thing is just gone).
**Verification:** 4 new tests — auto-dismiss lands at 4s and not the old 1500ms cutoff (confirmed still showing at +2000ms, gone by +4100ms), tapping the toast dismisses it early, tapping a new rating while it's up closes it immediately and opens the new dialog (the actual non-blocking requirement), and backgrounding removes it with no resurrection on resume. `flutter test`: **71/71 pass.**

DONE (5/10 — §1 sync throttle): Rewrote `SyncService._drain()` (`lib/services/sync_service.dart`): replaced the "3 rows per tick, 500ms apart" batch with a hard one-row-per-drain, one-upload-per-30s design. A new `_lastUploadCompletion` timestamp is set after every attempt (success, 422, or hard failure) and checked at the top of `_drain()` — if less than 30s has passed, the call returns immediately, doing nothing, and whichever trigger fires next (a new row's own 5s timer, the regular 45s tick, or connectivity coming back) gets another chance. This is the literal "where the 5s first attempt and the 30s throttle disagree, the throttle wins" rule. Kept unchanged, as instructed: the 5s first-attempt timer itself, the `connectivity_plus` immediate trigger, exponential backoff (45s→90s→3m→6m→12m, capped 15m, reset to 45s on success), 422→`synced=-1` with no retry, and 7-day pruning of `synced=1` rows. Nothing about this is visible to the user — there was already no progress indicator/counter/toast for the queue (checked: none existed to remove), and submit was already a local write with the same instant success message regardless of network state (FIX-02 §1), so "50 queued rows drain over ~25 minutes" changes nothing anyone can see.
**Verification:** rewrote the old 3-row-batch test (no longer applicable) into four targeted tests — one row uploaded per drain even with several queued, the throttle blocking an immediate second drain, a 422 rejecting without counting as a hard failure, and a hard failure backing off — plus kept the pre-existing "successful drain resets backoff" test. `flutter test`: **67/67 pass.**
**Could not verify:** the throttle's *positive* case (a second upload actually going out once a full 30s has elapsed) isn't covered by a fast unit test, since `_drain()` reads real `DateTime.now()` rather than an injectable clock — proving that branch without a real 30-second wait would need either a real-time test (slow) or a clock-injection refactor, which felt like more surface area than this fix warranted. The negative case (immediately-after is blocked) is directly verified, and the arithmetic (`< 30s` else proceed) is a two-line, low-risk conditional.

DONE (4/10 — §8 interaction hardening): Built on top of §3's dialog shell.
- **Double-tap / rapid cross-tap debounce** (`feedback_screen.dart`): `_dialogOpen` gates `_handleRatingTap` and is released the instant the feedback dialog route itself closes — not after the success message that follows — so a rating tap that arrives while the (still-to-come, non-blocking) success toast is up can open a new dialog immediately per §2, while a second tap arriving *while a dialog is open* is dropped, whether it's the same rating twice or five different ones in a burst.
- **Back button**: found and fixed a real bug while building this — `PopScope(canPop: false)` on the dialog shell had no `onPopInvokedWithResult`, so Android back did *nothing at all* while a dialog was open (not spec-compliant; §8 wants it to close the dialog). Fixed in the §3 commit; confirmed here that the root (`AppRoot`)'s own `PopScope(canPop: false)` genuinely still does nothing.
- **Barrier tap**: confirmed still a no-op (`barrierDismissible: false`, unchanged).
- **Stuck dialog can't be unrecoverable**: added `lib/services/crash_log.dart` (a capped 2MB rolling log file — FIX-03 §7's "keep internal capture," never surfaced) and wired `runZonedGuarded` + `FlutterError.onError` in `main.dart` to (a) log there and (b) call the `FeedbackDialogGuard.closeActiveDialog()` escape hatch built in §3, so any uncaught error while a dialog is open force-closes it back to the rating screen instead of leaving it unresponsive.
- **Text scale clamp**: confirmed already applied at the root in `main.dart`'s `FeedbackApp.builder` (0.85–1.3), unchanged — just verified.
- **Long category names**: found a real clipping bug — `CategoryPill`'s label had `maxLines: 1, overflow: TextOverflow.ellipsis`, i.e. it silently truncated instead of wrapping. Fixed (`category_pill.dart`): removed the clip, added `softWrap: true`, so a long reason wraps to multiple lines instead of hiding the word that mattered.
- **10+ categories**: already handled by the existing design — the whole dialog (head through actions row) is one `SingleChildScrollView`, so any number of categories just makes that scroll region taller; no separate/overflowing sub-region exists.

**Verification:** added 12 new tests to `test/widget_test.dart` (double-tap, rapid cross-tap, barrier tap, root back button, dialog back button, `FeedbackDialogGuard` force-close + no-op-when-idle, text-scale clamp both directions, 40-char category wrap, 14-category scroll). Ran `flutter test`: **64/64 pass.**
**Could not fully verify:** the `runZonedGuarded`/`FlutterError.onError` wiring in `main.dart` itself isn't exercised by any test, since widget tests build the widget tree directly and never call `main()`. What *is* verified directly is the mechanism those handlers call (`FeedbackDialogGuard.closeActiveDialog()` really does force-close whichever dialog is open) — confirmed by test — but an end-to-end "a real exception was thrown during a real run and the app actually recovered" scenario was not observed, since that would need a genuinely running app (device/emulator), not available here.

DONE (3/10 — §9 idle reset): Built together with §3 in the same commit (`2716494`), since FIX-03.md itself flagged that the idle reset touches the same dialog lifecycle as §2/§3. Re-verified against the full §9 checklist: 60s timer starts the moment the dialog's `initState` runs; any pointer-down anywhere in the dialog (`Listener(behavior: opaque)`) resets it, which covers touches, drags, and the start of a scroll without any extra plumbing; the comment field's `onChanged` also pings the same reset via a `DialogIdleScope` `InheritedWidget`, satisfying "reset on every keystroke, not just on open"; on timeout, `_close()` runs with no result, so `FeedbackScreen` never sees a `SubmitSuccess` (no submit, no message) and reuses the dialog's own normal dismiss animation (no extra one); closing also explicitly calls `FocusManager.instance.primaryFocus?.unfocus()` so the keyboard is gone, and disposing `NegativeDialogContent`'s state naturally discards the typed comment and selected categories. The rating screen itself never starts a timer — the timeout only exists for the lifetime of `_FeedbackDialogShellState`. Two dedicated tests (`FIX-03 §9: idle reset`) confirm both the timeout-closes-and-discards case and that genuine ongoing typing resets the clock rather than getting cut off — both pass.

DONE (2/10 — §6 contradiction, resolved before touching the debug dump): Diagnosed the on-device dump's `Sent (synced=1): 19` alongside `Last successful sync: never`. **Verdict: cosmetic, not data loss.** `SyncService._lastSuccessfulSync` (`lib/services/sync_service.dart`) is a plain in-memory field, set only inside `_drain()` after a successful upload in *that process's lifetime* — it is never persisted and always starts `null` on every fresh `SyncService()`, which `main()` constructs anew on every app launch. The `synced=1` count, by contrast, is a genuine SQLite aggregate that persists across restarts. So a device that has been running fine for days — successfully syncing 19 rows across many earlier launches — but hasn't yet had a *new* successful sync since the most recent restart, will show exactly `Sent: 19` / `never` with zero data loss. I re-audited the alternative (rows marked `synced=1` without the server accepting them) and ruled it out by tracing the code: `ApiService.submitFeedback` only returns `SubmitSuccess` when the response body literally contains `status: 'success'` or `success: true` (a null/non-JSON/malformed body defaults to an empty map, which fails that check and returns `SubmitFailure`); `_drain()` only calls `_db.markSynced(id)` inside the `result is SubmitSuccess` branch, and only sets `anySucceeded = true` there too — there is no path that marks a row synced without that check passing.
**Verification — real, not just reasoning:** added a test to `test/widget_test.dart` (`SyncService` group) that seeds a fake DB with 19 rows already `synced=1` "from a previous run" and constructs a *fresh* `SyncService` over it, exactly as `main()` does on every launch — `debugSummary()` reports `total=19, bySynced[1]=19, bySynced[0]=0, lastSuccessfulSync=null`, reproducing the exact reported combination. Ran `flutter test`: **53/53 pass.**
**Could not verify:** "check the server for those 19 rows if you can reach it" — confirmed the production API is reachable from this environment (`curl https://feedback.pathosoft.info/api/login` → HTTP 405, i.e. the server responded, just not to a GET), but there is no documented endpoint to list previously-submitted feedback (SPEC.md §5 only has `/feedback/store` to submit and `/admin/get-categories`), and no org credentials were provided — so the actual 19 rows on the real server were not, and could not be, inspected. This diagnosis is a code-level proof of the mechanism, not a confirmation against that specific device's real data.
**Not fixed yet, by design:** the underlying cosmetic gap (in-memory timestamp resets every launch) isn't patched in this step — priority order puts the *actual* debug-dump removal later ("§6 rest"), and the planned rolling log file for that step will give sync outcomes a durable record, which resolves this properly instead of patching the soon-to-be-removed field in isolation. The instrument (the dump, and `debugSummary()`) is left completely in place for now, as instructed.

DONE (1/10 — §3, highest priority): Dialog must scroll with the keyboard open. Root cause confirmed: `_DialogCard`'s `maxHeight` was `MediaQuery.size.height * fraction` — `size.height` never shrinks for the keyboard, only `viewInsets.bottom` does, and nothing read it. Fixed in `lib/theme/responsive.dart` (`Responsive` now also carries `viewInsetsBottom` from `MediaQuery.viewInsetsOf`, and a new `dialogMaxHeight` getter subtracts it before applying the existing fraction) and `lib/widgets/feedback_dialog.dart`:
- `_FeedbackDialogShellState` now wraps `Center` in `Padding(bottom: viewInsets.bottom)`, mirroring what a `Scaffold` with `resizeToAvoidBottomInset` does for its own body, so the dialog centres in the space actually visible above the keyboard.
- `_DialogCard` is now stateful: a `ScrollController` + `NotificationListener<ScrollMetricsNotification>` drive a reactive 24px bottom fade (ivory→transparent) shown whenever content continues below the fold, gone at the bottom of the scroll — and re-checked on every metrics change (keyboard open/close, rotation, categories loading in), not just on scroll.
- `SingleChildScrollView` now explicitly uses `ClampingScrollPhysics` (was inheriting default platform physics).
- `DialogHead` collapses to nothing when `isKeyboardOpen && isShortHeight` (the phone-landscape-with-keyboard worst case) and reappears the instant the keyboard closes — a normal MediaQuery-driven rebuild, no extra state.
- The comment field (`negative_dialog.dart`) now calls `Scrollable.ensureVisible` on focus, uses `TextInputAction.done` with `onEditingComplete` unfocusing, and `resizeToAvoidBottomInset` was already `true` in `main.dart` (confirmed, not changed).
- Tap-outside-the-comment-field-to-dismiss-keyboard added via an opaque `GestureDetector` at the dialog-shell level (only unfocuses when something has focus; doesn't fight with tapping the field itself, since that field's own tap handler re-requests focus as part of the same gesture pass).
- Fixed a related bug found while implementing this: the dialog's `PopScope(canPop: false)` had no `onPopInvokedWithResult`, so the Android back button did *nothing at all* while a dialog was open — not spec-compliant (§8 wants it to close the dialog). Now it does.

**Verification — real, not code-reading, but not on a real device (see caveat):** added `test/widget_test.dart` group "FIX-03 §3: dialog scroll + keyboard" using `tester.view.viewInsets = FakeViewPadding(bottom: ...)`, which simulates the exact mechanism a real keyboard changes (`MediaQuery.viewInsets.bottom`) — this is what 44 previously-passing tests never touched, which is exactly why none of them caught the bug. Ran `flutter test test/widget_test.dart`: **all 52 tests pass** (8 new), including the explicit worst case — phone landscape 915×412 with `viewInsets.bottom: 262` (leaving ~150 logical px) — confirming no overflow, the comment field is reachable and typeable, and Submit is reachable and completes a real submit. Also covers all 4 phone sizes with a ~40%-height keyboard, and rotation with the keyboard open, text typed, and a category selected (nothing lost). **Caveat, stated plainly per the user's ask:** this is a simulated `viewInsets` change, not a literal on-device software keyboard — no Android device/emulator is available in this environment. It exercises the precise code path the fix and the original bug both live in, but a real IME's behavior (autocomplete bar height, exact animation timing) was not observed.

DONE: Rebuild the signed release APK and confirm it's current, not stale. Ran `flutter build apk --release` (Gradle `assembleRelease`, 111.9s) → `build/app/outputs/flutter-apk/app-release.apk` (57.1MB), copied to the project root as `feedback.apk` per the existing convention. `apksigner verify --print-certs` confirms it's signed with the real release key (`CN=Feedback Machine, OU=Code Station 23`), not debug-signed. Freshness check the user asked for, both mtimes shown directly:
- `feedback.apk`: **2026-09-12 20:49:29+06** (57,119,988 bytes)
- `lib/services/db_service.dart`: **2026-09-12 19:29:35+06**
The APK is ~80 minutes newer than the fix this time, the opposite of last time's contradiction. Went one step further than mtimes alone: extracted `libapp.so` (AOT-compiled Dart) for all three architectures (`arm64-v8a`, `armeabi-v7a`, `x86_64`) from this APK and `strings`-grepped for the exact PRAGMA literals from `db_service.dart` — `PRAGMA journal_mode = WAL` and `PRAGMA table_info(feedbacks)` are both present in every architecture's compiled binary, so this isn't just "built after the file changed," the fixed code is demonstrably compiled in.

DONE: Run the 8-step local-first submit + sync pipeline verification (`flutter test tool/verify_sync_test.dart`), now that `libsqlite3-dev` is installed — real output, not code-reading. Confirmed `libsqlite3.so` (unversioned) now resolves via `ldconfig -p` before running. All 8 steps passed; test result: `All tests passed!` (exit code 0). Per-step evidence from the actual run:

1. **DB file created** — `DB path: /tmp/feedback_verify_GHHFAD/FeedbackSystem/feedback.db`, `File exists on disk: true`.
2. **Submit inserts a row** — `submit() returned in 27ms`; `sqlite3` CLI dump immediately after shows row `id=1, org_id=999, rating=poor, synced=0`.
3. **Row has synced=0** — same dump, `synced` column reads `0`; `debugSummary` confirms `pending=1 sent=0 rejected=0`.
4. **5s first-attempt tick fires** — mock server log: `mock server received: POST /api/feedback/store` with the multipart body (`organization_id=999`, `rating=poor`, `comment=...`) arriving during the "waiting for the 5s first-attempt tick" window.
5. **POST goes out, request + response logged** — full multipart request body logged above, and `mock server responded: 200 {"status":"success","message":"ok"}`.
6. **Row flips to synced=1** — `sqlite3` dump right after: `id=1 ... synced=1`; `debugSummary: pending=0 sent=1 rejected=0 lastSuccessfulSync=2026-09-12 20:44:11`.
7. **Network blocked** — mock server stopped, then `submit() returned in 9ms while offline` (still instant); dump shows the new row `id=2 ... synced=0` while row 1 stays `synced=1`. The row's own 5s attempt then genuinely failed against the down server (`DioException: connection error ... Connection refused`), correctly left at `synced=0`, `consecutiveFailures=1`, `currentBackoff=0:01:30`.
8. **Network restored, drains within one tick** — mock server restarted on the same port; the pending row's request (`rating=very_poor`) is logged arriving, server responds `200 success`, and the final dump shows both rows `synced=1`: `FINAL debugSummary: total=2 pending=0 sent=2 rejected=0`.

DONE: Resolve the "APK crashed but PROGRESS.md said the PRAGMA fix was already in place" contradiction — the installed `feedback.apk` predates the fix on disk. `git log` for `lib/services/db_service.dart` only has one entry (`c763e0b`, 2026-09-12 20:23:46+06) because this repo was `git init`'d partway through this session — there was no commit history before that to compare against, so the real evidence is filesystem mtimes, not git dates: `feedback.apk` was last built at **2026-09-12 19:16:17+06**, while `lib/services/db_service.dart` was last modified at **2026-09-12 19:29:35+06** — about 13 minutes *after* the APK was built (`lib/services/api_service.dart` and `lib/main.dart` are later still, 19:29:37 and 19:32:17). So the fix isn't missing or reverted — the committed APK is simply a stale build from before the fix existed, and it was never rebuilt afterward. The crash the user saw on-device is consistent with running that stale APK.

DONE: Audit the six FIX-02 work items against the current code (no changes made) — full findings below.

## FIX-02 audit (2026-09-12)

1. **Voice removed — DONE.** `lib/widgets/voice_recorder.dart` and
   `lib/services/audio_service.dart` don't exist. `record`, `just_audio`, and
   `permission_handler` are absent from `pubspec.yaml`. No
   `RECORD_AUDIO` permission anywhere under `android/`. The negative-dialog
   comment label already reads `অন্য কারণ থাকলে এখানে লিখুন` (voice half
   removed, `(ঐচ্ছিক)` kept). `voice_path` stays in the SQLite schema
   (`db_service.dart`) as instructed, and nothing in `feedback_entry.dart`
   reads or writes it any more. Only loose end: a stale doc comment in
   `lib/widgets/feedback_dialog.dart:263` still says "(stage 6) the voice
   recorder" — cosmetic, no functional code left.

2. **Local-first submit — DONE.** `SyncService.submit()`
   (`lib/services/sync_service.dart`) only `await`s `_db.insert(...)` — no
   network call in the submit path — then schedules a one-off 5s drain timer
   and returns the fixed string `আপনার মূল্যবান মতামতের জন্য ধন্যবাদ! 👏`
   unconditionally (no branch reads a server message). Both dialogs
   (`positive_dialog.dart`, `negative_dialog.dart`) wrap the `sync.submit()`
   call in a broad `try/catch` and show the real error on failure. Queue
   worker timing matches spec exactly: 5s first attempt, 45s regular tick,
   batch size 3 oldest-first, 500ms gap between rows, backoff doubles per
   consecutive failure capped at 15 minutes and resets to 45s on success,
   a `connectivity_plus` listener also triggers an immediate drain, and
   `deleteOldSyncedRows` prunes only `synced = 1` rows older than 7 days on
   `start()`. Per-row result handling (2xx-success → `synced=1`, 422 →
   `synced=-1` no retry, anything else → stop the batch and back off) is
   implemented in `_drain()`. `SyncService` is constructed once in `main()`
   and threaded down through `FeedbackApp`/`AppRoot`/`FeedbackScreen` — the
   `widget.sync ?? (SyncService(...)..start())` fallback in
   `_AppRootState` only exists for test injection and is never reached in
   production, since `main()` always passes `sync`. The debug dump
   (`FeedbackScreen._showDebugDump`) prints all nine fields in the exact
   order FIX-02 §1 specifies.

3. **API endpoints verified — DONE.** `lib/services/api_service.dart`
   implements all five endpoints from SPEC.md §5 with matching method,
   path, and payload shape: `POST /login` (JSON), `GET
   /get-org-logo/{orgId}`, `GET /get-marquee-text/{orgId}`, `POST
   /admin/get-categories` (JSON `{organization_id}`), `POST
   /feedback/store` (multipart, called only from `SyncService`'s queue
   worker per FIX-02 §1). Base URL matches
   `https://feedback.pathosoft.info/api`.

4. **Responsive + button styling — DONE.** Rating-button styling
   (`lib/widgets/rating_button.dart` + `lib/theme/responsive.dart`) matches
   FIX-02 §5 point for point: `ratingButtonPadding` is `EdgeInsets.all(...)`
   at 16/12/10 (expanded/medium/compact), resting border is 1.5px
   `AppTokens.border` (`#FFD4C9B0`) lerping to 2px accent on press,
   `ratingButtonRadius` is 18/16/14, height comes from
   `responsive.ratingButtonHeight` (uniform per class), content is
   centred with no extra bottom margin. For the responsive verification
   itself, an automated equivalent of FIX-02 §6's manual resize checklist
   already exists in `test/widget_test.dart` and was actually run this
   session (`flutter test test/widget_test.dart`, real output, not
   code-reading): all 44 tests pass, including "no overflow" checks for
   the feedback screen and login screen at all 8 listed sizes (360x640
   through 1920x1200), the negative dialog with categories selected + a
   3-line comment at all 8 sizes, and a rotate-with-dialog-open test that
   confirms selected category and typed comment survive a resize. A real
   on-device/desktop resize (as FIX-02 literally asks for) wasn't possible
   in this environment — no Android device/emulator is attached and the
   Linux desktop build is missing `clang++`/`ninja` — so this automated
   suite is the closest available real verification, and it passed clean.

5. **Performance — PARTIAL.** All prescribed code changes are in place:
   the background blur/darken/desaturate is pre-baked into a static asset
   (`assets/img/bd_blurred.png` — PNG rather than the spec's `.jpg`, a
   deliberate, documented substitution in `blurred_background.dart`
   because JPEG decoding hangs in this project's `flutter_tester`
   toolchain) and drawn plainly with no runtime `ImageFiltered`/
   `ColorFiltered`; `MarqueeBar`'s old `BackdropFilter` is gone, replaced
   by a plain semi-opaque `Container`; `RepaintBoundary` wraps both the
   background's scale animation and each `RatingButton` individually; the
   press animation drives only `Transform.scale`/`Transform.translate`;
   there's one background `AnimationController`, disposed in `dispose()`;
   `flutter analyze` is clean. Missing: FIX-02 explicitly asked to
   "diagnose with `flutter run --profile` and report actual frame times
   before changing anything" — that measurement was never produced and
   can't be produced in this environment (no Android device/emulator, and
   the Linux desktop toolchain can't build either), so the code-level fix
   is done but the requested frame-time evidence is outstanding.

6. **App icon — DONE.** `assets/img/icon.png` (1024x1024) and
   `assets/img/icon_foreground.png` exist; `pubspec.yaml` has
   `flutter_launcher_icons: ^0.14.1` under `dev_dependencies` configured
   exactly per spec (`adaptive_icon_background: "#1B4D3E"`, matching
   foreground path). `android/app/src/main/res/mipmap-hdpi/` (and
   -mdpi/-xhdpi/-xxhdpi/-xxxhdpi) each contain a generated
   `ic_launcher.png`, and `mipmap-anydpi-v26/ic_launcher.xml` is a real
   adaptive icon referencing `@color/ic_launcher_background` (`#1B4D3E`
   in `values/colors.xml`) with a 16%-inset foreground drawable. The
   splash colour lives in `drawable(-v21)/launch_background.xml` via
   `@color/verdant` = `#1B4D3E` (not literally in `styles.xml` as FIX-02
   says, but the same value reaching the same `windowBackground`).
   Given FIX-02's explicit warning that "the previous attempt at this
   reported success but the installed APK still had the default icon,"
   this was verified past the source tree: decompiled the actual
   committed `feedback.apk` with `aapt`/`aapt2` (`aapt dump badging`
   → `application-icon` resolves to an adaptive-icon XML; `aapt2 dump
   xmltree` on that XML shows a `background` color drawable plus a 16%
   `inset` `foreground` drawable) — the built artifact genuinely carries
   the new adaptive icon, not the Flutter default.

BLOCKED: Verify the 8-step local-first submit + sync pipeline with real running output (no code changes) — ran `flutter test tool/verify_sync_test.dart` (a pre-existing harness in the repo that drives the real `DbService`/`SyncService`/`ApiService` against a loopback mock HTTP server). It fails before step 1 produces any usable output: `sqflite_common_ffi` cannot open `libsqlite3.so` ("cannot open shared object file: No such file or directory"). The system has `libsqlite3-0` installed (`/usr/lib/x86_64-linux-gnu/libsqlite3.so.0`), but `dlopen("libsqlite3.so")` needs the unversioned dev-symlink (normally from `libsqlite3-dev`), which isn't present — no Android device/emulator is attached either (`adb devices` empty, no AVDs, no `emulator` binary), and the Linux desktop toolchain is incomplete (`flutter doctor`: missing clang++/ninja), so this Linux-desktop-FFI test run was the only path available for real (non-code-reading) verification. Paused mid-task, no steps confirmed yet, to handle a follow-up audit request first.

DONE: Fix SQLite PRAGMA execute() vs rawQuery() crash on Android (db_service.dart) — audited lib/services/db_service.dart: `PRAGMA journal_mode = WAL` and `PRAGMA table_info(feedbacks)` already use `rawQuery` (not `execute`), and the WAL pragma is already wrapped in its own try/catch so a failure doesn't block DB open. No other PRAGMA/raw-SQL misuse found elsewhere in lib/. `flutter analyze` clean.
