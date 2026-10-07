# FIX-06 — priority sync, true kiosk mode, responsive alerts, release

Six items. Nothing outside this file in this round.

Copy every Bengali string verbatim, using the same programmatic method as
FIX-03 §4 and FIX-04 §1. Do not retype.

Items 1 and 5 are the same subsystem — read both before touching
`sync_service.dart`.

---

## 1. Negative feedback drains in full; positive drains one at a time

**The change:** keep one 30-second tick for everything, but change how many
rows each kind sends per tick.

- **Negative** (`poor`, `very_poor`) → on each tick, upload **every** pending
  negative row, one after another, until none are left.
- **Positive** (`very_good`, `good`, `satisfactory`) → on each tick, upload
  **exactly one** row, however many are waiting.

Both kinds use the same 30-second tick. Nothing bypasses the tick, and there
is no second timer. The only difference is the batch size: all of them versus
one of them.

### Why the split

A complaint is time-sensitive. If someone reports a filthy toilet, the
hospital should have it within half a minute — not twenty minutes later when
a queue of happy ratings finally reaches it. Praise carries no urgency.

The volume argument holds too: on a working ward most feedback is positive,
so throttling that side still protects the backend, while the smaller
negative stream clears in full each tick.

### Implementation

- `_drain()` runs on the 30-second tick as it does now.
- Inside a tick, first select **all** pending rows where the rating is `poor`
  or `very_poor`, oldest first, and upload them in sequence. A short gap
  between them (300–500ms) so a large backlog doesn't arrive as one burst.
- Then, and only then, select **one** pending positive row, oldest first, and
  upload it.
- If any upload fails, stop the tick immediately — do not continue to the
  next row — and start the normal exponential backoff. This applies to both
  kinds. A down server must not turn a negative backlog into a hammer.
- On the next successful tick, resume from the oldest pending negative row.
- Backoff, 422 → `synced = -1`, and 7-day pruning are all unchanged.
- The 5-second first-attempt timer for a newly written row is unchanged, and
  applies to both kinds — it just means a fresh row gets its first shot
  sooner than waiting out the full tick.

### Still invisible

The user must not be able to tell the difference. No indicator, no different
message, no different timing on screen. Submit is still a local write that
returns instantly for every rating. This is entirely a backend-side ordering
change.

Write a test that seeds three positive rows and three negative rows, runs one
tick, and confirms all three negatives uploaded and exactly one positive did.

## 2. True kiosk mode — auto-pin on launch, auto-start on boot

**Current:** the app relies on someone manually enabling screen pinning.
That is not viable for a device nobody attends.

### Auto-pin on launch

The app enters Lock Task Mode by itself when it starts. No manual step, no
pin gesture, no way for a visitor to leave the app.

- Call `startLockTask()` in `onCreate` / on first frame.
- When the app is set as **device owner**, Lock Task Mode is silent and
  cannot be exited by the user at all. This is the intended deployment.
- When it is not device owner, `startLockTask()` falls back to ordinary
  screen pinning, which shows a confirmation and can be escaped by holding
  back + overview. Accept that fallback; don't crash.
- Wrap the whole thing in try/catch. On a device or emulator where it isn't
  available, the app must run normally rather than fail to start.
- Add `android:lockTaskMode="if_whitelisted"` to the activity, and call
  `setLockTaskPackages` for our own package in the device-owner path.

Also write the ADB commands needed to set device owner into a short
`KIOSK-SETUP.md` at the project root, so whoever installs this on the ward
can follow it. Include the factory-reset caveat — device owner can only be
set on a device with no accounts configured.

### Auto-start on boot

The device will lose power. When it comes back, the app must be on screen
without anyone touching it.

- A `BOOT_COMPLETED` broadcast receiver that launches the main activity.
- `<uses-permission android:name="android.permission.RECEIVE_BOOT_COMPLETED" />`
  and the receiver registered in the manifest with the right intent filter.
- Handle `QUICKBOOT_POWERON` as well — some Android builds send that instead.
- The launch must survive the boot-time race: if the activity can't start
  immediately, retry rather than give up silently.

Check what's already there. SPEC.md §4.9 asked for this originally, so parts
may exist. Report what you find before adding anything.

## 3. Enlarge `কেন সন্তুষ্ট হন নি?`

The secondary line in the negative dialog header is too small on device.

Sizes, replacing the current 15 / 14 / 13:

| | size |
|---|---|
| expanded | 22 |
| medium | 19 |
| compact | 17 |

Keep it as the secondary line — `inkMuted`, weight 400 — so the rating name
above it still reads as primary. Only the size changes.

Confirm the header still collapses correctly when the keyboard opens
(FIX-04 §1) at the new size.

## 4. Success and error cards scale with the device

**Current:** the success toast and the error alert are fixed-size. On a
tablet they look small and lost; on a phone they can crowd the edges.

Both cards must size from the responsive class like everything else.

### Card dimensions

| | max width | padding | radius |
|---|---|---|---|
| expanded | 520 | 32 | 24 |
| medium | 440 | 26 | 22 |
| compact | `screenWidth - 48` | 20 | 20 |

Never wider than `screenWidth - 48` at any breakpoint.

### Typography inside them

| | icon | title | body | countdown |
|---|---|---|---|---|
| expanded | 64 | 28 | 20 | 16 |
| medium | 54 | 24 | 17 | 14 |
| compact | 46 | 21 | 15 | 12 |

The countdown row is the `৪ সেকেন্ড পর হোম স্ক্রিনে ফিরে যাচ্ছি` line from
FIX-05 §3 — it stays the quietest line in the card.

Apply the same scale to the error alert
(`দুঃখিত, একটি সমস্যা হয়েছে। আবার চেষ্টা করুন।`) and to the empty-feedback
warning, so all three alerts feel like one family.

Everything else about the toast is unchanged: 4 seconds, non-blocking,
dismissable by tapping, removed on backgrounding.

Verify at all 8 sizes from SPEC-RESPONSIVE.md §9 that no alert overflows or
gets clipped.

## 5. Sync every 30 seconds

Change the regular tick from 45 seconds to **30 seconds**.

- Regular tick: 30s (was 45s). One tick governs everything.
- Per tick: all pending negative rows, then one positive row (item 1).
- Backoff on consecutive failure now starts from 30s: 30s → 60s → 2m → 4m →
  8m, capped at 15 minutes. Resets to 30s on the first success.
- The 5-second first-attempt timer for a new row is unchanged.
- The `connectivity_plus` immediate trigger is unchanged.

The old per-row 30-second throttle from FIX-03 §1 is replaced by this. There
is now one timer, not a timer plus a separate gap check — the tick interval
*is* the throttle. Remove `_lastUploadCompletion` and its check; the batching
rule in item 1 does that job now.

## 6. Release

1. `flutter analyze` — zero issues.
2. Full test suite passes, including the 8-size and keyboard-open suites.
3. Build the signed release APK as `feedback.apk` in the project root.
4. Prove it's current both ways:
   - `find lib pubspec.yaml android/app/src -type f -newer feedback.apk`
     returns nothing.
   - Search `libapp.so` for a literal introduced in this round. Remember the
     UTF-16LE encoding note from FIX-04 §4 — a plain UTF-8 grep finds nothing
     even when the string is present.
5. Confirm the manifest actually contains the boot receiver and the lock-task
   attribute, via `aapt dump xmltree` on the built APK — not by reading the
   source manifest.
6. Report path, size, and the change from the previous build.

Then a short report: what changed per item, anything decided differently, and
what you could not verify.

The device-owner and boot-receiver behaviour in item 2 cannot be verified
without hardware. Say so plainly rather than implying it works.
