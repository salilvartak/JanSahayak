import 'package:flutter/material.dart';
import 'package:cached_network_image/cached_network_image.dart';
import 'package:flutter/services.dart';

import '../models/conversation_history.dart';
import '../services/api_service.dart';
import '../services/device_service.dart';
import '../services/history_service.dart';
import 'conversation_screen.dart';

class HistoryScreen extends StatefulWidget {
  final int refreshSeed;

  const HistoryScreen({super.key, this.refreshSeed = 0});

  @override
  State<HistoryScreen> createState() => _HistoryScreenState();
}

class _HistoryScreenState extends State<HistoryScreen> {
  List<ConversationHistory> _items = [];
  bool _loading = true;

  @override
  void initState() {
    super.initState();
    _load();
  }

  @override
  void didUpdateWidget(covariant HistoryScreen oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.refreshSeed != widget.refreshSeed) {
      _load();
    }
  }

  Future<void> _load() async {
    if (!mounted) return;
    setState(() => _loading = true);

    debugPrint('[HistoryScreen] Initializing _load()');

    // Initial load from local db
    final localData = await HistoryService.list();
    debugPrint('[HistoryScreen] Loaded ${localData.length} items from local HistoryService cache.');
    if (mounted) setState(() => _items = localData);

    try {
      final deviceId = await DeviceService.getDeviceId();
      debugPrint('[HistoryScreen] Using deviceId: $deviceId');
      
      final remoteData = await ApiService().getHistory(deviceId);
      debugPrint('[HistoryScreen] Received ${remoteData.length} items from backend API.');
      
      for (final conv in remoteData) {
        await HistoryService.upsert(conv);
      }
      
      final updatedLocal = await HistoryService.list();
      debugPrint('[HistoryScreen] Finished merging remote. New local count: ${updatedLocal.length}');

      if (!mounted) return;
      setState(() {
        _items = updatedLocal;
        _loading = false;
      });
    } catch (e) {
      debugPrint('[HistoryScreen] Fatal error in _load(): $e');
      if (mounted) setState(() => _loading = false);
    }
  }

  Future<void> _clearAll() async {
    await HistoryService.clear();
    await _load();
  }

  Future<void> _openConversation(ConversationHistory item) async {
    await Navigator.push(
      context,
      MaterialPageRoute(
        builder: (_) => ConversationScreen.resume(
          resumeConversation: item,
        ),
      ),
    );
    if (!mounted) return;
    _load();
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: const Color(0xFF07191D),
      body: Container(
        decoration: const BoxDecoration(
          gradient: LinearGradient(
            begin: Alignment.topCenter,
            end: Alignment.bottomCenter,
            colors: [
              Color(0xFF07191D),
              Color(0xFF031015),
            ],
          ),
        ),
        child: SafeArea(
          child: Column(
            children: [
              Padding(
                padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 8),
                child: Row(
                  children: [
                    IconButton(
                      onPressed: _load,
                      icon: const Icon(Icons.refresh_rounded, color: Colors.white),
                    ),
                    Expanded(
                      child: Center(
                        child: Image.asset(
                          'assets/Images/Jansahayak_logo.png',
                          height: 38,
                          fit: BoxFit.contain,
                        ),
                      ),
                    ),
                    IconButton(
                      onPressed: _items.isEmpty ? null : _clearAll,
                      icon: const Icon(Icons.history_toggle_off_rounded, color: Colors.white),
                    ),
                  ],
                ),
              ),
              Expanded(
                child: _loading
                    ? const Center(
                        child: CircularProgressIndicator(color: Color(0xFF5FA6A6)),
                      )
                    : _items.isEmpty
                        ? const Center(
                            child: Icon(
                              Icons.hourglass_empty_rounded,
                              color: Colors.white30,
                              size: 40,
                            ),
                          )
                        : ListView.builder(
                            padding: const EdgeInsets.fromLTRB(12, 4, 12, 16),
                            itemCount: _items.length,
                            itemBuilder: (_, i) {
                              final item = _items[i];
                              return Padding(
                                padding: const EdgeInsets.only(bottom: 12),
                                child: _HistoryCard(
                                  item: item,
                                  onTap: () => _openConversation(item),
                                ),
                              );
                            },
                          ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

class _HistoryCard extends StatelessWidget {
  final ConversationHistory item;
  final VoidCallback onTap;

  const _HistoryCard({
    required this.item,
    required this.onTap,
  });

  @override
  Widget build(BuildContext context) {
    return Material(
      color: Colors.transparent,
      child: InkWell(
        borderRadius: BorderRadius.circular(22),
        onTap: () {
          HapticFeedback.lightImpact();
          onTap();
        },
        child: Ink(
          decoration: BoxDecoration(
            color: const Color(0xFF102025).withValues(alpha: 0.82),
            borderRadius: BorderRadius.circular(22),
            border: Border.all(color: Colors.white10),
            boxShadow: const [
              BoxShadow(
                color: Color(0x66000000),
                blurRadius: 16,
                offset: Offset(0, 8),
              ),
            ],
          ),
          child: Padding(
            padding: const EdgeInsets.all(12),
            child: Row(
              children: [
                ClipRRect(
                  borderRadius: BorderRadius.circular(16),
                  child: item.previewImageUrl.isNotEmpty
                      ? CachedNetworkImage(
                          imageUrl: item.previewImageUrl,
                          width: 100,
                          height: 100,
                          fit: BoxFit.cover,
                        )
                      : Container(
                          width: 100,
                          height: 100,
                          color: const Color(0xFF1B2B30),
                          child: const Icon(
                            Icons.image_rounded,
                            color: Colors.white38,
                            size: 34,
                          ),
                        ),
                ),
                const SizedBox(width: 16),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        item.title,
                        maxLines: 2,
                        overflow: TextOverflow.ellipsis,
                        style: const TextStyle(
                          color: Colors.white,
                          fontSize: 16,
                          fontWeight: FontWeight.bold,
                        ),
                      ),
                      const SizedBox(height: 6),
                      Text(
                        _formatDate(item.updatedAt),
                        style: const TextStyle(
                          color: Colors.white38,
                          fontSize: 13,
                        ),
                      ),
                    ],
                  ),
                ),
                const Icon(
                  Icons.chevron_right_rounded,
                  color: Colors.white24,
                  size: 28,
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }

  String _formatDate(DateTime dt) {
    final now = DateTime.now();
    if (dt.year == now.year && dt.month == now.month && dt.day == now.day) {
      return 'Today, ${dt.hour}:${dt.minute.toString().padLeft(2, '0')}';
    }
    return '${dt.day}/${dt.month}/${dt.year}';
  }
}
