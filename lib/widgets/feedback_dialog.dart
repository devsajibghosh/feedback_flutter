import 'dart:async';

import 'package:flutter/material.dart';

import '../theme/app_theme.dart';
import '../theme/responsive.dart';
import '../theme/tokens.dart';

/// Pops the dialog's route. Pass a result to hand back to whoever awaited
/// [showFeedbackDialog] (e.g. a [SubmitResult] on a successful submit).
typedef DialogCloser = Future<void> Function([Object? result]);

typedef DialogContentBuilder = Widget Function(
  BuildContext context,
  DialogCloser close,
);

/// The idle timeout for an open dialog (FIX-03 §9): a hospital complaint
/// half-typed and abandoned should not be readable by the next person in
/// line, so a dialog nobody has touched for this long closes itself and
/// discards everything.
const _idleTimeout = Duration(seconds: 60);

/// Global escape hatch for FIX-03 §8's "a stuck dialog is unacceptable": if
/// anything throws anywhere while a feedback dialog is open, the app-level
/// error handlers in `main.dart` call [FeedbackDialogGuard.closeActiveDialog]
/// so the kiosk falls back to the rating screen instead of sitting on a
/// broken, unresponsive dialog with nobody around to restart it. At most one
/// dialog is ever open at a time (the barrier isn't dismissible and rating
/// taps are debounced), so a single slot is enough.
class FeedbackDialogGuard {
  FeedbackDialogGuard._();

  static VoidCallback? _closeActive;

  static void closeActiveDialog() {
    final closer = _closeActive;
    if (closer == null) return;
    try {
      closer();
    } catch (_) {
      // The graceful close itself is broken — nothing more we can safely
      // try from a global error handler. Leaving the kiosk showing a
      // dialog is still bad, but re-throwing from an error handler would
      // be worse.
    }
  }
}

/// Broadcasts "something happened inside this dialog" down to content that
/// isn't a descendant of the pointer-catching [Listener] alone — specifically
/// keystrokes in the comment field, which don't generate a new pointer-down
/// event per character (FIX-03 §9: "reset on every keystroke, not just on
/// open").
class DialogIdleScope extends InheritedWidget {
  const DialogIdleScope({
    super.key,
    required this.onInteraction,
    required super.child,
  });

  final VoidCallback onInteraction;

  static DialogIdleScope? maybeOf(BuildContext context) =>
      context.dependOnInheritedWidgetOfExactType<DialogIdleScope>();

  @override
  bool updateShouldNotify(DialogIdleScope oldWidget) => false;
}

/// Opens the shared feedback modal shell (§3.4): centred, `ivory`, radius
/// 28, barrier at black 55% with dismiss disabled — only [DialogCloser] or
/// a successful submit may close it.
Future<T?> showFeedbackDialog<T extends Object?>(
  BuildContext context, {
  required bool isPositive,
  required DialogContentBuilder builder,
}) {
  return Navigator.of(context).push<T>(
    PageRouteBuilder<T>(
      opaque: false,
      barrierDismissible: false,
      barrierColor: Colors.black.withOpacity(0.55),
      transitionDuration: Duration.zero,
      reverseTransitionDuration: Duration.zero,
      pageBuilder: (context, animation, secondaryAnimation) {
        return _FeedbackDialogShell(isPositive: isPositive, builder: builder);
      },
    ),
  );
}

class _FeedbackDialogShell extends StatefulWidget {
  const _FeedbackDialogShell({required this.isPositive, required this.builder});

  final bool isPositive;
  final DialogContentBuilder builder;

  @override
  State<_FeedbackDialogShell> createState() => _FeedbackDialogShellState();
}

