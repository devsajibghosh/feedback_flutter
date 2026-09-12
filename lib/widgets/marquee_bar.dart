import 'package:flutter/material.dart';

import '../theme/app_theme.dart';
import '../theme/responsive.dart';
import '../theme/tokens.dart';

/// The fixed top bar showing the org's ticker text (§3.3).
///
/// The background is now static (FIX-02 §4), so the `BackdropFilter` this
/// bar used to blur whatever scrolled behind it — re-composited every time
/// anything below it changed — bought nothing but cost: a plain semi-opaque
/// fill looks near-identical here and is far cheaper.
class MarqueeBar extends StatelessWidget {
  const MarqueeBar({super.key, required this.text});

  final String text;

  @override
  Widget build(BuildContext context) {
    final responsive = Responsive.of(context);
    final fontSize = responsive.marqueeFontSize;
    return Positioned(
      top: 0,
      left: 0,
      right: 0,
      child: Container(
        padding: EdgeInsets.symmetric(
          vertical: 9,
          horizontal: responsive.marqueeHorizontalPadding,
        ),
        decoration: BoxDecoration(
          color: const Color.fromRGBO(10, 28, 20, 0.84),
          border: Border(
            bottom: BorderSide(
              color: AppTokens.white.withOpacity(0.07),
            ),
          ),
        ),
        child: Text(
          text,
          textAlign: TextAlign.center,
          maxLines: 1,
          overflow: TextOverflow.ellipsis,
          style: TextStyle(
            fontFamily: AppTheme.bodyFontFamily,
            fontFamilyFallback: AppTheme.bengaliFallback,
            fontSize: fontSize,
            fontWeight: FontWeight.w500,
            color: const Color(0xFFC2E0D0).withOpacity(0.88),
            letterSpacing: fontSize * 0.05,
          ),
        ),
      ),
    );
  }
}
