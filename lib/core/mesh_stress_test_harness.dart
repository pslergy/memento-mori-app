// 🔒 Stress test harness для mesh-системы.
// Изолированный режим: при MESH_STRESS_TEST_MODE == true можно запускать
// симуляцию входящего трафика. Production-логика не меняется.

import 'dart:async';
import 'dart:math' as math;

import 'extended_identity_test_mode.dart';
import 'gossip_manager.dart';
import 'locator.dart';
import 'mesh_service.dart';

/// Включение режима стресс-теста. При false система работает как обычно.
bool MESH_STRESS_TEST_MODE = false;

/// Время старта расширенного churn-теста (для UI: elapsed). null когда тест не идёт.
DateTime? _extendedChurnStartTime;
DateTime? get extendedChurnStartTime => _extendedChurnStartTime;

/// Результат одного прогона стресс-теста.
class StressTestResult {
  final int incomingTotal;
  final int acceptedTotal;
  final int relayAttempts;
  final int relayDroppedByBudget;
  final int waveDedupHits;
  final int identityCleanupRuns;
  final int maxIdentityFirstSeen;
  final int maxProcessedWaves;
  final int maxGenerationWindowSize;
  final Duration duration;
  final bool hadCrash;
  final double? avgRelayAttemptsPerMinute;

  StressTestResult({
    required this.incomingTotal,
    required this.acceptedTotal,
    required this.relayAttempts,
    required this.relayDroppedByBudget,
    required this.waveDedupHits,
    required this.identityCleanupRuns,
    required this.maxIdentityFirstSeen,
    required this.maxProcessedWaves,
    required this.maxGenerationWindowSize,
    required this.duration,
    required this.hadCrash,
    this.avgRelayAttemptsPerMinute,
  });

  @override
  String toString() {
    final min = duration.inSeconds / 60.0;
    return '''
=== STRESS TEST RESULT ===
incomingTotal: $incomingTotal
acceptedTotal: $acceptedTotal
relayAttempts: $relayAttempts
relayDroppedByBudget: $relayDroppedByBudget
waveDedupHits: $waveDedupHits
identityCleanupRuns: $identityCleanupRuns
maxIdentityFirstSeen: $maxIdentityFirstSeen
maxProcessedWaves: $maxProcessedWaves
maxGenerationWindowSize: $maxGenerationWindowSize
duration: ${duration.inSeconds}s (${min.toStringAsFixed(1)} min)
hadCrash: $hadCrash
avgRelayAttempts/min: ${avgRelayAttemptsPerMinute?.toStringAsFixed(1) ?? 'n/a'}
==========================''';
  }
}

/// Результат расширенного Identity Churn теста.
class ExtendedChurnResult {
  final Duration duration;
  final int maxIdentityFirstSeen;
  final int identityCleanupRuns;
  final int maxGenerationWindowSize;
  final int relayAttempts;
  final int relayDroppedByBudget;
  final bool hadCrash;

  ExtendedChurnResult({
    required this.duration,
    required this.maxIdentityFirstSeen,
    required this.identityCleanupRuns,
    required this.maxGenerationWindowSize,
    required this.relayAttempts,
    required this.relayDroppedByBudget,
    required this.hadCrash,
  });

  @override
  String toString() {
    return '''
=== EXTENDED CHURN RESULT ===
duration: ${duration.inMinutes}m ${duration.inSeconds % 60}s
maxIdentityFirstSeen: $maxIdentityFirstSeen
identityCleanupRuns: $identityCleanupRuns
maxGenerationWindow: $maxGenerationWindowSize
relayAttempts: $relayAttempts
relayDroppedByBudget: $relayDroppedByBudget
hadCrash: $hadCrash
=============================''';
  }
}

