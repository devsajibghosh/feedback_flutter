import 'dart:async';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';

import 'screens/feedback_screen.dart';
import 'screens/login_screen.dart';
import 'services/api_service.dart';
import 'services/crash_log.dart';
import 'services/kiosk_service.dart';
import 'services/storage_service.dart';
import 'services/sync_service.dart';
import 'theme/app_theme.dart';
import 'theme/tokens.dart';
import 'widgets/blurred_background.dart';
import 'widgets/feedback_dialog.dart';

void main() {
  // FIX-03 §7/§8: a stuck dialog is unacceptable — nobody is around to
  // restart this kiosk. Every uncaught error, sync or async, is logged to
  // the internal rolling file (never surfaced) and, if a feedback dialog
  // happens to be open, force-closes it back to the rating screen instead
  // of leaving it sitting there unresponsive.
  runZonedGuarded(
    () async {
      WidgetsFlutterBinding.ensureInitialized();

      FlutterError.onError = (details) {
        unawaited(CrashLog.record('FlutterError', details.exception, details.stack));
        FeedbackDialogGuard.closeActiveDialog();
      };

      // The real `sqflite` plugin only has an Android/iOS implementation. On
      // every other platform, swap in the FFI-backed desktop implementation
      // so the database (and therefore the app) can open at all — this
      // branch never runs on Android/iOS, so production behaviour there is
      // unchanged.
      if (!Platform.isAndroid && !Platform.isIOS) {
        sqfliteFfiInit();
        databaseFactory = databaseFactoryFfi;
      }

      await KioskService.enable();

      // A single long-lived queue worker for the life of the app (FIX-02
      // §1) — created and started here, never owned by a widget, so it
      // keeps draining the local queue regardless of which screen is on top
      // or how many times the feedback screen itself is rebuilt.
      final api = ApiService();
      final storage = StorageService();
      final sync = SyncService(api: api);
      sync.start();

      runApp(FeedbackApp(api: api, storage: storage, sync: sync));
    },
    (error, stackTrace) {
      unawaited(CrashLog.record('zoned', error, stackTrace));
      FeedbackDialogGuard.closeActiveDialog();
    },
  );
}

class FeedbackApp extends StatelessWidget {
  const FeedbackApp({super.key, this.api, this.storage, this.sync});

  /// Injectable for tests; defaults (via [AppRoot]) to the real
  /// network/storage services and a freshly-started [SyncService].
  final ApiService? api;
  final StorageService? storage;
  final SyncService? sync;

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: 'Feedback Machine',
      debugShowCheckedModeBanner: false,
      theme: AppTheme.theme,
      // A system font scale up to 2.0x would break the fixed-height rating
      // buttons and dialog chrome — clamp it once, here, for the whole app
      // (SPEC-RESPONSIVE.md §7).
      builder: (context, child) {
        final clamped = MediaQuery.textScalerOf(
          context,
        ).scale(1.0).clamp(0.85, 1.3);
        return MediaQuery(
          data: MediaQuery.of(
            context,
          ).copyWith(textScaler: TextScaler.linear(clamped)),
          child: child!,
        );
      },
      home: AppRoot(api: api, storage: storage, sync: sync),
    );
  }
}

/// Decides, on launch, whether to show the login screen or the feedback
/// screen (§4.1): a blank verdant screen first (no flash of white), then
/// the saved org id decides the destination.
class AppRoot extends StatefulWidget {
  const AppRoot({super.key, this.api, this.storage, this.sync});

  /// Injectable for tests; defaults to the real network/storage services.
  final ApiService? api;
  final StorageService? storage;
  final SyncService? sync;

  @override
  State<AppRoot> createState() => _AppRootState();
}

class _AppRootState extends State<AppRoot> {
  late final ApiService _api = widget.api ?? ApiService();
  late final StorageService _storage = widget.storage ?? StorageService();
  late final SyncService _sync =
      widget.sync ?? (SyncService(api: _api)..start());
  bool _checking = true;
  int? _orgId;

  @override
  void initState() {
    super.initState();
    _checkLoginStatus();
  }

  Future<void> _checkLoginStatus() async {
    final orgId = await _storage.getOrgId();
    if (!mounted) return;
    setState(() {
      _orgId = orgId;
      _checking = false;
    });
  }

  void _handleLoginSuccess(int orgId) {
    setState(() => _orgId = orgId);
  }

  @override
  Widget build(BuildContext context) {
    // The back button must never exit the app (§4.9) — this covers both
    // the blank startup frame and the fully-loaded screen below.
    return PopScope(canPop: false, child: _buildContent(context));
  }

  Widget _buildContent(BuildContext context) {
    if (_checking) {
      return const SizedBox.expand(
        child: ColoredBox(color: AppTokens.verdant),
      );
    }

    final orgId = _orgId;
    return Scaffold(
      resizeToAvoidBottomInset: true,
      body: BlurredBackground(
        child: orgId != null
            ? FeedbackScreen(
                orgId: orgId,
                api: _api,
                storage: _storage,
                sync: _sync,
              )
            : SafeArea(
                child: LayoutBuilder(
                  builder: (context, constraints) {
                    // Centres when there's room, scrolls when there isn't —
                    // including when the keyboard opens (SPEC-RESPONSIVE.md
                    // §3, §5).
                    return SingleChildScrollView(
                      physics: const ClampingScrollPhysics(),
                      child: ConstrainedBox(
                        constraints: BoxConstraints(
                          minHeight: constraints.maxHeight,
                        ),
                        child: Center(
                          child: LoginScreen(
                            onLoginSuccess: _handleLoginSuccess,
                          ),
                        ),
                      ),
                    );
                  },
                ),
              ),
      ),
    );
  }
}
