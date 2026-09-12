# FIX-03 — production readiness

Final round before this goes on an unattended hospital kiosk. Everything
below was either observed on a real device or follows from how the device
will actually be used.

Read the whole file before starting. Several items interact — the scroll work
in §3 changes what §5 can do, and the idle reset in §9 touches the same
dialog lifecycle as §2 and §3.

**The operating context matters.** This is not an app someone chose to
install. It is a screen bolted to a wall in a hospital corridor. The user is
often unwell, possibly elderly, possibly holding a child, and gives it about
fifteen seconds. They will not scroll to look for a button. They will not
read instructions. If something is off-screen it does not exist, and if
something takes two taps when it should take one, they walk away.

Design every decision here for that person.

---

## 1. Sync throttle — one row per 30 seconds, invisible

Change the queue worker: regardless of how many rows are pending, upload
**at most one every 30 seconds**.

Replace "3 rows per tick, 500ms apart" with:

- One row per drain, oldest first.
- A minimum 30-second gap between the *completion* of one upload and the
  *start* of the next. Measure from completion, not from the tick, so a slow
  upload can't cause two to overlap.
- 50 queued rows leave over roughly 25 minutes. Intentional.

Keep: the 5s first attempt for a newly written row, the `connectivity_plus`
immediate trigger, exponential backoff on failure (45s → 90s → 3m → 6m →
12m, cap 15m), 422 → `synced = -1`, 7-day pruning of `synced = 1`.

Where the 5s first attempt and the 30s throttle disagree, the throttle wins.

### This must be completely invisible to the user

They must never be able to tell a queue exists.

- No progress indicator, no counter, no "syncing" text, no status icon.
- No visible difference between a device that is online and one that has
  been offline for a week.
- The success message is identical either way and appears at the same speed
  — instantly, because submit is a local write.
- No toast, banner, or notification when the queue drains or fails.
- If a row is rejected with 422, the user sees nothing. It is logged and
  marked, and that is all.

The entire user-visible model is: tap a face, get a thank-you, done.

## 2. Success message — 4 seconds, non-blocking

Currently 1500ms. Change to 4000ms.

- Closes on its own with no interaction.
- Tapping it closes it early.
- **It must not block the next rating tap.** If someone taps a face while the
  message is up, the message closes immediately and the new dialog opens. A
  kiosk with two people queued cannot make the second wait out an animation.
- If the app is backgrounded and comes back while the message is up, the
  message is gone. Do not resume a stale timer.

## 3. The dialog must scroll — the most important item here

**Observed on device:** with the negative dialog open, tapping the comment
field raises the keyboard and everything below the field vanishes. Submit and
Cancel become unreachable. A user who types a comment cannot send it.

44 tests pass and none caught this, because widget tests do not raise a
keyboard. Verify with a real keyboard, not by reading the widget tree.

### The rule

The dialog is never a fixed-height box. It is always a scrollable region
whose maximum height responds to what is actually available:

```
maxHeight = (screenHeight - viewInsets.bottom) * 0.9
```

recomputed on every keyboard show and hide, and on rotation. If content
exceeds that, it scrolls. If content fits, the dialog shrink-wraps and
centres.

### What to check

- `MediaQuery.viewInsets.bottom` is subtracted. `MediaQuery.size.height`
  alone does not shrink when the keyboard appears — this is almost certainly
  the bug.
- `resizeToAvoidBottomInset` is not false anywhere in the chain.
- The scroll view sits *inside* the dialog wrapping the body, with the action
  buttons positioned so they stay reachable by scrolling.
- Focusing the comment field scrolls it into view above the keyboard. Use
  `Scrollable.ensureVisible` on focus, or set the field's `scrollPadding` to
  clear the keyboard plus the action row.
- Physics is `ClampingScrollPhysics`. No iOS-style bounce — it reads as
  broken on Android.

### Make it visible that there is more

A user who cannot see the submit button will not think to scroll. Add an
affordance:

- A soft fade at the bottom edge of the scroll area whenever content
  continues below the fold. Remove it at the bottom of the scroll.
- A 24px gradient from the dialog's `ivory` to transparent, via `ShaderMask`
  or a positioned overlay.