class _FeedbackDialogShellState extends State<_FeedbackDialogShell>
    with SingleTickerProviderStateMixin {
  late final AnimationController _controller;
  Timer? _idleTimer;

  // A stable per-instance reference, so dispose() only clears the guard
  // slot if it's still pointing at *this* dialog (defensive; in practice
  // only one dialog is ever open at a time, since the barrier isn't
  // dismissible and rating taps are debounced). `_close` accepts an
  // optional arg, so the bare tear-off already satisfies VoidCallback.
  late final VoidCallback _closeRef = _close;

  @override
  void initState() {
    super.initState();
    _controller = AnimationController(
      vsync: this,
      duration: const Duration(milliseconds: 320),
    )..forward();
    FeedbackDialogGuard._closeActive = _closeRef;
    _resetIdleTimer();
  }

  @override
  void dispose() {
    _idleTimer?.cancel();
    if (identical(FeedbackDialogGuard._closeActive, _closeRef)) {
      FeedbackDialogGuard._closeActive = null;
    }
    _controller.dispose();
    super.dispose();
  }

  void _resetIdleTimer() {
    _idleTimer?.cancel();
    _idleTimer = Timer(_idleTimeout, _handleIdleTimeout);
  }

  void _handleIdleTimeout() {
    if (!mounted) return;
    // Silent discard (FIX-03 §9): no submit, no message, no animation
    // beyond the dialog's own normal dismiss.
    _close();
  }

  Future<void> _close([Object? result]) async {
    _idleTimer?.cancel();
    FocusManager.instance.primaryFocus?.unfocus();
    try {
      _controller.duration = const Duration(milliseconds: 280);
      await _controller.reverse();
    } catch (_) {
      // Best-effort animation only — a broken controller must not prevent
      // the dialog from actually closing (FIX-03 §8).
    }
    if (mounted) Navigator.of(context).pop(result);
  }

  @override
  Widget build(BuildContext context) {
    final bottomInset = MediaQuery.viewInsetsOf(context).bottom;
    return PopScope(
      canPop: false,
      onPopInvokedWithResult: (didPop, result) {
        // The root screen ignores the back button entirely (main.dart); a
        // dialog on top closes on it and does nothing more (FIX-03 §8).
        if (!didPop) _close();
      },
      child: Listener(
        // Catches every tap/drag anywhere in the dialog, including on
        // category pills and buttons nested inside their own gesture
        // detectors — pointer-down events reach every Listener in the hit
        // path regardless of which descendant's tap recognizer eventually
        // wins the gesture arena.
        behavior: HitTestBehavior.opaque,
        onPointerDown: (_) => _resetIdleTimer(),
        child: DialogIdleScope(
          onInteraction: _resetIdleTimer,
          child: GestureDetector(
            // Tapping empty dialog space dismisses the keyboard without
            // closing the dialog (FIX-03 §3). A tap that lands on the
            // comment field re-focuses it as part of the same gesture pass,
            // so this doesn't fight with focusing the field.
            behavior: HitTestBehavior.opaque,
            onTap: () {
              final focus = FocusScope.of(context);
              if (!focus.hasPrimaryFocus && focus.focusedChild != null) {
                focus.unfocus();
              }
            },
            child: Padding(
              // Mirrors what a Scaffold with resizeToAvoidBottomInset does
              // for its own body: shrinks the space Center has to work
              // with, so the dialog centres in the area still visible above
              // the keyboard instead of behind it.
              padding: EdgeInsets.only(bottom: bottomInset),
              child: Center(
                child: AnimatedBuilder(
                  animation: _controller,
                  builder: (context, child) {
                    final reversing =
                        _controller.status == AnimationStatus.reverse;
                    final curve = reversing
                        ? AppTokens.curveStandard
                        : AppTokens.curveDialogEnter;
                    final hiddenOffset = reversing ? 24.0 : 32.0;
                    final shown = curve.transform(_controller.value);

                    // FadeTransition rather than Opacity (FIX-02 §4): its
                    // RenderAnimatedOpacity skips compositing entirely once
                    // the value settles at 0 or 1, which is most of this
                    // animation's very short life.
                    return FadeTransition(
                      opacity: AlwaysStoppedAnimation(shown.clamp(0.0, 1.0)),
                      child: Transform.translate(
                        offset: Offset(0, (1 - shown) * hiddenOffset),
                        child: Transform.scale(
                          scale: 0.97 + 0.03 * shown,
                          child: child,
                        ),
                      ),
                    );
                  },
                  child: Material(
                    type: MaterialType.transparency,
                    child: _DialogCard(
                      isPositive: widget.isPositive,
                      child: Builder(
                        builder: (context) => widget.builder(context, _close),
                      ),
                    ),
                  ),
                ),
              ),
            ),
          ),
        ),
      ),
    );
  }
}

class _DialogCard extends StatefulWidget {
  const _DialogCard({required this.isPositive, required this.child});

