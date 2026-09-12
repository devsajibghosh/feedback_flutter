# Progress Log

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
