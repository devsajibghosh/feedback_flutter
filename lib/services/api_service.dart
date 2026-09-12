import 'package:dio/dio.dart';

import '../models/category.dart';

/// Result of a login attempt. `LoginFailure.message` is already the
/// Bengali copy meant for display — see §5 of SPEC.md for the exact wording
/// rules (no response at all vs. any HTTP error).
sealed class LoginResult {
  const LoginResult();
}

class LoginSuccess extends LoginResult {
  const LoginSuccess(this.orgId);
  final int orgId;
}

class LoginFailure extends LoginResult {
  const LoginFailure(this.message);
  final String message;
}

/// The marquee heading + ticker text for an organisation (§5, §3.3).
class MarqueeData {
  const MarqueeData({required this.heading, required this.text});
  final String heading;
  final String text;
}

/// Result of a raw `/feedback/store` call. This is the online-only half of
/// §4.7 — [SyncService] wraps it with the offline fallback (save locally,
/// always report success) and is what dialogs actually call.
sealed class SubmitResult {
  const SubmitResult();
}

class SubmitSuccess extends SubmitResult {
  const SubmitSuccess(this.message);
  final String message;
}

class SubmitFailure extends SubmitResult {
  const SubmitFailure(this.message);
  final String message;
}

/// Thin wrapper around the Laravel backend at
/// https://feedback.pathosoft.info/api. Every request times out at 10s.
class ApiService {
  /// [baseUrl] is injectable so a verification harness can point this at a
  /// local mock server instead of the live production API — production code
  /// never passes it, so the default is unchanged.
  ApiService({String baseUrl = 'https://feedback.pathosoft.info/api'})
      : _dio = Dio(
          BaseOptions(
            baseUrl: baseUrl,
            connectTimeout: const Duration(seconds: 10),
            receiveTimeout: const Duration(seconds: 10),
            sendTimeout: const Duration(seconds: 10),
          ),
        );

  final Dio _dio;

  Future<LoginResult> login(String email, String password) async {
    try {
      final response = await _dio.post<Map<String, dynamic>>(
        '/login',
        data: {'email': email, 'password': password},
      );
      final orgId = response.data?['org_id'];
      return LoginSuccess(
        orgId is int ? orgId : int.parse(orgId.toString()),
      );
    } on DioException catch (e) {
      if (e.response == null) {
        return const LoginFailure(
          'ইন্টারনেট কানেকশন নেই। অনুগ্রহ করে সংযোগটি চেক করুন।',
        );
      }
      return const LoginFailure('ভুল ইমেইল বা পাসওয়ার্ড। আবার চেষ্টা করুন।');
    }
  }

  /// Returns the org's logo URL, or null if the request fails or there is
  /// no logo set.
  Future<String?> getOrgLogo(int orgId) async {
    try {
      final response = await _dio.get<Map<String, dynamic>>(
        '/get-org-logo/$orgId',
      );
      final logo = response.data?['logo'];
      return logo is String && logo.isNotEmpty ? logo : null;
    } on DioException {
      return null;
    }
  }

  /// Returns the marquee heading + text, or null if the request fails.
  Future<MarqueeData?> getMarqueeText(int orgId) async {
    try {
      final response = await _dio.get<Map<String, dynamic>>(
        '/get-marquee-text/$orgId',
      );
      final data = response.data ?? const <String, dynamic>{};
      return MarqueeData(
        heading: data['heading']?.toString() ?? '',
        text: data['text']?.toString() ?? '',
      );
    } on DioException {
      return null;
    }
  }

  /// Returns the org's negative-feedback reason categories, or null if the
  /// request fails. An empty (but non-null) list means the server responded
  /// but has nothing to show — callers should leave any existing list as-is
  /// rather than clearing it, matching the Electron source exactly (§4.3).
  Future<List<Category>?> getCategories(int orgId) async {
    try {
      final response = await _dio.post<Map<String, dynamic>>(
        '/admin/get-categories',
        data: {'organization_id': orgId},
      );
      final data = response.data;
      if (data?['success'] != true) return const [];
      final list = data?['categories'];
      if (list is! List) return const [];
      return list
          .whereType<Map<String, dynamic>>()
          .map(Category.fromJson)
          .toList();
    } on DioException {
      return null;
    }
  }

  /// Posts one feedback entry (§5 multipart field names). Called only by
  /// [SyncService]'s background queue worker now (FIX-02 §1) — never
  /// directly from a dialog's submit handler.
  ///
  /// Unlike the other methods here, network/HTTP failures are NOT caught —
  /// they propagate as [DioException] so [SyncService] can tell a 422
  /// (permanent rejection) apart from any other failure (retry with
  /// backoff). The only case this still returns [SubmitFailure] directly
  /// for is a 2xx response whose body doesn't actually claim success.
  Future<SubmitResult> submitFeedback({
    required int orgId,
    required String rating,
    String comment = '',
    List<int> categoryIds = const [],
  }) async {
    final formData = FormData();
    formData.fields.addAll([
      MapEntry('organization_id', orgId.toString()),
      MapEntry('rating', rating),
      MapEntry('comment', comment),
      for (final id in categoryIds) MapEntry('category_ids[]', id.toString()),
    ]);
    final response = await _dio.post<Map<String, dynamic>>(
      '/feedback/store',
      data: formData,
    );
    final rawData = response.data;
    // FIX-03 §7: a malformed or unexpected body — a captive-portal login
    // page real hospital wifi serves for every request until someone signs
    // in, say — must be treated as a failure, never parsed as success.
    // Non-JSON content already throws before reaching here (Dio's JSON
    // transformer rejects it), but this also covers a response that *is*
    // valid JSON just not the shape expected (a bare array, a string, an
    // accidental `{"status":"success"}` from a misbehaving proxy that
    // returns the same placeholder body for everything it intercepts).
    if (rawData is! Map<String, dynamic>) {
      return const SubmitFailure('');
    }
    final message = rawData['message']?.toString() ?? '';
    // Mirrors the Electron background-sync check (§4.8): a 2xx response
    // whose body doesn't actually claim success is still a failure.
    final ok = rawData['status'] == 'success' || rawData['success'] == true;
    return ok ? SubmitSuccess(message) : SubmitFailure(message);
  }
}
