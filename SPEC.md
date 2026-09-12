# Feedback Machine — Flutter Android Port

Port an existing Electron kiosk app to a Flutter Android app.
The visual design and behaviour must match the Electron version **exactly**.
Do not redesign anything. Do not "improve" the layout. Match it.

Target: Android tablet, landscape, kiosk mode. Min SDK 24, target SDK 34.
Package: `com.codestation23.feedback`
App name: `Feedback Machine`

---

## 1. Design tokens

Define these in `lib/theme/tokens.dart` as static consts. Use them everywhere.
Never hardcode a colour anywhere else in the codebase.

```
verdant      #1B4D3E
verdantMid   #2E6B52
verdantLit   #3D8A68
sageFill     #E8F2EC
ivory        #F9F6EE
parchment    #EDE8D9
border       #D4C9B0
borderMid    #C0B49A
ink          #1C1C1A
inkMid       #4A4438
inkMuted     #8C7B6B
amber        #B5813D
amberLit     #F5E9D0
white        #FFFFFF
error        #922B21
errorMid     #C0392B
errorLit     #FDECEA

cVeryGood    #1B4D3E
cGood        #2E6B52
cSatisfact   #B5813D
cPoor        #922B21
cVeryPoor    #6B1A1A
```

Radii: xs 6, sm 10, md 14, lg 20, xl 28.

Shadows:
- `shCard`  — black 7% blur 10 offsetY 2, plus black 4% blur 3 offsetY 1
- `shFloat` — black 18% blur 40 offsetY 12, plus black 8% blur 12 offsetY 4
- `shModal` — black 30% blur 80 offsetY 28, plus black 14% blur 24 offsetY 8

Motion: fast 160ms, mid 220ms. Standard curve `Curves.easeInOutCubic`.
Spring curve `Cubic(0.34, 1.56, 0.64, 1.0)` — used for card hover/press scale.

## 2. Fonts

Two families, bundled locally in `assets/fonts/` (do not fetch from Google at runtime —
the device is often offline):

- **Cormorant Garamond** (400, 600, 700) — headings only
- **DM Sans** (300, 400, 500, 600, 700) — everything else

Bengali text must render correctly. DM Sans has no Bengali glyphs, so add
**Hind Siliguri** (400, 500, 600, 700) as the fallback family and set it in
`fontFamilyFallback` on the default TextTheme. All UI strings in this app are Bengali.

Download the fonts with `google_fonts`'s static files or fetch the TTFs and commit them.
Register all three in `pubspec.yaml`.

---

## 3. Screens

### 3.1 Background (both screens share it)

A `Stack`:
1. `assets/img/bd.jpg` as `BoxFit.cover`, wrapped in
   `ImageFiltered(ImageFilter.blur(sigmaX: 14, sigmaY: 14))`, with a
   `ColorFiltered` matrix applying brightness 0.30 and saturation 0.75.
2. That image slowly scales 1.0 → 1.09 and back over 32 seconds, looping forever
   (`AnimationController` + `ScaleTransition`, `reverse: true`).
3. A noise texture overlay at 3.5% opacity — generate a 220×220 tiling PNG at build
   time or ship `assets/img/noise.png` and repeat it. `IgnorePointer` on top.
4. Base scaffold colour behind everything: `verdant`.

Bottom-left, fixed: `Developed by Code Station 23`, 11px.
"Developed by" at white 28%, "Code Station 23" bold at white 48%. Not tappable.

### 3.2 Login screen

Centred card, max width 420, full-width minus margins on small screens.
Background `ivory`, radius 28, `shModal`, border 1px white at 14%.
Padding 52 vertical / 48 horizontal. On screens under 600 wide: 38/28 and 20 margin.

Contents, centred, in order:

- 60×60 rounded square (radius 18), fill `verdant`, shadow verdant 38% blur 20 offsetY 6.
  Inside: a hospital icon in white, ~22px. Use `Icons.local_hospital` or a
  FontAwesome hospital glyph — either is fine, keep it white and centred.
- 18px gap.
- `অ্যাডমিন প্যানেল` — Cormorant Garamond 700, 28px, colour `ink`, letter-spacing -0.02em.
- 5px gap. `আপনার অ্যাকাউন্টে প্রবেশ করুন` — 13px, `inkMuted`.
- 36px gap, then the fields (left-aligned).

Each field: an uppercase label (11px, 700, `inkMid`, letter-spacing 0.12em, 7px below),
then the input. Input is 12/16 padding, white fill, 1.5px `border`, radius 10, 15px text.
On focus: border becomes `verdant` plus a 3px verdant-12% glow ring.

