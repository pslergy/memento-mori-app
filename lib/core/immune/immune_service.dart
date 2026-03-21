// lib/core/immune/immune_service.dart
//
// Оркестратор системы иммунных чанков.
// Дневник попыток (локально) + кэш рецептов (из gossip, при включённом feature).
// Transport-agnostic: не содержит BLE/HTTP — только данные и логика.

import 'dart:async';

import 'attempt_log.dart';
import 'attempt_log_repository.dart';
import 'immune_chunk.dart';
import 'immune_constants.dart';
import 'recipe_cache.dart';
import '../internet/tunnel_config.dart';
import '../storage_service.dart';

class ImmuneService {
  final AttemptLogRepository _attemptRepo = AttemptLogRepository();
  final RecipeCache _recipeCache = RecipeCache();

  DateTime? _lastImmuneGossipEmitAt;
  String? _lastImmuneGossipRecipeHash;

  /// Записать попытку подключения (fire-and-forget).
  /// Вызывать асинхронно после попытки, не блокирует.
  void logAttempt(AttemptLog log) {
    unawaited(_attemptRepo.insert(log));
  }

  /// Получить последние записи дневника.
  Future<List<AttemptLog>> getRecentAttempts({int limit = 100}) =>
      _attemptRepo.getRecent(limit: limit);

  /// Получить записи по донору и режиму.
  Future<List<AttemptLog>> getAttemptsByDonorAndMode(
    String donorSni,
    String mode, {
    int limit = 50,
  }) =>
      _attemptRepo.getByDonorAndMode(donorSni, mode, limit: limit);

  /// Выбрать лучший рецепт для контекста (из кэша от gossip).
  /// Возвращает null если кэш пуст или feature выключен.
  RecipeParams? selectRecipe({
    String? operatorCode,
    int? hourOfDay,
    String? region,
  }) {
    if (!kImmuneChunkFeatureEnabled) return null;
    return _recipeCache.selectBest(
      operatorCode: operatorCode,
      hourOfDay: hourOfDay,
      region: region,
    );
  }

  /// Обработать входящий иммунный чанк (из GossipManager).
  /// Возвращает true если чанк принят и сохранён.
  Future<bool> handleIncomingChunk(Map<String, dynamic> packet) async {
    if (!kImmuneChunkFeatureEnabled) return false;

    try {
      final chunk = ImmuneChunk.fromWire(packet);
      if (chunk.id.isEmpty || chunk.recipe.donorSni.isEmpty) return false;

      _recipeCache.put(chunk);
      return true;
    } catch (_) {
      return false;
    }
  }

  /// Создать иммунный чанк из успешной попытки (для relay).
  /// Возвращает null если feature выключен или нечего отправить.
  ImmuneChunk? createChunkFromSuccess({
    required String donorSni,
    required String mode,
    String? paddingConfig,
    String? operatorCode,
    String? region,
    String? nodeId,
  }) {
    if (!kImmuneChunkFeatureEnabled) return null;

    final params = RecipeParams(
      donorSni: donorSni,
      mode: mode,
      paddingConfig: paddingConfig,
    );
    final now = DateTime.now();

    return ImmuneChunk(
      id: 'immune_${now.millisecondsSinceEpoch}_${params.recipeHash}',
      recipe: params,
      meta: RecipeMeta(
        operatorCode: operatorCode,
        region: region,
        hourOfDay: now.hour,
        successCount: 1,
        attemptCount: 1,
        confirmedBy: nodeId != null ? [nodeId] : [],
        lastSuccessAt: now,
      ),
      ttlSeconds: kImmuneChunkBaseTtlSeconds,
      senderId: nodeId,
    );
  }

  /// Обработать сигнал тревоги (рецепт не сработал).
  void handleAlert(String recipeHash) {
    _recipeCache.demote(recipeHash);
  }

  /// Обработать подтверждение (рецепт сработал у другого узла).
  void handleConfirm(String recipeHash, String nodeId) {
    if (!kImmuneChunkFeatureEnabled) return;
    _recipeCache.addConfirmation(recipeHash, nodeId);
  }

  /// Построить пакет IMMUNE_CHUNK для gossip-relay после успешного HTTP (с rate limit).
  /// Вызывающий код передаёт пакет в [GossipManager.attemptRelay] — так нет цикла импортов.
  Future<Map<String, dynamic>?> buildImmuneGossipPacketAfterHttpSuccess({
    required TunnelConfig config,
    String? operatorCode,
    String? region,
  }) async {
    if (!kImmuneChunkFeatureEnabled) return null;

    final now = DateTime.now();
    if (_lastImmuneGossipEmitAt != null &&
        now.difference(_lastImmuneGossipEmitAt!) < kImmuneGossipEmitMinInterval) {
      return null;
    }

    final params = RecipeParams(
      donorSni: config.donorHost,
      mode: config.mode,
      paddingConfig: config.paddingConfig,
    );
    final recipeHash = params.recipeHash;
    if (recipeHash.isEmpty) return null;

    if (_lastImmuneGossipRecipeHash == recipeHash &&
        _lastImmuneGossipEmitAt != null &&
        now.difference(_lastImmuneGossipEmitAt!) <
            kImmuneGossipSameRecipeMinInterval) {
      return null;
    }

    final nodeId = (await Vault.read('user_id'))?.trim();
    final chunk = createChunkFromSuccess(
      donorSni: config.donorHost,
      mode: config.mode,
      paddingConfig: config.paddingConfig,
      operatorCode: operatorCode,
      region: region,
      nodeId: nodeId?.isNotEmpty == true ? nodeId : null,
    );
    if (chunk == null) return null;

    return Map<String, dynamic>.from(chunk.toWire())
      ..['ttl'] = kImmuneChunkMeshRelayHops
      ..['timestamp'] = now.millisecondsSinceEpoch
      ..['h'] = chunk.id
      ..['senderId'] = nodeId ?? '';
  }

  /// Вызвать после успешного [GossipManager.attemptRelay] для учёта rate limit.
  void markImmuneGossipEmitCompleted(String recipeHash) {
    final now = DateTime.now();
    _lastImmuneGossipEmitAt = now;
    _lastImmuneGossipRecipeHash = recipeHash;
  }
}
