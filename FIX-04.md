# FIX-04 — negative dialog polish, then ship

Two UI changes to the negative dialog, then the final production build.

This assumes FIX-03 is complete. If any FIX-03 item is still outstanding,
finish it first — in particular §3 (dialog scroll and keyboard insets),
because §1 below depends on that work being correct.

Copy every Bengali string in this file **verbatim**, including the final `।`
where present. Do not retype them — retyping breaks conjuncts and swaps the
danda for a full stop.

---

## 1. Negative dialog header — mirror the rating that was tapped

**Current:** the dialog opens with a small pill badge reading
`খারাপ — মন্তব্য জানান` and the title `কোথায় সমস্যা হয়েছে জানান`. Nothing
connects it back to the face the user just pressed, so it reads as a new
screen rather than a continuation.

**Change:** lead with the same emoji they tapped, large.

### Head layout, top to bottom, centred

1. **The emoji from the tapped rating** — 🙁 for `poor`, 😞 for `very_poor`.
   Whichever card was pressed, not a generic icon.
   Size 56 expanded / 46 medium / 38 compact.
   Same colour-emoji rendering as the rating cards.

2. 10px gap. **Title** — Cormorant Garamond 700, colour `ink`,
   30 expanded / 26 medium / 24 compact:
   ```
   কেন সন্তুষ্ট হন নি?
   ```

3. 6px gap. **Subtitle** — 15 expanded / 14 medium / 13 compact,
   colour `inkMuted`, weight 400:
   ```
   এক বা একাধিক কারণ বেছে নিতে পারেন
   ```

### What is removed

- The `খারাপ — মন্তব্য জানান` pill badge. The emoji does that job now.
- The old title `কোথায় সমস্যা হয়েছে জানান`.
- The `কারণ নির্বাচন করুন (একাধিক নির্বাচন করা যাবে)` section label above the
  category pills. The new subtitle already says this. Repeating it wastes
  vertical space that the keyboard case badly needs.

### What stays

The red gradient stripe at the top, and the notice strip
(`আপনার সেবা দিতে না পারার জন্য আমরা আন্তরিকভাবে দুঃখিত।`) — both unchanged.

### Interaction with the keyboard

This head is what collapses when the keyboard opens. When
`MediaQuery.viewInsets.bottom > 0`: hide the emoji, title, and subtitle,
leaving the notice strip and the categories. Restore on keyboard close.
Animate over 160ms so it doesn't jump.

That collapse is the whole reason the head is worth enlarging — it costs
nothing when the user needs the space, and it makes the dialog legible from
a few feet away when they don't.

## 2. Comment label — larger, and it absorbs the caption above it

**Observed:** the label above the comment box is too small to read at a
glance on a wall-mounted screen. On the device it reads as decoration
rather than an instruction.

Replace the current section label — pen icon plus
`অন্য কারণ থাকলে এখানে লিখুন` in 11px muted caption styling — with a single
readable line:

```
অন্য কারণ থাকলে এখানে লিখুন
```

- Size 18 expanded / 16 medium / 15 compact.
- Colour `ink`, weight 600. Not `inkMuted` — this is a prompt, not a hint.
- Keep `(ঐচ্ছিক)` after it, but at 13 / 12 / 11 in `inkMuted` weight 400, so
  the optional marker stays visually secondary.
- Drop the pen icon. At this size the text carries itself.
- 11px between the label and the field.

The placeholder inside the field is unchanged:
`আপনার মতামত বিস্তারিত লিখুন...`

If the notice strip now looks small beside this, bump it to match — the two
should read as the same tier of text.

## 3. Final bug sweep

Before building. Report what you find, not just what you fix.

**Rerun everything**
- `flutter analyze` — zero issues, no exceptions made.
- Full test suite — every test passes.
- All 8 sizes from SPEC-RESPONSIVE.md §9, portrait and landscape, **with the
  keyboard open on the comment field at each one**. Any `RenderFlex
  overflowed` is a failure.

**Walk the whole user path on a device, not in a test**
1. Cold start with no saved login → login screen appears, no white flash.
2. Log in → feedback screen, logo and marquee load.
3. Tap each of the five ratings in turn → correct dialog variant each time.
4. Positive submit → success message, 4 seconds, auto-closes.
5. Negative submit with only a category → works.
6. Negative submit with only a comment → works, and Submit was reachable
   with the keyboard up.
7. Negative submit with nothing → warning, nothing sent.
8. Open a dialog, wait 60 seconds untouched → closes silently, state cleared.
9. Double-tap a rating fast → one dialog, not two.
10. Rotate with a dialog open and text typed → nothing lost.
11. Airplane mode → submit still shows success instantly.
12. Restore network → queue drains at one row per 30 seconds.
13. Kill and relaunch → opens straight to ratings, pending rows still there.

**Confirm nothing debug-looking remains**
- No long-press dump anywhere.
- No raw exception text in any alert — only
  `দুঃখিত, একটি সমস্যা হয়েছে। আবার চেষ্টা করুন।`
- No `print`/`debugPrint` on a user path, no `LogInterceptor`, no `// TEMP`
  blocks left behind.
- Grep for `FIX-01`, `FIX-02`, `TEMP`, `debug` across `lib/` and show me
  what's left.

**Leave it running**
15 minutes minimum with the queue draining. Confirm no memory growth, no
leaked timers, no stuck state, no growing log file.

## 4. Build and ship

1. Build the signed release APK as `feedback.apk` in the project root.
2. Confirm the APK's mtime is **newer than every file under `lib/`**. Print
   both. The stale-build mistake has happened twice — do not let it happen a
   third time.
3. Confirm the icon inside the built APK via `aapt dump badging`.
4. Report path, size, and the change from the previous build.

Then the final report. Three parts:

- **What changed**, per item.
- **What you decided differently** from this spec, and why.
- **What you could not verify.** This is the part I actually need. Be
  specific — "couldn't test colour emoji rendering on Android because no
  device is attached" is useful; "mostly verified" is not.

This goes on a wall in a hospital where I can't easily reach it to update.
An honest list of gaps is worth more to me than a clean-sounding summary.
