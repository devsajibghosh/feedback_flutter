# FIX-02 — local-first rewrite, voice removal, icon, responsive

FIX-01 §2 and §3 are done. This file covers what remains, plus one
architectural change that supersedes SPEC.md §4.7.

Work through the sections in the order given. After each one: run
`flutter analyze`, confirm zero issues, report what changed, and stop.
Do not start the next section until I say so.

---

## 1. Local-first submit — this replaces SPEC.md §4.7 entirely

### The change

Right now the code tries the network first and only falls back to SQLite when
that fails. That is backwards for this app. Reverse it:

```
on submit:
    1. write the row to SQLite with synced = 0
    2. close the dialog and show the success message
    3. return

separately, in the background:
    a queue worker drains synced = 0 rows to the server
```

The network is no longer in the submit path at all. Nothing the user does
waits on it.

### Why

This is a kiosk in a hospital corridor. People tap a face and walk away. A
10-second Dio timeout means the dialog can sit there for 10 seconds before
anything happens — and on a bad connection that is exactly what happens today.

With the reversal, submit is a single local INSERT. It completes in a
millisecond or two whether the network is up, down, or slow. The success
message appears instantly, every time, and the queue catches up on its own.

It also removes an entire class of bug: there is now one code path instead of
two, so "did it save?" has one answer instead of depending on which branch ran.

### What to implement

**Submit handler** — no `await` on anything network. Write the row, show the
alert, done. Wrap the insert in try/catch: if even the local write fails,
show the error alert with the real exception (the FIX-01 §3 surface already
does this) rather than a silent failure.

**Success message** — always the same string, since we no longer know or care
whether the server has it yet:

```
আপনার মূল্যবান মতামতের জন্য ধন্যবাদ! 👏
```

Drop the branch that used the server's `message` field. Nothing shows a
server message any more, because the user is gone before the server replies.

**Queue worker** — a single long-lived service, started once from `main()`,
never owned by a widget.

Timing:
- First attempt for a new row: 5 seconds after it lands. Long enough that a
  visitor tapping three ratings in a row doesn't fire three requests, short
  enough that a healthy connection clears the queue almost immediately.
- Regular tick: every 45 seconds.
- Batch size: 3 rows per tick, oldest first.
- Between rows in a batch: 500ms gap, so a burst doesn't hammer the endpoint.

Backoff — when a tick fails, do not keep retrying at 45s. Double the interval
each consecutive failure: 45s, 90s, 3m, 6m, 12m, capped at 15 minutes. Reset
to 45s on the first success. Store the failure count in memory; it doesn't
need to survive a restart.

Also trigger a drain immediately when `connectivity_plus` reports the
connection came back, regardless of where the backoff timer is.