- Field 1: `ইমেইল`, hint `admin@example.com`, keyboard type email.
- Field 2: `পাসওয়ার্ড`, hint `••••••••`, obscured, with a trailing eye toggle button
  (`inkMuted`, darkens to `ink` on press) that flips between eye and eye-slash.
- 16px between fields, 10px before the button.

Login button: full width, 13/20 padding, `verdant` fill, white text 15px 700,
radius 10, shadow verdant 32% blur 14 offsetY 4. A sign-in icon then
`প্রবেশ করুন`, 9px gap. On press: darken to `verdantMid`, lift 1px, shadow grows.

On tap → call `POST /login`. See §5.

### 3.3 Feedback screen

Replaces the login screen entirely once authenticated.

**Top marquee bar** — fixed to the top, full width, 9px vertical / 20px horizontal
padding, fill `rgba(10,28,20,0.84)` with a 14px backdrop blur (`BackdropFilter`),
1px bottom border white 7%. Inside: a single line of text, 13px, weight 500,
colour `#C2E0D0` at 88%, centred, letter-spacing 0.05em, ellipsised if too long.
Initial text `লোড হচ্ছে...`, replaced by the API value.

**Body** — centred column, padding top 84, bottom 52, horizontal 24:

- Org logo: 130×130, `BoxFit.contain`, radius 24, `ivory` at 97% background,
  10px inner padding, `shFloat`. Hidden until a logo URL loads. Cache it to disk so
  it survives offline restarts (`cached_network_image` with a persistent cache dir).
- 22px gap.
- Heading, from the API: Cormorant Garamond 700, size scales with screen width —
  clamp between 30px and 50px, roughly `width * 0.05`. Colour `ivory`, line-height 1.18,
  centred, letter-spacing -0.015em, shadow black 28% blur 28 offsetY 2.
  Default text `আমাদের সেবার মান কেমন ছিল?`
- 8px gap. Subtitle `আপনার মতামত আমাদের সেবা উন্নত করতে সাহায্য করে` —
  13px, `#EDE8D9` at 60%, letter-spacing 0.04em.
- 52px gap.
- The rating row.

**Rating buttons** — five, in a `Row`, each `Expanded`, gap scales 6–16px with width,
max container width 1200.

Each button: height 220, `ivory` fill, radius 20, 2px transparent border, `shFloat`,
18/14 padding. Column-centred: emoji (font size clamped 46–82px), 13px gap,
label (size clamped 22–28px, weight 700, colour `ink`).

| Order | Emoji | Label | Value sent | Accent |
|---|---|---|---|---|
| 1 | 😍 | খুব ভালো | `very_good` | cVeryGood |
| 2 | ☺️ | ভালো | `good` | cGood |
| 3 | 😐 | সন্তোষজনক | `satisfactory` | cSatisfact |
| 4 | 🙁 | খারাপ | `poor` | cPoor |
| 5 | 😞 | খুব খারাপ | `very_poor` | cVeryPoor |

Press feedback (there is no hover on a tablet, so bind this to press-down):
scale to 1.04 and translate up 10px, emoji scales to 1.18, border takes the accent
colour, shadow becomes accent-at-24% blur 50 offsetY 20, and a
7%-opacity accent tint washes over the card. Release returns to rest with the
spring curve. On actual tap-down for a moment: scale 0.99, translate up 2px, 80ms.

Emoji must render in colour. Bundle **Noto Color Emoji** and put it in
`fontFamilyFallback` for the emoji text, otherwise some Android builds show
monochrome boxes.

Responsive: under 600px wide, wrap to a grid of 2–3 per row, each card
`flex 1 1 45%`, min height 140. Under 380px, allow 80px minimum width.

### 3.4 Feedback dialog

A modal dialog, max width 880, width `screenWidth - 32`, max height 90% of screen.
`ivory` fill, 1px `border`, radius 28, `shModal`, clipped to the radius.
Barrier is black at 55%, and **barrier dismiss is disabled** — only the Cancel
button or a successful submit closes it.

Enter animation: fade 0→1 over 280ms plus slide up 32px and scale 0.97→1.0
over 320ms with `Cubic(0.34, 1.24, 0.64, 1.0)`. Exit is the reverse, 280ms,
sliding down 24px.

