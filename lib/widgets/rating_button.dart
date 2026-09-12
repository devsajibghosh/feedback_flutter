import 'dart:ui';

import 'package:flutter/material.dart';

import '../theme/app_theme.dart';
import '../theme/responsive.dart';
import '../theme/tokens.dart';

/// One entry in the five-way rating row (§3.3).
class RatingSpec {
  const RatingSpec({
    required this.emoji,
    required this.label,
    required this.englishLabel,
    required this.value,
    required this.accent,
  });

  final String emoji;
  final String label;

  /// FIX-03 §5's "English sub" line, confirmed in FIX-04 §5 as: Excellent /
  /// Good / Satisfactory / Poor / Very poor.
  final String englishLabel;

  final String value;
  final Color accent;
}

const List<RatingSpec> kRatingSpecs = [
  RatingSpec(
    emoji: '😍',
    label: 'খুব ভালো',
    englishLabel: 'Excellent',
    value: 'very_good',
    accent: AppTokens.cVeryGood,
  ),
  RatingSpec(
    emoji: '☺️',
    label: 'ভালো',
    englishLabel: 'Good',
    value: 'good',
    accent: AppTokens.cGood,
  ),
  RatingSpec(
    emoji: '😐',
    label: 'সন্তোষজনক',
    englishLabel: 'Satisfactory',
    value: 'satisfactory',
    accent: AppTokens.cSatisfact,
  ),
  RatingSpec(
    emoji: '🙁',
    label: 'খারাপ',
    englishLabel: 'Poor',
    value: 'poor',
    accent: AppTokens.cPoor,
  ),
  RatingSpec(
    emoji: '😞',
    label: 'খুব খারাপ',
    englishLabel: 'Very poor',
    value: 'very_poor',
    accent: AppTokens.cVeryPoor,
  ),
];

/// A single rating card. There is no hover on a tablet, so the "hover" look
/// (lifted, accent border/glow/tint) is bound to press-down instead, with a
/// brief 80ms squash right at the moment of contact (§3.3). Sizing comes
/// entirely from [Responsive] (SPEC-RESPONSIVE.md §4.1).
class RatingButton extends StatefulWidget {
  const RatingButton({super.key, required this.spec, required this.onTap});

  final RatingSpec spec;
  final VoidCallback onTap;

  @override
  State<RatingButton> createState() => _RatingButtonState();
}