/// Расширенный Identity Churn Stress Test. Пакеты идут только через processIncomingPacket(),
/// rate limiter и guards не обходятся. Транспорт, TTL, relay тайминги не меняются.
Future<ExtendedChurnResult> simulateIdentityChurn({
  Duration duration = const Duration(minutes: 15),
  Duration identityRotationInterval = const Duration(seconds: 2),
  int messagesPerMinute = 60,
}) async {
  if (!EXTENDED_IDENTITY_TEST_MODE) {
    throw StateError(
        'EXTENDED_IDENTITY_TEST_MODE must be true to run extended churn test');
  }

  final mesh = locator<MeshService>();
  final gossip = locator<GossipManager>();
  gossip.resetStressTestCounters();

  _extendedChurnStartTime = DateTime.now();
  final stopwatch = Stopwatch()..start();
  final endTime = DateTime.now().add(duration);
  DateTime lastIdentityRotation = _extendedChurnStartTime!;
  String currentIdentityKey = 'churn_identity_${lastIdentityRotation.millisecondsSinceEpoch}';
  DateTime lastStatusLog = _extendedChurnStartTime!;

  int maxIdentityFirstSeen = 0;
  int maxGenerationWindowSize = 0;
  bool hadCrash = false;

  try {
    while (DateTime.now().isBefore(endTime)) {
      final now = DateTime.now();

      if (now.difference(lastIdentityRotation).inSeconds >= identityRotationInterval.inSeconds) {
        currentIdentityKey = 'churn_identity_${now.millisecondsSinceEpoch}';
        lastIdentityRotation = now;
      }

      final perSec = (messagesPerMinute / 60).ceil().clamp(1, 120);
      for (var i = 0; i < perSec; i++) {
        final ts = now.millisecondsSinceEpoch + i;
        final packet = <String, dynamic>{
          'type': 'OFFLINE_MSG',
          'content': 'churn_msg_${ts}_$i',
          'senderId': 'churn_sender_$currentIdentityKey',
          'identityKey': currentIdentityKey,
          'chatId': 'THE_BEACON_GLOBAL',
          'timestamp': ts,
          'h': 'churn_h_${ts}_$i',
          'ttl': 5,
          'senderIp': '127.0.0.1',
        };
        await mesh.processIncomingPacket(packet);
      }

      final snap = gossip.getStressTestSnapshot();
      if (snap['currentIdentityCount']! > maxIdentityFirstSeen) {
        maxIdentityFirstSeen = snap['currentIdentityCount']!;
      }
      if (snap['currentGenerationWindowSize']! > maxGenerationWindowSize) {
        maxGenerationWindowSize = snap['currentGenerationWindowSize']!;
      }

      if (now.difference(lastStatusLog).inSeconds >= 30) {
        lastStatusLog = now;
        final elapsed = now.difference(_extendedChurnStartTime!);
        final relayAttempts = snap['relayAttempts']!;
        final relayPerMin = elapsed.inMinutes > 0
            ? (relayAttempts / (elapsed.inMinutes + elapsed.inSeconds / 60.0)).round()
            : relayAttempts;
        mesh.addLog('''
=== EXTENDED CHURN STATUS ===
elapsed: ${elapsed.inMinutes}m ${elapsed.inSeconds % 60}s
active identities: ${snap['currentIdentityCount']}
max identities: $maxIdentityFirstSeen
cleanup runs: ${snap['identityCleanupRuns']}
generation window: ${snap['currentGenerationWindowSize']}
relay attempts/min: $relayPerMin
=============================''');
      }

      await Future.delayed(const Duration(seconds: 1));
    }
  } catch (e, st) {
    hadCrash = true;
    mesh.addLog('❌ [EXTENDED CHURN] Crash: $e\n$st');
  } finally {
    stopwatch.stop();
    _extendedChurnStartTime = null;
    EXTENDED_IDENTITY_TEST_MODE = false;
  }

  final snap = gossip.getStressTestSnapshot();
  final elapsed = stopwatch.elapsed;

  final result = ExtendedChurnResult(
    duration: elapsed,
    maxIdentityFirstSeen: maxIdentityFirstSeen > 0 ? maxIdentityFirstSeen : snap['currentIdentityCount']!,
    identityCleanupRuns: snap['identityCleanupRuns']!,
    maxGenerationWindowSize: maxGenerationWindowSize > 0 ? maxGenerationWindowSize : snap['currentGenerationWindowSize']!,
    relayAttempts: snap['relayAttempts']!,
    relayDroppedByBudget: snap['relayDroppedByBudget']!,
    hadCrash: hadCrash,
  );

  mesh.addLog(result.toString());
  return result;
}

