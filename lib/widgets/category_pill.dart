import 'package:flutter/material.dart';

import '../models/category.dart';
import '../theme/app_theme.dart';
import '../theme/responsive.dart';
import '../theme/tokens.dart';

/// One selectable reason pill in the negative dialog's category list
/// (§3.4). Sized to its own content, not full width; tapping anywhere on it
/// toggles selection.
class CategoryPill extends StatelessWidget {
  const CategoryPill({
    super.key,
    required this.category,
    required this.serial,
    required this.selected,
    required this.onTap,
  });

  final Category category;
  final int serial;
  final bool selected;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final responsive = Responsive.of(context);
    final serialSize = responsive.categorySerialSize;
    final labelSize = responsive.categoryLabelSize;

    return GestureDetector(
      onTap: onTap,
      child: AnimatedContainer(
        duration: AppTokens.durFast,
        curve: AppTokens.curveStandard,
        transform: Matrix4.translationValues(0, selected ? -1 : 0, 0),
        padding: responsive.categoryPillPadding,
        decoration: BoxDecoration(
          color: selected ? AppTokens.verdant : AppTokens.white,
          border: Border.all(
            color: selected ? AppTokens.verdant : AppTokens.border,
            width: 2,
          ),
          borderRadius: BorderRadius.circular(100),
          boxShadow: selected
              ? [
                  BoxShadow(
                    color: AppTokens.verdant.withOpacity(0.3),
                    blurRadius: 20,
                    offset: const Offset(0, 5),
                  ),
                ]
              : null,
        ),
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            AnimatedContainer(
              duration: AppTokens.durFast,
              curve: AppTokens.curveStandard,
              width: serialSize,
              height: serialSize,
              alignment: Alignment.center,
              decoration: BoxDecoration(
                shape: BoxShape.circle,
                color: selected
                    ? AppTokens.white.withOpacity(0.22)
                    : AppTokens.parchment,
                border: Border.all(
                  color: selected
                      ? AppTokens.white.withOpacity(0.45)
                      : AppTokens.borderMid,
                  width: 2,
                ),
              ),
              child: Text(
                '$serial',
                style: TextStyle(
                  fontFamily: AppTheme.bodyFontFamily,
                  fontSize: serialSize * 0.389, // 14/36 of the original size
                  fontWeight: FontWeight.w700,
                  fontFeatures: const [FontFeature.tabularFigures()],
                  color: selected ? AppTokens.white : AppTokens.inkMid,
                ),
              ),
            ),
            const SizedBox(width: 14),
            // Wraps instead of clipping (FIX-03 §8): a hospital-corridor
            // complaint category can run long, and truncating it with "..."
            // would hide exactly the word that mattered.
            Flexible(
              child: Text(
                category.name,
                softWrap: true,
                style: TextStyle(
                  fontFamily: AppTheme.bodyFontFamily,
                  fontFamilyFallback: AppTheme.bengaliFallback,
                  fontSize: labelSize,
                  fontWeight: FontWeight.w600,
                  color: selected ? AppTokens.white : AppTokens.ink,
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }
}
