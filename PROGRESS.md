# Progress Log

IN PROGRESS: FIX-03 production-readiness pass (10 items, priority order: §3, §6-contradiction, §9, §8, §1, §2, §4, §5, §6-rest, §7, §10).

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