/// Симулирует входящий трафик: передаёт пакеты в processIncomingPacket.
/// Rate limit и guards не обходятся — пакеты проходят полный пайплайн.
Future<StressTestResult> simulateIncomingTraffic({
  required int messagesPerMinute,
  required int wavePerMinute,
  required int fragmentMessagesPerMinute,
  required Duration duration,
  String? identityKeyOverride,
  bool rotateIdentityEvery2Sec = false,
}) async {
  if (!MESH_STRESS_TEST_MODE) {
    throw StateError(
        'MESH_STRESS_TEST_MODE must be true to run stress test');
  }

  final mesh = locator<MeshService>();
  final gossip = locator<GossipManager>();
  gossip.resetStressTestCounters();

  int incomingTotal = 0;
  int maxIdentityFirstSeen = 0;
  int maxProcessedWaves = 0;
  int maxGenerationWindowSize = 0;
  bool hadCrash = false;
  DateTime? lastIdentityRotation;
  String currentIdentityKey = identityKeyOverride ?? 'stress_identity_0';

  final stopwatch = Stopwatch()..start();
  final endTime = DateTime.now().add(duration);
  DateTime lastLogTime = DateTime.now();
  int lastAccepted = 0;
  int lastRelayAttempts = 0;
  int lastRelayDroppedByBudget = 0;
  int lastWaveDedupHits = 0;

  void logStatus() {
    final snap = gossip.getStressTestSnapshot();
    final now = DateTime.now();
    final elapsedSec = now.difference(lastLogTime).inSeconds.clamp(1, 3600);
    final acceptedDelta = snap['acceptedTotal']! - lastAccepted;
    final relayDelta = snap['relayAttempts']! - lastRelayAttempts;
    final budgetDelta = snap['relayDroppedByBudget']! - lastRelayDroppedByBudget;
    final waveDelta = snap['waveDedupHits']! - lastWaveDedupHits;
    lastAccepted = snap['acceptedTotal']!;
    lastRelayAttempts = snap['relayAttempts']!;
    lastRelayDroppedByBudget = snap['relayDroppedByBudget']!;
    lastWaveDedupHits = snap['waveDedupHits']!;
    lastLogTime = now;

    final totalMin = stopwatch.elapsed.inSeconds / 60;
    final incomingPerMin = totalMin > 0 ? (incomingTotal / totalMin).round() : 0;
    final acceptedPerMin = (acceptedDelta / (elapsedSec / 60)).round();
    final relayedPerMin = (relayDelta / (elapsedSec / 60)).round();
    final budgetDropsPerMin = (budgetDelta / (elapsedSec / 60)).round();
    final waveDedupPerMin = (waveDelta / (elapsedSec / 60)).round();

    mesh.addLog('''
=== STRESS STATUS ===
incoming/min: $incomingPerMin
accepted/min: $acceptedPerMin
relayed/min: $relayedPerMin
budget drops/min: $budgetDropsPerMin
wave dedup hits/min: $waveDedupPerMin
active identities: ${snap['currentIdentityCount']}
generation window size: ${snap['currentGenerationWindowSize']}
unified window size: ${snap['currentUnifiedWindowSize']}
=====================''');
  }

  try {
    while (DateTime.now().isBefore(endTime)) {
      final now = DateTime.now();
      if (rotateIdentityEvery2Sec &&
          (lastIdentityRotation == null ||
              now.difference(lastIdentityRotation).inSeconds >= 2)) {
        currentIdentityKey = 'stress_identity_${now.millisecondsSinceEpoch}';
        lastIdentityRotation = now;
      }

      final perSecMessages = (messagesPerMinute / 60).ceil();
      final perSecWaves = (wavePerMinute / 60).ceil();
      final perSecFragmentMessages = (fragmentMessagesPerMinute / 60).ceil();

      for (var i = 0; i < perSecMessages; i++) {
        final ts = DateTime.now().millisecondsSinceEpoch;
        final packet = <String, dynamic>{
          'type': 'OFFLINE_MSG',
          'content': 'stress_msg_${ts}_$i',
          'senderId': 'stress_sender_$currentIdentityKey',
          'identityKey': currentIdentityKey,
          'chatId': 'THE_BEACON_GLOBAL',
          'timestamp': ts,
          'h': 'stress_h_${ts}_$i',
          'ttl': 5,
          'senderIp': '127.0.0.1',
        };
        incomingTotal++;
        await mesh.processIncomingPacket(packet);
      }

      for (var i = 0; i < perSecWaves; i++) {
        final ts = DateTime.now().millisecondsSinceEpoch;
        final packet = <String, dynamic>{
          'type': 'MAGNET_WAVE',
          'senderId': 'wave_sender_${ts}_$i',
          'hops': math.Random().nextInt(10),
          'senderIp': '127.0.0.1',
        };
        incomingTotal++;
        await mesh.processIncomingPacket(packet);
      }

      for (var i = 0; i < perSecFragmentMessages; i++) {
        final mid = 'stress_mid_${now.millisecondsSinceEpoch}_$i';
        final tot = 3 + math.Random().nextInt(3);
        for (var idx = 0; idx < tot; idx++) {
          final packet = <String, dynamic>{
            'type': 'MSG_FRAG',
            'mid': mid,
            'idx': idx,
            'tot': tot,
            'data': 'frag_${mid}_$idx',
            'senderId': 'stress_sender_$currentIdentityKey',
            'identityKey': currentIdentityKey,
            'chatId': 'THE_BEACON_GLOBAL',
            'senderIp': '127.0.0.1',
          };
          incomingTotal++;
          await mesh.processIncomingPacket(packet);
        }
      }

      final snap = gossip.getStressTestSnapshot();
      if (snap['currentIdentityCount']! > maxIdentityFirstSeen) {
        maxIdentityFirstSeen = snap['currentIdentityCount']!;
      }
      if (snap['currentProcessedWavesSize']! > maxProcessedWaves) {
        maxProcessedWaves = snap['currentProcessedWavesSize']!;
      }
      if (snap['currentGenerationWindowSize']! > maxGenerationWindowSize) {
        maxGenerationWindowSize = snap['currentGenerationWindowSize']!;
      }

      if (DateTime.now().difference(lastLogTime).inSeconds >= 10) {
        logStatus();
      }

      await Future.delayed(const Duration(seconds: 1));
    }
  } catch (e, st) {
    hadCrash = true;
    mesh.addLog('❌ [STRESS] Crash: $e\n$st');
  }

  stopwatch.stop();
  final snap = gossip.getStressTestSnapshot();
  final dur = stopwatch.elapsed;
  final min = dur.inSeconds / 60.0;

  return StressTestResult(
    incomingTotal: incomingTotal,
    acceptedTotal: snap['acceptedTotal']!,
    relayAttempts: snap['relayAttempts']!,
    relayDroppedByBudget: snap['relayDroppedByBudget']!,
    waveDedupHits: snap['waveDedupHits']!,
    identityCleanupRuns: snap['identityCleanupRuns']!,
    maxIdentityFirstSeen: maxIdentityFirstSeen > 0 ? maxIdentityFirstSeen : snap['currentIdentityCount']!,
    maxProcessedWaves: maxProcessedWaves > 0 ? maxProcessedWaves : snap['currentProcessedWavesSize']!,
    maxGenerationWindowSize: maxGenerationWindowSize > 0 ? maxGenerationWindowSize : snap['currentGenerationWindowSize']!,
    duration: dur,
    hadCrash: hadCrash,
    avgRelayAttemptsPerMinute: min > 0 ? snap['relayAttempts']! / min : null,
  );
}

