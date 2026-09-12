import 'dart:convert';

/// A row in the local `feedbacks` table (§6). `synced`: 0 pending, 1 sent,
/// -1 permanently rejected by the server.
class FeedbackEntry {
  const FeedbackEntry({
    this.id,
    required this.orgId,
    required this.rating,
    required this.comment,
    required this.categoryIds,
    required this.createdAt,
    required this.synced,
  });

  final int? id;
  final int orgId;
  final String rating;
  final String comment;
  final List<int> categoryIds;
  final DateTime createdAt;
  final int synced;

  // The `voice_path` column still exists in the database (dropping it is
  // version-dependent in SQLite and not worth the risk on an existing
  // install) but voice recording is gone (FIX-02 §2) — nothing here reads
  // or writes it any more.
  factory FeedbackEntry.fromMap(Map<String, dynamic> map) {
    final rawCategoryIds = map['category_ids'] as String?;
    final decoded = rawCategoryIds == null || rawCategoryIds.isEmpty
        ? const <dynamic>[]
        : jsonDecode(rawCategoryIds) as List<dynamic>;
    return FeedbackEntry(
      id: map['id'] as int?,
      orgId: map['org_id'] as int,
      rating: map['rating'] as String,
      comment: map['comment'] as String? ?? '',
      categoryIds: decoded.map((e) => e as int).toList(),
      createdAt: DateTime.parse(map['created_at'] as String),
      synced: map['synced'] as int? ?? 0,
    );
  }

  Map<String, dynamic> toMap() => {
        'org_id': orgId,
        'rating': rating,
        'comment': comment,
        'category_ids': jsonEncode(categoryIds),
        'created_at': createdAt.toIso8601String(),
        'synced': synced,
      };
}
