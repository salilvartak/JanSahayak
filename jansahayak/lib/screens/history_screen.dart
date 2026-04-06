import 'package:flutter/material.dart';
import 'package:cached_network_image/cached_network_image.dart';
import 'package:flutter/services.dart';
import 'package:flutter_tts/flutter_tts.dart';

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
  final FlutterTts _tts = FlutterTts();
  List<ConversationHistory> _items = [];
  bool _loading = true;
  int? _playingIndex;

  @override
  void initState() {
    super.initState();
    _tts.setCompletionHandler(() {
      if (mounted) setState(() => _playingIndex = null);
    });
    _tts.setCancelHandler(() {
      if (mounted) setState(() => _playingIndex = null);
    });
    _load();
  }

  @override
  void didUpdateWidget(covariant HistoryScreen oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.refreshSeed != widget.refreshSeed) {
      _load();
    }
  }

  @override
  void dispose() {
    _tts.stop();
    super.dispose();
  }

  Future<void> _load() async {
    if (!mounted) return;
    setState(() => _loading = true);

    final localData = await HistoryService.list();
    if (mounted) setState(() => _items = localData);

    try {
      final deviceId = await DeviceService.getDeviceId();
      final remoteData = await ApiService().getHistory(deviceId);

      for (final conv in remoteData) {
        await HistoryService.upsert(conv);
      }

      final updatedLocal = await HistoryService.list();

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

  Future<void> _confirmClearAll() async {
    HapticFeedback.heavyImpact();

    final confirmed = await showDialog<bool>(
      context: context,
      builder: (ctx) => Dialog(
        backgroundColor: const Color(0xFF102025),
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(24)),
        child: Padding(
          padding: const EdgeInsets.all(32),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              const Icon(Icons.delete_forever_rounded, color: Colors.redAccent, size: 56),
              const SizedBox(height: 32),
              Row(
                mainAxisAlignment: MainAxisAlignment.spaceEvenly,
                children: [
                  SizedBox(
                    width: 64,
                    height: 64,
                    child: IconButton.filled(
                      onPressed: () {
                        HapticFeedback.lightImpact();
                        Navigator.pop(ctx, false);
                      },
                      style: IconButton.styleFrom(backgroundColor: Colors.white24),
                      icon: const Icon(Icons.close_rounded, size: 32, color: Colors.white),
                    ),
                  ),
                  SizedBox(
                    width: 64,
                    height: 64,
                    child: IconButton.filled(
                      onPressed: () {
                        HapticFeedback.heavyImpact();
                        Navigator.pop(ctx, true);
                      },
                      style: IconButton.styleFrom(backgroundColor: Colors.redAccent),
                      icon: const Icon(Icons.check_rounded, size: 32, color: Colors.white),
                    ),
                  ),
                ],
              ),
            ],
          ),
        ),
      ),
    );

    if (confirmed == true) {
      await HistoryService.clear();
      await _load();
    }
  }

  Future<void> _playCardSummary(int index, ConversationHistory item) async {
    if (_playingIndex == index) {
      await _tts.stop();
      if (mounted) setState(() => _playingIndex = null);
      return;
    }
    await _tts.stop();
    if (mounted) setState(() => _playingIndex = index);

    final text = item.turns.isNotEmpty ? item.turns.first.text : '';
    if (text.isEmpty) return;

    final ttsLang = _detectLanguage(text);
    await _tts.setLanguage(ttsLang);
    await _tts.setSpeechRate(0.65);
    await _tts.speak(text);
  }

  String _detectLanguage(String text) {
    if (text.contains(RegExp(r'[\u0900-\u097F]'))) return 'hi-IN';
    if (text.contains(RegExp(r'[\u0C00-\u0C7F]'))) return 'te-IN';
    return 'en-IN';
  }

  Future<void> _openConversation(ConversationHistory item) async {
    await _tts.stop();
    if (!mounted) return;
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

  IconData _relativeTimeIcon(DateTime dt) {
    final diff = DateTime.now().difference(dt);
    if (diff.inHours < 24) return Icons.access_time_rounded;
    if (diff.inDays < 7) return Icons.today_rounded;
    return Icons.date_range_rounded;
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
                      onPressed: _items.isEmpty ? null : _confirmClearAll,
                      icon: const Icon(Icons.delete_outline_rounded, color: Colors.white),
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
                                  isPlaying: _playingIndex == i,
                                  timeIcon: _relativeTimeIcon(item.updatedAt),
                                  onTap: () => _openConversation(item),
                                  onPlay: () => _playCardSummary(i, item),
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
  final bool isPlaying;
  final IconData timeIcon;
  final VoidCallback onTap;
  final VoidCallback onPlay;

  const _HistoryCard({
    required this.item,
    required this.isPlaying,
    required this.timeIcon,
    required this.onTap,
    required this.onPlay,
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
            padding: const EdgeInsets.all(10),
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
                const SizedBox(width: 12),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Icon(timeIcon, color: Colors.white30, size: 18),
                      const SizedBox(height: 6),
                      IconButton(
                        onPressed: () {
                          HapticFeedback.lightImpact();
                          onPlay();
                        },
                        icon: Icon(
                          isPlaying ? Icons.pause_circle_rounded : Icons.play_circle_rounded,
                          color: Colors.tealAccent,
                          size: 40,
                        ),
                        padding: EdgeInsets.zero,
                        constraints: const BoxConstraints(),
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
}
