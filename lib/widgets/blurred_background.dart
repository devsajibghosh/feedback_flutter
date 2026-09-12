import 'package:flutter/material.dart';

import '../theme/app_theme.dart';
import '../theme/tokens.dart';

/// The slowly-drifting photo backdrop shared by every screen. The blur,
/// darkening, and desaturation (SPEC.md §3.1) are baked into
/// `assets/img/bd_blurred.png` at build time instead of applied at runtime
/// (FIX-02 §4) — a 14px `ImageFiltered` blur plus two `ColorFiltered`
/// matrices on a full-screen image that a 32s `ScaleTransition` keeps
/// re-scaling was re-running that whole filter chain on every frame,
/// forever, for no visual benefit over doing it once ahead of time. This
/// widget just draws the pre-baked PNG plainly and scales it 1.0 → 1.09 →
/// 1.0 on a 32s loop, plus a faint noise texture on top for depth and the
/// fixed "Developed by Code Station 23" credit in the corner.
///
/// Baked as PNG rather than the FIX-02 §4 spec's suggested JPEG: this
/// environment's `flutter_tester` (used by `flutter test`) hangs
/// indefinitely decoding any JPEG asset, reproduced even with a trivial 4×4
/// pixel file, while the exact same bytes decode fine through Pillow and
/// ffprobe — so the file itself is valid, but this build/test toolchain's
/// JPEG codepath is not trustworthy here. PNG is proven to work (it's what
/// the original background and the app icon both already use), so it's the
/// safer choice for an asset a hospital kiosk depends on, at the cost of
/// ~137KB more than an equivalent JPEG would have been.
///
/// [child] is painted above the background, matching the reference where
/// the login card / feedback content sits on top of this stage.
class BlurredBackground extends StatefulWidget {
  const BlurredBackground({super.key, this.child});

  final Widget? child;

  @override
  State<BlurredBackground> createState() => _BlurredBackgroundState();
}

class _BlurredBackgroundState extends State<BlurredBackground>
    with SingleTickerProviderStateMixin {
  late final AnimationController _controller;
  late final Animation<double> _scale;

  @override
  void initState() {
    super.initState();
    _controller = AnimationController(
      vsync: this,
      duration: const Duration(seconds: 32),
    )..repeat(reverse: true);
    _scale = Tween<double>(begin: 1.0, end: 1.09).animate(
      CurvedAnimation(parent: _controller, curve: Curves.easeInOut),
    );
  }

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return Stack(
      fit: StackFit.expand,
      children: [
        // Base scaffold colour behind everything, in case the image is
        // still loading or fails to decode.
        const ColoredBox(color: AppTokens.verdant),

        // Pre-blurred, pre-darkened, pre-desaturated photo (FIX-02 §4) —
        // drawn plainly, only ever scaled. The RepaintBoundary isolates the
        // 32s scale animation's own repaints from the rest of the tree
        // (the login card / feedback content painted on top of it).
        RepaintBoundary(
          child: ScaleTransition(
            scale: _scale,
            child: const Image(
              image: AssetImage('assets/img/bd_blurred.png'),
              fit: BoxFit.cover,
            ),
          ),
        ),

        // Faint tiling noise texture, purely decorative.
        const IgnorePointer(
          child: Opacity(
            opacity: 0.035,
            child: _TiledNoise(),
          ),
        ),

        if (widget.child != null) widget.child!,

        const _DevCredit(),
      ],
    );
  }
}

class _TiledNoise extends StatelessWidget {
  const _TiledNoise();

  @override
  Widget build(BuildContext context) {
    return const DecoratedBox(
      decoration: BoxDecoration(
        image: DecorationImage(
          image: AssetImage('assets/img/noise.png'),
          repeat: ImageRepeat.repeat,
        ),
      ),
    );
  }
}

class _DevCredit extends StatelessWidget {
  const _DevCredit();

  @override
  Widget build(BuildContext context) {
    return Positioned(
      left: 16,
      bottom: 12,
      child: IgnorePointer(
        child: Text.rich(
          TextSpan(
            style: const TextStyle(
              fontFamily: AppTheme.bodyFontFamily,
              fontFamilyFallback: AppTheme.bengaliFallback,
              fontSize: 11,
              letterSpacing: 0.04,
            ),
            children: [
              TextSpan(
                text: 'Developed by ',
                style: TextStyle(color: AppTokens.white.withOpacity(0.28)),
              ),
              TextSpan(
                text: 'Code Station 23',
                style: TextStyle(
                  color: AppTokens.white.withOpacity(0.48),
                  fontWeight: FontWeight.bold,
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}
