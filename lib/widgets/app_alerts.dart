import 'package:flutter/material.dart';

import '../theme/app_theme.dart';
import '../theme/responsive.dart';
import '../theme/tokens.dart';

/// The shared card shape behind [showErrorAlert] and [showWarningAlert]
/// (FIX-06 §4): sized from [Responsive] exactly like the success toast, so
/// all three alerts read as one family instead of the success toast being
/// the only one that scales with the device.
class _AlertCard extends StatelessWidget {
  const _AlertCard({
    required this.icon,
    required this.iconColor,
    this.title,
    required this.message,
    required this.confirmLabel,
  });

  final IconData icon;
  final Color iconColor;
  final String? title;
  final String message;
  final String confirmLabel;

  @override
  Widget build(BuildContext context) {
    final responsive = Responsive.of(context);
    return Dialog(
      backgroundColor: Colors.transparent,
      insetPadding: const EdgeInsets.symmetric(horizontal: 24, vertical: 24),
      child: Material(
        color: AppTokens.ivory,
        borderRadius: BorderRadius.circular(responsive.alertRadius),
        child: Container(
          constraints: BoxConstraints(maxWidth: responsive.alertMaxWidth),
          padding: EdgeInsets.all(responsive.alertPadding),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              Icon(icon, color: iconColor, size: responsive.alertIconSize),
              const SizedBox(height: 14),
              if (title != null) ...[
                Text(
                  title!,
                  textAlign: TextAlign.center,
                  style: TextStyle(
                    fontFamily: AppTheme.headingFontFamily,
                    fontFamilyFallback: AppTheme.bengaliFallback,
                    fontWeight: FontWeight.w700,
                    fontSize: responsive.alertTitleSize,
                    color: AppTokens.ink,
                  ),
                ),
                const SizedBox(height: 8),
              ],
              Text(
                message,
                textAlign: TextAlign.center,
                style: TextStyle(
                  fontFamily: AppTheme.bodyFontFamily,
                  fontFamilyFallback: AppTheme.bengaliFallback,
                  fontSize: responsive.alertBodySize,
                  color: AppTokens.inkMid,
                ),
              ),
              const SizedBox(height: 20),
              TextButton(
                style: TextButton.styleFrom(
                  backgroundColor: AppTokens.verdant,
                  foregroundColor: AppTokens.white,
                  padding:
                      const EdgeInsets.symmetric(horizontal: 28, vertical: 12),
                  shape: RoundedRectangleBorder(
                    borderRadius: BorderRadius.circular(AppTokens.radiusSm),
                  ),
                ),
                onPressed: () => Navigator.of(context).pop(),
                child: Text(
                  confirmLabel,
                  style: const TextStyle(
                    fontFamily: AppTheme.bodyFontFamily,
                    fontFamilyFallback: AppTheme.bengaliFallback,
                    fontWeight: FontWeight.w700,
                    fontSize: 14,
                  ),
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

/// Recreates the SweetAlert2 dialogs from the Electron app (§3.5): same
/// icon, title, body, and button, styled with `ivory` / `ink`, now sized
/// from [Responsive] (FIX-06 §4) instead of a fixed radius/font set.
///
/// The Electron source calls `Swal.fire(title, message, 'error')` for submit
/// failures without a custom `confirmButtonText`, so SweetAlert2's own
/// default "OK" is what users actually see there — pass `confirmLabel: 'OK'`
/// to match that; login failure customises it to 'ঠিক আছে', which is the
/// default here.
Future<void> showErrorAlert(
  BuildContext context, {
  required String title,
  required String message,
  String confirmLabel = 'ঠিক আছে',
}) {
  return showDialog<void>(
    context: context,
    builder: (context) => _AlertCard(
      icon: Icons.error,
      iconColor: AppTokens.error,
      title: title,
      message: message,
      confirmLabel: confirmLabel,
    ),
  );
}

/// The fallback for anything `_submit()` catches that isn't a handled
/// [SubmitFailure] (FIX-03 §6): no raw exception text or "(ডিবাগ)" label
/// shown to the user any more — the real error still goes to the internal
/// rolling log (`CrashLog`, called by the caller before this), but what a
/// visitor on the kiosk actually sees is the same plain, calm copy every
/// other alert uses.
Future<void> showGenericErrorAlert(BuildContext context) {
  return showErrorAlert(
    context,
    title: 'দুঃখিত',
    message: 'দুঃখিত, একটি সমস্যা হয়েছে। আবার চেষ্টা করুন।',
    confirmLabel: 'ঠিক আছে',
  );
}

/// The warning shape (§3.5): used both for "empty negative feedback" (no
/// title) and the mic-permission-denied dialog (titled 'মাইক্রোফোন'). The
/// Electron source calls the mic one via `Swal.fire({icon, title, text})`
/// with no `confirmButtonText`, so — same as the error shorthand calls —
/// SweetAlert2's real default there is "OK", not a Bengali label. Sized
/// from [Responsive] via the same [_AlertCard] the error alert uses
/// (FIX-06 §4), so the empty-feedback warning matches that family too.
Future<void> showWarningAlert(
  BuildContext context, {
  required String message,
  String? title,
  String confirmLabel = 'ঠিক আছে',
}) {
  return showDialog<void>(
    context: context,
    builder: (context) => _AlertCard(
      icon: Icons.warning_amber,
      iconColor: AppTokens.amber,
      title: title,
      message: message,
      confirmLabel: confirmLabel,
    ),
  );
}

/// The "max recording time" shape (§3.5): a corner toast, not a modal —
/// top-end, info icon, auto-dismisses after 3000ms, no button.
void showInfoToast(BuildContext context, {required String message}) {
  final overlay = Overlay.of(context);
  late final OverlayEntry entry;
  entry = OverlayEntry(
    builder: (context) => Positioned(
      top: MediaQuery.paddingOf(context).top + 12,
      right: 12,
      child: Material(
        color: AppTokens.ivory,
        elevation: 8,
        shadowColor: Colors.black.withOpacity(0.3),
        borderRadius: BorderRadius.circular(AppTokens.radiusMd),
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
          child: Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              const Icon(Icons.info, color: AppTokens.verdantMid, size: 20),
              const SizedBox(width: 10),
              Text(
                message,
                style: const TextStyle(
                  fontFamily: AppTheme.bodyFontFamily,
                  fontFamilyFallback: AppTheme.bengaliFallback,
                  fontSize: 13,
                  fontWeight: FontWeight.w500,
                  color: AppTokens.ink,
                ),
              ),
            ],
          ),
        ),
      ),
    ),
  );

  overlay.insert(entry);
  Future.delayed(const Duration(milliseconds: 3000), entry.remove);
}

/// The submit-success shape (§3.5) now lives in `feedback_screen.dart` as a
/// non-blocking [Overlay] toast rather than a modal (FIX-03 §2) — it must
/// never block the next rating tap, which a `showDialog` barrier would.