A 4px full-width stripe sits at the very top of the dialog:
- positive → horizontal gradient `verdant` → `verdantLit`
- negative → horizontal gradient `error` → `errorMid`

The body scrolls if it overflows; the stripe does not.

#### Positive variant — shown for very_good, good, satisfactory

Head, padding 22/28/12:
- A pill badge: 5/11 padding, radius 100, 11px, 700, uppercase, letter-spacing 0.09em.
  `sageFill` background, `verdant` text, 1px verdant-18% border. A small star icon,
  6px gap, then `মূল্যবান মতামত`.
- 10px gap. Title, Cormorant Garamond 700, 30px, `ink`, two lines:
  `আপনার ইতিবাচক মতামতের` / `জন্য ধন্যবাদ!`

Body, padding 6/28/28:
- A card: `sageFill` fill, 1px verdant-15% border, radius 14, padding 28/20, centred.
  🎉 at 48px, 12px gap, then two lines at 15px, weight 600, colour `verdant`:
  `ফিডব্যাক জমা দিতে নিচের বাটনে ক্লিক করুন,` / `বাতিল করতে বাতিল বাটনে ক্লিক করুন।`
- 22px gap, then the two action buttons.

#### Negative variant — shown for poor, very_poor

Head:
- Badge, `errorLit` background, `error` text, 1px error-18% border,
  an X-circle icon then `খারাপ — মন্তব্য জানান`.
- Title: `কোথায় সমস্যা হয়েছে জানান`

Body, in order:

1. **Notice strip** — `errorLit` fill, 3px left border in `error`, radius 0/6/6/0,
   padding 11/14, 16px text weight 500 colour `error`, 20px bottom margin:
   `আপনার সেবা দিতে না পারার জন্য আমরা আন্তরিকভাবে দুঃখিত।`

2. **Section label** — a tag icon, then `কারণ নির্বাচন করুন` in 11px 700 uppercase
   `inkMuted` letter-spacing 0.12em, then `(একাধিক নির্বাচন করা যাবে)` in the same
   size but weight 400, not uppercase, no letter-spacing. 6px gaps, 11px below.

3. **Category pills** — a vertical list, left-aligned, 10px gap, each sized to its
   content (not full width). Rendered from the API list, in order.

   Rest state: white fill, 2px `border`, radius 100 (fully rounded),
   padding 13 top/bottom, 12 left, 28 right, 14px gap between children.
   - A 36×36 circle: `parchment` fill, 2px `borderMid` border, the 1-based serial
     number in `inkMid`, 14px, 700, tabular figures.
   - The category name: 23px, weight 600, colour `ink`, single line.

   Selected state: fill and border both `verdant`, lifted 1px, shadow verdant-30%
   blur 20 offsetY 5. The serial circle becomes white-22% fill, white-45% border,
   white text. The label turns white. Transition 160ms.

   Tapping anywhere on the pill toggles it. Multiple selection allowed.

   While loading with no cache: `লোড হচ্ছে...` in `inkMuted`, 14px, 8px vertical padding.
   If the fetch fails and no cache exists:
   `ইন্টারনেট সংযোগ না থাকায় ক্যাটেগরি লোড হয়নি।` in `inkMuted`, 14px.

4. **Divider** — 1px, `parchment`, 18px margin top and bottom. Used between sections.

5. **Comment** — section label with a pen icon:
   `অন্য কারণ থাকলে এখানে লিখুন অথবা ভয়েস রেকর্ড করুন` plus `(ঐচ্ছিক)` in light style.
   Then a multiline field, min height 108, padding 13/15, white fill, 1.5px `border`,
   radius 14, 15px text, vertically resizable in spirit — in Flutter use
   `maxLines: null` with a min height. Hint: `আপনার মতামত বিস্তারিত লিখুন...`
   Focus ring same as the login inputs.

6. **Divider.**

