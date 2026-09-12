import 'package:flutter/material.dart';

import '../services/debug_log.dart';
import '../theme/app_theme.dart';
import '../theme/tokens.dart';

/// Recreates the SweetAlert2 dialogs from the Electron app (§3.5): same
/// icon, title, body, and button, styled with `ivory` / `ink` / radius 20.
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
    builder: (context) => AlertDialog(
      backgroundColor: AppTokens.ivory,
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(AppTokens.radiusLg),
      ),
      icon: const Icon(Icons.error, color: AppTokens.error, size: 46),
      title: Text(
        title,
        textAlign: TextAlign.center,
        style: const TextStyle(
          fontFamily: AppTheme.headingFontFamily,
          fontFamilyFallback: AppTheme.bengaliFallback,
          fontWeight: FontWeight.w700,
          fontSize: 20,
          color: AppTokens.ink,
        ),
      ),
      content: Text(
        message,
        textAlign: TextAlign.center,
        style: const TextStyle(
          fontFamily: AppTheme.bodyFontFamily,
          fontFamilyFallback: AppTheme.bengaliFallback,
          fontSize: 14,
          color: AppTokens.inkMid,
        ),
      ),
      actionsAlignment: MainAxisAlignment.center,
      actions: [
        TextButton(
          style: TextButton.styleFrom(
            backgroundColor: AppTokens.verdant,
            foregroundColor: AppTokens.white,
            padding: const EdgeInsets.symmetric(horizontal: 28, vertical: 12),
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
  );
}

/// TEMP (FIX-01 §3): the submit path used to let anything that wasn't a
/// `DioException` escape uncaught — no alert, no reset, the button just
/// died. This is the fallback for that: whatever it actually is, show its
/// real type and message instead of a generic string, and log it to
/// [DebugLog] so it also shows up in the long-press debug dump without
/// needing a cable. Ugly on purpose — this is a diagnostic tool, not the
/// final copy.
Future<void> showUnexpectedErrorAlert(
  BuildContext context, {
  required Object error,
  StackTrace? stackTrace,
  String source = 'submit',
}) {
  DebugLog.record(source, error, stackTrace);
  return showErrorAlert(
    context,
    title: 'অপ্রত্যাশিত ত্রুটি (ডিবাগ)',
    message: '${error.runtimeType}: $error',
    confirmLabel: 'OK',
  );
}

/// The warning shape (§3.5): used both for "empty negative feedback" (no
/// title) and the mic-permission-denied dialog (titled 'মাইক্রোফোন'). The
/// Electron source calls the mic one via `Swal.fire({icon, title, text})`
/// with no `confirmButtonText`, so — same as the error shorthand calls —
/// SweetAlert2's real default there is "OK", not a Bengali label.
Future<void> showWarningAlert(
  BuildContext context, {
  required String message,
  String? title,
  String confirmLabel = 'ঠিক আছে',
}) {
  return showDialog<void>(
    context: context,
    builder: (context) => AlertDialog(
      backgroundColor: AppTokens.ivory,
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(AppTokens.radiusLg),
      ),
      icon: const Icon(
        Icons.warning_amber,
        color: AppTokens.amber,
        size: 46,
      ),
      title: title == null
          ? null
          : Text(
              title,
              textAlign: TextAlign.center,
              style: const TextStyle(
                fontFamily: AppTheme.headingFontFamily,
                fontFamilyFallback: AppTheme.bengaliFallback,
                fontWeight: FontWeight.w700,
                fontSize: 20,
                color: AppTokens.ink,
              ),
            ),
      content: Text(
        message,
        textAlign: TextAlign.center,
        style: const TextStyle(
          fontFamily: AppTheme.bodyFontFamily,
          fontFamilyFallback: AppTheme.bengaliFallback,
          fontSize: 14,
          color: AppTokens.inkMid,
        ),
      ),
      actionsAlignment: MainAxisAlignment.center,
      actions: [
        TextButton(
          style: TextButton.styleFrom(
            backgroundColor: AppTokens.verdant,
            foregroundColor: AppTokens.white,
            padding: const EdgeInsets.symmetric(horizontal: 28, vertical: 12),
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
