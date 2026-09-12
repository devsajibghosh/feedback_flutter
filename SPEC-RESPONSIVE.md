# Responsive addendum to SPEC.md

This section overrides §3.3 "Responsive", the fixed sizes in §3.2 and §3.4,
and the orientation lock in §4.9. Where this file and SPEC.md disagree,
this file wins.

The app must look correct and be fully usable on every Android screen from a
small phone to a large tablet, in both portrait and landscape. Nothing may
overflow, clip, or become unreachable at any size.

---

## 1. Orientation

Remove the landscape lock. Allow all four orientations:

```dart
SystemChrome.setPreferredOrientations([
  DeviceOrientation.portraitUp,
  DeviceOrientation.portraitDown,
  DeviceOrientation.landscapeLeft,
  DeviceOrientation.landscapeRight,
]);
```

In `AndroidManifest.xml` use `android:screenOrientation="fullSensor"`,
not `sensorLandscape`.

The layout decides what to show based on the *available* width and height at
runtime, not on a device category. A phone in landscape and a small tablet in
portrait can have similar dimensions and should get similar treatment.

## 2. Breakpoints

Define these once in `lib/theme/breakpoints.dart` and use them everywhere.
Base every decision on `MediaQuery.sizeOf(context)`, measured in logical pixels.

```
compact   shortestSide <  600     phones
medium    shortestSide >= 600 and < 840    small tablets, large phones
expanded  shortestSide >= 840     tablets
```

Separately, track available height, because a phone in landscape is wide but
very short:

```
shortHeight   height < 500     phone in landscape
```

`shortestSide` is the smaller of width and height, so it stays stable when the
device rotates. That is what should drive type scale and card sizing. Height is
a separate axis and only controls vertical compression.

## 3. Global rule: everything scrolls

Wrap the body of both the login screen and the feedback screen in a
`SingleChildScrollView`. Wrap the dialog body too (SPEC.md §3.4 already says
the body scrolls — make sure that is real, not just stated).

Every scroll view gets:

```dart
SingleChildScrollView(
  physics: const ClampingScrollPhysics(),
  child: ConstrainedBox(
    constraints: BoxConstraints(minHeight: availableHeight),
    child: IntrinsicHeight(child: /* the column */),
  ),
)
```

so that content centres when there is room and scrolls when there isn't.

A `RenderFlex overflowed` warning anywhere, at any size, counts as a bug.

## 4. Feedback screen

### 4.1 Rating buttons — the important part

Five buttons. How they arrange depends on available width:

- **expanded** and **medium** → one row of 5, each `Expanded`.
- **compact, landscape** → one row of 5, each `Expanded`, compressed heights
  (see below). Five across still fits at 700+ logical px wide.
- **compact, portrait** → do NOT force five across; at 360px wide each button
  would be ~64px and the Bengali labels would be unreadable. Use a `Wrap` with
  two rows: 3 on top, 2 below, each button taking
  `(availableWidth - gaps) / 3`.

Sizing, interpolated smoothly rather than snapped at breakpoints:

| | compact portrait | compact landscape | medium | expanded |
|---|---|---|---|---|
| button height | 150 | 120 | 180 | 220 |
| emoji size | 44 | 38 | 58 | clamp(w*0.047, 46, 82) |
| label size | 17 | 15 | 21 | clamp(w*0.019, 22, 28) |
| gap | 8 | 8 | 12 | clamp(w*0.011, 6, 16) |
| padding | 12/8 | 10/8 | 16/12 | 18/14 |

When `shortHeight` is true, additionally cap the button height at
`availableHeight * 0.42` so the row can never push the rating buttons off screen.

Labels must never be clipped. Give each label
`maxLines: 2, textAlign: center, overflow: TextOverflow.visible` and let it use
`FittedBox(fit: BoxFit.scaleDown)` inside a fixed-height box, so a long Bengali
label shrinks rather than truncating.

