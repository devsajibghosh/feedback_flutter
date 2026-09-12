# FIX-01 — post-install issues

Six problems found after installing the release APK on a real device.
Work through them in the order below. Do not batch them into one commit.

Two of these are functional bugs where **nothing works at all** (§2 submit,
§3 success message). Diagnose those before changing any code — the cause
matters more than the patch.

---

## 1. App icon

Currently showing Flutter's default icon.

Use `assets/img/logo.jpeg` as the launcher icon.

JPEG is the wrong format for an Android icon — it has no alpha channel, so it
will render as a square with hard edges on launchers that expect transparency.
Convert it first:

- Produce a 1024x1024 PNG from `logo.jpeg`. If it isn't square, letterbox it on
  a transparent canvas rather than stretching it.
- Save it as `assets/img/icon.png`.
- Also produce `assets/img/icon_foreground.png` — the same artwork scaled to
  about 70% and centred on a 1024x1024 transparent canvas, for the adaptive
  icon foreground layer. Android crops adaptive icons to a circle or squircle
  depending on the launcher, and artwork that fills the full square gets its
  edges cut off.

Then use `flutter_launcher_icons`:

```yaml
dev_dependencies:
  flutter_launcher_icons: ^0.14.1

flutter_launcher_icons:
  android: true
  ios: false
  image_path: "assets/img/icon.png"
  adaptive_icon_background: "#1B4D3E"
  adaptive_icon_foreground: "assets/img/icon_foreground.png"
```

Run `dart run flutter_launcher_icons`, then rebuild. Confirm the generated
files landed in `android/app/src/main/res/mipmap-*/`.

Also set the splash screen background to `#1B4D3E` so there is no white flash
before the first frame (SPEC.md §4.1 already asks for this — verify it happened).

---

## 2. Feedback submit does not work

Nothing is reaching the server. Before changing anything, find out where it
stops. Add temporary logging at each step and report back what you see:

1. Is the submit handler firing at all? (Is `isSubmitting` stuck at `true` from
   an earlier failed attempt that never reset it in a `finally` block? That is
   the single most likely cause — one failure and the button is dead forever.)
2. Is the request being built? Log the full multipart body: field names,
   values, and the org id.
3. Is the request being sent? Enable Dio's `LogInterceptor` with
   `requestBody: true, responseBody: true`.
4. What comes back? Status code, headers, and the raw body — not the parsed
   object, the raw string.

Report all four before you patch anything.

Things to check specifically:

- **`isSubmitting` reset.** It must be reset in a `finally`, so an exception
  can never leave it stuck. Same for any loading flag on the button.
- **Org id type.** The API returns `org_id`; confirm whether it comes back as
  an int or a string, and that the same type goes out in `organization_id`.
  A stringified int in a multipart field is usually fine, but `null` is not —
  log it and confirm it isn't null after a cold restart.
- **`category_ids[]`.** Dio's `FormData` needs repeated keys added as separate
  `MapEntry` items, not as a list value. `FormData.fromMap({'category_ids[]': [1,2]})`
  does not produce what Laravel expects. Build it explicitly:
  ```dart
  final form = FormData();
  form.fields.add(MapEntry('organization_id', orgId.toString()));
  form.fields.add(MapEntry('rating', rating));
  form.fields.add(MapEntry('comment', comment));
  for (final id in categoryIds) {
    form.fields.add(MapEntry('category_ids[]', id.toString()));
  }
  ```
- **Content type.** Dio sets the multipart boundary automatically. If anything
  in the code sets `Content-Type` manually on this request, remove it — a
  hand-set header without the boundary makes Laravel see an empty body.
- **`validateStatus`.** If Dio is configured to accept all status codes, a 422
  or 500 will look like success and the error will be swallowed. Check this.
- **Response shape.** The code expects `status == 'success'`. Confirm the server
  actually sends that key. If it sends `success: true` instead, handle both.
- **Cleartext / TLS.** The base URL is HTTPS so this should be fine, but confirm
  the request isn't being blocked by the network security config on the device.

