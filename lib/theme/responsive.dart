import 'dart:ui' show lerpDouble;

import 'package:flutter/widgets.dart';

/// All screen-size-driven sizing lives here (SPEC-RESPONSIVE.md §2, §8).
/// No other widget should read raw `MediaQuery` numbers or branch on its
/// own breakpoint logic — call [Responsive.of] and read a getter instead.
///
/// `shortestSide` (not raw width) drives the compact/medium/expanded class,
/// so it stays stable across rotation; `height` is tracked separately only
/// to detect the "phone in landscape" short-height case.
class Responsive {
  const Responsive._(this.size, this.viewInsetsBottom);

  factory Responsive.of(BuildContext context) => Responsive._(
        MediaQuery.sizeOf(context),
        MediaQuery.viewInsetsOf(context).bottom,
      );

  final Size size;

  /// The on-screen keyboard's height, or 0 when it's closed. Tracked here
  /// (rather than read raw from `MediaQuery` at each call site) so the
  /// dialog's available height can react to it the same way every other
  /// size in this class reacts to screen size (FIX-03 §3).
  final double viewInsetsBottom;

  double get width => size.width;
  double get height => size.height;
  double get shortestSide => size.shortestSide;
  bool get isKeyboardOpen => viewInsetsBottom > 0;

  static const _compactMax = 600.0;
  static const _mediumMax = 840.0;

  bool get isCompact => shortestSide < _compactMax;
  bool get isMedium => shortestSide >= _compactMax && shortestSide < _mediumMax;
  bool get isExpanded => shortestSide >= _mediumMax;
  bool get isShortHeight => height < 500;
  bool get isPortrait => height >= width;
  bool get isLandscape => !isPortrait;

  /// Piecewise-linear across the whole size axis instead of snapping at the
  /// 600/840 breakpoints (§3.3 "Sizing, interpolated smoothly"): flat at
  /// [compact] below 600, a straight ramp from [compact] to [expandedAt840]
  /// between 600 and 840, then whatever [expanded] itself does above 840 —
  /// which is usually its own already-continuous `clamp(width * k, ...)`
  /// formula, so there's no seam at 840 either.
  double _scale({
    required double compactPortrait,
    double? compactLandscape,
    required double Function(double shortestSide) expanded,
  }) {
    final compact =
        isPortrait ? compactPortrait : (compactLandscape ?? compactPortrait);
    if (shortestSide <= _compactMax) return compact;
    final expandedAt840 = expanded(_mediumMax);
    if (shortestSide >= _mediumMax) return expanded(shortestSide);
    final t = (shortestSide - _compactMax) / (_mediumMax - _compactMax);
    return lerpDouble(compact, expandedAt840, t)!;
  }

  // ── Rating buttons (§4.1, typography FIX-03 §5) ─────────────────────
  /// Emoji leads at roughly 2.2x the Bengali label, three fixed steps (not
  /// the smooth interpolation most other sizes here use, since FIX-03 §5
  /// asks for exact values "at every breakpoint") — 68/56/46 across
  /// expanded/medium/compact.
  double get ratingEmojiSize => isExpanded ? 68.0 : (isMedium ? 56.0 : 46.0);

  /// 30/25/21 — the label the emoji's size now leads over.
  double get ratingLabelSize => isExpanded ? 30.0 : (isMedium ? 25.0 : 21.0);

  /// Tall enough to comfortably fit the emoji + label at the sizes above
  /// with no clipping, at every one of the 8 SPEC-RESPONSIVE.md test sizes
  /// including short-height/landscape — FIX-03 §5 explicitly prefers
  /// growing the card over shrinking the type ("if the larger type breaks
  /// [the near-square aspect], grow the card rather than shrink the type"),
  /// so unlike the old formula this is no longer clamped down for
  /// [isShortHeight]. All five cards share this one value, so they stay
  /// exactly the same height regardless of how much any one label's
  /// [FittedBox] has to shrink to fit its own card's width. FIX-05 §5
  /// dropped the English sub-label's own term entirely (rather than
  /// zeroing it out) now that there's no third line to make room for.
  double get ratingButtonHeight {
    final vertical = ratingButtonPadding.vertical;
    final content = ratingEmojiSize * 1.15 +
        13 + // gap below the emoji
        ratingLabelSize * 1.3;
    return vertical + content;
  }

  double get ratingGap => _scale(
        compactPortrait: 8,
        expanded: (s) => (s * 0.011).clamp(6.0, 16.0),
      );

  /// Uniform on all four sides (FIX-02 §5) — three fixed steps, not the
  /// smooth interpolation most other sizes here use, since that's what was
  /// asked for explicitly.
  EdgeInsets get ratingButtonPadding {
    final value = isExpanded ? 16.0 : (isMedium ? 12.0 : 10.0);
    return EdgeInsets.all(value);
  }

  /// Gently rounded corners (FIX-02 §5), same three-step pattern as
  /// [ratingButtonPadding].
  double get ratingButtonRadius => isExpanded ? 18.0 : (isMedium ? 16.0 : 14.0);

  /// Five across in a row, or a 3-then-2 wrap on a narrow portrait phone
  /// (§4.1).
  bool get ratingButtonsWrap => isCompact && isPortrait;

