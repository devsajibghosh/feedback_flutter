import 'package:cached_network_image/cached_network_image.dart';
import 'package:flutter/material.dart';

import '../services/api_service.dart';
import '../services/storage_service.dart';
import '../services/sync_service.dart';
import '../theme/app_theme.dart';
import '../theme/responsive.dart';
import '../theme/tokens.dart';
import '../widgets/app_alerts.dart';
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

class _FeedbackScreenState extends State<FeedbackScreen> {
  static const _defaultHeading = 'আমাদের সেবার মান কেমন ছিল?';
  static const _offlineFallback =
      'ইন্টারনেট সংযোগ দিন, যাতে ফিডব্যাকগুলো sync হতে পারে।';

  late final ApiService _api = widget.api ?? ApiService();
  late final StorageService _storage = widget.storage ?? StorageService();
  late final SyncService _sync = widget.sync ?? SyncService(api: _api);

  String? _logoUrl;
  String _marqueeText = 'লোড হচ্ছে...';
  String _heading = _defaultHeading;

  @override
  void initState() {
    super.initState();
    _loadLogo();
    _loadMarquee();
    _prefetchCategories();
    // The queue worker (FIX-02 §1) is started once in main() and outlives
    // this screen — nothing to start or dispose here.
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

  void _handleRatingTap(String rating) {
    if (_positiveRatings.contains(rating)) {
      _openPositiveDialog(rating);
    } else {
      _openNegativeDialog(rating);
    }
  }

  Future<void> _openPositiveDialog(String rating) async {
    final result = await showFeedbackDialog<SubmitResult>(
      context,
      isPositive: true,
      builder: (context, close) => PositiveDialogContent(
        orgId: widget.orgId,
        rating: rating,
        close: close,
        sync: _sync,
      ),
    );

    if (result is SubmitSuccess && mounted) {
      await showSuccessAlert(context,
          title: 'ধন্যবাদ!', message: result.message);
    }
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

  Future<void> _openNegativeDialog(String rating) async {
    final result = await showFeedbackDialog<SubmitResult>(
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

    if (result is SubmitSuccess && mounted) {
      await showSuccessAlert(context,
          title: 'ধন্যবাদ!', message: result.message);
    }
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
