import 'dart:async';

import 'package:cached_network_image/cached_network_image.dart';
import 'package:flutter/material.dart';

import '../services/api_service.dart';
import '../services/storage_service.dart';
import '../services/sync_service.dart';
import '../theme/app_theme.dart';
import '../theme/responsive.dart';
import '../theme/tokens.dart';
import '../widgets/feedback_dialog.dart';
import '../widgets/marquee_bar.dart';
import '../widgets/negative_dialog.dart';
import '../widgets/positive_dialog.dart';
import '../widgets/rating_button.dart';

const _positiveRatings = {'very_good', 'good', 'satisfactory'};

/// The main feedback screen (§3.3): marquee, org logo, heading, subtitle,
/// and the five rating buttons. Replaces the login screen once authenticated.
class FeedbackScreen extends StatefulWidget {
  const FeedbackScreen({
    super.key,
    required this.orgId,
    this.api,
    this.storage,
    this.sync,
  });

  final int orgId;

  /// Injectable for tests; defaults to the real network/storage services.
  final ApiService? api;
  final StorageService? storage;
  final SyncService? sync;

  @override
  State<FeedbackScreen> createState() => _FeedbackScreenState();
}

class _FeedbackScreenState extends State<FeedbackScreen>
    with WidgetsBindingObserver {
  static const _defaultHeading = 'আমাদের সেবার মান কেমন ছিল?';
  static const _offlineFallback =
      'ইন্টারনেট সংযোগ দিন, যাতে ফিডব্যাকগুলো sync হতে পারে।';

  /// FIX-03 §2: 4 seconds, not the old 1500ms.
  static const _successToastDuration = Duration(milliseconds: 4000);

  late final ApiService _api = widget.api ?? ApiService();
  late final StorageService _storage = widget.storage ?? StorageService();
  late final SyncService _sync = widget.sync ?? SyncService(api: _api);

  String? _logoUrl;
  String _marqueeText = 'লোড হচ্ছে...';
  String _heading = _defaultHeading;

  // FIX-03 §8: an unattended kiosk gets double-taps and rapid taps across
  // different ratings that a phone app never has to worry about. Gating on
  // "is a dialog already open" (rather than a fixed-duration debounce)
  // handles both at once, and for exactly as long as it needs to — no
  // dialog can be opened while one is already showing, whether that's the
  // same rating tapped twice or five different ones tapped in a burst.
  bool _dialogOpen = false;

  OverlayEntry? _successEntry;
  Timer? _successTimer;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    _loadLogo();
    _loadMarquee();
    _prefetchCategories();
    // The queue worker (FIX-02 §1) is started once in main() and outlives
    // this screen — nothing to start or dispose here.
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    _dismissSuccessToast();
    super.dispose();
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    // FIX-03 §2: "if the app is backgrounded and comes back while the
    // message is up, the message is gone. Do not resume a stale timer."
    // The simplest thing that satisfies this exactly: any transition away
    // from `resumed` removes the toast outright — there is nothing to
    // "resume" once it no longer exists, so coming back to `resumed` later
    // needs no special handling at all.
    if (state != AppLifecycleState.resumed) {
      _dismissSuccessToast();
    }
  }

  /// Pre-warms the category cache at launch (§4.2) so the negative dialog's
  /// own fetch-on-open has something fresh to fall back to if it's offline
  /// the first time it's opened. Silent either way — nothing is rendered
  /// here, the dialog does its own render-from-cache when it mounts.
  Future<void> _prefetchCategories() async {
    final fetched = await _api.getCategories(widget.orgId);
    if (fetched != null && fetched.isNotEmpty) {
      await _storage.setCategoriesCache(widget.orgId, fetched);
    }
  }

  Future<void> _loadLogo() async {
    final url = await _api.getOrgLogo(widget.orgId);
    if (!mounted || url == null) return;
    setState(() => _logoUrl = url);
  }

  Future<void> _loadMarquee() async {
    final result = await _api.getMarqueeText(widget.orgId);
    if (!mounted) return;

    if (result != null) {
      await _storage.setMarqueeCache(widget.orgId, result);
      if (!mounted) return;
      setState(() {
        _heading = result.heading;
        _marqueeText = result.text;
      });
      return;
    }

    final cached = await _storage.getMarqueeCache(widget.orgId);
    if (!mounted) return;
    setState(() {
      _heading = cached?.heading ?? _offlineFallback;
      _marqueeText = cached?.text ?? _offlineFallback;
    });
  }

  // FIX-03 §8: `_dialogOpen` is released the moment the feedback dialog
  // route itself closes, not after the success message that may follow —
  // gating only the dialog means a rating tap that arrives while the
  // (non-blocking, FIX-03 §2) success message is still showing can open a
  // new dialog right away, exactly as §2 requires, while a second tap that
  // arrives *while a dialog is open* is dropped.
  Future<void> _handleRatingTap(String rating) async {
    if (_dialogOpen) return;
    // FIX-03 §2: "if someone taps a face while the message is up, the
    // message closes immediately and the new dialog opens" — a kiosk with
    // two people queued cannot make the second wait out an animation.
    _dismissSuccessToast();
    _dialogOpen = true;
    SubmitResult? result;
    try {
      result = _positiveRatings.contains(rating)
          ? await _showPositiveDialog(rating)
          : await _showNegativeDialog(rating);
    } finally {
      _dialogOpen = false;
    }
    if (result is SubmitSuccess && mounted) {
      _showSuccessToast(result.message);
    }
  }

  void _dismissSuccessToast() {
    _successTimer?.cancel();
    _successTimer = null;
    _successEntry?.remove();
    _successEntry = null;
  }

  /// Non-blocking (FIX-03 §2): an [OverlayEntry], not a `showDialog` modal —
  /// there is no barrier, so it can never intercept the tap that's supposed
  /// to dismiss it early or open the next dialog.
  void _showSuccessToast(String message) {
    _dismissSuccessToast();
    late final OverlayEntry entry;
    entry = OverlayEntry(
      builder: (context) =>
          _SuccessToast(message: message, onTap: _dismissSuccessToast),
    );
    _successEntry = entry;
    Overlay.of(context).insert(entry);
    _successTimer = Timer(_successToastDuration, _dismissSuccessToast);
  }

  Future<SubmitResult?> _showPositiveDialog(String rating) {
    return showFeedbackDialog<SubmitResult>(
      context,
      isPositive: true,
      builder: (context, close) => PositiveDialogContent(
        orgId: widget.orgId,
        rating: rating,
        close: close,
        sync: _sync,
      ),
    );
  }

  /// Long-press the marquee bar to see local DB and queue-worker state
  /// without a cable (FIX-01 §5, extended by FIX-02 §1). Keep this until
  /// told to remove it.
  Future<void> _showDebugDump() async {
    final summary = await _sync.debugSummary();
    if (!mounted) return;

    final bySynced = summary.bySynced;
    final dump = 'Total rows: ${summary.total}\n'
        'Pending (synced=0): ${bySynced[0] ?? 0}\n'
        'Sent (synced=1): ${bySynced[1] ?? 0}\n'
        'Rejected (synced=-1): ${bySynced[-1] ?? 0}\n'
        'Oldest pending: ${summary.oldestPending?.toIso8601String() ?? '—'}\n'
        'Current backoff interval: ${summary.currentBackoff.inSeconds}s\n'
        'Consecutive failures: ${summary.consecutiveFailures}\n'
        'Last error: ${summary.lastError ?? 'none'}\n'
        'Last successful sync: '
        '${summary.lastSuccessfulSync?.toIso8601String() ?? 'never'}\n'
        'DB path: ${summary.dbPath}';

    await showDialog<void>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('Debug dump (FIX-01 §5 — temporary)'),
        content: SingleChildScrollView(child: Text(dump)),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(context).pop(),
            child: const Text('Close'),
          ),
        ],
      ),
    );
  }

  Future<SubmitResult?> _showNegativeDialog(String rating) {
    return showFeedbackDialog<SubmitResult>(
      context,
      isPositive: false,
      builder: (context, close) => NegativeDialogContent(
        orgId: widget.orgId,
        rating: rating,
        close: close,
        api: _api,
        storage: _storage,
        sync: _sync,
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final responsive = Responsive.of(context);
    // On a very short screen (phone in landscape) the logo is decoration
    // and the subtitle is the first thing to go — the ratings are the
    // point of the screen (SPEC-RESPONSIVE.md §4.2, §4.3).
    final showLogo = _logoUrl != null && !responsive.isShortHeight;
    final showSubtitle = !responsive.isShortHeight;

    return Stack(
      children: [
        Positioned.fill(
          child: SafeArea(
            top: false,
            child: Padding(
              padding: const EdgeInsets.fromLTRB(24, 84, 24, 52),
              child: LayoutBuilder(
                builder: (context, constraints) {
                  return SingleChildScrollView(
                    physics: const ClampingScrollPhysics(),
                    child: ConstrainedBox(
                      constraints:
                          BoxConstraints(minHeight: constraints.maxHeight),
                      // No IntrinsicHeight here: this Column has no Row
                      // siblings that need height-matching, and IntrinsicHeight
                      // can't contain a LayoutBuilder (used below by the
                      // compact-portrait rating wrap) — it would throw
                      // "LayoutBuilder does not support returning intrinsic
                      // dimensions." ConstrainedBox + Column centering below
                      // already gives the "centre when short, scroll when
                      // tall" behaviour on its own.
                      child: Column(
                        mainAxisAlignment: MainAxisAlignment.center,
                        children: [
                          if (showLogo) ...[
                            _OrgLogo(url: _logoUrl!),
                            SizedBox(height: responsive.gap(22)),
                          ],
                          _Heading(text: _heading),
                          SizedBox(height: responsive.gap(8)),
                          if (showSubtitle) const _Subtitle(),
                          SizedBox(
                            height: responsive.isShortHeight
                                ? 20
                                : responsive.gap(52),
                          ),
                          _RatingRow(onSelect: _handleRatingTap),
                          if (!responsive.isShortHeight) const _RatingHelperText(),
                        ],
                      ),
                    ),
                  );
                },
              ),
            ),
          ),
        ),
        MarqueeBar(text: _marqueeText, onDebugLongPress: _showDebugDump),
      ],
    );
  }
}

class _OrgLogo extends StatelessWidget {
  const _OrgLogo({required this.url});

  final String url;

  @override
  Widget build(BuildContext context) {
    final size = Responsive.of(context).logoSize;
    return Container(
      width: size,
      height: size,
      padding: EdgeInsets.all(size * 0.077), // 10/130 of the original size
      decoration: BoxDecoration(
        color: AppTokens.ivory.withOpacity(0.97),
        borderRadius: BorderRadius.circular(24),
        boxShadow: AppTokens.shFloat,
      ),
      child: CachedNetworkImage(
        imageUrl: url,
        fit: BoxFit.contain,
        fadeInDuration: Duration.zero,
        errorWidget: (context, url, error) => const SizedBox.shrink(),
        placeholder: (context, url) => const SizedBox.shrink(),
      ),
    );
  }
}

class _Heading extends StatelessWidget {
  const _Heading({required this.text});

  final String text;

  @override
  Widget build(BuildContext context) {
    final fontSize = Responsive.of(context).headingSize;
    return Text(
      text,
      textAlign: TextAlign.center,
      style: TextStyle(
        fontFamily: AppTheme.headingFontFamily,
        fontFamilyFallback: AppTheme.bengaliFallback,
        fontWeight: FontWeight.w700,
        fontSize: fontSize,
        color: AppTokens.ivory,
        height: 1.18,
        letterSpacing: -0.015 * fontSize,
        shadows: [
          Shadow(
            color: Colors.black.withOpacity(0.28),
            blurRadius: 28,
            offset: const Offset(0, 2),
          ),
        ],
      ),
    );
  }
}

class _Subtitle extends StatelessWidget {
  const _Subtitle();

  @override
  Widget build(BuildContext context) {
    final fontSize = Responsive.of(context).subtitleSize;
    return Text(
      'আপনার মতামত আমাদের সেবা উন্নত করতে সাহায্য করে',
      textAlign: TextAlign.center,
      style: TextStyle(
        fontFamily: AppTheme.bodyFontFamily,
        fontFamilyFallback: AppTheme.bengaliFallback,
        fontSize: fontSize,
        color: AppTokens.parchment.withOpacity(0.6),
        letterSpacing: fontSize * 0.04,
      ),
    );
  }
}

class _RatingRow extends StatelessWidget {
  const _RatingRow({required this.onSelect});

  final ValueChanged<String> onSelect;

  @override
  Widget build(BuildContext context) {
    final responsive = Responsive.of(context);
    final gap = responsive.ratingGap;

    if (!responsive.ratingButtonsWrap) {
      return ConstrainedBox(
        constraints: const BoxConstraints(maxWidth: 1200),
        child: Row(
          children: [
            for (var i = 0; i < kRatingSpecs.length; i++) ...[
              if (i > 0) SizedBox(width: gap),
              Expanded(
                child: RatingButton(
                  spec: kRatingSpecs[i],
                  onTap: () => onSelect(kRatingSpecs[i].value),
                ),
              ),
            ],
          ],
        ),
      );
    }

    // Narrow portrait phone: 3 on top, 2 below, never forced five-across
    // (SPEC-RESPONSIVE.md §4.1).
    return LayoutBuilder(
      builder: (context, constraints) {
        final cardWidth = (constraints.maxWidth - 2 * gap) / 3;
        return Wrap(
          alignment: WrapAlignment.center,
          spacing: gap,
          runSpacing: gap,
          children: [
            for (final spec in kRatingSpecs)
              SizedBox(
                width: cardWidth,
                child: RatingButton(
                  spec: spec,
                  onTap: () => onSelect(spec.value),
                ),
              ),
          ],
        );
      },
    );
  }
}

/// The hint below the rating grid (FIX-03 §4): tells a visitor who's about
/// to tap 🙁 or 😞 that there's a place to explain what went wrong, before
/// they've committed to a rating and possibly walked away. Plain text, not
/// a control — no gesture, no semantics as a button, just informational
/// copy a screen reader reads like any other paragraph. Hidden on a short
/// (phone-landscape) screen, where the ratings themselves need the room
/// more than the hint does.
class _RatingHelperText extends StatelessWidget {
  const _RatingHelperText();

  @override
  Widget build(BuildContext context) {
    final size = Responsive.of(context).helperTextSize;
    return Padding(
      padding: const EdgeInsets.only(top: 16),
      // Same maxWidth as _RatingRow's non-wrap branch, so on a very wide
      // screen this wraps at the same point the rating grid itself does —
      // the screen edge and the grid edge are only the same thing up to
      // 1200px.
      child: ConstrainedBox(
        constraints: const BoxConstraints(maxWidth: 1200),
        child: Text(
          'খারাপ বা খুব খারাপ নির্বাচন করলে সমস্যার বিস্তারিত জানানোর সুযোগ থাকবে।',
          textAlign: TextAlign.center,
          style: TextStyle(
            fontFamily: AppTheme.bodyFontFamily,
            fontFamilyFallback: AppTheme.bengaliFallback,
            fontWeight: FontWeight.w400,
            fontSize: size,
            color: AppTokens.parchment.withOpacity(0.6),
            letterSpacing: size * 0.04,
          ),
        ),
      ),
    );
  }
}

/// The submit-success shape (§3.5), now a non-blocking overlay rather than a
/// modal (FIX-03 §2): tapping it dismisses it early; tapping anywhere else —
/// including a rating card behind it — reaches whatever's underneath, since
/// there's no barrier at all, only this centred card.
class _SuccessToast extends StatelessWidget {
  const _SuccessToast({required this.message, required this.onTap});

  final String message;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    return Center(
      child: GestureDetector(
        onTap: onTap,
        child: Material(
          color: AppTokens.ivory,
          elevation: 8,
          shadowColor: Colors.black.withOpacity(0.3),
          borderRadius: BorderRadius.circular(AppTokens.radiusLg),
          child: Container(
            constraints: const BoxConstraints(maxWidth: 360),
            padding: const EdgeInsets.symmetric(horizontal: 28, vertical: 26),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                const Icon(
                  Icons.check_circle,
                  color: AppTokens.verdant,
                  size: 46,
                ),
                const SizedBox(height: 14),
                const Text(
                  'ধন্যবাদ!',
                  textAlign: TextAlign.center,
                  style: TextStyle(
                    fontFamily: AppTheme.headingFontFamily,
                    fontFamilyFallback: AppTheme.bengaliFallback,
                    fontWeight: FontWeight.w700,
                    fontSize: 20,
                    color: AppTokens.ink,
                  ),
                ),
                const SizedBox(height: 8),
                Text(
                  message,
                  textAlign: TextAlign.center,
                  style: const TextStyle(
                    fontFamily: AppTheme.bodyFontFamily,
                    fontFamilyFallback: AppTheme.bengaliFallback,
                    fontSize: 14,
                    color: AppTokens.inkMid,
                  ),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}