7. **Voice recorder** — section label, mic icon in `error`, `ভয়েস মেসেজ` `(ঐচ্ছিক)`.
   Then a row: `parchment` fill, 1.5px `border`, radius 14, padding 10/14, 10px gap.
   - Record button: white fill, 1.5px `border`, radius 6, padding 8/15,
     14px text weight 600 colour `ink`, a filled circle icon in `error`, 7px gap.
     Label `রেকর্ড শুরু করুন`.
     While recording: button fill and border become `errorMid`, text white,
     label `রেকর্ড থামান`, and the circle icon pulses (scale 1.0 ↔ 1.15, ~700ms loop).
     After stopping: label becomes `পুনরায় রেকর্ড করুন`, styling returns to rest.
   - Timer chip: `error` fill, white text, 13px 700, padding 4/10, radius 6,
     tabular figures, letter-spacing 0.05em, format `MM:SS`, starts at `00:00`.
   Below the row, once a recording exists: an audio player, full width, height 36,
   radius 6, with play/pause, a seek bar and elapsed/total time.

   Max recording length is **60 seconds**. On hitting it, stop automatically and
   show a toast (top-end, info icon, 3s, no button):
   `সর্বোচ্চ সময়সীমা (১ মিনিট) শেষ!`

   If mic permission is denied, show a warning dialog titled `মাইক্রোফোন` with
   `মাইক্রোফোন এক্সেস পাওয়া যায়নি!`

8. **Actions** — two buttons in an even 2-column grid, 10px gap, 22px top margin.
   Under 600px wide, stack them into one column.
   - Cancel: `parchment` fill, 1.5px `border`, `inkMid` text. On press, fill `border`,
     text `ink`. An X icon then `বাতিল`.
   - Submit: `verdant` fill, white text, shadow verdant-28% blur 12 offsetY 3.
     On press `verdantMid`, lift 1px. A paper-plane icon then
     `ফিডব্যাক জমা দিন` (negative) or `জমা দিন` (positive).
   Both: 13/18 padding, radius 10, 15px, weight 700.

### 3.5 Toasts and alerts

The Electron app uses SweetAlert2. Recreate the same shapes as Flutter dialogs
and toasts — same icon, same title, same body, same timings:

- Login failure → error icon, title `লগইন ব্যর্থ`, body = server message,
  confirm button `ঠিক আছে`.
- Submit success → success icon, title `ধন্যবাদ!`, body = server message,
  auto-dismiss after 1500ms, no confirm button.
- Submit failure (positive path) → error icon, title `দুঃখিত`, body = message.
- Submit failure (negative path) → error icon, title `ভুল বা ত্রুটি`, body = message.
- Empty negative feedback → warning icon, no title, body
  `দয়া করে কারণ সিলেক্ট করুন অথবা আপনার অভিজ্ঞতা লিখুন।`, confirm `ঠিক আছে`.
- Max recording time → toast, top-end, info icon, 3000ms, no button.

Keep them styled to the same palette: `ivory` surface, `ink` text, radius 20.

---

## 4. Behaviour

### 4.1 Startup

1. Show a blank `verdant` screen (no flash of white — set the native splash
   background to `#1B4D3E` too).
2. Read the saved `org_id` from secure/persistent storage.
3. If present → go straight to the feedback screen and call `loadData()`.
4. If absent → show the login screen.

### 4.2 loadData()

Runs after login and on every app launch when already authenticated.
Fires three requests. **None of them may block the UI** — the screen renders
immediately with cached or default values and updates when responses arrive.

- Logo → set the image, cache to disk.
- Marquee → set both the marquee text and the heading.
  On failure, both fall back to
  `ইন্টারনেট সংযোগ দিন, যাতে ফিডব্যাকগুলো sync হতে পারে।`
  Cache the last good values and prefer them over the fallback when offline.
- Categories → see below.

### 4.3 Category caching

Cache key: `categories_<orgId>`, stored as JSON.

Order of operations, matching the Electron version exactly:
1. If a cache entry exists and is non-empty, render it immediately.
2. Otherwise render the loading text.
3. Fire the network request regardless.
4. If it returns a non-empty list, overwrite the cache and re-render.
5. If it throws and there was no cache, render the offline message.
   If there *was* a cache, leave the cached list on screen and say nothing.

Categories are re-fetched every time the negative dialog opens.

### 4.4 Rating tap

Sets the pending rating, then opens the dialog in the matching variant.
For the negative variant, first clear the comment field and reset the recorder state.

### 4.5 Submitting

Guard with an `isSubmitting` flag — ignore taps while a submit is in flight.

**Positive:** send org id, rating, empty comment, no categories.

**Negative:** collect the trimmed comment and the checked category ids.
If the rating is `poor` or `very_poor` **and** no categories are selected
**and** the comment is empty → show the warning and abort without sending.
(Voice recording was removed in FIX-02 §2 — it's no longer part of this
guard.)

Otherwise send. On success: close the dialog, clear the comment, show the
success toast.

### 4.6 Dialog cleanup

Whenever the dialog closes for any reason, clear the comment field. A fresh
dialog instance is created each time it opens, so this falls out of normal
widget lifecycle rather than needing explicit reset code.

