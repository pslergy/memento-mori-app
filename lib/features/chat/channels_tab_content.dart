// Вкладка каналов: подписки, Discover с фильтрами и поиском (преимущественно на стороне пользователя).

import 'package:flutter/material.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:memento_mori_app/core/api_service.dart';
import 'package:memento_mori_app/core/channel_types.dart';
import 'package:memento_mori_app/features/chat/channel_screen.dart';
import 'package:memento_mori_app/features/chat/create_channel_screen.dart';
import 'package:memento_mori_app/features/theme/app_colors.dart';

class ChannelsTabContent extends StatefulWidget {
  final ApiService api;

  const ChannelsTabContent({super.key, required this.api});

  @override
  State<ChannelsTabContent> createState() => _ChannelsTabContentState();
}

class _ChannelsTabContentState extends State<ChannelsTabContent> {
  final _searchController = TextEditingController();
  String _filterCategory = '';
  String _filterSort = kChannelSortOptions.first.id;
  List<Map<String, dynamic>> _subscribed = [];
  List<Map<String, dynamic>> _recommended = [];
  List<Map<String, dynamic>> _discover = [];
  bool _loadingSubscribed = true;
  bool _loadingDiscover = false;
  bool _loadingRecommended = false;
  bool _prefsLoaded = false;

  @override
  void initState() {
    super.initState();
    _loadPrefs();
    _loadSubscribed();
    _loadRecommended();
  }

  Future<void> _loadPrefs() async {
    final prefs = await SharedPreferences.getInstance();
    if (!mounted) return;
    setState(() {
      _filterCategory = prefs.getString(kPrefChannelFilterCategory) ?? '';
      _filterSort = prefs.getString(kPrefChannelFilterSort) ?? kChannelSortOptions.first.id;
      _prefsLoaded = true;
    });
    _loadDiscover();
  }

