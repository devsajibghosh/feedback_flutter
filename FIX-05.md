# FIX-05 — five UI changes, then rebuild

Five changes, all observed on the installed release build. Nothing else in
this round.

Copy every Bengali string in this file **verbatim**. Do not retype them —
retyping breaks conjuncts and swaps the danda for a full stop. Use the same
programmatic copy discipline established in FIX-03 §4 and FIX-04 §1.

Items 4 and 5 interact: removing the English sub-label frees the vertical
space the larger emoji and Bengali label need. Do 5 before 4.

---

## 1. Negative dialog header — show the rating name under the emoji

**Current:** the header shows the tapped emoji, then `কেন সন্তুষ্ট হন নি?`,
then a subtitle.

**Change:** put the rating's own Bengali name directly under the emoji, so
the user sees which face they pressed spelled out.

New header order, top to bottom, centred:

1. The tapped emoji — 🙁 for `poor`, 😞 for `very_poor`. Unchanged size.
2. 8px gap. **The rating name**, matching the card that was tapped:
   - `poor` → `খারাপ`
   - `very_poor` → `খুব খারাপ`

   Style it as the primary line: Cormorant Garamond 700, colour `ink`,
   same sizes the title currently uses (30 expanded / 26 medium / 24 compact).
3. 6px gap. `কেন সন্তুষ্ট হন নি?` stays, but demoted to a secondary line:
   15 expanded / 14 medium / 13 compact, colour `inkMuted`, weight 400.

The old subtitle `এক বা একাধিক কারণ বেছে নিতে পারেন` moves out of the header
— see item 2. It must not appear twice.

Everything else about the header is unchanged: the red gradient stripe above
it, and the collapse-when-keyboard-opens behaviour from FIX-04 §1.

## 2. Replace the apology strip

**Current:** the notice strip below the header reads
`আপনার সেবা দিতে না পারার জন্য আমরা আন্তরিকভাবে দুঃখিত।`

**Change:** replace that text with:

```
এক বা একাধিক কারণ বেছে নিতে পারেন
```

The apology line is removed entirely and does not reappear anywhere.

Keep the strip's existing visual treatment exactly as it is — `errorLit`
fill, 3px left border in `error`, the same radius, padding, and font size.
Only the words change.

Since this string used to live in the header (item 1), confirm after the
change that it appears exactly **once** in the rendered dialog. A test that
counts occurrences is worth writing here.

## 3. Success message — visible countdown in Bengali

**Current:** the toast shows for 4 seconds and vanishes with no warning.

**Change:** add a live countdown line so the user knows what is happening
and how long is left.

Add below the existing `আপনার মূল্যবান মতামতের জন্য ধন্যবাদ! 👏` line:

```
৪ সেকেন্ড পর হোম স্ক্রিনে ফিরে যাচ্ছি
```

The leading numeral counts down each second: `৪` → `৩` → `২` → `১`, then the
toast dismisses.

- **Bengali numerals** (`৪ ৩ ২ ১`), not Latin digits. This is the whole point
  — a Latin `4` beside Bengali text looks wrong.
- Updates once per second on a `Timer.periodic`, cancelled in `dispose()`.
- Style: smaller and quieter than the thank-you line — 13 expanded /
  12 medium / 11 compact, `inkMuted`, weight 400.
- Everything else about the toast is unchanged: still 4000ms total, still
  non-blocking, still dismissable early by tapping it, still removed on
  backgrounding without resuming a stale timer (FIX-03 §2).
- If the user taps a rating while the countdown is running, the toast
  disappears immediately as before — the countdown does not delay that.

## 4. Bigger emoji and bigger Bengali label on the cards

Increase both, taking the space item 5 frees up.

| | emoji | Bengali label |
|---|---|---|
| expanded | 84 | 36 |
| medium | 70 | 30 |
| compact | 58 | 25 |

The ratio stays around 2.3x, so the emoji still leads.

- Cards grow to fit. No clipping, no ellipsis, at any of the 8 test sizes
  from SPEC-RESPONSIVE.md §9.
- All five cards stay exactly the same height.
- Emoji and label optically centred as a group.
- The `ratingButtonHeight` formula added in FIX-03 §5 computes height from
  the actual type sizes, so it should follow automatically — but confirm it
  does rather than assuming, and re-run the 8-size overflow suite.
- Keep the near-square aspect at rest. If the larger type breaks it, grow
  the card rather than shrink the type.

## 5. Remove the English sub-labels

Delete `Excellent`, `Good`, `Satisfactory`, `Poor`, `Very poor` from the
rating cards entirely. Bengali only.

Remove:
- `RatingSpec.englishLabel` and every value assigned to it.
- The third `Text` line in `RatingButton`'s content column, and its
  `FittedBox`.
- `Responsive.ratingEnglishSubSize`.
- Any test asserting the English labels exist — replace with a test
  asserting they do **not** appear anywhere on the rating screen.

Do this before item 4, so the height recalculation happens once with the
final content rather than twice.

---

## Rebuild

After all five:

1. `flutter analyze` — zero issues.
2. Full test suite passes, including the 8-size and keyboard-open suites.
3. Build the signed release APK as `feedback.apk` in the project root.
4. Prove it's current the same two ways as last time:
   - `find lib pubspec.yaml android/app/src -type f -newer feedback.apk`
     returns nothing.
   - Search `libapp.so` for `৪ সেকেন্ড পর হোম স্ক্রিনে ফিরে যাচ্ছি` — a
     literal that exists only in this round's code. Remember the UTF-16LE
     encoding note from FIX-04 §4: a plain UTF-8 grep will find nothing even
     when the string is present.
5. Report path, size, and the change from the previous build.

Then a short report: what changed per item, anything decided differently,
and what you could not verify.