### 4.2 Logo

| | size |
|---|---|
| compact portrait | 84 |
| compact landscape | 60 |
| medium | 108 |
| expanded | 130 |

When `shortHeight` and the content still doesn't fit, hide the logo entirely
rather than scrolling the rating buttons out of view. The ratings are the
point of the screen; the logo is decoration.

### 4.3 Heading and subtitle

Heading size: `clamp(shortestSide * 0.058, 22, 50)`.
Subtitle size: `clamp(shortestSide * 0.022, 11, 14)`.

On `shortHeight`, drop the subtitle entirely and reduce the gap above the
rating row from 52 to 20.

Vertical gaps scale too — multiply the SPEC.md values by:
- compact portrait → 0.6
- compact landscape → 0.4
- medium → 0.8
- expanded → 1.0

### 4.4 Marquee bar

Height and text size stay as specified, but on compact reduce horizontal
padding from 20 to 12 and font size from 13 to 11.

## 5. Login screen

Card max width stays 420. Below 460 available width, the card becomes
`availableWidth - 32` with 16px side margins.

Padding:
- compact → 32 vertical / 24 horizontal
- medium and up → 52 / 48

Icon square: 48 on compact, 60 otherwise.
Title: 24 on compact, 28 otherwise.

When the keyboard opens, the card must scroll so the focused field stays
visible. `resizeToAvoidBottomInset: true` plus the scroll view handles this,
but verify it by focusing the password field on a 360x640 screen.

## 6. Feedback dialog

Max width 880 stays. Actual width is `min(880, screenWidth - 32)`.

On compact:
- Title 24 instead of 30.
- Head padding 16/18/10, body padding 6/18/20.
- Category pill: label 17 instead of 23, serial circle 28 instead of 36,
  padding 10 top/bottom, 10 left, 18 right.
- Notice strip text 14 instead of 16.
- Action buttons stack into one column (already in SPEC.md — keep it).

On medium: interpolate between compact and expanded values.

Category pills use a `Wrap`, not a `Column`, so short labels sit side by side
on a wide screen and stack on a narrow one. Keep 10px spacing both ways.

The dialog's max height is `screenHeight * 0.9`, and on `shortHeight` it is
`screenHeight * 0.95` with the head padding halved.

## 7. Text scaling

Users can set a system font scale up to 2.0x. That will break fixed-height
buttons. Clamp it:

```dart
MediaQuery(
  data: MediaQuery.of(context).copyWith(
    textScaler: TextScaler.linear(
      MediaQuery.textScalerOf(context).scale(1.0).clamp(0.85, 1.3),
    ),
  ),
  child: child,
)
```

Apply this once at the root in `MaterialApp.builder`.

## 8. Implementation notes

Put the sizing logic in one place — `lib/theme/responsive.dart` — exposing
something like:

```dart
class Responsive {
  final Size size;
  final bool isCompact, isMedium, isExpanded, isShortHeight, isPortrait;
  double get ratingButtonHeight;
  double get ratingEmojiSize;
  double get ratingLabelSize;
  double get logoSize;
  double get headingSize;
  double gap(double base);   // applies the multiplier
  // ...
}
```

Read it with `Responsive.of(context)`. No widget should compute its own
breakpoint logic inline, and no widget should read raw MediaQuery numbers
except this class.

Do not use `LayoutBuilder` at the top level to switch between two entirely
separate widget trees. One tree, parameterised sizes. That keeps state alive
across rotation and keeps the code half the size.

## 9. Verification

Before calling this done, run the app at each of these logical sizes and
confirm no overflow, no clipping, all five ratings reachable, and the dialog
fully scrollable:

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

On the Linux desktop build you can resize the window to each of these and check
visually. Report which ones you actually tested and what you saw.

Then rotate the device (or resize the window) while a dialog is open with
categories selected and text typed in the comment box. Nothing may be lost.
