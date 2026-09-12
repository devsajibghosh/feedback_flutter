import 'dart:async';

import 'package:flutter/material.dart';

import '../models/category.dart';
import '../services/api_service.dart';
import '../services/crash_log.dart';
import '../services/storage_service.dart';
import '../services/sync_service.dart';
import '../theme/app_theme.dart';
import '../theme/responsive.dart';
import '../theme/tokens.dart';
import 'app_alerts.dart';
import 'category_pill.dart';
import 'feedback_dialog.dart';

/// The negative variant (§3.4): shown for poor, very_poor. A fresh instance
/// is created every time the dialog opens and disposed when it closes, so
/// §4.4's "clear comment on open" and §4.6's "reset everything on close"
/// both fall out of normal widget lifecycle rather than needing explicit
/// reset code.
class NegativeDialogContent extends StatefulWidget {
  const NegativeDialogContent({
    super.key,
    required this.orgId,
    required this.rating,
    required this.close,
    this.api,
    this.storage,
    this.sync,
  });

  final int orgId;
  final String rating;
  final DialogCloser close;
  final ApiService? api;
  final StorageService? storage;
  final SyncService? sync;

  @override
  State<NegativeDialogContent> createState() => _NegativeDialogContentState();
}

class _NegativeDialogContentState extends State<NegativeDialogContent> {
  late final ApiService _api = widget.api ?? ApiService();
  late final StorageService _storage = widget.storage ?? StorageService();
  late final SyncService _sync = widget.sync ?? SyncService(api: _api);
  final _commentController = TextEditingController();
  final Set<int> _selectedCategoryIds = {};

  // null = nothing to show yet (no cache and no successful fetch).
  List<Category>? _categories;
  bool _categoriesFailed = false;
  bool _isSubmitting = false;

  @override
  void initState() {
    super.initState();
    _loadCategories();
  }

  @override
  void dispose() {
    _commentController.dispose();
    super.dispose();
  }

  Future<void> _loadCategories() async {
    final cached = await _storage.getCategoriesCache(widget.orgId);
    if (mounted && cached != null && cached.isNotEmpty) {
      setState(() => _categories = cached);
    }

    // Categories are re-fetched every time this dialog opens (§4.3),
    // regardless of whether a cache was just shown.
    final fetched = await _api.getCategories(widget.orgId);
    if (!mounted) return;

    if (fetched != null && fetched.isNotEmpty) {
      await _storage.setCategoriesCache(widget.orgId, fetched);
      if (!mounted) return;
      setState(() {
        _categories = fetched;
        _categoriesFailed = false;
      });
    } else if (fetched != null && _categories == null) {
      // The server responded successfully but this org simply has no
      // categories configured, and there's no cache either. Show an empty
      // list rather than leaving the "লোড হচ্ছে..." spinner on screen
      // forever — §4.3 only covers the non-empty and network-failure cases.
      setState(() => _categories = const []);
    } else if (fetched == null &&
        (_categories == null || _categories!.isEmpty)) {
      setState(() => _categoriesFailed = true);
    }
  }

  void _toggleCategory(int id) {
    setState(() {
      if (!_selectedCategoryIds.remove(id)) {
        _selectedCategoryIds.add(id);
      }
    });
  }

