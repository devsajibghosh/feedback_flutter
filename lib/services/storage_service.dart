import 'dart:convert';

import 'package:shared_preferences/shared_preferences.dart';

import '../models/category.dart';
import 'api_service.dart';

/// Persists small pieces of state across app launches (§4.1, §4.2, §4.3):
/// the logged-in organisation id, the last-known-good marquee copy, and the
/// cached negative-feedback categories.
class StorageService {
  static const _orgIdKey = 'org_id';

  Future<int?> getOrgId() async {
    final prefs = await SharedPreferences.getInstance();
    return prefs.getInt(_orgIdKey);
  }

  Future<void> setOrgId(int orgId) async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setInt(_orgIdKey, orgId);
  }

  Future<MarqueeData?> getMarqueeCache(int orgId) async {
    final prefs = await SharedPreferences.getInstance();
    final heading = prefs.getString('marquee_heading_$orgId');
    final text = prefs.getString('marquee_text_$orgId');
    if (heading == null || text == null) return null;
    return MarqueeData(heading: heading, text: text);
  }

  Future<void> setMarqueeCache(int orgId, MarqueeData data) async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString('marquee_heading_$orgId', data.heading);
    await prefs.setString('marquee_text_$orgId', data.text);
  }

  Future<List<Category>?> getCategoriesCache(int orgId) async {
    final prefs = await SharedPreferences.getInstance();
    final raw = prefs.getString('categories_$orgId');
    if (raw == null) return null;
    final decoded = jsonDecode(raw);
    if (decoded is! List) return null;
    return decoded
        .whereType<Map<String, dynamic>>()
        .map(Category.fromJson)
        .toList();
  }

  Future<void> setCategoriesCache(int orgId, List<Category> categories) async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString(
      'categories_$orgId',
      jsonEncode(categories.map((c) => c.toJson()).toList()),
    );
  }
}
