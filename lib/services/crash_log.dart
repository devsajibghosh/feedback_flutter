import 'dart:io';

import 'package:meta/meta.dart';
import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';

/// Append-only diagnostic log for FIX-03 §6/§7: "keep internal capture —
/// `runZonedGuarded` plus `FlutterError.onError` writing to a local rolling
/// log file, capped at a few MB. Never surfaced, but there if this needs
/// diagnosing in six months." Nothing here ever reaches the UI.
///
/// Capped by simple truncation rather than numbered rotation: this is a
/// kiosk with no one to collect multiple log files from, so one file that
/// keeps its most recent half when it gets too big is simpler than a
/// rotation scheme nobody will ever read the older half of anyway.
class CrashLog {
  CrashLog._();

  static const _capBytes = 2 * 1024 * 1024; // 2MB
  static File? _file;
  static bool _initFailed = false;

  /// Tests only — the resolved file handle is cached for the life of the
  /// process (there's exactly one real log file for the app's whole
  /// lifetime), which a test suite that swaps `PathProviderPlatform`
  /// between cases needs to be able to clear.
  @visibleForTesting
  static void resetForTest() {
    _file = null;
    _initFailed = false;
  }

  static Future<void> record(
    String context,
    Object error, [
    StackTrace? stackTrace,
  ]) async {
    try {
      final file = await _ensureFile();
      if (file == null) return;
      final line = StringBuffer()
        ..write(DateTime.now().toIso8601String())
        ..write(' [')
        ..write(context)
        ..write('] ')
        ..write(error.runtimeType)
        ..write(': ')
        ..write(error);
      if (stackTrace != null) {
        line
          ..write('\n')
          ..write(stackTrace);
      }
      line.write('\n');
      await file.writeAsString(
        line.toString(),
        mode: FileMode.append,
        flush: true,
      );
      await _trimIfNeeded(file);
    } catch (_) {
      // Logging must never itself crash the app.
    }
  }

  static Future<File?> _ensureFile() async {
    final existing = _file;
    if (existing != null) return existing;
    if (_initFailed) return null;
    try {
      final dir = await getApplicationDocumentsDirectory();
      final logDir = Directory(p.join(dir.path, 'FeedbackSystem'));
      await logDir.create(recursive: true);
      final file = File(p.join(logDir.path, 'app.log'));
      _file = file;
      return file;
    } catch (_) {
      _initFailed = true;
      return null;
    }
  }

  static Future<void> _trimIfNeeded(File file) async {
    try {
      final length = await file.length();
      if (length <= _capBytes) return;
      final bytes = await file.readAsBytes();
      final trimmed = bytes.sublist(bytes.length - (_capBytes ~/ 2));
      await file.writeAsBytes(trimmed, flush: true);
    } catch (_) {
      // Trim failure isn't worth losing the log entry that was just
      // written over.
    }
  }
}