  final bool isPositive;
  final Widget child;

  @override
  State<_DialogCard> createState() => _DialogCardState();
}

class _DialogCardState extends State<_DialogCard> {
  final _scrollController = ScrollController();
  bool _showBottomFade = false;

  @override
  void initState() {
    super.initState();
    _scrollController.addListener(_updateFade);
    WidgetsBinding.instance.addPostFrameCallback((_) => _updateFade());
  }

  @override
  void dispose() {
    _scrollController.removeListener(_updateFade);
    _scrollController.dispose();
    super.dispose();
  }

  /// Reactive to scroll position (FIX-03 §3): shown whenever content
  /// continues below the fold, gone once scrolled to the bottom. Also
  /// re-checked on every metrics change (keyboard open/close, rotation,
  /// categories loading in) via the [NotificationListener] below, since
  /// those can change whether there's anything left to scroll to without
  /// the user having scrolled at all.
  void _updateFade() {
    // Defensive against a post-frame callback firing after this card has
    // already been disposed (FIX-03 §7) — `hasClients` alone already
    // covers the common case (a disposed ScrollController has none), but
    // an explicit check costs nothing and removes any doubt.
    if (!mounted || !_scrollController.hasClients) return;
    final position = _scrollController.position;
    final canScrollMore =
        position.maxScrollExtent > 0 && position.pixels < position.maxScrollExtent - 1;
    if (canScrollMore != _showBottomFade) {
      setState(() => _showBottomFade = canScrollMore);
    }
  }

  @override
  Widget build(BuildContext context) {
    final responsive = Responsive.of(context);
    return ConstrainedBox(
      constraints: BoxConstraints(
        maxWidth: 880,
        maxHeight: responsive.dialogMaxHeight,
      ),
      child: Container(
        width: responsive.dialogMaxWidth,
        decoration: BoxDecoration(
          color: AppTokens.ivory,
          border: Border.all(color: AppTokens.border),
          borderRadius: BorderRadius.circular(AppTokens.radiusXl),
          boxShadow: AppTokens.shModal,
        ),
        clipBehavior: Clip.antiAlias,
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Container(
              height: 4,
              decoration: BoxDecoration(
                gradient: LinearGradient(
                  colors: widget.isPositive
                      ? [AppTokens.verdant, AppTokens.verdantLit]
                      : [AppTokens.error, AppTokens.errorMid],
                ),
              ),
            ),
            Flexible(
              child: Stack(
                children: [
                  NotificationListener<ScrollMetricsNotification>(
                    onNotification: (_) {
                      WidgetsBinding.instance
                          .addPostFrameCallback((_) => _updateFade());
                      return false;
                    },
                    child: SingleChildScrollView(
                      controller: _scrollController,
                      physics: const ClampingScrollPhysics(),
                      child: widget.child,
                    ),
                  ),
                  // Soft fade so a user who can't see the submit button
                  // still knows there's more below (FIX-03 §3) — this costs
                  // almost nothing and is the difference between a usable
                  // dialog and an abandoned one.
                  if (_showBottomFade)
                    Positioned(
                      left: 0,
                      right: 0,
                      bottom: 0,
                      child: IgnorePointer(
                        child: Container(
                          height: 24,
                          decoration: BoxDecoration(
                            gradient: LinearGradient(
                              begin: Alignment.bottomCenter,
                              end: Alignment.topCenter,
                              colors: [
                                AppTokens.ivory,
                                AppTokens.ivory.withOpacity(0),
                              ],
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
    );
  }
}

/// The `m-head` padding block (§3.4): 22 top, 28 sides, 12 bottom.
class DialogHead extends StatelessWidget {
  const DialogHead({super.key, required this.children});

  final List<Widget> children;

  @override
  Widget build(BuildContext context) {
    final responsive = Responsive.of(context);
    // The worst case (FIX-03 §3): phone in landscape with the keyboard
    // open, roughly 150 logical px available. The badge and title aren't
    // needed while typing, so they collapse away entirely to leave room for
    // the comment field and Submit — and reappear the instant the keyboard
    // closes, since this is just a normal MediaQuery-driven rebuild.
    if (responsive.isKeyboardOpen && responsive.isShortHeight) {
      return const SizedBox.shrink();
    }
    var padding = responsive.dialogHeadPadding;
    if (responsive.isShortHeight) {
      padding = EdgeInsets.fromLTRB(
        padding.left,
        padding.top / 2,
        padding.right,
        padding.bottom / 2,
      );
    }
    return Padding(
      padding: padding,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        mainAxisSize: MainAxisSize.min,
        children: children,
      ),
    );
  }
}

/// The `m-body` padding block (§3.4): 6 top, 28 sides, 28 bottom.
class DialogBody extends StatelessWidget {
  const DialogBody({super.key, required this.children});

  final List<Widget> children;

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: Responsive.of(context).dialogBodyPadding,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        mainAxisSize: MainAxisSize.min,
        children: children,
      ),
    );
  }
}

/// The small uppercase pill badge at the top of a dialog head (§3.4).
class DialogBadge extends StatelessWidget {
  const DialogBadge({
    super.key,
    required this.icon,
    required this.label,
    required this.background,
    required this.foreground,
    required this.borderColor,
  });

  final IconData icon;
  final String label;
  final Color background;
  final Color foreground;
  final Color borderColor;

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 11, vertical: 5),
      decoration: BoxDecoration(
        color: background,
        borderRadius: BorderRadius.circular(100),
        border: Border.all(color: borderColor),
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Icon(icon, size: 11, color: foreground),
          const SizedBox(width: 6),
          Flexible(
            child: Text(
              label,
              overflow: TextOverflow.ellipsis,
              style: TextStyle(
                fontFamily: AppTheme.bodyFontFamily,
                fontFamilyFallback: AppTheme.bengaliFallback,
                fontSize: 11,
                fontWeight: FontWeight.w700,
                letterSpacing: 0.99, // 0.09em * 11px
                color: foreground,
              ),
            ),
          ),
        ],
      ),
    );
  }
}

/// An uppercase section label with a leading icon, used before the category
/// list, the comment field, and (stage 6) the voice recorder (§3.4).
class DialogSectionLabel extends StatelessWidget {
  const DialogSectionLabel({
    super.key,
    required this.icon,
    required this.label,
    this.iconColor,
    this.lightSuffix,
  });

