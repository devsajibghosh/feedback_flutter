# Progress Log

DONE: Fix SQLite PRAGMA execute() vs rawQuery() crash on Android (db_service.dart) — audited lib/services/db_service.dart: `PRAGMA journal_mode = WAL` and `PRAGMA table_info(feedbacks)` already use `rawQuery` (not `execute`), and the WAL pragma is already wrapped in its own try/catch so a failure doesn't block DB open. No other PRAGMA/raw-SQL misuse found elsewhere in lib/. `flutter analyze` clean.