### 4.7 Offline-first save

This is the most important behaviour in the app. Never lose a feedback.

```
try:
    POST /feedback/store as multipart
    on success:
        insert locally with synced = 1
        return the server's response body
except:
    if the server responded with a body (4xx/5xx with JSON):
        return that body, do not save locally
    else (network failure, timeout):
        insert locally with synced = 0
        return { status: 'success',
                 message: 'আপনার মূল্যবান মতামতের জন্য ধন্যবাদ! 👏' }
```

The user must see a success message when offline. That is deliberate — from
their point of view the feedback *was* accepted.

Reject any voice file over 10 MB before sending, with
`ভয়েস ফাইলের সাইজ ১০ এমবি এর বেশি হতে পারবে না।`

### 4.8 Background sync

Every 30 seconds while the app is running, take up to 5 rows where `synced = 0`,
oldest first, and POST each one.

- Success (`status == 'success'` or `success == true`) → set `synced = 1`.
- HTTP 422 → set `synced = -1` (permanently rejected, never retry).
- Any other error → **break out of the loop entirely** and wait for the next tick.
  Do not burn through the queue while offline.

Wrap the whole thing so it can never crash the app or surface an error to the user.

The device is a dedicated kiosk that stays awake, so a `Timer.periodic` tied to
the app lifecycle is sufficient. Also trigger a sync immediately when
connectivity is regained (`connectivity_plus`).

### 4.9 Kiosk mode

The Electron app forced fullscreen, frameless, always-on-top, and refocused
itself on blur. The Android equivalents:

- `SystemChrome.setEnabledSystemUIMode(SystemUiMode.immersiveSticky)` — hide
  the status and nav bars, and bring them back only on a deliberate swipe.
- `SystemChrome.setPreferredOrientations` → landscape only.
- `WakelockPlus.enable()` — the screen never sleeps.
- Intercept the back button at the root (`PopScope` with `canPop: false`) so it
  cannot exit the app.
- Enable Android **Lock Task Mode** when the app is set as device owner; fall
  back to `startLockTask()` (screen pinning) otherwise. Wrap this in a try/catch
  — it must not crash on devices where it is unavailable.
- Register a `BOOT_COMPLETED` receiver so the app relaunches after a reboot.

Also disable text selection and any long-press context menus on the rating
buttons and headings.

---

## 5. API

Base URL: `https://feedback.pathosoft.info/api`
Timeout: 10 seconds on every request.

| Purpose | Method | Path | Body | Response used |
|---|---|---|---|---|
| Login | POST | `/login` | JSON `{email, password}` | `org_id` |
| Logo | GET | `/get-org-logo/{orgId}` | — | `logo` (URL string) |
| Marquee | GET | `/get-marquee-text/{orgId}` | — | `heading`, `text` |
| Categories | POST | `/admin/get-categories` | JSON `{organization_id}` | `success`, `categories[]` — each `{id, name}` |
| Submit | POST | `/feedback/store` | multipart | `status`, `message` |

Multipart field names, exactly as the Laravel backend expects:

```
organization_id   the org id
rating            very_good | good | satisfactory | poor | very_poor
comment           string, may be empty
category_ids[]    repeated once per selected id
voice             file, filename voice_note.webm, content type audio/webm
```

Login errors:
- No response at all (network down) →
  `ইন্টারনেট কানেকশন নেই। অনুগ্রহ করে সংযোগটি চেক করুন।`
- Any HTTP error →
  `ভুল ইমেইল বা পাসওয়ার্ড। আবার চেষ্টা করুন।`

---

## 6. Local database

SQLite via `sqflite`. File at the app's documents dir,
`FeedbackSystem/feedback.db`. Enable WAL.

```sql
CREATE TABLE IF NOT EXISTS feedbacks (
  id            INTEGER PRIMARY KEY AUTOINCREMENT,
  org_id        INTEGER,
  rating        TEXT,
  comment       TEXT,
  category_ids  TEXT,          -- JSON array, e.g. "[3,7]"
  voice_path    TEXT,          -- absolute path to the .webm on disk
  created_at    TEXT,          -- ISO 8601
  synced        INTEGER DEFAULT 0
);

CREATE INDEX IF NOT EXISTS idx_org_date ON feedbacks (org_id, created_at);
```

One deliberate change from the Electron schema: audio is stored as a **file path**,
not a BLOB. Multi-megabyte blobs in SQLite are slow on mid-range Android tablets.
Write recordings to `<documents>/FeedbackSystem/voices/<uuid>.webm` and delete the
file once its row reaches `synced = 1`.