Result handling, per row:
- 2xx with `status == 'success'` or `success == true` → `synced = 1`
- HTTP 422 → `synced = -1`, never retry (bad data, retrying won't help)
- Any other HTTP status, or a network error → leave at 0, stop the batch,
  start the backoff. Do not advance to the next row.

**Never block, never crash.** The whole worker sits inside a try/catch that
swallows everything and logs it. A sync failure must never surface to the
user or interrupt what's on screen.

**Retention.** Rows at `synced = 1` are dead weight — the server has them.
Delete anything with `synced = 1` older than 7 days on startup. Keep
`synced = -1` rows indefinitely so we can inspect them later.

### The debug dump stays

Extend the long-press dump from FIX-01 §5 to show, in this order:

```
Total rows
Pending (synced = 0)
Sent (synced = 1)
Rejected (synced = -1)
Oldest pending: <created_at>
Current backoff interval
Consecutive failures
Last error: <type> — <message>
Last successful sync: <timestamp>
DB path
```

This is how I verify the whole thing works without a cable. Keep it until I
say to remove it.

---

## 2. Remove voice recording

This was FIX-01 §4 and hasn't been done — the recorder is still in the
negative dialog on the installed build.

Delete:
- `lib/widgets/voice_recorder.dart` and `lib/services/audio_service.dart`
- The recorder block from the negative dialog, and the divider above it
- The `voice` multipart field and the 10MB check
- The `voices/` directory handling and the delete-on-sync logic
- `record`, `just_audio`, and `permission_handler` from `pubspec.yaml`
  — check nothing else needs `permission_handler` before removing it
- `<uses-permission android:name="android.permission.RECORD_AUDIO" />`

Leave the `voice_path` column in the SQLite schema. Dropping a column is
version-dependent in SQLite and a failed migration on an existing install is
worse than an unused column. Just stop reading and writing it.

Change the comment section's label. It currently reads
`অন্য কারণ থাকলে এখানে লিখুন অথবা ভয়েস রেকর্ড করুন` — remove the voice half:

```
অন্য কারণ থাকলে এখানে লিখুন
```

Keep `(ঐচ্ছিক)` after it.

Update the validation rule (SPEC.md §4.5). With voice gone:

> If the rating is `poor` or `very_poor`, and no categories are selected, and
> the comment is empty → show the warning and do not send.

Removing three plugins should also cut a noticeable chunk off the 57MB APK.
Report the new size.

---

## 3. App icon

Still showing Flutter's default. The source file is at `assets/img/logo.jpeg`
and it is already in the project.

JPEG has no alpha channel, so it can't be used directly — Android will render
it as a hard square. Convert it first:

- `assets/img/icon.png` — 1024x1024. If `logo.jpeg` isn't square, pad it onto
  a transparent canvas; do not stretch.
- `assets/img/icon_foreground.png` — the same artwork at roughly 70% scale,
  centred on a 1024x1024 transparent canvas. Adaptive icons get cropped to a
  circle or squircle depending on the launcher, so artwork that fills the full
  square loses its edges.

You can do the conversion with ImageMagick or a small Dart script using the
`image` package — either is fine.

Then:

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

Run `dart run flutter_launcher_icons`. Then confirm the generated PNGs
actually landed in `android/app/src/main/res/mipmap-*/` — list the directory
contents and show me. The previous attempt at this reported success but the
installed APK still had the default icon, so verify rather than assume.

Also confirm the splash background is `#1B4D3E` in
`android/app/src/main/res/values/styles.xml`, so there's no white flash on
launch.

---

## 4. Performance

FIX-01 §6, still outstanding. Diagnose with `flutter run --profile` and report
actual frame times before changing anything.

The prime suspect is the background. SPEC.md §3.1 asks for a 14px
`ImageFilter.blur` over a full-screen image that is simultaneously being
scaled by a 32-second animation. That re-blurs the whole screen every frame,
forever.

Fix it at build time instead:
- Generate `assets/img/bd_blurred.jpg` from `bd.png` with the 14px Gaussian
  blur, brightness 0.30 and saturation 0.75 already baked in.
- Downscale to ~1280px on the long edge. It's blurred; detail is wasted bytes.
- Draw it plainly — no `ImageFiltered`, no `ColorFiltered` at runtime.
- Keep the slow scale animation, wrapped in a `RepaintBoundary`.

Second suspect: the marquee bar's `BackdropFilter`. It's pinned to the top and
re-composites whenever anything below changes. With the background now static,
replace it with a plain semi-opaque `Container` in the same colour. Visually
near-identical, far cheaper.

Then check:
- Any `Opacity` around an animating child → `FadeTransition` or bake the alpha
  into the colour
- `RepaintBoundary` around each rating button so pressing one doesn't repaint
  the other four
- The press animation must drive `Transform.scale` and `Transform.translate`
  only — never padding, height, or anything that triggers relayout
- `shModal`'s 80px blur only on the dialog, never on anything animating
- `dart fix --apply` for missing `const`
- One background `AnimationController`, disposed properly

Target: steady 60fps on the rating screen, no dropped frames when the dialog
opens.

---

## 5. Rating button styling

- **Uniform padding on all four sides.** Currently 18 vertical / 14 horizontal.
  One value for all four edges, scaled by the responsive class: 16 expanded,
  12 medium, 10 compact.
- **Visible resting border.** Currently 2px transparent. Make it 1.5px in
  `border` (`#D4C9B0`) at rest so each card reads as a defined object. On press
  it takes the accent colour at 2px.
- **Softer corners.** 18 expanded, 16 medium, 14 compact.
- **Optically centred content.** Equal space above the emoji and below the
  label. `MainAxisAlignment.center` on the column, no extra bottom margin.
- **Equal heights.** All five identical regardless of label length. Fixed
  height from the responsive class.

Everything else — shadow, tint wash, press scale — stays as specified.

---

## 6. Responsive verification

SPEC-RESPONSIVE.md was written but never verified on a real screen. Do it now,
methodically, and report each result separately.

Run on Linux desktop and resize the window to each size below. For every one,
tell me: does anything overflow, is any text clipped, are all five ratings
reachable, does the dialog scroll fully, and is the comment field usable.

| Size | Represents |
|---|---|
| 360 x 640 | small phone, portrait |
| 640 x 360 | small phone, landscape |
| 412 x 915 | large phone, portrait |
| 915 x 412 | large phone, landscape |
| 800 x 1280 | 7" tablet, portrait |
| 1280 x 800 | 7" tablet, landscape |
| 1200 x 1920 | 10" tablet, portrait |
| 1920 x 1200 | 10" tablet, landscape |

Then, at 640x360 and 915x412 specifically — the two hardest cases, a phone in
landscape where height is scarce — open the negative dialog with four
categories, select two, type three lines into the comment, and confirm
everything is still reachable by scrolling.

Then rotate (resize) while that dialog is open with state in it. Nothing may
be lost.

A `RenderFlex overflowed` warning at any size counts as a failure. Report
every one you see rather than only the ones you fix.

---

## Order

1. §1 local-first. The architecture change, and the most important.
2. §2 voice removal. Shrinks everything else.
3. §6 responsive. Do it before styling so the styling is applied to a layout
   that already fits.
4. §5 button styling.
5. §4 performance.
6. §3 icon, last.

Then rebuild `feedback.apk` and report the path and size.

One request: where something here conflicts with what you find in the code, or
where you think a step is wrong, say so before doing it. The last two rounds
had me chasing hypotheses that turned out to be false — I would rather you
push back early.