  Future<void> _submit() async {
    if (_isSubmitting) return;

    final comment = _commentController.text.trim();

    if (_selectedCategoryIds.isEmpty && comment.isEmpty) {
      await showWarningAlert(
        context,
        message: 'দয়া করে কারণ সিলেক্ট করুন অথবা আপনার অভিজ্ঞতা লিখুন।',
      );
      return;
    }

    setState(() => _isSubmitting = true);

    // FIX-03 §7: the button-gating flag resets in a `finally`, so no path
    // through here — however it exits — can leave Submit stuck showing its
    // spinner forever.
    try {
      // §2/§3 fix: a broad catch here, not just `on DioException`. Anything
      // _sync.submit() throws — a local db error, anything — must still
      // tell the user something happened, instead of the failure being
      // silent.
      SubmitResult? result;
      Object? error;
      StackTrace? stackTrace;
      try {
        result = await _sync.submit(
          orgId: widget.orgId,
          rating: widget.rating,
          comment: comment,
          categoryIds: _selectedCategoryIds.toList(),
        );
      } catch (e, st) {
        error = e;
        stackTrace = st;
      }

      if (!mounted) return;

      if (error != null) {
        unawaited(
          CrashLog.record('NegativeDialog._submit', error, stackTrace),
        );
        await showGenericErrorAlert(context);
        return;
      }

      switch (result!) {
        case SubmitSuccess():
          await widget.close(result);
        case SubmitFailure(:final message):
          await showErrorAlert(
            context,
            title: 'ভুল বা ত্রুটি',
            message: message,
            confirmLabel: 'OK',
          );
      }
    } finally {
      if (mounted) setState(() => _isSubmitting = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    return Column(
      mainAxisSize: MainAxisSize.min,
      children: [
        _NegativeDialogHead(rating: widget.rating),
        DialogBody(
          children: [
            const _NoticeStrip(
              text: 'এক বা একাধিক কারণ বেছে নিতে পারেন',
            ),
            _CategoryList(
              categories: _categories,
              failed: _categoriesFailed,
              selectedIds: _selectedCategoryIds,
              onToggle: _toggleCategory,
            ),
            const DialogDivider(),
            const _CommentLabel(),
            _CommentField(controller: _commentController),
            const SizedBox(height: 22),
            DialogActionsRow(
              submitLabel: 'ফিডব্যাক জমা দিন',
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

/// The negative dialog's head (FIX-04 §1, rating name added FIX-05 §1):
/// leads with the same emoji the visitor just tapped — 🙁 for `poor`, 😞 for
/// `very_poor` — then the rating's own Bengali name spelled out as the
/// primary line, with `কেন সন্তুষ্ট হন নি?` demoted to a secondary line below
/// it. The old subtitle here moved out to the notice strip (FIX-05 §2).
/// Collapses on *any* screen size whenever the keyboard opens (not just
/// short-height, unlike the shared [DialogHead] used by the positive
/// dialog), since this head is now tall enough to matter everywhere, and
/// animates over 160ms so it doesn't jump.
class _NegativeDialogHead extends StatelessWidget {
  const _NegativeDialogHead({required this.rating});

  final String rating;

  @override
  Widget build(BuildContext context) {
    final responsive = Responsive.of(context);
    var padding = responsive.dialogHeadPadding;
    if (responsive.isShortHeight) {
      padding = EdgeInsets.fromLTRB(
        padding.left,
        padding.top / 2,
        padding.right,
        padding.bottom / 2,
      );
    }
    final emoji = rating == 'very_poor' ? '😞' : '🙁';
    final ratingName = rating == 'very_poor' ? 'খুব খারাপ' : 'খারাপ';

    return AnimatedSize(
      duration: const Duration(milliseconds: 160),
      curve: AppTokens.curveStandard,
      alignment: Alignment.topCenter,
      child: responsive.isKeyboardOpen
          ? const SizedBox.shrink()
          : Padding(
              padding: padding,
              child: Column(
                mainAxisSize: MainAxisSize.min,
                children: [
                  Text(
                    emoji,
                    textAlign: TextAlign.center,
                    style: TextStyle(
                      fontSize: responsive.negativeHeadEmojiSize,
                      fontFamilyFallback: const ['Noto Color Emoji'],
                      height: 1,
                    ),
                  ),
                  const SizedBox(height: 8),
                  Text(
                    ratingName,
                    textAlign: TextAlign.center,
                    style: TextStyle(
                      fontFamily: AppTheme.headingFontFamily,
                      fontFamilyFallback: AppTheme.bengaliFallback,
                      fontWeight: FontWeight.w700,
                      fontSize: responsive.negativeHeadRatingNameSize,
                      color: AppTokens.ink,
                      height: 1.2,
                    ),
                  ),
                  const SizedBox(height: 6),
                  Text(
                    'কেন সন্তুষ্ট হন নি?',
                    textAlign: TextAlign.center,
                    style: TextStyle(
                      fontFamily: AppTheme.bodyFontFamily,
                      fontFamilyFallback: AppTheme.bengaliFallback,
                      fontWeight: FontWeight.w400,
                      fontSize: responsive.negativeHeadQuestionSize,
                      color: AppTokens.inkMuted,
                    ),
                  ),
                ],
              ),
            ),
    );
  }
}

/// The comment field's label (FIX-04 §2): a readable prompt, not a small
/// muted caption — no icon, `ink` at weight 600, with the optional marker
/// kept visually secondary.
class _CommentLabel extends StatelessWidget {
  const _CommentLabel();

  @override
  Widget build(BuildContext context) {
    final responsive = Responsive.of(context);
    return Padding(
      padding: const EdgeInsets.only(bottom: 11),
      child: Wrap(
        crossAxisAlignment: WrapCrossAlignment.end,
        spacing: 6,
        children: [
          Text(
            'অন্য কারণ থাকলে এখানে লিখুন',
            style: TextStyle(
              fontFamily: AppTheme.bodyFontFamily,
              fontFamilyFallback: AppTheme.bengaliFallback,
              fontSize: responsive.commentLabelSize,
              fontWeight: FontWeight.w600,
              color: AppTokens.ink,
            ),
          ),
          Text(
            '(ঐচ্ছিক)',
            style: TextStyle(
              fontFamily: AppTheme.bodyFontFamily,
              fontFamilyFallback: AppTheme.bengaliFallback,
              fontSize: responsive.commentLabelOptionalSize,
              fontWeight: FontWeight.w400,
              color: AppTokens.inkMuted,
            ),
          ),
        ],
      ),
    );
  }
}

class _NoticeStrip extends StatelessWidget {
  const _NoticeStrip({required this.text});

  final String text;

  @override
  Widget build(BuildContext context) {
    return Container(
      width: double.infinity,
      margin: const EdgeInsets.only(bottom: 20),
      padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 11),
      decoration: const BoxDecoration(
        color: AppTokens.errorLit,
        border: Border(
          left: BorderSide(color: AppTokens.error, width: 3),
        ),
        borderRadius: BorderRadius.only(
          topRight: Radius.circular(AppTokens.radiusXs),
          bottomRight: Radius.circular(AppTokens.radiusXs),
        ),
      ),
      child: Text(
        text,
        style: TextStyle(
          fontFamily: AppTheme.bodyFontFamily,
          fontFamilyFallback: AppTheme.bengaliFallback,
          fontSize: Responsive.of(context).noticeStripFontSize,
          fontWeight: FontWeight.w500,
          color: AppTokens.error,
          height: 1.5,
        ),
      ),
    );
  }
}

class _CategoryList extends StatelessWidget {
  const _CategoryList({
    required this.categories,
    required this.failed,
    required this.selectedIds,
    required this.onToggle,
  });

  final List<Category>? categories;
  final bool failed;
  final Set<int> selectedIds;
  final ValueChanged<int> onToggle;

  @override
  Widget build(BuildContext context) {
    final list = categories;
    if (list == null) {
      return Padding(
        padding: const EdgeInsets.symmetric(vertical: 8),
        child: Text(
          failed
              ? 'ইন্টারনেট সংযোগ না থাকায় ক্যাটেগরি লোড হয়নি।'
              : 'লোড হচ্ছে...',
          style: const TextStyle(
            fontFamily: AppTheme.bodyFontFamily,
            fontFamilyFallback: AppTheme.bengaliFallback,
            fontSize: 14,
            color: AppTokens.inkMuted,
          ),
        ),
      );
    }

    // A Wrap, not a Column, so short labels sit side by side on a wide
    // dialog and stack on a narrow one (SPEC-RESPONSIVE.md §6).
    return Wrap(
      spacing: 10,
      runSpacing: 10,
      children: [
        for (var i = 0; i < list.length; i++)
          CategoryPill(
            category: list[i],
            serial: i + 1,
            selected: selectedIds.contains(list[i].id),
            onTap: () => onToggle(list[i].id),
          ),
      ],
    );
  }
}

class _CommentField extends StatefulWidget {
  const _CommentField({required this.controller});

  final TextEditingController controller;

  @override
  State<_CommentField> createState() => _CommentFieldState();
}

class _CommentFieldState extends State<_CommentField> {
  final _focusNode = FocusNode();
  bool _focused = false;

  @override
  void initState() {
    super.initState();
    _focusNode.addListener(() {
      setState(() => _focused = _focusNode.hasFocus);
      if (_focusNode.hasFocus) {
        // Scrolls the field above the keyboard as soon as it's focused
        // (FIX-03 §3), rather than leaving the user to discover they need
        // to scroll themselves.
        WidgetsBinding.instance.addPostFrameCallback((_) {
          if (!mounted) return;
          Scrollable.ensureVisible(
            context,
            alignment: 0.1,
            duration: AppTokens.durFast,
            curve: AppTokens.curveStandard,
          );
        });
      }
    });
  }

  @override
  void dispose() {
    _focusNode.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return AnimatedContainer(
      duration: AppTokens.durFast,
      curve: AppTokens.curveStandard,
      width: double.infinity,
      constraints: const BoxConstraints(minHeight: 108),
      decoration: BoxDecoration(
        color: AppTokens.white,
        borderRadius: BorderRadius.circular(AppTokens.radiusMd),
        border: Border.all(
          color: _focused ? AppTokens.verdant : AppTokens.border,
          width: 1.5,
        ),
        boxShadow: _focused
            ? [
                BoxShadow(
                  color: AppTokens.verdant.withOpacity(0.1),
                  spreadRadius: 3,
                ),
              ]
            : null,
      ),
      child: TextField(
        controller: widget.controller,
        focusNode: _focusNode,
        maxLines: null,
        textInputAction: TextInputAction.done,
        onEditingComplete: () => FocusScope.of(context).unfocus(),
        onChanged: (_) => DialogIdleScope.maybeOf(context)?.onInteraction(),
        style: const TextStyle(
          fontFamily: AppTheme.bodyFontFamily,
          fontFamilyFallback: AppTheme.bengaliFallback,
          fontSize: 15,
          color: AppTokens.ink,
        ),
        cursorColor: AppTokens.verdant,
        decoration: const InputDecoration(
          isDense: true,
          border: InputBorder.none,
          hintText: 'আপনার মতামত বিস্তারিত লিখুন...',
          hintStyle: TextStyle(
            fontFamily: AppTheme.bodyFontFamily,
            fontSize: 15,
            color: AppTokens.inkMuted,
          ),
          contentPadding: EdgeInsets.symmetric(horizontal: 15, vertical: 13),
        ),
      ),
    );
  }
}