class _RatingButtonState extends State<RatingButton>
    with SingleTickerProviderStateMixin {
  // The 220ms press transition is split into an 80ms initial dip
  // (scale 0.99, translateY -2) followed by the rise into the full held
  // look (scale 1.04, translateY -10).
  static const double _dipWeight = 80 / 220 * 100;
  static const double _riseWeight = 100 - _dipWeight;

  late final AnimationController _controller;
  late final Animation<double> _scale;
  late final Animation<double> _translateY;

  @override
  void initState() {
    super.initState();
    _controller = AnimationController(
      vsync: this,
      duration: AppTokens.durMid,
    );
    _scale = TweenSequence<double>([
      TweenSequenceItem(
          tween: Tween(begin: 1.0, end: 0.99), weight: _dipWeight),
      TweenSequenceItem(
          tween: Tween(begin: 0.99, end: 1.04), weight: _riseWeight),
    ]).animate(_controller);
    _translateY = TweenSequence<double>([
      TweenSequenceItem(
          tween: Tween(begin: 0.0, end: -2.0), weight: _dipWeight),
      TweenSequenceItem(
          tween: Tween(begin: -2.0, end: -10.0), weight: _riseWeight),
    ]).animate(_controller);
  }

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  void _setPressed(bool pressed) {
    _controller.animateTo(
      pressed ? 1 : 0,
      duration: AppTokens.durMid,
      curve: AppTokens.curveSpring,
    );
  }

  @override
  Widget build(BuildContext context) {
    final responsive = Responsive.of(context);

    // Isolates this button's own press-animation repaints from the other
    // four (FIX-02 §4) — without this, every tick of one card's scale/
    // translate/border animation would repaint the whole rating row.
    return RepaintBoundary(
      child: GestureDetector(
        behavior: HitTestBehavior.opaque,
        onTapDown: (_) => _setPressed(true),
        onTapCancel: () => _setPressed(false),
        onTapUp: (_) {
          _setPressed(false);
          widget.onTap();
        },
        child: AnimatedBuilder(
          animation: _controller,
          builder: (context, child) {
            final t = _controller.value;
            // Visible resting border, accent colour on press (FIX-02 §5) —
            // not transparent-to-accent, so each card reads as a defined
            // object even before it's touched.
            final borderColor =
                Color.lerp(AppTokens.border, widget.spec.accent, t)!;
            final borderWidth = lerpDouble(1.5, 2.0, t)!;
            final radius = responsive.ratingButtonRadius;
            final emojiScale = lerpDouble(1.0, 1.18, t)!;

            return Transform.translate(
              offset: Offset(0, _translateY.value),
              child: Transform.scale(
                scale: _scale.value,
                child: Container(
                  height: responsive.ratingButtonHeight,
                  padding: responsive.ratingButtonPadding,
                  decoration: BoxDecoration(
                    color: AppTokens.ivory,
                    borderRadius: BorderRadius.circular(radius),
                    border: Border.all(color: borderColor, width: borderWidth),
                    boxShadow: [
                      ...AppTokens.shFloat,
                      BoxShadow(
                        color: widget.spec.accent.withOpacity(0.24 * t),
                        blurRadius: lerpDouble(0, 50, t)!,
                        offset: Offset(0, lerpDouble(0, 20, t)!),
                      ),
                    ],
                  ),
                  child: Stack(
                    children: [
                      Positioned.fill(
                        child: DecoratedBox(
                          decoration: BoxDecoration(
                            color: widget.spec.accent.withOpacity(0.07 * t),
                            borderRadius: BorderRadius.circular(radius),
                          ),
                        ),
                      ),
                      Center(
                        child: Column(
                          mainAxisSize: MainAxisSize.min,
                          children: [
                            Transform.scale(
                              scale: emojiScale,
                              child: Text(
                                widget.spec.emoji,
                                style: TextStyle(
                                  fontSize: responsive.ratingEmojiSize,
                                  fontFamilyFallback: const [
                                    'Noto Color Emoji'
                                  ],
                                  height: 1,
                                ),
                              ),
                            ),
                            const SizedBox(height: 13),
                            // Long Bengali labels shrink to fit instead of
                            // clipping (SPEC-RESPONSIVE.md §4.1).
                            Flexible(
                              child: SizedBox(
                                width: double.infinity,
                                child: FittedBox(
                                  fit: BoxFit.scaleDown,
                                  child: Text(
                                    widget.spec.label,
                                    textAlign: TextAlign.center,
                                    maxLines: 2,
                                    overflow: TextOverflow.visible,
                                    style: TextStyle(
                                      fontFamily: AppTheme.bodyFontFamily,
                                      fontFamilyFallback:
                                          AppTheme.bengaliFallback,
                                      fontSize: responsive.ratingLabelSize,
                                      fontWeight: FontWeight.w700,
                                      color: AppTokens.ink,
                                      letterSpacing:
                                          responsive.ratingLabelSize * 0.01,
                                    ),
                                  ),
                                ),
                              ),
                            ),
                            const SizedBox(height: 3),
                            // The English sub-label (FIX-03 §5): confirms
                            // what the emoji+Bengali already conveyed, so it
                            // shrinks rather than clips too, same as above.
                            Flexible(
                              child: SizedBox(
                                width: double.infinity,
                                child: FittedBox(
                                  fit: BoxFit.scaleDown,
                                  child: Text(
                                    widget.spec.englishLabel,
                                    textAlign: TextAlign.center,
                                    maxLines: 1,
                                    overflow: TextOverflow.visible,
                                    style: TextStyle(
                                      fontFamily: AppTheme.bodyFontFamily,
                                      fontSize: responsive.ratingEnglishSubSize,
                                      fontWeight: FontWeight.w500,
                                      color: AppTokens.inkMuted,
                                    ),
                                  ),
                                ),
                              ),
                            ),
                          ],
                        ),
                      ),
                    ],
                  ),
                ),
              ),
            );
          },
        ),
      ),
    );
  }
}
