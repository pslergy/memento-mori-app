// Каналы (Telegram-style). Только онлайн: обновления через сервер.
// Mesh, транспорт и тайминги не используются.

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:memento_mori_app/core/api_service.dart';
import 'package:memento_mori_app/core/locator.dart';
import 'package:memento_mori_app/features/theme/app_colors.dart';

class ChannelScreen extends StatefulWidget {
  final String channelId;
  final String channelName;

  const ChannelScreen({
    super.key,
    required this.channelId,
    required this.channelName,
  });

  @override
  State<ChannelScreen> createState() => _ChannelScreenState();
}

class _ChannelScreenState extends State<ChannelScreen> {
  List<Map<String, dynamic>> _posts = [];
  bool _loading = true;
  String? _error;

  @override
  void initState() {
    super.initState();
    _loadPosts();
  }

  Future<void> _loadPosts() async {
    if (!locator.isRegistered<ApiService>()) {
      setState(() {
        _loading = false;
        _error = 'Channels need internet';
      });
      return;
    }
    if (locator<ApiService>().isGhostMode) {
      setState(() {
        _loading = false;
        _error = 'Channels need internet';
      });
      return;
    }
    setState(() {
      _loading = true;
      _error = null;
    });
    try {
      final api = locator<ApiService>();
      final list = await api.getChannelPosts(widget.channelId);
      if (mounted) {
        setState(() {
          _posts = list;
          _loading = false;
        });
      }
    } catch (e) {
      if (mounted) {
        setState(() {
          _loading = false;
          _error = e.toString();
        });
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: Colors.black,
      appBar: AppBar(
        title: Text(
          widget.channelName,
          style: const TextStyle(
            letterSpacing: 1,
            fontWeight: FontWeight.bold,
            fontSize: 16,
          ),
        ),
        backgroundColor: Colors.black,
        elevation: 0,
        iconTheme: const IconThemeData(color: Colors.white70),
        actions: [
          IconButton(
            icon: const Icon(Icons.link),
            tooltip: 'Invite by link',
            onPressed: _showInviteLink,
          ),
        ],
      ),
      body: _buildBody(),
    );
  }

  Widget _buildBody() {
    if (_error != null) {
      return Center(
        child: Padding(
          padding: const EdgeInsets.all(24),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              Icon(Icons.cloud_off, color: AppColors.textDim, size: 48),
              const SizedBox(height: 16),
              Text(
                'Channels need internet',
                style: TextStyle(color: AppColors.stealthOrange, fontSize: 14),
                textAlign: TextAlign.center,
              ),
              const SizedBox(height: 8),
              Text(
                _error!,
                style: const TextStyle(color: Colors.white24, fontSize: 11),
                textAlign: TextAlign.center,
              ),
            ],
          ),
        ),
      );
    }
    if (_loading) {
      return const Center(
        child: CircularProgressIndicator(color: AppColors.stealthOrange),
      );
    }
    if (_posts.isEmpty) {
      return Center(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(Icons.campaign_outlined, color: Colors.white24, size: 48),
            const SizedBox(height: 12),
            Text(
              'No posts yet',
              style: TextStyle(color: AppColors.textDim, fontSize: 14),
            ),
          ],
        ),
      );
    }
    return RefreshIndicator(
      onRefresh: _loadPosts,
      color: AppColors.stealthOrange,
      child: ListView.builder(
        padding: const EdgeInsets.symmetric(vertical: 8, horizontal: 12),
        itemCount: _posts.length,
        itemBuilder: (context, index) {
          final p = _posts[index];
          final content = p['content']?.toString() ?? '';
          final authorId = p['authorId']?.toString() ?? p['senderId']?.toString() ?? '';
          final createdAt = p['createdAt'];
          final ts = createdAt is int
              ? DateTime.fromMillisecondsSinceEpoch(createdAt)
              : (createdAt != null ? DateTime.tryParse(createdAt.toString()) : null);
          return Container(
            margin: const EdgeInsets.only(bottom: 12),
            padding: const EdgeInsets.all(12),
            decoration: BoxDecoration(
              color: AppColors.surface,
              borderRadius: BorderRadius.circular(12),
              border: Border.all(color: AppColors.white05),
            ),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                if (ts != null)
                  Text(
                    _formatDate(ts),
                    style: TextStyle(
                      color: Colors.white24,
                      fontSize: 10,
                    ),
                  ),
                const SizedBox(height: 6),
                Text(
                  content,
                  style: const TextStyle(
                    color: Colors.white,
                    fontSize: 14,
                  ),
                ),
                if (authorId.isNotEmpty)
                  Padding(
                    padding: const EdgeInsets.only(top: 6),
                    child: Text(
                      authorId.length > 12 ? '${authorId.substring(0, 12)}…' : authorId,
                      style: TextStyle(color: Colors.white24, fontSize: 10),
                    ),
                  ),
              ],
            ),
          );
        },
      ),
    );
  }

  Future<void> _showInviteLink() async {
    if (!locator.isRegistered<ApiService>()) return;
    final api = locator<ApiService>();
    if (api.isGhostMode) return;
    try {
      final data = await api.getChannelInviteLink(widget.channelId);
      final url = data['inviteUrl']?.toString() ?? data['url']?.toString() ?? '';
      final token = data['inviteToken']?.toString() ?? data['token']?.toString() ?? '';
      final link = url.isNotEmpty ? url : (token.isNotEmpty ? 'https://memento.app/channel/join?invite=$token' : '');
      if (!mounted || link.isEmpty) return;
      showModalBottomSheet<void>(
        context: context,
        backgroundColor: AppColors.surface,
        shape: const RoundedRectangleBorder(borderRadius: BorderRadius.vertical(top: Radius.circular(16))),
        builder: (ctx) => Padding(
          padding: const EdgeInsets.all(20),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              Text('Invite friends by link', style: TextStyle(color: AppColors.textDim, fontSize: 12)),
              const SizedBox(height: 8),
              SelectableText(link, style: const TextStyle(color: Colors.white, fontSize: 13)),
              const SizedBox(height: 16),
              Row(
                children: [
                  Expanded(
                    child: OutlinedButton.icon(
                      onPressed: () {
                        Clipboard.setData(ClipboardData(text: link));
                        ScaffoldMessenger.of(context).showSnackBar(const SnackBar(content: Text('Link copied'), backgroundColor: AppColors.stealthOrange));
                        Navigator.pop(ctx);
                      },
                      icon: const Icon(Icons.copy, size: 18),
                      label: const Text('Copy'),
                      style: OutlinedButton.styleFrom(foregroundColor: AppColors.stealthOrange, side: const BorderSide(color: AppColors.stealthOrange)),
                    ),
                  ),
                ],
              ),
            ],
          ),
        ),
      );
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text('Could not get invite link: $e'), backgroundColor: Colors.red));
      }
    }
  }

  String _formatDate(DateTime d) {
    final now = DateTime.now();
    if (d.day == now.day && d.month == now.month && d.year == now.year) {
      return '${d.hour.toString().padLeft(2, '0')}:${d.minute.toString().padLeft(2, '0')}';
    }
    return '${d.day}.${d.month}.${d.year} ${d.hour.toString().padLeft(2, '0')}:${d.minute.toString().padLeft(2, '0')}';
  }
}