  // ── Logo (§4.2) ──────────────────────────────────────────────────────
  double get logoSize => _scale(
        compactPortrait: 84,
        compactLandscape: 60,
        expanded: (_) => 130,
      );

  // ── Heading / subtitle (§4.3) ────────────────────────────────────────
  double get headingSize => (shortestSide * 0.058).clamp(22.0, 50.0);
  double get subtitleSize => (shortestSide * 0.022).clamp(11.0, 14.0);

  double get _gapMultiplier => _scale(
        compactPortrait: 0.6,
        compactLandscape: 0.4,
        expanded: (_) => 1.0,
      );

  double gap(double base) => base * _gapMultiplier;

  // ── Marquee bar (§4.4) ───────────────────────────────────────────────
  double get marqueeHorizontalPadding => isCompact ? 12 : 20;
  double get marqueeFontSize => isCompact ? 11 : 13;

  // ── Login screen (§5) ────────────────────────────────────────────────
  double get loginCardMaxWidth => width < 460 ? width - 32 : 420;
  EdgeInsets get loginCardPadding => isCompact
      ? const EdgeInsets.symmetric(vertical: 32, horizontal: 24)
      : const EdgeInsets.symmetric(vertical: 52, horizontal: 48);
  double get loginIconSize => isCompact ? 48 : 60;
  double get loginTitleSize => isCompact ? 24 : 28;

  // ── Feedback dialog (§6) ─────────────────────────────────────────────
  double get dialogMaxWidth => width - 32 < 880 ? width - 32 : 880;
  double get dialogMaxHeightFraction => isShortHeight ? 0.95 : 0.9;

  /// The dialog's actual height budget (FIX-03 §3): `MediaQuery.size.height`
  /// alone never shrinks when the keyboard appears, so `viewInsetsBottom`
  /// must be subtracted first — recomputed on every build because
  /// [Responsive.of] depends on both `MediaQuery.sizeOf` and
  /// `MediaQuery.viewInsetsOf`, which change on keyboard show/hide and on
  /// rotation.
  double get dialogMaxHeight =>
      (height - viewInsetsBottom).clamp(0.0, height) * dialogMaxHeightFraction;

  double get dialogTitleSize => _scale(
        compactPortrait: 24,
        expanded: (_) => 30,
      );

  EdgeInsets get dialogHeadPadding {
    if (isExpanded) return const EdgeInsets.fromLTRB(28, 22, 28, 12);
    if (isCompact) {
      final top = isShortHeight ? 8.0 : 16.0;
      return EdgeInsets.fromLTRB(18, top, 18, 10);
    }
    // Medium: interpolate each side independently.
    final t = (shortestSide - 600) / (840 - 600);
    double l(double a, double b) => lerpDouble(a, b, t)!;
    return EdgeInsets.fromLTRB(l(18, 28), l(16, 22), l(18, 28), l(10, 12));
  }

  EdgeInsets get dialogBodyPadding {
    if (isExpanded) return const EdgeInsets.fromLTRB(28, 6, 28, 28);
    if (isCompact) return const EdgeInsets.fromLTRB(18, 6, 18, 20);
    final t = (shortestSide - 600) / (840 - 600);
    double l(double a, double b) => lerpDouble(a, b, t)!;
    return EdgeInsets.fromLTRB(l(18, 28), 6, l(18, 28), l(20, 28));
  }

  double get categoryLabelSize =>
      _scale(compactPortrait: 17, expanded: (_) => 23);
  double get categorySerialSize =>
      _scale(compactPortrait: 28, expanded: (_) => 36);
  EdgeInsets get categoryPillPadding {
    final left = _scale(compactPortrait: 10, expanded: (_) => 12);
    final right = _scale(compactPortrait: 18, expanded: (_) => 28);
    return EdgeInsets.fromLTRB(left, 10, right, 10);
  }

  /// FIX-04 §2: "if the notice strip now looks small beside [the enlarged
  /// comment label], bump it to match — the two should read as the same
  /// tier of text." Now the same size as [commentLabelSize] rather than
  /// its own smaller 14–16 scale.
  double get noticeStripFontSize => commentLabelSize;

  // ── Rating-grid helper text (FIX-03 §4) ─────────────────────────────
  double get helperTextSize => isExpanded ? 13.0 : (isMedium ? 12.0 : 11.0);

  // ── Negative dialog head (FIX-04 §1) — mirrors the tapped rating ─────
  double get negativeHeadEmojiSize =>
      isExpanded ? 56.0 : (isMedium ? 46.0 : 38.0);
  double get negativeHeadTitleSize =>
      isExpanded ? 30.0 : (isMedium ? 26.0 : 24.0);
  double get negativeHeadSubtitleSize =>
      isExpanded ? 15.0 : (isMedium ? 14.0 : 13.0);

  // ── Comment label (FIX-04 §2) — a prompt now, not a caption ──────────
  double get commentLabelSize => isExpanded ? 18.0 : (isMedium ? 16.0 : 15.0);
  double get commentLabelOptionalSize =>
      isExpanded ? 13.0 : (isMedium ? 12.0 : 11.0);
}