  Future<void> _saveFilterPrefs() async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString(kPrefChannelFilterCategory, _filterCategory);
    await prefs.setString(kPrefChannelFilterSort, _filterSort);
  }

  Future<void> _loadSubscribed() async {
    setState(() => _loadingSubscribed = true);
    final list = await widget.api.getSubscribedChannels();
    if (!mounted) return;
    setState(() {
      _subscribed = list;
      _loadingSubscribed = false;
    });
  }

  Future<void> _loadRecommended() async {
    setState(() => _loadingRecommended = true);
    final list = await widget.api.getRecommendedChannels();
    if (!mounted) return;
    setState(() {
      _recommended = list;
      _loadingRecommended = false;
    });
  }

  Future<void> _loadDiscover() async {
    if (!_prefsLoaded) return;
    setState(() => _loadingDiscover = true);
    final list = await widget.api.getChannels(
      category: _filterCategory.isEmpty ? null : _filterCategory,
      sort: _filterSort,
      q: _searchController.text.trim().isEmpty ? null : _searchController.text.trim(),
    );
    if (!mounted) return;
    setState(() {
      _discover = _applyClientSideFilter(list, _searchController.text.trim(), _filterCategory, _filterSort);
      _loadingDiscover = false;
    });
  }

  /// Фильтрация на стороне пользователя: по поиску (name/description), по категории, сортировка.
  List<Map<String, dynamic>> _applyClientSideFilter(
    List<Map<String, dynamic>> list,
    String query,
    String category,
    String sort,
  ) {
    var result = list;
    if (query.isNotEmpty) {
      final q = query.toLowerCase();
      result = result.where((c) {
        final name = (c['name'] as String? ?? '').toLowerCase();
        final desc = (c['description'] as String? ?? '').toLowerCase();
        final type = (c['type'] as String? ?? '').toLowerCase();
        return name.contains(q) || desc.contains(q) || type.contains(q);
      }).toList();
    }
    if (category.isNotEmpty) {
      result = result.where((c) => (c['type']?.toString() ?? '') == category).toList();
    }
    switch (sort) {
      case 'newest':
        result = List.from(result)
          ..sort((a, b) {
            final at = _parseTime(a['createdAt']);
            final bt = _parseTime(b['createdAt']);
            return bt.compareTo(at);
          });
        break;
      case 'subscribers':
      case 'popular':
        result = List.from(result)
          ..sort((a, b) {
            final an = (a['subscribersCount'] is int) ? a['subscribersCount'] as int : 0;
            final bn = (b['subscribersCount'] is int) ? b['subscribersCount'] as int : 0;
            return bn.compareTo(an);
          });
        break;
      default:
        break;
    }
    return result;
  }

  int _parseTime(dynamic v) {
    if (v == null) return 0;
    if (v is int) return v;
    final d = DateTime.tryParse(v.toString());
    return d?.millisecondsSinceEpoch ?? 0;
  }

  @override
  void dispose() {
    _searchController.dispose();
    super.dispose();
  }

  void _onFilterChanged() {
    _saveFilterPrefs();
    _loadDiscover();
  }

  /// Из ссылки вида https://...?invite=TOKEN или .../join/TOKEN извлекаем TOKEN.
  static String? _parseInviteTokenFromLink(String input) {
    final s = input.trim();
    if (s.isEmpty) return null;
    try {
      final uri = Uri.tryParse(s);
      if (uri != null) {
        final fromQuery = uri.queryParameters['invite'];
        if (fromQuery != null && fromQuery.isNotEmpty) return fromQuery;
        final pathSegments = uri.pathSegments;
        final joinIdx = pathSegments.indexOf('join');
        if (joinIdx >= 0 && joinIdx < pathSegments.length - 1) return pathSegments[joinIdx + 1];
      }
    } catch (_) {}
    return s.length > 10 ? s : null;
  }

  Future<void> _showJoinByInviteDialog() async {
    final controller = TextEditingController();
    final input = await showDialog<String>(
      context: context,
      builder: (ctx) => AlertDialog(
        backgroundColor: AppColors.surface,
        title: const Text('Join by invite link', style: TextStyle(color: Colors.white)),
        content: TextField(
          controller: controller,
          decoration: InputDecoration(
            hintText: 'Paste invite link or token',
            hintStyle: TextStyle(color: AppColors.textDim),
            border: OutlineInputBorder(borderRadius: BorderRadius.circular(12)),
          ),
          style: const TextStyle(color: Colors.white),
          maxLines: 2,
        ),
        actions: [
          TextButton(onPressed: () => Navigator.pop(ctx), child: const Text('Cancel')),
          FilledButton(
            style: FilledButton.styleFrom(backgroundColor: AppColors.stealthOrange),
            onPressed: () => Navigator.pop(ctx, controller.text),
            child: const Text('Join'),
          ),
        ],
      ),
    );
    if (input == null || input.trim().isEmpty) return;
    final token = _parseInviteTokenFromLink(input) ?? input.trim();
    if (token.isEmpty) {
      ScaffoldMessenger.of(context).showSnackBar(const SnackBar(content: Text('Invalid invite link')));
      return;
    }
    try {
      await widget.api.joinChannelByInvite(token);
      _loadSubscribed();
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(const SnackBar(content: Text('Joined channel'), backgroundColor: AppColors.stealthOrange));
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text('Could not join: $e')));
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    return RefreshIndicator(
      onRefresh: () async {
        await _loadSubscribed();
        await _loadRecommended();
        await _loadDiscover();
      },
      color: AppColors.stealthOrange,
      child: ListView(
        padding: const EdgeInsets.symmetric(vertical: 8, horizontal: 12),
        children: [
          // Кнопки: создать канал | вступить по ссылке
          Padding(
            padding: const EdgeInsets.only(bottom: 12),
            child: Row(
              children: [
                Expanded(
                  child: OutlinedButton.icon(
                    onPressed: () async {
                      final created = await Navigator.of(context).push<bool>(
                        MaterialPageRoute(builder: (_) => const CreateChannelScreen()),
                      );
                      if (created == true) _loadSubscribed();
                    },
                    icon: const Icon(Icons.add, size: 18, color: AppColors.stealthOrange),
                    label: const Text('Create', style: TextStyle(color: AppColors.stealthOrange)),
                    style: OutlinedButton.styleFrom(
                      side: const BorderSide(color: AppColors.stealthOrange),
                      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
                    ),
                  ),
                ),
                const SizedBox(width: 8),
                Expanded(
                  child: OutlinedButton.icon(
                    onPressed: _showJoinByInviteDialog,
                    icon: const Icon(Icons.link, size: 18, color: AppColors.stealthOrange),
                    label: const Text('Join by link', style: TextStyle(color: AppColors.stealthOrange)),
                    style: OutlinedButton.styleFrom(
                      side: const BorderSide(color: AppColors.stealthOrange),
                      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
                    ),
                  ),
                ),
              ],
            ),
          ),
          // Мои каналы (подписки)
          _sectionTitle('My channels'),
          if (_loadingSubscribed)
            const Padding(padding: EdgeInsets.all(24), child: Center(child: CircularProgressIndicator(color: AppColors.stealthOrange)))
          else if (_subscribed.isEmpty)
            Padding(
              padding: const EdgeInsets.symmetric(vertical: 12),
              child: Text('No subscriptions yet', style: TextStyle(color: AppColors.textDim, fontSize: 12)),
            )
          else
            ..._subscribed.map((ch) => _channelTile(ch, isSubscribed: true)),
          if (_loadingRecommended)
            const Padding(padding: EdgeInsets.symmetric(vertical: 8), child: Center(child: SizedBox(height: 20, width: 20, child: CircularProgressIndicator(color: AppColors.stealthOrange, strokeWidth: 2))))
          else if (_recommended.isNotEmpty) ...[
            const SizedBox(height: 16),
            _sectionTitle('Recommended'),
            ..._recommended.map((ch) {
              final id = ch['id']?.toString() ?? '';
              final isSub = _subscribed.any((s) => (s['id']?.toString() ?? '') == id);
              return _channelTile(ch, isSubscribed: isSub);
            }),
          ],
          const SizedBox(height: 20),
          // Discover: фильтры и поиск
          _sectionTitle('Discover'),
          TextField(
            controller: _searchController,
            decoration: InputDecoration(
              hintText: 'Search channels',
              hintStyle: TextStyle(color: AppColors.textDim),
              prefixIcon: Icon(Icons.search, color: AppColors.textDim, size: 20),
              filled: true,
              fillColor: AppColors.surface,
              border: OutlineInputBorder(borderRadius: BorderRadius.circular(12), borderSide: BorderSide.none),
              contentPadding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
            ),
            style: const TextStyle(color: Colors.white, fontSize: 14),
            onSubmitted: (_) => _loadDiscover(),
            onChanged: (_) => setState(() {}),
          ),
          const SizedBox(height: 8),
          Row(
            children: [
              Expanded(
                child: _filterDropdown(
                  value: _filterCategory,
                  items: const [DropdownMenuItem(value: '', child: Text('All categories'))]
                    ..addAll(kChannelTypes.map((t) => DropdownMenuItem(value: t.id, child: Text(t.labelEn)))),
                  onChanged: (v) {
                    setState(() => _filterCategory = v ?? '');
                    _onFilterChanged();
                  },
                ),
              ),
              const SizedBox(width: 8),
              Expanded(
                child: _filterDropdown(
                  value: _filterSort,
                  items: kChannelSortOptions.map((s) => DropdownMenuItem(value: s.id, child: Text(s.labelEn))).toList(),
                  onChanged: (v) {
                    if (v != null) {
                      setState(() => _filterSort = v);
                      _onFilterChanged();
                    }
                  },
                ),
              ),
            ],
          ),
          const SizedBox(height: 8),
          if (_loadingDiscover)
            const Padding(padding: EdgeInsets.all(16), child: Center(child: CircularProgressIndicator(color: AppColors.stealthOrange)))
          else if (_discover.isEmpty)
            Padding(
              padding: const EdgeInsets.symmetric(vertical: 12),
              child: Text('No channels found', style: TextStyle(color: AppColors.textDim, fontSize: 12)),
            )
          else
            ..._discover.map((ch) {
              final id = ch['id']?.toString() ?? '';
              final isSub = _subscribed.any((s) => (s['id']?.toString() ?? '') == id);
              return _channelTile(ch, isSubscribed: isSub);
            }),
        ],
      ),
    );
  }

  Widget _sectionTitle(String title) {
    return Padding(
      padding: const EdgeInsets.only(bottom: 8),
      child: Text(
        title.toUpperCase(),
        style: TextStyle(color: AppColors.textDim, fontSize: 10, fontWeight: FontWeight.bold, letterSpacing: 1),
      ),
    );
  }

  Widget _filterDropdown({
    required String value,
    required List<DropdownMenuItem<String>> items,
    required ValueChanged<String?> onChanged,
  }) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 4),
      decoration: BoxDecoration(
        color: AppColors.surface,
        borderRadius: BorderRadius.circular(10),
        border: Border.all(color: AppColors.white10),
      ),
      child: DropdownButtonHideUnderline(
        child: DropdownButton<String>(
          value: value.isEmpty ? items.first.value : value,
          isExpanded: true,
          dropdownColor: AppColors.surface,
          style: const TextStyle(color: Colors.white, fontSize: 13),
          items: items,
          onChanged: onChanged,
        ),
      ),
    );
  }

  Widget _channelTile(Map<String, dynamic> ch, {required bool isSubscribed}) {
    final id = ch['id']?.toString() ?? '';
    final name = ch['name']?.toString() ?? 'Channel';
    final desc = ch['description']?.toString() ?? '';
    final type = ch['type']?.toString() ?? '';
    final typeLabel = kChannelTypes.where((t) => t.id == type).isEmpty ? type : kChannelTypes.firstWhere((t) => t.id == type).labelEn;

    return ListTile(
      tileColor: AppColors.surface,
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
      leading: CircleAvatar(
        backgroundColor: AppColors.white05,
        child: Icon(Icons.campaign_outlined, color: AppColors.stealthOrange),
      ),
      title: Text(name, style: const TextStyle(color: Colors.white, fontWeight: FontWeight.bold, fontSize: 14)),
      subtitle: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        mainAxisSize: MainAxisSize.min,
        children: [
          if (desc.isNotEmpty) Text(desc, style: TextStyle(color: AppColors.textDim, fontSize: 11), maxLines: 2, overflow: TextOverflow.ellipsis),
          if (typeLabel.isNotEmpty) Text(typeLabel, style: TextStyle(color: AppColors.textDim, fontSize: 10)),
        ],
      ),
      trailing: isSubscribed ? const Icon(Icons.chevron_right, color: Colors.white24) : Icon(Icons.add_circle_outline, color: AppColors.stealthOrange, size: 22),
      onTap: () {
        if (isSubscribed) {
          Navigator.of(context).push(MaterialPageRoute(builder: (_) => ChannelScreen(channelId: id, channelName: name)));
        } else {
          widget.api.subscribeToChannel(id).then((_) {
            _loadSubscribed();
            if (mounted) ScaffoldMessenger.of(context).showSnackBar(const SnackBar(content: Text('Subscribed'), backgroundColor: AppColors.stealthOrange));
          });
        }
      },
    );
  }
}
