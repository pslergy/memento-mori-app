import 'dart:async';

/// 🔥 PEER CACHE SERVICE - Локальная память сети
/// 
/// Хранит метрики взаимодействия с пирами БЕЗ синхронизации.
/// Используется ТОЛЬКО для локальных эвристик и выбора каналов.
/// 
/// ❗ КРИТИЧНО: Не влияет на существующую логику доставки.
/// Если метрики недоступны → fallback к текущему поведению.
class PeerCacheService {
  static final PeerCacheService _instance = PeerCacheService._internal();
  factory PeerCacheService() => _instance;
  PeerCacheService._internal() {
    // Периодическая очистка устаревших записей
    _cleanupTimer = Timer.periodic(const Duration(minutes: 5), (_) => _cleanup());
  }

  final Map<String, PeerMetrics> _peers = {};
  Timer? _cleanupTimer;

  /// Получить метрики пира
  PeerMetrics? getPeer(String peerId) {
    return _peers[peerId];
  }

  /// Обновить метрики после успешной передачи
  void recordSuccess({
    required String peerId,
    required Duration latency,
    String? channel,
  }) {
    final metrics = _peers.putIfAbsent(
      peerId,
      () => PeerMetrics(peerId: peerId),
    );

    metrics.recordSuccess(latency, channel);
  }

  /// Обновить метрики после неудачной передачи
  void recordFailure({
    required String peerId,
    String? channel,
    String? reason,
  }) {
    final metrics = _peers.putIfAbsent(
      peerId,
      () => PeerMetrics(peerId: peerId),
    );

    metrics.recordFailure(channel, reason);
  }

  /// Обновить наблюдение роли пира
  void recordRoleObservation({
    required String peerId,
    required String role, // "BRIDGE" или "GHOST"
  }) {
    final metrics = _peers.putIfAbsent(
      peerId,
      () => PeerMetrics(peerId: peerId),
    );

    metrics.recordRoleObservation(role);
  }

  /// Вычислить bridge_score для пира.
  /// 🔒 P1: Деградация метрик со временем — устаревшие аплинки получают меньший вес (свежесть по lastSeen).
  /// Формула: base_score * freshness; base = hasInternet + successRate*50 - latency/10 - hops*5.
  double? calculateBridgeScore({
    required String peerId,
    required bool hasInternet,
    required int hops,
  }) {
    final metrics = _peers[peerId];
    if (metrics == null) return null;

    double score = hasInternet ? 100.0 : 0.0;
    score += metrics.successRate * 50.0;
    score -= metrics.avgLatency.inMilliseconds / 10.0;
    score -= hops * 5.0;

    // 🔒 P1: Свежесть — снижаем вес при старых lastSeen (без изменения логики доставки, только scoring)
    final age = DateTime.now().difference(metrics.lastSeen);
    double freshness = 1.0;
    if (age.inMinutes > 60) {
      freshness = 0.2;
    } else if (age.inMinutes > 15) {
      freshness = 0.4;
    } else if (age.inMinutes > 5) {
      freshness = 0.7;
    }
    score *= freshness;

    return score.clamp(0.0, 200.0);
  }

  /// Очистка устаревших записей (старше 1 часа)
  void _cleanup() {
    final now = DateTime.now();
    final expired = <String>[];

    for (final entry in _peers.entries) {
      if (now.difference(entry.value.lastSeen).inHours > 1) {
        expired.add(entry.key);
      }
    }

    for (final id in expired) {
      _peers.remove(id);
    }
  }

  /// Очистить все метрики (для тестирования)
  void clear() {
    _peers.clear();
  }

  /// Получить статистику
  Map<String, dynamic> getStats() {
    return {
      'totalPeers': _peers.length,
      'bridges': _peers.values.where((p) => p.observedRoles.contains('BRIDGE')).length,
      'ghosts': _peers.values.where((p) => p.observedRoles.contains('GHOST')).length,
    };
  }

  void dispose() {
    _cleanupTimer?.cancel();
    _peers.clear();
  }
}

/// Метрики взаимодействия с пиром
class PeerMetrics {
  final String peerId;
  DateTime lastSeen;
  
  // Статистика успешности
  int totalAttempts = 0;
  int totalSuccesses = 0;
  final List<Duration> latencies = [];
  
  // Наблюдаемые роли
  final Set<String> observedRoles = {};
  
  // Статистика по каналам
  final Map<String, ChannelStats> channelStats = {};

  PeerMetrics({
    required this.peerId,
  }) : lastSeen = DateTime.now();

  /// Записать успешную передачу
  void recordSuccess(Duration latency, String? channel) {
    lastSeen = DateTime.now();
    totalAttempts++;
    totalSuccesses++;
    
    latencies.add(latency);
    if (latencies.length > 100) {
      latencies.removeAt(0); // Ограничиваем историю
    }

    if (channel != null) {
      channelStats.putIfAbsent(channel, () => ChannelStats(channel: channel))
          .recordSuccess(latency);
    }
  }

  /// Записать неудачную передачу
  void recordFailure(String? channel, String? reason) {
    lastSeen = DateTime.now();
    totalAttempts++;

    if (channel != null) {
      channelStats.putIfAbsent(channel, () => ChannelStats(channel: channel))
          .recordFailure();
    }
  }

  /// Записать наблюдение роли
  void recordRoleObservation(String role) {
    observedRoles.add(role);
    lastSeen = DateTime.now();
  }

  /// Успешность (0.0 - 1.0)
  double get successRate {
    if (totalAttempts == 0) return 0.5; // Неизвестно - средний приоритет
    return totalSuccesses / totalAttempts;
  }

  /// Средняя задержка
  Duration get avgLatency {
    if (latencies.isEmpty) return const Duration(seconds: 5); // Дефолт
    final sum = latencies.fold<int>(
      0,
      (acc, d) => acc + d.inMilliseconds,
    );
    return Duration(milliseconds: sum ~/ latencies.length);
  }

  /// Лучший канал по успешности
  String? get bestChannel {
    if (channelStats.isEmpty) return null;
    
    String? best;
    double bestRate = 0.0;
    
    for (final stats in channelStats.values) {
      if (stats.successRate > bestRate) {
        bestRate = stats.successRate;
        best = stats.channel;
      }
    }
    
    return best;
  }
}

/// Статистика по каналу
class ChannelStats {
  final String channel;
  int attempts = 0;
  int successes = 0;
  final List<Duration> latencies = [];

  ChannelStats({required this.channel});

  void recordSuccess(Duration latency) {
    attempts++;
    successes++;
    latencies.add(latency);
    if (latencies.length > 50) {
      latencies.removeAt(0);
    }
  }

  void recordFailure() {
    attempts++;
  }

  double get successRate {
    if (attempts == 0) return 0.5;
    return successes / attempts;
  }

  Duration get avgLatency {
    if (latencies.isEmpty) return const Duration(seconds: 5);
    final sum = latencies.fold<int>(
      0,
      (acc, d) => acc + d.inMilliseconds,
    );
    return Duration(milliseconds: sum ~/ latencies.length);
  }
}
