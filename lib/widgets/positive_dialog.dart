import 'package:flutter/material.dart';

import '../services/api_service.dart';
import '../services/sync_service.dart';
import '../theme/app_theme.dart';
import '../theme/responsive.dart';
import '../theme/tokens.dart';
import 'app_alerts.dart';
import 'feedback_dialog.dart';

/// The positive variant (§3.4): shown for very_good, good, satisfactory.
/// On a successful submit it closes itself and hands the [SubmitResult]
/// back through [close] so the caller can show the success toast with a
/// context that's still mounted.
class PositiveDialogContent extends StatefulWidget {
  const PositiveDialogContent({
    super.key,
    required this.orgId,
    required this.rating,
    required this.close,
    this.sync,
  });

  final int orgId;
  final String rating;
  final DialogCloser close;
  final SyncService? sync;

  @override
  State<PositiveDialogContent> createState() => _PositiveDialogContentState();
}

class _PositiveDialogContentState extends State<PositiveDialogContent> {
  late final SyncService _sync = widget.sync ?? SyncService();
  bool _isSubmitting = false;

  Future<void> _submit() async {
    if (_isSubmitting) return;
    setState(() => _isSubmitting = true);

    // A broad catch here, not just `on DioException`: with submit now
    // local-first (FIX-02 §1), the only way this can fail is the local
    // insert itself (a full disk, a locked database) — anything thrown
    // must still reset isSubmitting and tell the user something happened,
    // instead of leaving the button stuck and the failure silent.
    SubmitResult? result;
    Object? error;
    StackTrace? stackTrace;
    try {
      result = await _sync.submit(orgId: widget.orgId, rating: widget.rating);
    } catch (e, st) {
      error = e;
      stackTrace = st;
    }

    if (!mounted) return;

    if (error != null) {
      setState(() => _isSubmitting = false);
      await showUnexpectedErrorAlert(
        context,
        error: error,
        stackTrace: stackTrace,
        source: 'PositiveDialog._submit',
      );
      return;
    }

    switch (result!) {
      case SubmitSuccess():
        await widget.close(result);
      case SubmitFailure(:final message):
        setState(() => _isSubmitting = false);
        await showErrorAlert(
          context,
          title: 'দুঃখিত',
          message: message,
          confirmLabel: 'OK',
        );
    }
  }

  @override
  Widget build(BuildContext context) {
    final titleSize = Responsive.of(context).dialogTitleSize;
    return Column(
      mainAxisSize: MainAxisSize.min,
      children: [
        DialogHead(
          children: [
            DialogBadge(
              icon: Icons.star,
              label: 'মূল্যবান মতামত',
              background: AppTokens.sageFill,
              foreground: AppTokens.verdant,
              borderColor: AppTokens.verdant.withOpacity(0.18),
            ),
            const SizedBox(height: 10),
            Text(
              'আপনার ইতিবাচক মতামতের\nজন্য ধন্যবাদ!',
              style: TextStyle(
                fontFamily: AppTheme.headingFontFamily,
                fontFamilyFallback: AppTheme.bengaliFallback,
                fontWeight: FontWeight.w700,
                fontSize: titleSize,
                color: AppTokens.ink,
                letterSpacing: -0.015 * titleSize,
                height: 1.2,
              ),
            ),
          ],
        ),
        DialogBody(
          children: [
            Container(
              width: double.infinity,
              padding: const EdgeInsets.symmetric(vertical: 28, horizontal: 20),
              decoration: BoxDecoration(
                color: AppTokens.sageFill,
                border: Border.all(color: AppTokens.verdant.withOpacity(0.15)),
                borderRadius: BorderRadius.circular(AppTokens.radiusMd),
              ),
              child: const Column(
                children: [
                  Text('🎉', style: TextStyle(fontSize: 48, height: 1)),
                  SizedBox(height: 12),
                  Text(
                    'ফিডব্যাক জমা দিতে নিচের বাটনে ক্লিক করুন,\n'
                    'বাতিল করতে বাতিল বাটনে ক্লিক করুন।',
                    textAlign: TextAlign.center,
                    style: TextStyle(
                      fontFamily: AppTheme.bodyFontFamily,
                      fontFamilyFallback: AppTheme.bengaliFallback,
                      fontSize: 15,
                      fontWeight: FontWeight.w600,
                      color: AppTokens.verdant,
                      height: 1.5,
                    ),
                  ),
                ],
              ),
            ),
            const SizedBox(height: 22),
            DialogActionsRow(
              submitLabel: 'জমা দিন',
              isSubmitting: _isSubmitting,
              onCancel: () => widget.close(),
              onSubmit: _submit,
            ),
          ],
        ),
      ],
    );
  }
}
