import 'dart:async';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:animate_do/animate_do.dart';
import 'package:memento_mori_app/core/api_service.dart';
import 'package:memento_mori_app/core/network_monitor.dart';
import 'package:memento_mori_app/core/locator.dart';
import 'package:memento_mori_app/core/mesh_service.dart';
import 'package:memento_mori_app/core/module_status_panel.dart';
import 'package:memento_mori_app/core/ultrasonic_service.dart';
import 'package:memento_mori_app/features/chat/conversation_screen.dart';
import 'package:memento_mori_app/features/chat/donate_screen.dart';
import 'package:memento_mori_app/features/profile/profile_screen.dart';
import 'package:memento_mori_app/features/chat/mesh_hybrid_screen.dart';
import 'package:memento_mori_app/features/friends/friends_list_screen.dart';
import 'package:memento_mori_app/features/chat/map_screen.dart';
import 'package:memento_mori_app/features/chat/channel_screen.dart';
import 'package:memento_mori_app/features/chat/channels_tab_content.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'dart:convert';
import '../../core/local_db_service.dart';
import '../../core/storage_service.dart';
import '../../core/websocket_service.dart';
import '../../core/beacon_country_helper.dart';
import '../../l10n/app_localizations.dart';
import '../theme/app_colors.dart';

class ChatListScreen extends StatefulWidget {
  const ChatListScreen({super.key});

  @override
  State<ChatListScreen> createState() => _ChatListScreenState();
}