  final IconData icon;
  final String label;
  final Color? iconColor;
  final String? lightSuffix;

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.only(bottom: 11),
      child: Wrap(
        crossAxisAlignment: WrapCrossAlignment.center,
        spacing: 6,
        children: [
          Icon(icon, size: 12, color: iconColor ?? AppTokens.inkMuted),
          Text(
            label,
            style: const TextStyle(
              fontFamily: AppTheme.bodyFontFamily,
              fontFamilyFallback: AppTheme.bengaliFallback,
              fontSize: 11,
              fontWeight: FontWeight.w700,
              color: AppTokens.inkMuted,
              letterSpacing: 1.32, // 0.12em * 11px
            ),
          ),
          if (lightSuffix != null)
            Text(
              lightSuffix!,
              style: const TextStyle(
                fontFamily: AppTheme.bodyFontFamily,
                fontFamilyFallback: AppTheme.bengaliFallback,
                fontSize: 11,
                fontWeight: FontWeight.w400,
                color: AppTokens.inkMuted,
              ),
            ),
        ],
      ),
    );
  }
}

/// A 1px `parchment` rule with 18px vertical margin, used between dialog
/// body sections (§3.4).
class DialogDivider extends StatelessWidget {
  const DialogDivider({super.key});

  @override
  Widget build(BuildContext context) {
    return Container(
      height: 1,
      margin: const EdgeInsets.symmetric(vertical: 18),
      color: AppTokens.parchment,
    );
  }
}

/// The Cancel/Submit action pair shared by both dialog variants (§3.4 §8):
/// side-by-side on tablet width, stacked under 600px.
class DialogActionsRow extends StatelessWidget {
  const DialogActionsRow({
    super.key,
    required this.submitLabel,
    required this.onCancel,
    required this.onSubmit,
    required this.isSubmitting,
  });

  final String submitLabel;
  final VoidCallback onCancel;
  final VoidCallback? onSubmit;
  final bool isSubmitting;

