// lib/core/immune/recipe_cache.dart
//
// In-memory кэш рецептов от иммунных чанков.
// Ограничен по размеру, LRU-подобное вытеснение по дате.

import 'immune_chunk.dart';
import 'immune_constants.dart';

class RecipeCache {
  final Map<String, CachedRecipe> _byHash = {};
  final List<String> _order = [];

  static bool _isExpired(ImmuneChunk c) {
    if (c.ttlSeconds <= 0) return false;
    return DateTime.now().difference(c.meta.lastSuccessAt) >
        Duration(seconds: c.ttlSeconds);
  }

  void _purgeExpired() {
    final toRemove = <String>[];
    for (final e in _byHash.entries) {
      if (_isExpired(e.value.chunk)) toRemove.add(e.key);
    }
    for (final h in toRemove) {
      _byHash.remove(h);
      _order.remove(h);
    }
  }

  /// Добавить или обновить рецепт (при повторном получении — мерж подтверждений).
  void put(ImmuneChunk chunk) {
    _purgeExpired();
    final hash = chunk.recipeHash;
    if (hash.isEmpty) return;

    if (_byHash.containsKey(hash)) {
      final existing = _byHash[hash]!;
      existing.merge(chunk);
      _touch(hash);
      return;
    }

    _evictIfNeeded();
    _byHash[hash] = CachedRecipe(chunk);
    _order.add(hash);
  }

  /// Получить чанк по хешу рецепта.
  ImmuneChunk? getByHash(String recipeHash) {
    _purgeExpired();
    final c = _byHash[recipeHash];
    if (c == null || c.isBlocked) return null;
    if (_isExpired(c.chunk)) {
      _byHash.remove(recipeHash);
      _order.remove(recipeHash);
      return null;
    }
    return c.chunk;
  }

  /// Добавить подтверждение от узла (без дубликатов).
  void addConfirmation(String recipeHash, String nodeId) {
    final c = _byHash[recipeHash];
    if (c == null || c.isBlocked) return;
    if (c.chunk.meta.confirmedBy.contains(nodeId)) return;

    final m = c.chunk.meta;
    final updated = ImmuneChunk(
      id: c.chunk.id,
      recipe: c.chunk.recipe,
      meta: RecipeMeta(
        operatorCode: m.operatorCode,
        region: m.region,
        hourOfDay: m.hourOfDay,
        successCount: m.successCount + 1,
        attemptCount: m.attemptCount + 1,
        confirmedBy: [...m.confirmedBy, nodeId],
        lastSuccessAt: DateTime.now(),
      ),
      ttlSeconds: c.chunk.ttlSeconds,
      senderId: c.chunk.senderId,
    );
    _byHash[recipeHash] = CachedRecipe(updated);
  }

  /// Понизить рейтинг (сигнал тревоги).
  void demote(String recipeHash) {
    final c = _byHash[recipeHash];
    if (c == null) return;
    c.demote();
  }

  /// Получить лучший рецепт для контекста.
  RecipeParams? selectBest({
    String? operatorCode,
    int? hourOfDay,
    String? region,
  }) {
    _purgeExpired();
    if (_byHash.isEmpty) return null;

    CachedRecipe? best;
    double bestScore = -1;

    for (final c in _byHash.values) {
      if (c.isBlocked) continue;
      if (_isExpired(c.chunk)) continue;

      var score = c.chunk.meta.successRate * 10;
      score += c.chunk.meta.confirmedBy.length * 2;

      if (operatorCode != null &&
          c.chunk.meta.operatorCode != null &&
          c.chunk.meta.operatorCode == operatorCode) {
        score += 5;
      }
      if (hourOfDay != null &&
          c.chunk.meta.hourOfDay != null &&
          (c.chunk.meta.hourOfDay! - hourOfDay).abs() <= 2) {
        score += 2;
      }
      if (region != null &&
          c.chunk.meta.region != null &&
          c.chunk.meta.region == region) {
        score += 3;
      }

      final ageHours =
          DateTime.now().difference(c.chunk.meta.lastSuccessAt).inHours;
      if (ageHours > 24) score *= 0.8;
      if (ageHours > 168) score *= 0.5;

      if (score > bestScore) {
        bestScore = score;
        best = c;
      }
    }

    return best?.chunk.recipe;
  }

  /// Все рецепты (для отладки), исключая заблокированные.
  List<ImmuneChunk> getAll() {
    _purgeExpired();
    return _byHash.values
        .where((c) => !c.isBlocked && !_isExpired(c.chunk))
        .map((c) => c.chunk)
        .toList();
  }

  void _touch(String hash) {
    _order.remove(hash);
    _order.add(hash);
  }

  void _evictIfNeeded() {
    while (_byHash.length >= kRecipeCacheMaxEntries && _order.isNotEmpty) {
      final oldest = _order.removeAt(0);
      _byHash.remove(oldest);
    }
  }
}

class CachedRecipe {
  ImmuneChunk chunk;
  int _alertCount = 0;
  static const int _blockThreshold = 3;

  CachedRecipe(this.chunk);

  bool get isBlocked => _alertCount >= _blockThreshold;

  void merge(ImmuneChunk other) {
    final m = chunk.meta;
    final om = other.meta;

    chunk = ImmuneChunk(
      id: chunk.id,
      recipe: chunk.recipe,
      meta: RecipeMeta(
        operatorCode: m.operatorCode ?? om.operatorCode,
        region: m.region ?? om.region,
        hourOfDay: m.hourOfDay ?? om.hourOfDay,
        successCount: m.successCount + om.successCount,
        attemptCount: m.attemptCount + om.attemptCount,
        confirmedBy: {...m.confirmedBy, ...om.confirmedBy}.toList(),
        lastSuccessAt: m.lastSuccessAt.isAfter(om.lastSuccessAt)
            ? m.lastSuccessAt
            : om.lastSuccessAt,
      ),
      ttlSeconds: chunk.ttlSeconds,
      senderId: chunk.senderId,
    );
  }

  void demote() {
    _alertCount++;
  }
}