class _ChatListScreenState extends State<ChatListScreen>
    with SingleTickerProviderStateMixin {
  late TabController _tabController;

  List<dynamic> _allChats = [];
  bool _isLoading = true;
  StreamSubscription? _socketSubscription;

  @override
  void initState() {
    super.initState();
    _tabController =
        TabController(length: 6, vsync: this); // SIGNAL, SQUADS, NODES, FRIENDS, MAP, CHANNELS
    _tabController.addListener(() {
      if (!_tabController.indexIsChanging) setState(() {});
    });

    _loadChats();
    _listenToSocket();
    if (locator.isRegistered<MeshService>()) {
      locator<MeshService>().loadMessengerMode().then((_) {
        if (mounted) setState(() {});
      });
    }

    NetworkMonitor().onRoleChanged.listen((role) {
      if (mounted) _loadChats();
    });
  }

  @override
  void dispose() {
    _tabController.dispose();
    _socketSubscription?.cancel();
    super.dispose();
  }

  Future<void> _loadChats() async {
    if (!mounted) return;
    setState(() => _isLoading = true);

    // Ghost/Offline: log when ApiService not registered; UI still shows Beacon fallback
    if (!locator.isRegistered<ApiService>()) {
      logMissingFor('ChatListScreen._loadChats', requireApi: true);
    }

    try {
      // Retry логика для Tecno/Xiaomi (более агрессивные оптимизации батареи)
      List<dynamic> chats = [];
      int retries = 0;
      const maxRetries = 2;

      final api =
          locator.isRegistered<ApiService>() ? locator<ApiService>() : null;
      while (retries < maxRetries && chats.isEmpty && api != null) {
        try {
          chats = await api.getChats();
          if (chats.isNotEmpty) break; // Успешно загрузили
        } catch (e) {
          retries++;
          if (retries < maxRetries) {
            // Ждем перед повторной попыткой
            await Future.delayed(Duration(seconds: retries * 2));
          }
        }
      }

      // 🔥 ГАРАНТИЯ: Если список пустой - добавляем Beacon с id по стране
      if (chats.isEmpty) {
        final beaconId = BeaconCountryHelper.beaconChatIdForCountry();
        final beaconName = beaconId == 'THE_BEACON_GLOBAL'
            ? 'THE BEACON (Global SOS)'
            : 'THE BEACON · ${BeaconCountryHelper.beaconCountryDisplayName(beaconId)}';
        chats = [
          {
            'id': beaconId,
            'name': beaconName,
            'type': 'GLOBAL',
            'lastMessage': {
              'content': 'Mesh Active. Frequency secured.',
              'createdAt': DateTime.now().toIso8601String()
            },
          }
        ];
      }

      // Локальные чаты (decoy / ghost): мержим комнаты из БД, чтобы отображались лички и фейк-переписка
      if (locator.isRegistered<LocalDatabaseService>()) {
        try {
          final db = locator<LocalDatabaseService>();
          final localRooms = await db.getAllChatRooms();
          final currentUserId = await getCurrentUserIdSafe();
          final friendMaps = await db.getFriends();
          final existingIds = <String>{};
          for (final c in chats) {
            if (c != null && c['id'] != null) existingIds.add(c['id'] as String);
          }
          for (final r in localRooms) {
            final id = r['id'] as String?;
            if (id == null || id.isEmpty || existingIds.contains(id)) continue;
            if (r['type'] != 'DIRECT' && r['type'] != 'GROUP') continue;
            final participantsJson = r['participants'] as String? ?? '[]';
            List<dynamic> participants = [];
            try {
              participants = jsonDecode(participantsJson) as List<dynamic>? ?? [];
            } catch (_) {}
            String? otherId;
            for (final p in participants) {
              final pid = p is String ? p : p.toString();
              if (pid != currentUserId) {
                otherId = pid;
                break;
              }
            }
            final name = r['name'] as String? ?? 'Chat';
            final lastMsg = r['lastMessage'] as String? ?? '';
            final lastActivity = r['lastActivity'] as int? ?? DateTime.now().millisecondsSinceEpoch;
            String otherName = name;
            if (otherId != null) {
              final friendList = friendMaps.where((f) => f['id'] == otherId).toList();
            final friend = friendList.isEmpty ? null : friendList.first;
              if (friend != null) otherName = friend['username'] as String? ?? otherId;
            }
            existingIds.add(id);
            chats.add({
              'id': id,
              'name': name,
              'type': r['type'] ?? 'DIRECT',
              'lastMessage': {
                'content': lastMsg,
                'createdAt': DateTime.fromMillisecondsSinceEpoch(lastActivity).toIso8601String(),
              },
              'otherUser': otherId != null ? {'id': otherId, 'username': otherName} : null,
            });
          }
        } catch (_) {}
      }

      if (mounted) {
        setState(() {
          _allChats = chats;
          _isLoading = false;
        });
      }
    } catch (e) {
      // 🔥 FALLBACK: показываем хотя бы Beacon с id по стране (как в API)
      if (mounted) {
        final beaconId = BeaconCountryHelper.beaconChatIdForCountry();
        final beaconName = beaconId == 'THE_BEACON_GLOBAL'
            ? 'THE BEACON (Global SOS)'
            : 'THE BEACON · ${BeaconCountryHelper.beaconCountryDisplayName(beaconId)}';
        setState(() {
          _allChats = [
            {
              'id': beaconId,
              'name': beaconName,
              'type': 'GLOBAL',
              'lastMessage': {
                'content': 'Mesh Active. Frequency secured.',
                'createdAt': DateTime.now().toIso8601String()
              },
            }
          ];
          _isLoading = false;
        });
      }
    }
  }

  void _listenToSocket() {
    _socketSubscription = WebSocketService().stream.listen((data) {
      if (data['type'] == 'updateChatList' || data['type'] == 'newMessage') {
        _loadChats();
      }
    });
  }

  List<dynamic> get _directChats =>
      _allChats.where((c) => c != null && c['type'] == 'DIRECT').toList();
  List<dynamic> get _groupChats =>
      _allChats.where((c) => c != null && c['type'] == 'GROUP').toList();

  dynamic get _beaconChat {
    final matches = _allChats.where((c) =>
        c != null &&
        (c['id'] == 'THE_BEACON_GLOBAL' ||
            c['type'] == 'GLOBAL' ||
            BeaconCountryHelper.isBeaconChat(c['id']?.toString())));
    return matches.isEmpty ? null : matches.first;
  }

  // --- 🔥 ЛОГИКА СОНАРА (AUTO-LINK) ---
  void _emitHandshakeSignal() async {
    HapticFeedback.heavyImpact();
    final String myId = locator.isRegistered<ApiService>()
        ? locator<ApiService>().currentUserId
        : (await Vault.read('user_id') ?? 'GHOST');
    if (myId.isEmpty) return;

    ScaffoldMessenger.of(context).showSnackBar(
      const SnackBar(
        content: Text(
          "🔊 EMITTING HANDSHAKE PULSE",
          style: TextStyle(
              fontSize: 10,
              color: Colors.purpleAccent,
              fontWeight: FontWeight.bold),
        ),
        backgroundColor: Colors.black,
        duration: Duration(seconds: 3),
      ),
    );

    // Сонар шлет команду на автоподключение
    await locator<UltrasonicService>().transmitFrame("LNK:$myId");
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: Colors.black,
      appBar: AppBar(
        title: const Text(
          'GRID_COMMS',
          style: TextStyle(
            letterSpacing: 2,
            fontWeight: FontWeight.bold,
            fontSize: 16,
          ),
        ),
        backgroundColor: Colors.black,
        elevation: 0,
        actions: [
          // Кнопка Сонара (Handshake)
          IconButton(
            icon: Pulse(
                child: Center(child: const Icon(Icons.spatial_audio_off,
                    color: Colors.purpleAccent)),
                infinite: true),
            onPressed: _emitHandshakeSignal,
            tooltip: "Emit Handshake Pulse",
          ),
          IconButton(
            icon: const Icon(Icons.radar, color: Colors.cyanAccent),
            onPressed: () => Navigator.of(context).push(
                MaterialPageRoute(builder: (_) => const MeshHybridScreen())),
          ),
          IconButton(
            icon: const Icon(Icons.account_circle_outlined),
            onPressed: () => Navigator.of(context)
                .push(MaterialPageRoute(builder: (_) => const ProfileScreen())),
          ),
        ],
        bottom: TabBar(
          controller: _tabController,
          indicatorColor: Colors.redAccent,
          labelStyle: TextStyle(
              fontSize: 10, fontWeight: FontWeight.bold, letterSpacing: 1),
          tabs: [
            Tab(text: "SIGNAL"),
            Tab(text: "SQUADS"),
            Tab(text: "NODES"),
            Tab(text: "FRIENDS"),
            Tab(text: "MAP"),
            Tab(text: "CHANNELS"),
          ],
        ),
      ),
      body: Column(
        children: [
          _buildMessengerModeSwitch(),
          _buildTacticalHUD(),
          Padding(
            padding: const EdgeInsets.fromLTRB(12, 4, 12, 4),
            child: ModuleStatusPanel(compact: true),
          ),
          Expanded(
            child: TabBarView(
              controller: _tabController,
              children: [
                _buildGlobalTab(),
                _buildChatList(
                    _groupChats, "No squads detected in this sector."),
                _buildChatList(_directChats, "No private links established."),
                const FriendsListScreen(),
                const MapScreen(),
                _buildChannelsTab(),
              ],
            ),
          ),
        ],
      ),
    );
  }

  /// Вкладка каналов (онлайн-only). Mesh не используется.
  Widget _buildChannelsTab() {
    final api = locator.isRegistered<ApiService>() ? locator<ApiService>() : null;
    final isOnline = api != null && !api.isGhostMode;

    if (!isOnline) {
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
                style: TextStyle(
                  color: AppColors.stealthOrange,
                  fontSize: 14,
                  fontWeight: FontWeight.bold,
                ),
                textAlign: TextAlign.center,
              ),
              const SizedBox(height: 8),
              Text(
                'Updates are delivered through the server when you are online.',
                style: TextStyle(color: AppColors.textDim, fontSize: 12),
                textAlign: TextAlign.center,
              ),
            ],
          ),
        ),
      );
    }
    return ChannelsTabContent(api: api!);
  }

  // --- 🔥 ВИЗИТКА МЕССЕНДЖЕРА: ОНЛАЙН / ОФФЛАЙН ---
  Widget _buildMessengerModeSwitch() {
    if (!locator.isRegistered<MeshService>()) return const SizedBox.shrink();
    final mesh = locator<MeshService>();
    return ListenableBuilder(
      listenable: mesh,
      builder: (context, _) {
        final offline = mesh.preferOfflineMode;
        return Container(
          width: double.infinity,
          padding: const EdgeInsets.fromLTRB(12, 10, 12, 8),
          decoration: BoxDecoration(
            color: Colors.black,
            border: Border(
              bottom: BorderSide(
                color: (offline ? Colors.cyanAccent : Colors.greenAccent)
                    .withOpacity(0.4),
                width: 1,
              ),
            ),
          ),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(
                'MESSENGER MODE',
                style: TextStyle(
                  color: Colors.white38,
                  fontSize: 9,
                  fontWeight: FontWeight.bold,
                  letterSpacing: 1.5,
                ),
              ),
              const SizedBox(height: 8),
              Row(
                children: [
                  Expanded(
                    child: _ModeSegment(
                      label: 'ONLINE',
                      subtitle: 'Cloud + mesh',
                      isSelected: !offline,
                      accent: Colors.greenAccent,
                      onTap: () {
                        mesh.setPreferOfflineMode(false);
                        setState(() {});
                      },
                    ),
                  ),
                  const SizedBox(width: 8),
                  Expanded(
                    child: _ModeSegment(
                      label: 'OFFLINE',
                      subtitle: 'Mesh only',
                      isSelected: offline,
                      accent: Colors.cyanAccent,
                      onTap: () {
                        mesh.setPreferOfflineMode(true);
                        setState(() {});
                      },
                    ),
                  ),
                ],
              ),
            ],
          ),
        );
      },
    );
  }

  // --- 🔥 ТАКТИЧЕСКИЙ HUD (HEADS-UP DISPLAY) ---
  Widget _buildTacticalHUD() {
    if (!locator.isRegistered<MeshService>()) {
      return Container(
        width: double.infinity,
        padding: const EdgeInsets.symmetric(vertical: 6),
        decoration: BoxDecoration(
          color: Colors.orangeAccent.withOpacity(0.05),
          border: Border(
              bottom: BorderSide(
                  color: Colors.orangeAccent.withOpacity(0.3), width: 0.5)),
        ),
        child: const Center(
            child: Text("MODE: STEALTH (AIR-GAP)",
                style: TextStyle(color: Colors.orangeAccent, fontSize: 11))),
      );
    }
    final mesh = locator<MeshService>();
    return StreamBuilder<MeshRole>(
      stream: NetworkMonitor().onRoleChanged,
      initialData: NetworkMonitor().currentRole,
      builder: (context, snapshot) {
        final bool isOnline = snapshot.data == MeshRole.BRIDGE;
        final bool isMesh = mesh.isP2pConnected;

        Color themeColor = isOnline
            ? Colors.greenAccent
            : (isMesh ? Colors.cyanAccent : Colors.orangeAccent);
        String statusText = isOnline
            ? "UPLINK: SECURED"
            : (isMesh ? "GRID: ACTIVE (P2P)" : "MODE: STEALTH (AIR-GAP)");

        return Container(
          width: double.infinity,
          padding: const EdgeInsets.symmetric(vertical: 6),
          decoration: BoxDecoration(
            color: themeColor.withOpacity(0.05),
            border: Border(
                bottom:
                    BorderSide(color: themeColor.withOpacity(0.3), width: 0.5)),
          ),
          child: Row(
            mainAxisAlignment: MainAxisAlignment.center,
            crossAxisAlignment: CrossAxisAlignment.center,
            children: [
              Center(child: _PulseDot(color: themeColor)),
              const SizedBox(width: 10),
              Text(
                statusText,
                style: TextStyle(
                  color: themeColor,
                  fontSize: 10,
                  fontWeight: FontWeight.bold,
                  letterSpacing: 1,
                  fontFamily: 'monospace',
                ),
              ),
              if (isMesh) ...[
                const SizedBox(width: 15),
                Text(
                  "|  RELAYS: ${mesh.nearbyNodes.length}",
                  style: TextStyle(
                      color: themeColor.withOpacity(0.5), fontSize: 9),
                ),
              ]
            ],
          ),
        );
      },
    );
  }

  Widget _buildGlobalTab() {
    if (_isLoading)
      return const Center(
          child: CircularProgressIndicator(color: Colors.redAccent));

    return RefreshIndicator(
      onRefresh: _loadChats,
      backgroundColor: Colors.grey[900],
      color: Colors.redAccent,
      child: ListView(
        padding: const EdgeInsets.symmetric(vertical: 8),
        children: [
          if (_beaconChat != null) _buildBeaconTile(_beaconChat),
          _buildNearbyTile(),
          _buildDonateTile(),
          Padding(
            padding: const EdgeInsets.fromLTRB(16, 20, 16, 8),
            child: Row(
              children: [
                const Icon(Icons.waves, color: Colors.white24, size: 12),
                const SizedBox(width: 8),
                const Text(
                  "NEIGHBORHOOD FREQUENCIES",
                  style: TextStyle(
                    color: Colors.white24,
                    fontSize: 9,
                    fontWeight: FontWeight.bold,
                    letterSpacing: 1,
                  ),
                ),
              ],
            ),
          ),
          FutureBuilder<List<dynamic>>(
            future: locator.isRegistered<ApiService>()
                ? locator<ApiService>().getTrendingBranches()
                : Future.value(<dynamic>[]),
            builder: (context, snapshot) {
              final branches = snapshot.data ?? [];
              if (branches.isEmpty) return const SizedBox.shrink();
              return Column(
                  children: branches
                      .where((b) => !BeaconCountryHelper.isBeaconChat(b['id']?.toString()))
                      .map((b) => _buildBranchTile(b))
                      .toList());
            },
          ),
        ],
      ),
    );
  }

  Widget _buildBeaconTile(dynamic chat) {
    return FadeInLeft(
      child: Container(
        margin: const EdgeInsets.symmetric(horizontal: 12, vertical: 4),
        decoration: BoxDecoration(
          gradient: LinearGradient(
              colors: [Colors.redAccent.withOpacity(0.15), Colors.transparent]),
          borderRadius: BorderRadius.circular(12),
          border: Border.all(color: Colors.redAccent.withOpacity(0.3)),
        ),
        child: ListTile(
          leading: SizedBox(
            width: 48,
            height: 48,
            child: Pulse(
                child: Center(
                    child: const Icon(Icons.warning_amber_rounded,
                        color: Colors.redAccent, size: 28)),
                infinite: true),
          ),
          title: const Text(
            "THE BEACON",
            style: TextStyle(
              color: Colors.white,
              fontSize: 16,
              fontWeight: FontWeight.bold,
              letterSpacing: 1,
            ),
          ),
          subtitle: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            mainAxisSize: MainAxisSize.min,
            children: [
              Text(
                BeaconCountryHelper.beaconCountryDisplayName(BeaconCountryHelper.beaconChatIdForCountry()).toUpperCase() + " // BROADCASTING",
                style: const TextStyle(
                    color: Colors.redAccent,
                    fontSize: 8,
                    fontWeight: FontWeight.bold),
              ),
              const SizedBox(height: 2),
              Text(
                AppLocalizations.of(context)!.beaconHoldToChangeCountry,
                style: TextStyle(
                  fontSize: 10,
                  color: Colors.white.withOpacity(0.35),
                  fontStyle: FontStyle.italic,
                ),
              ),
            ],
          ),
          trailing: const Icon(Icons.chevron_right, color: Colors.white24),
          onTap: () => _openBeaconChat(),
          onLongPress: () => _showBeaconCountryPicker(context),
        ),
      ),
    );
  }

  static const _beaconWarningKey = 'beacon_country_warning_seen';

  Future<void> _openBeaconChat() async {
    final prefs = await SharedPreferences.getInstance();
    final seen = prefs.getBool(_beaconWarningKey) ?? false;
    if (!seen && mounted) {
      await showDialog<void>(
        context: context,
        builder: (ctx) => AlertDialog(
          backgroundColor: Colors.grey[900],
          title: Text(
            AppLocalizations.of(context)!.beaconWarningTitle,
            style: const TextStyle(color: Colors.white, fontSize: 16),
          ),
          content: Text(
            AppLocalizations.of(context)!.beaconWarningMessage,
            style: const TextStyle(color: Colors.white70, fontSize: 14),
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.of(ctx).pop(),
              child: Text(
                AppLocalizations.of(context)!.beaconUnderstood,
                style: const TextStyle(color: Colors.redAccent),
              ),
            ),
          ],
        ),
      );
      await prefs.setBool(_beaconWarningKey, true);
    }
    if (!mounted) return;
    final beaconChatId = BeaconCountryHelper.beaconChatIdForCountry();
    _openChat(beaconChatId, 'THE BEACON', beaconChatId);
  }

  void _showBeaconCountryPicker(BuildContext context) {
    final choices = BeaconCountryHelper.countryChoicesForPicker;
    final maxHeight = MediaQuery.of(context).size.height * 0.6;
    showModalBottomSheet<void>(
      context: context,
      backgroundColor: Colors.grey[900],
      builder: (ctx) {
        return SafeArea(
          child: ConstrainedBox(
            constraints: BoxConstraints(maxHeight: maxHeight),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                Padding(
                  padding: const EdgeInsets.all(12.0),
                  child: Text(
                    'Страна для THE BEACON',
                    style: TextStyle(
                      color: Colors.white,
                      fontSize: 16,
                      fontWeight: FontWeight.bold,
                    ),
                  ),
                ),
                Flexible(
                  child: ListView.builder(
                    shrinkWrap: true,
                    itemCount: choices.length,
                    itemBuilder: (context, index) {
                      final e = choices[index];
                      final code = e.key;
                      final name = e.value;
                      final isSelected = (code.isEmpty && (BeaconCountryHelper.countryOverride == null || BeaconCountryHelper.countryOverride == '')) ||
                          (code.isNotEmpty && BeaconCountryHelper.countryOverride == code);
                      return ListTile(
                        title: Text(name, style: TextStyle(color: Colors.white)),
                        trailing: isSelected ? Icon(Icons.check, color: Colors.redAccent) : null,
                        onTap: () async {
                          await BeaconCountryHelper.setCountryOverride(code.isEmpty ? '' : code);
                          if (ctx.mounted) Navigator.of(ctx).pop();
                          if (mounted) setState(() {});
                        },
                      );
                    },
                  ),
                ),
              ],
            ),
          ),
        );
      },
    );
  }

  Widget _buildNearbyTile() {
    return FadeInLeft(
      child: Container(
        margin: const EdgeInsets.symmetric(horizontal: 12, vertical: 4),
        decoration: BoxDecoration(
          gradient: LinearGradient(
              colors: [Colors.blue.withOpacity(0.12), Colors.transparent]),
          borderRadius: BorderRadius.circular(12),
          border: Border.all(color: Colors.blue.withOpacity(0.3)),
        ),
        child: ListTile(
          leading: const Icon(Icons.people_outline, color: Colors.blue, size: 28),
          title: const Text(
            "Рядом",
            style: TextStyle(
              color: Colors.white,
              fontSize: 16,
              fontWeight: FontWeight.bold,
            ),
          ),
          subtitle: const Text("Кто рядом по BLE / Wi‑Fi — без геолокации",
              style: TextStyle(color: Colors.blue, fontSize: 10)),
          trailing: const Icon(Icons.chevron_right, color: Colors.white24),
          onTap: () => _openChat('BEACON_NEARBY', 'Рядом', 'BEACON_NEARBY'),
        ),
      ),
    );
  }

  Widget _buildDonateTile() {
    return FadeInLeft(
      child: Container(
        margin: const EdgeInsets.symmetric(horizontal: 12, vertical: 4),
        decoration: BoxDecoration(
          gradient: LinearGradient(
              colors: [Colors.greenAccent.withOpacity(0.12), Colors.transparent],
              begin: Alignment.centerLeft,
              end: Alignment.centerRight),
          borderRadius: BorderRadius.circular(12),
          border: Border.all(color: Colors.greenAccent.withOpacity(0.3)),
        ),
        child: ListTile(
          leading: const Icon(Icons.volunteer_activism,
              color: Colors.greenAccent, size: 28),
          title: const Text(
            "SUPPORT / DONATE",
            style: TextStyle(
              color: Colors.white,
              fontSize: 14,
              fontWeight: FontWeight.bold,
              letterSpacing: 1,
            ),
          ),
          subtitle: const Text(
            "CRYPTO • DONATION LINK",
            style: TextStyle(
              color: Colors.greenAccent,
              fontSize: 8,
              fontWeight: FontWeight.bold,
            ),
          ),
          trailing: const Icon(Icons.chevron_right, color: Colors.white24),
          onTap: () => Navigator.of(context).push(
            MaterialPageRoute(builder: (_) => const DonateScreen()),
          ),
        ),
      ),
    );
  }

  Widget _buildChatList(List<dynamic> chats, String emptyMsg) {
    if (_isLoading)
      return const Center(
          child: CircularProgressIndicator(color: Colors.white));
    if (chats.isEmpty) {
      return Center(
        child: Text(
          emptyMsg,
          style: const TextStyle(
            color: Colors.white10,
            fontSize: 12,
            fontFamily: 'monospace',
          ),
        ),
      );
    }

    return ListView.separated(
      padding: const EdgeInsets.all(8),
      itemCount: chats.length,
      separatorBuilder: (_, __) => const SizedBox(height: 4),
      itemBuilder: (context, index) {
        final chat = chats[index];
        final String title = chat['type'] == 'DIRECT'
            ? (chat['otherUser']?['username'] ?? 'Anonymous')
            : (chat['name'] ?? 'Squad Alpha');

        final String sub = chat['type'] == 'DIRECT'
            ? "Direct Link established"
            : "Mesh Squad Active";

        return ListTile(
          tileColor: const Color(0xFF0A0A0A),
          shape:
              RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
          leading: CircleAvatar(
            // 🔥 ИСПРАВЛЕНО ЗДЕСЬ:
            backgroundColor: Colors.white.withOpacity(0.05),
            child: Icon(
                chat['type'] == 'GROUP'
                    ? Icons.groups_3_outlined
                    : Icons.person_outline,
                color: Colors.white38),
          ),
          title: Text(
            title,
            style: const TextStyle(
                color: Colors.white, fontWeight: FontWeight.bold, fontSize: 14),
          ),
          subtitle: Text(
            sub,
            style: const TextStyle(
              color: Colors.white24,
              fontSize: 9,
              fontFamily: 'monospace',
            ),
          ),
          onTap: () => _openChat(
              chat['type'] == 'DIRECT' ? chat['otherUser']['id'] : '',
              title,
              chat['id']),
        );
      },
    );
  }

  Widget _buildBranchTile(dynamic branch) {
    return ListTile(
      leading: const Icon(Icons.radar, color: Colors.white10, size: 20),
      title: Text(branch['name'] ?? 'Public Freq',
          style: const TextStyle(color: Colors.white70, fontSize: 14)),
      subtitle: const Text("Relaying nearby signals",
          style: TextStyle(color: Colors.white10, fontSize: 10)),
      onTap: () => _openChat('', branch['name'], branch['id']),
    );
  }

  void _openChat(String friendId, String name, String? roomId) {
    Navigator.of(context).push(MaterialPageRoute(
      builder: (_) => ConversationScreen(
          friendId: friendId, friendName: name, chatRoomId: roomId),
    ));
  }
}