Once you know the cause, fix it and show me the log of one successful submit.

---

## 3. Success message does not appear

Related to §2 but verify separately — it may have its own cause.

The flow after a successful submit should be: close the dialog, then show the
success alert. If the alert is being shown with the dialog's `BuildContext`
*after* that dialog has been popped, the context is dead and nothing renders,
silently.

Fix by using a root navigator key or a `ScaffoldMessenger` held above the dialog:

```dart
final rootMessengerKey = GlobalKey<ScaffoldMessengerState>();
// on MaterialApp: scaffoldMessengerKey: rootMessengerKey
```

Show the success alert through that key, never through the dialog's context.

Also confirm:
- The alert isn't rendering behind the modal barrier.
- The 1500ms auto-dismiss timer isn't firing before the widget mounts.
- `mounted` is checked before any `setState` that follows an `await`.

Test all four paths: positive submit online, positive submit offline,
negative submit online, negative submit offline. All four must show a message.

---

## 4. Remove voice recording entirely

The feature is not wanted. Remove it completely rather than hiding it — dead
code and unused permissions both cost something.

Delete:
- `lib/widgets/voice_recorder.dart`
- `lib/services/audio_service.dart`
- The whole voice recorder block from the negative dialog (SPEC.md §3.4 item 7),
  and the divider that preceded it.
- The `voice` multipart field and the 10MB size check.
- The `voice_path` column from the SQLite schema, the `voices/` directory
  handling, and the file-deletion-on-sync logic.
- `record`, `just_audio`, and `permission_handler` from `pubspec.yaml`
  (keep `permission_handler` only if something else still needs it — check).
- `<uses-permission android:name="android.permission.RECORD_AUDIO" />` from
  the manifest.

Update the validation rule in SPEC.md §4.5. It currently reads: warn if there
is no recording AND no categories AND no comment. With voice gone it becomes:

> If the rating is `poor` or `very_poor` and no categories are selected and the
> comment is empty → show the warning and do not send.

Update the comment field's section label — it currently says
`অন্য কারণ থাকলে এখানে লিখুন অথবা ভয়েস রেকর্ড করুন`. Change it to
`অন্য কারণ থাকলে এখানে লিখুন` and keep the `(ঐচ্ছিক)` suffix.

For existing installs, the `voice_path` column may already exist in their
database. Leave it in place rather than dropping it — SQLite's `DROP COLUMN`
support is version-dependent and a failed migration is worse than an unused
column. Just stop reading and writing it.

---

## 5. Local save, sync, and the offline path

Reported as not working. Verify each link in the chain and report what you find
before patching:

1. Does the database file actually get created? Print its full path on startup
   and confirm the file exists on disk.
2. Does a row get inserted on an offline submit? Query the table right after
   and log the row count and the row itself.
3. Does the 30-second timer fire? Log each tick.
4. Does the sync attempt run and what does it return?
5. Does the row flip to `synced = 1`?

Likely causes, in order of probability:

- **The offline branch is never reached.** SPEC.md §4.7 says: save locally only
  when there is no response at all. If Dio is throwing a `DioExceptionType` that
  the code treats as "server responded", a network failure takes the wrong
  branch and nothing is saved. Check the exception type explicitly:
  `connectionError`, `connectionTimeout`, `receiveTimeout`, `sendTimeout`, and
  `unknown` with a `SocketException` inside all mean offline.
- **The database is opened lazily and the first call races.** Make the open a
  single awaited future that everything shares.
- **`Timer.periodic` is created in a widget that rebuilds**, spawning duplicates
  or getting cancelled. Move it into a service that lives for the app's lifetime,
  started once from `main()`.
- **The sync loop's `break` on error is breaking on the first row every time**
  because that row is permanently malformed. Log which row and why.

Add a temporary debug screen or a long-press gesture somewhere unobtrusive that
dumps: total rows, count by `synced` value, and the oldest pending row. That
makes this verifiable on a real device without a cable. Leave it in for now;
we can remove it before the final build.

---

## 6. Performance