Include the same defensive migration logic: check `PRAGMA table_info` on startup
and `ALTER TABLE ADD COLUMN` for any missing column, wrapped in try/catch.

`synced` values: `0` pending, `1` sent, `-1` rejected by the server.

---

## 7. Audio recording

Use `record` for capture and `just_audio` for playback.

Format: `AudioEncoder.opus` in a WebM container if the device supports it —
that keeps the uploaded file byte-compatible with what the backend already
receives from Electron. If the device cannot produce WebM/Opus, fall back to
AAC in an M4A container and change the upload filename and content type to
match (`voice_note.m4a`, `audio/mp4`). Detect this at runtime, do not assume.

Request `RECORD_AUDIO` permission at the moment the record button is first
tapped, not at startup.

---

## 8. Project structure

```
lib/
  main.dart
  theme/tokens.dart
  theme/app_theme.dart
  models/category.dart
  models/feedback_entry.dart
  services/api_service.dart
  services/db_service.dart
  services/sync_service.dart
  services/audio_service.dart
  services/storage_service.dart
  screens/login_screen.dart
  screens/feedback_screen.dart
  widgets/blurred_background.dart
  widgets/marquee_bar.dart
  widgets/rating_button.dart
  widgets/feedback_dialog.dart
  widgets/category_pill.dart
  widgets/voice_recorder.dart
  widgets/app_alerts.dart
assets/
  img/bd.jpg
  img/noise.png
  fonts/...
```

Dependencies: `dio`, `sqflite`, `path_provider`, `shared_preferences`,
`record`, `just_audio`, `permission_handler`, `connectivity_plus`,
`cached_network_image`, `wakelock_plus`, `uuid`.

State: `provider` or plain `ChangeNotifier` — keep it simple, this app has
very little state. Do not pull in a heavy state framework.

---

## 9. Build

Produce a **signed release APK**, not a debug build and not an app bundle —
it will be sideloaded from Google Drive, so it must be a single installable file.

```
flutter build apk --release
```

Generate a keystore and wire up `android/key.properties` and the signing config
in `android/app/build.gradle`. Commit `key.properties` to `.gitignore` and print
the keystore password to the terminal once so it can be saved.

Enable `minifyEnabled` and `shrinkResources`, and add whatever ProGuard keep
rules the plugins need so the release build does not crash where debug worked.

Add to `AndroidManifest.xml`:

```xml
<uses-permission android:name="android.permission.INTERNET" />
<uses-permission android:name="android.permission.RECORD_AUDIO" />
<uses-permission android:name="android.permission.WAKE_LOCK" />
<uses-permission android:name="android.permission.RECEIVE_BOOT_COMPLETED" />
```

Set `android:screenOrientation="sensorLandscape"` on the main activity and
`android:usesCleartextTraffic="false"` (the API is HTTPS).

---

## 10. Definition of done

Verify each of these before saying the work is complete:

1. `flutter analyze` reports zero issues.
2. The release APK builds and its path is printed.
3. Login persists — kill and relaunch the app, it opens straight to the ratings.
4. All five rating buttons open the correct dialog variant.
5. Positive submit works and shows the success toast.
6. Negative submit with only a category works.
7. Negative submit with only a comment works.
8. Negative submit with only a voice note works.
9. Negative submit with nothing at all shows the warning and does not send.
10. With airplane mode on: submit still shows success, and the row lands in
    SQLite with `synced = 0`.
11. Turn networking back on: within 30 seconds the row flips to `synced = 1`
    and the voice file is deleted from disk.
12. Categories render from cache instantly on a cold offline start.
13. The recorder stops itself at exactly 60 seconds and shows the toast.
14. Back button does nothing. Status bar stays hidden. Screen never sleeps.
15. Bengali text renders correctly everywhere, with no tofu boxes, and emoji
    render in colour.

---

## Working notes

Build it in this order and tell me when each stage is done:

1. Project scaffold, tokens, theme, fonts, background.
2. Login screen and the API service.
3. Feedback screen, marquee, logo, rating buttons.
4. Positive dialog end to end.
5. Negative dialog: categories, comment, actions.
6. Voice recorder.
7. SQLite, offline save, background sync.
8. Kiosk mode and boot receiver.
9. Signed release build.

Do not skip ahead. If a spec detail here conflicts with something you find in
the original Electron source, follow this spec and flag the conflict.