/// Сегмент переключателя режима ONLINE / OFFLINE.
class _ModeSegment extends StatelessWidget {
  final String label;
  final String subtitle;
  final bool isSelected;
  final Color accent;
  final VoidCallback onTap;

  const _ModeSegment({
    required this.label,
    required this.subtitle,
    required this.isSelected,
    required this.accent,
    required this.onTap,
  });

  @override
  Widget build(BuildContext context) {
    return Material(
      color: isSelected ? accent.withOpacity(0.15) : Colors.white.withOpacity(0.03),
      borderRadius: BorderRadius.circular(10),
      child: InkWell(
        onTap: onTap,
        borderRadius: BorderRadius.circular(10),
        child: Container(
          padding: const EdgeInsets.symmetric(vertical: 12, horizontal: 8),
          decoration: BoxDecoration(
            borderRadius: BorderRadius.circular(10),
            border: Border.all(
              color: isSelected ? accent.withOpacity(0.7) : Colors.white12,
              width: isSelected ? 1.5 : 0.5,
            ),
          ),
          child: Column(
            children: [
              Text(
                label,
                style: TextStyle(
                  color: isSelected ? accent : Colors.white54,
                  fontSize: 12,
                  fontWeight: FontWeight.bold,
                  letterSpacing: 1.2,
                ),
              ),
              const SizedBox(height: 2),
              Text(
                subtitle,
                style: TextStyle(
                  color: isSelected ? accent.withOpacity(0.9) : Colors.white24,
                  fontSize: 8,
                  letterSpacing: 0.5,
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

class _PulseDot extends StatefulWidget {
  final Color color;
  const _PulseDot({required this.color});

  @override
  State<_PulseDot> createState() => _PulseDotState();
}

class _PulseDotState extends State<_PulseDot>
    with SingleTickerProviderStateMixin {
  late AnimationController _controller;
  @override
  void initState() {
    super.initState();
    _controller =
        AnimationController(vsync: this, duration: const Duration(seconds: 2))
          ..repeat(reverse: true);
  }

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return AnimatedBuilder(
      animation: _controller,
      builder: (context, child) => Container(
        width: 8,
        height: 8,
        decoration: BoxDecoration(
            shape: BoxShape.circle,
            color: widget.color,
            boxShadow: [
              BoxShadow(
                  color: widget.color,
                  blurRadius: 4 + _controller.value * 6,
                  spreadRadius: _controller.value * 2)
            ]),
      ),
    );
  }
}