/// Сценарий A — нормальная нагрузка.
Future<StressTestResult> runScenarioA() async {
  return simulateIncomingTraffic(
    messagesPerMinute: 30,
    wavePerMinute: 10,
    fragmentMessagesPerMinute: 5,
    duration: const Duration(minutes: 5),
  );
}

/// Сценарий B — высокая нагрузка.
Future<StressTestResult> runScenarioB() async {
  return simulateIncomingTraffic(
    messagesPerMinute: 120,
    wavePerMinute: 40,
    fragmentMessagesPerMinute: 20,
    duration: const Duration(minutes: 5),
  );
}

/// Сценарий C — ротация identity каждые 2 секунды.
Future<StressTestResult> runScenarioC() async {
  return simulateIncomingTraffic(
    messagesPerMinute: 60,
    wavePerMinute: 0,
    fragmentMessagesPerMinute: 0,
    duration: const Duration(minutes: 5),
    rotateIdentityEvery2Sec: true,
  );
}

/// Запускает сценарий и выводит итоговый отчёт в лог MeshService.
/// Перед вызовом установите MESH_STRESS_TEST_MODE = true и убедитесь, что locator инициализирован.
Future<StressTestResult> runScenarioAndPrint(
  String scenarioName,
  Future<StressTestResult> Function() scenario,
) async {
  final mesh = locator<MeshService>();
  mesh.addLog('🔄 [STRESS] Starting scenario: $scenarioName');
  final result = await scenario();
  mesh.addLog('$result');
  mesh.addLog(
      '📊 [STRESS] maxIdentityFirstSeen=${result.maxIdentityFirstSeen} maxProcessedWaves=${result.maxProcessedWaves} maxGenerationWindow=${result.maxGenerationWindowSize} crash=${result.hadCrash}');
  return result;
}