The app is slow on device. Diagnose with `flutter run --profile` and the
DevTools performance overlay, then report the actual frame times before
optimising blind.

The likely culprits, in order:

**The blurred background is the prime suspect.** SPEC.md §3.1 asks for a 14px
`ImageFilter.blur` over a full-screen image that is *also* being continuously
scaled by an animation. That means the GPU re-blurs the entire screen every
single frame, forever. On a mid-range tablet this alone can eat the whole
frame budget.

Fix: pre-blur the image once, at build time, and ship the blurred version as
an asset. Then the runtime cost is just drawing a bitmap.

- Generate `assets/img/bd_blurred.jpg` — the original with a 14px Gaussian
  blur, brightness 0.30, saturation 0.75 already baked in. Downscale it to
  around 1280px on the long edge; it's blurred, so detail is wasted bytes.
- Draw it directly with no `ImageFiltered` and no `ColorFiltered` at runtime.
- Keep the slow scale animation, but wrap the image in a `RepaintBoundary` so
  the animation doesn't invalidate anything above it.

**The marquee bar's `BackdropFilter`** is the second suspect. `BackdropFilter`
is expensive and it is pinned to the top of the screen, so it re-composites on
every frame that anything below it changes. Since the background behind it is
now a static pre-blurred image, replace the `BackdropFilter` with a plain
semi-opaque `Container` in the same colour. Visually near-identical, far cheaper.

**Other things to check:**
- Any `Opacity` widget wrapping something that animates → use
  `AnimatedOpacity`, `FadeTransition`, or bake the alpha into the colour.
- Shadows: `shModal` is an 80px blur. Large shadow blurs are costly. Use them
  only on the dialog, never on anything that animates or repeats.
- Wrap each rating button in a `RepaintBoundary` so pressing one doesn't
  repaint the other four.
- Confirm the rating press animation drives only `Transform.scale` and
  `Transform.translate`, not a layout property — animating padding or height
  forces a relayout every frame.
- Check that `const` is used on every widget that can take it. Run
  `dart fix --apply` for the easy ones.
- Make sure the background `AnimationController` is disposed properly and only
  one exists.

Target: a steady 60fps with no jank on the rating screen, and no dropped frames
when the dialog opens.

---

## 7. Rating button styling

Current buttons need refinement. Requirements:

- **Even padding on all four sides.** Currently 18 vertical / 14 horizontal.
  Make it uniform — one value used for all four edges, scaled by the responsive
  class (see SPEC-RESPONSIVE.md). Suggested base: 16 on expanded, 12 on medium,
  10 on compact.
- **A visible resting border.** Currently 2px transparent. Change to 1.5px in
  `border` (`#D4C9B0`) at rest, so the card reads as a defined object against
  the ivory fill rather than a floating shadow. On press it still takes the
  accent colour, at 2px.
- **Softer corners.** Radius 20 currently. Change to 18 on expanded, 16 on
  medium, 14 on compact — gentler at small sizes so the corners don't eat the
  content area.
- **Identical on all four sides.** The emoji and label must be optically
  centred as a group, with equal breathing room above the emoji and below the
  label. Use `MainAxisAlignment.center` on the column and let the padding do
  the rest — do not add an extra bottom margin on the label.
- **Consistent across the row.** All five buttons must be exactly the same
  height regardless of label length. Enforce with `IntrinsicHeight` on the row
  or a fixed height from the responsive class.

Keep everything else — the shadow, the tint wash, the press scale — as
specified. This is a refinement, not a redesign.

---

## Order of work

1. §2 and §3 first. Diagnose both, report findings, then fix. Nothing else
   matters if feedback doesn't submit.
2. §5 next, same approach — diagnose, report, fix.
3. §4 — remove voice. Easy, and it shrinks the surface area of everything else.
4. §6 — performance.
5. §7 — button styling.
6. §1 — icon, last, right before the rebuild.

After each numbered section: run `flutter analyze`, confirm zero issues, and
tell me what changed. Do not move to the next section until I say so.

Then rebuild the release APK as `feedback.apk` and give me the path and size.
