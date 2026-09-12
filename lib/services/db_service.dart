import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';
import 'package:sqflite/sqflite.dart';

import '../models/feedback_entry.dart';

const _requiredColumns = {
  'org_id': 'INTEGER',
  'rating': 'TEXT',
  'comment': 'TEXT',
  'category_ids': 'TEXT',
  'voice_path': 'TEXT',
  'created_at': 'TEXT',
  'synced': 'INTEGER DEFAULT 0',
};

/// The local `feedbacks` table (§6): WAL-enabled SQLite at
/// `<documents>/FeedbackSystem/feedback.db`, with the same defensive
/// `PRAGMA table_info` + `ALTER TABLE ADD COLUMN` migration check the
/// Electron app runs on every startup, rather than a version-gated
/// migration — so a column added later still gets picked up on an
/// existing install.
class DbService {
  Database? _db;
  String? _dbPath;

  Future<Database> get _database async => _db ??= await _open();

  Future<Database> _open() async {
    final documentsDir = await getApplicationDocumentsDirectory();
    final dbPath = p.join(documentsDir.path, 'FeedbackSystem', 'feedback.db');
    _dbPath = dbPath;

    final db = await openDatabase(
      dbPath,
      version: 1,
      onConfigure: (db) async {
        // `PRAGMA journal_mode = WAL` returns a row (the mode that took
        // effect), and Android's SQLiteDatabase rejects any statement that
        // returns a result set when run through execute() — "Queries can be
        // performed using SQLiteDatabase query or rawQuery methods only."
        // rawQuery() is the correct call here. WAL is an optimisation, not a
        // requirement, so a failure (an unusual device, a locked-down
        // filesystem) must not stop the database — and therefore the whole
        // app — from opening.
        try {
          await db.rawQuery('PRAGMA journal_mode = WAL');
        } catch (_) {}
      },
      onCreate: (db, version) async {
        await db.execute('''
          CREATE TABLE IF NOT EXISTS feedbacks (
            id INTEGER PRIMARY KEY AUTOINCREMENT,
            org_id INTEGER,
            rating TEXT,
            comment TEXT,
            category_ids TEXT,
            voice_path TEXT,
            created_at TEXT,
            synced INTEGER DEFAULT 0
          )
        ''');
        await db.execute(
          'CREATE INDEX IF NOT EXISTS idx_org_date ON feedbacks (org_id, created_at)',
        );
      },
    );

    await _ensureColumns(db);
    return db;
  }

  Future<void> _ensureColumns(Database db) async {
    try {
      final columns = await db.rawQuery('PRAGMA table_info(feedbacks)');
      final existing = columns.map((c) => c['name'] as String).toSet();
      for (final entry in _requiredColumns.entries) {
        if (!existing.contains(entry.key)) {
          await db.execute(
            'ALTER TABLE feedbacks ADD COLUMN ${entry.key} ${entry.value}',
          );
        }
      }
    } catch (_) {
      // Never let a migration hiccup block the app from starting.
    }
  }

  Future<int> insert(FeedbackEntry entry) async {
    final db = await _database;
    return db.insert('feedbacks', entry.toMap());
  }

  /// Up to [limit] unsynced rows, oldest first (FIX-02 §1).
  Future<List<FeedbackEntry>> getUnsyncedBatch({int limit = 3}) async {
    final db = await _database;
    final rows = await db.query(
      'feedbacks',
      where: 'synced = ?',
      whereArgs: [0],
      orderBy: 'created_at ASC',
      limit: limit,
    );
    return rows.map(FeedbackEntry.fromMap).toList();
  }

  Future<void> markSynced(int id) async {
    final db = await _database;
    await db.update(
      'feedbacks',
      {'synced': 1},
      where: 'id = ?',
      whereArgs: [id],
    );
  }

  Future<void> markRejected(int id) async {
    final db = await _database;
    await db.update(
      'feedbacks',
      {'synced': -1},
      where: 'id = ?',
      whereArgs: [id],
    );
  }

  /// FIX-02 §1 retention: rows the server already has are dead weight.
  /// `synced = -1` rows are kept indefinitely so they can be inspected
  /// later — only successfully-sent rows age out.
  Future<void> deleteOldSyncedRows(
      {Duration olderThan = const Duration(days: 7)}) async {
    final db = await _database;
    final cutoff = DateTime.now().subtract(olderThan).toIso8601String();
    await db.delete(
      'feedbacks',
      where: 'synced = 1 AND created_at < ?',
      whereArgs: [cutoff],
    );
  }

  /// The on-device debug dump (FIX-01 §5, extended by FIX-02 §1): total row
  /// count, a count per `synced` value, the oldest still-pending row's
  /// timestamp, and the database's path on disk — there's no cable to pull
  /// the file off this device to inspect it directly.
  Future<DbDebugSummary> debugSummary() async {
    final db = await _database;
    final totalRows = await db.rawQuery('SELECT COUNT(*) AS c FROM feedbacks');
    final total = (totalRows.first['c'] as int?) ?? 0;

    final grouped = await db.rawQuery(
      'SELECT synced, COUNT(*) AS c FROM feedbacks GROUP BY synced',
    );
    final bySynced = <int, int>{
      for (final row in grouped) row['synced'] as int: row['c'] as int,
    };

    final oldestRows = await db.query(
      'feedbacks',
      columns: ['created_at'],
      where: 'synced = ?',
      whereArgs: [0],
      orderBy: 'created_at ASC',
      limit: 1,
    );
    final oldestPending = oldestRows.isEmpty
        ? null
        : DateTime.tryParse(oldestRows.first['created_at'] as String);

    return DbDebugSummary(
      total: total,
      bySynced: bySynced,
      oldestPending: oldestPending,
      dbPath: _dbPath ?? '(not opened yet)',
    );
  }
}

/// See [DbService.debugSummary].
class DbDebugSummary {
  const DbDebugSummary({
    required this.total,
    required this.bySynced,
    required this.oldestPending,
    required this.dbPath,
  });

  final int total;

  /// Keyed by the `synced` column's value: 0 pending, 1 sent, -1 rejected.
  final Map<int, int> bySynced;

  final DateTime? oldestPending;
  final String dbPath;
}