- Reactive to scroll position, not static.

This costs almost nothing and is the difference between a usable dialog and
an abandoned one.

### The worst case

Phone in landscape with the keyboard open — available height drops to roughly
150 logical pixels. Test this specifically. The dialog must still show the
comment field and let the user reach Submit by scrolling.

If that isn't achievable, collapse the head (badge and title) while the
keyboard is open and restore it when the keyboard closes. The title is not
needed while typing.

### Also

- Rotating with the keyboard open, text typed, and categories selected must
  lose nothing.
- The keyboard action key on the comment field should be "done", not "next"
  — there is nothing after it.
- Tapping outside the comment field dismisses the keyboard without closing
  the dialog.

## 4. Helper text under the rating cards

Add this line, exactly as written, below the rating grid:

```
খারাপ বা খুব খারাপ নির্বাচন করলে সমস্যার বিস্তারিত জানানোর সুযোগ থাকবে।
```

Copy the string verbatim, including the final `।` — do not retype it or
substitute a full stop.

### Placement

It sits **after the last rating card, outside the grid** — not inside any
card, not between rows, not above the grid. On a phone in portrait the five
cards wrap to 2 + 2 + 1, and this line goes below the fifth card, spanning
the full width of the grid and centred against it.

The reference screenshot shows exactly this: the line runs under the
"খুব খারাপ" card, centred, wrapping to two lines.

### Styling

- Same muted treatment as the existing subtitle: `#EDE8D9` at 60%,
  letter-spacing 0.04em, weight 400.
- Size 13 expanded, 12 medium, 11 compact.
- Centred, `TextAlign.center`, wrapping to two lines on narrow screens with
  both lines centred. Never truncate or ellipsise — if it doesn't fit, it
  wraps to three lines.
- 16px above, 0 below.
- Horizontal padding matching the grid's, so the wrap point lines up with
  the card edges rather than the screen edges.

### Visibility

Hidden when `shortHeight` is true — a phone in landscape has no room for it,
and the ratings matter more than the hint.

It is informational only: not tappable, no gesture, no link, excluded from
the semantics tree as a button. Screen readers should read it as plain text.

## 5. Card typography — emoji leads, text confirms

**Observed:** emoji and label are close in size, so the eye has to read
before it understands. Reverse that. The emoji should carry the meaning at a
glance; the text confirms it.

Emoji at roughly **2.2x** the Bengali label, at every breakpoint:

| | emoji | Bengali | English sub |
|---|---|---|---|
| expanded | 68 | 30 | 16 |
| medium | 56 | 25 | 14 |
| compact | 46 | 21 | 12 |

The English sub-label stays about half the Bengali size, in `inkMuted`.

- Cards grow to fit. No clipping, no ellipsis, at any of the 8 test sizes.
- All five cards exactly the same height.
- Emoji and both labels optically centred as a group.
- Keep the near-square aspect at rest. If the larger type breaks it, grow the
  card rather than shrink the type.
- Emoji must render in colour on Android. Confirm on the device, not the
  desktop build — the font fallback chain differs between them.

## 6. Remove every debug surface

Remove:

- The long-press debug dump on the marquee — handler, dialog, queries.
- The raw-exception alert (`অপ্রত্যাশিত ত্রুটি (ডিবাগ)`). Replace with a
  plain message in the same visual style as the other alerts:
  ```
  দুঃখিত, একটি সমস্যা হয়েছে। আবার চেষ্টা করুন।
  ```
- Every `// TEMP (FIX-01 §2)` block in `api_service.dart`,
  `sync_service.dart`, and both dialogs.
- Dio's `LogInterceptor`.
- Any `print`/`debugPrint` on a normal user path.

Keep internal capture — `runZonedGuarded` plus `FlutterError.onError` writing
to a local rolling log file, capped at a few MB. Never surfaced, but there if
this needs diagnosing in six months.

### Resolve the contradiction before removing the instrument

The last on-device dump read `Sent (synced=1): 19` alongside
`Last successful sync: never`. Those cannot both be true.

Two possibilities with very different stakes:

- The timestamp simply isn't written on success. Cosmetic.
- Rows are being marked `synced = 1` without the server accepting them —
  meaning feedback is silently discarded. That is the worst failure this app
  can have.

Find out which. Check the server for those 19 rows if you can reach it. Do
not remove the instrument while it is still reporting a contradiction.

## 7. Stability audit

**Database**
- Every raw SQL call uses the right method — `execute` only for statements
  returning nothing, `rawQuery`/`query` for anything returning rows. The WAL
  bug was exactly this; confirm there are no siblings.
- DB open is one shared future. No race on first launch.
- Directory created before the first open attempt.
- Every write wrapped so a failure can't leave the UI stuck.
- **A broken database must not brick the kiosk.** If open fails, log it and
  let the app run. Lost feedback is bad; a screen showing an error all day is
  worse.

**Async**
- Every `setState` after an `await` guarded by `mounted`.
- Every button-gating flag reset in a `finally`.
- No `await` on a network call in any user-facing path.
- Every `Timer`, `AnimationController`, `StreamSubscription` disposed. Rotate
  20 times and confirm nothing leaks.

**Long-running** — this runs for weeks without a restart.
- Nothing grows without bound: log file, image cache, pending queue, the
  SQLite file itself.
- The 7-day prune actually runs and actually deletes.
- `wakelock_plus` survives the screen being manually cycled off and on.
- Leave it running 15+ minutes with the queue draining. Confirm no growth,
  no leaks, no stuck state.

**Network**
- Every endpoint has a timeout. A hung request must not block the queue.
- A malformed or HTML response — a captive portal login page, say — is
  treated as a failure, not parsed as success. Real hospital wifi does this.

## 8. Interaction hardening

Things an unattended kiosk gets that a phone app does not.

- **Double-tap on a rating** must not open two dialogs. Debounce, or gate on
  whether a dialog is already showing.
- **Rapid tapping across different ratings** must not queue up dialogs.
- **Tapping the barrier** does nothing. Already specified — confirm it holds.
- **The back button** does nothing at the root; inside the dialog it closes
  the dialog and nothing more.
- **A stuck dialog is unacceptable.** If anything throws, the dialog closes
  and the app returns to the rating screen. It must never sit there
  unresponsive, because nobody is around to restart it.
- **System text scale** clamped to 0.85–1.3 (SPEC-RESPONSIVE.md §7) —
  confirm it is actually applied at the root, not just written down.
- Long category names must wrap or shrink, never clip. Test with a
  40-character Bengali category.
- 10+ categories must scroll within the dialog, not overflow.

## 9. Idle reset — the kiosk problem nobody thinks about

Someone taps 🙁, the negative dialog opens, they get called in to see the
doctor, and they walk away. The dialog stays open. The next person walks up
to a half-filled form with a stranger's typed comment in it.

Add an idle timeout:

- If the dialog is open with no interaction for **60 seconds**, close it
  silently and discard everything. No submit, no message, no animation beyond
  the normal dismiss.
- Any touch, scroll, or keystroke resets the timer. Reset on every keystroke,
  not just on open, so someone composing a genuine complaint isn't cut off
  mid-sentence.
- On the rating screen no timeout is needed — that is already the home state.
- After the reset: comment empty, no categories selected, keyboard dismissed.

This is a privacy matter as much as a usability one. A hospital complaint
half-typed and abandoned should not be readable by the next person in line.

## 10. Release

After 1 through 9:

1. `flutter analyze` — zero issues.
2. Full test suite passes.
3. All 8 sizes from SPEC-RESPONSIVE.md §9, portrait and landscape, **with the
   keyboard open on the comment field at each one**. §3 is why this matters.
4. Build the signed release APK as `feedback.apk`.
5. Confirm the APK's mtime is newer than every source file. The stale-build
   mistake has happened twice.
6. Confirm the icon in the built APK via `aapt dump badging`.
7. Report path, size, and the change from the last build.

Then a final report: what changed per item, anything decided differently and
why, and — the part I care about most — **what you could not verify**.

I am installing this somewhere I cannot easily reach to update. The list of
things you couldn't check is worth more to me than reassurance about the
things you could.