  @override
  Widget build(BuildContext context) {
    final isSmall = Responsive.of(context).dialogMaxWidth < 600;
    final cancelBtn = _CancelButton(onTap: onCancel);
    final submitBtn = _SubmitButton(
      label: submitLabel,
      onTap: isSubmitting ? null : onSubmit,
      loading: isSubmitting,
    );

    if (isSmall) {
      return Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [cancelBtn, const SizedBox(height: 10), submitBtn],
      );
    }
    return Row(
      children: [
        Expanded(child: cancelBtn),
        const SizedBox(width: 10),
        Expanded(child: submitBtn),
      ],
    );
  }
}

class _CancelButton extends StatefulWidget {
  const _CancelButton({required this.onTap});

  final VoidCallback onTap;

  @override
  State<_CancelButton> createState() => _CancelButtonState();
}

class _CancelButtonState extends State<_CancelButton> {
  bool _pressed = false;

  @override
  Widget build(BuildContext context) {
    return GestureDetector(
      onTapDown: (_) => setState(() => _pressed = true),
      onTapCancel: () => setState(() => _pressed = false),
      onTapUp: (_) => setState(() => _pressed = false),
      onTap: widget.onTap,
      child: AnimatedContainer(
        duration: AppTokens.durFast,
        curve: AppTokens.curveStandard,
        padding: const EdgeInsets.symmetric(vertical: 13, horizontal: 18),
        decoration: BoxDecoration(
          color: _pressed ? AppTokens.border : AppTokens.parchment,
          border: Border.all(color: AppTokens.border, width: 1.5),
          borderRadius: BorderRadius.circular(AppTokens.radiusSm),
        ),
        child: Row(
          mainAxisAlignment: MainAxisAlignment.center,
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(
              Icons.close,
              size: 16,
              color: _pressed ? AppTokens.ink : AppTokens.inkMid,
            ),
            const SizedBox(width: 8),
            Text(
              'বাতিল',
              style: TextStyle(
                fontFamily: AppTheme.bodyFontFamily,
                fontFamilyFallback: AppTheme.bengaliFallback,
                fontSize: 15,
                fontWeight: FontWeight.w700,
                color: _pressed ? AppTokens.ink : AppTokens.inkMid,
              ),
            ),
          ],
        ),
      ),
    );
  }
}

class _SubmitButton extends StatefulWidget {
  const _SubmitButton({
    required this.label,
    required this.onTap,
    required this.loading,
  });

  final String label;
  final VoidCallback? onTap;
  final bool loading;

  @override
  State<_SubmitButton> createState() => _SubmitButtonState();
}

class _SubmitButtonState extends State<_SubmitButton> {
  bool _pressed = false;

  @override
  Widget build(BuildContext context) {
    return GestureDetector(
      onTapDown: (_) => setState(() => _pressed = true),
      onTapCancel: () => setState(() => _pressed = false),
      onTapUp: (_) => setState(() => _pressed = false),
      onTap: widget.onTap,
      child: AnimatedContainer(
        duration: AppTokens.durFast,
        curve: AppTokens.curveStandard,
        padding: const EdgeInsets.symmetric(vertical: 13, horizontal: 18),
        transform: Matrix4.translationValues(0, _pressed ? -1 : 0, 0),
        decoration: BoxDecoration(
          color: _pressed ? AppTokens.verdantMid : AppTokens.verdant,
          borderRadius: BorderRadius.circular(AppTokens.radiusSm),
          boxShadow: [
            BoxShadow(
              color: AppTokens.verdant.withOpacity(0.28),
              blurRadius: 12,
              offset: const Offset(0, 3),
            ),
          ],
        ),
        child: Row(
          mainAxisAlignment: MainAxisAlignment.center,
          mainAxisSize: MainAxisSize.min,
          children: [
            if (widget.loading)
              const SizedBox(
                width: 15,
                height: 15,
                child: CircularProgressIndicator(
                  strokeWidth: 2,
                  color: AppTokens.white,
                ),
              )
            else
              const Icon(Icons.send, size: 16, color: AppTokens.white),
            const SizedBox(width: 8),
            Flexible(
              child: Text(
                widget.label,
                overflow: TextOverflow.ellipsis,
                style: const TextStyle(
                  fontFamily: AppTheme.bodyFontFamily,
                  fontFamilyFallback: AppTheme.bengaliFallback,
                  fontSize: 15,
                  fontWeight: FontWeight.w700,
                  color: AppTokens.white,
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }
}
