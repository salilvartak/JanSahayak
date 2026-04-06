import 'dart:convert';

import 'package:shared_preferences/shared_preferences.dart';

import '../models/conversation_history.dart';

class HistoryService {
  HistoryService._();

  static const _storageKey = 'jan_conversation_history_v1';
  static const _maxConversations = 30;

  static Future<List<ConversationHistory>> list() async {
    final prefs = await SharedPreferences.getInstance();
    final raw = prefs.getString(_storageKey);
    if (raw == null || raw.isEmpty) return [];
    try {
      final parsed = jsonDecode(raw) as List<dynamic>;
      final items = parsed
          .map((e) => ConversationHistory.fromJson(e as Map<String, dynamic>))
          .toList();
      items.sort((a, b) => b.updatedAt.compareTo(a.updatedAt));
      return items;
    } catch (_) {
      return [];
    }
  }

  static Future<void> upsert(ConversationHistory conversation) async {
    final all = await list();
    final idx = all.indexWhere((c) => c.id == conversation.id);
    if (idx >= 0) {
      all[idx] = conversation;
    } else {
      all.insert(0, conversation);
    }

    if (all.length > _maxConversations) {
      all.removeRange(_maxConversations, all.length);
    }

    final prefs = await SharedPreferences.getInstance();
    await prefs.setString(
      _storageKey,
      jsonEncode(all.map((e) => e.toJson()).toList()),
    );
  }

  static Future<void> delete(String id) async {
    final all = await list();
    all.removeWhere((c) => c.id == id);
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString(
      _storageKey,
      jsonEncode(all.map((e) => e.toJson()).toList()),
    );
  }

  static Future<void> clear() async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.remove(_storageKey);
  }
}
