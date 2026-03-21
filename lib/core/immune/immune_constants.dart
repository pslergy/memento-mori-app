// lib/core/immune/immune_constants.dart
//
// Константы для системы иммунных чанков (Immune Chunk).
// Ограничения защищают от переполнения памяти и перегрузки mesh.

/// Максимум записей в дневнике попыток на устройстве.
const int kAttemptLogMaxEntries = 200;

/// Максимум рецептов в локальном кэше.
const int kRecipeCacheMaxEntries = 50;

/// Максимум иммунных чанков для relay в минуту на узел.
const int kImmuneChunkRateLimitPerMinute = 5;

/// TTL иммунного чанка в секундах (базовый).
const int kImmuneChunkBaseTtlSeconds = 7200; // 2 часа

/// Число mesh-hop'ов для gossip-ретрансляции IMMUNE_* (как у WIFI_CREDENTIAL).
const int kImmuneChunkMeshRelayHops = 3;

/// Минимальный интервал между эмитами IMMUNE_CHUNK после успешного HTTP (на узел).
const Duration kImmuneGossipEmitMinInterval = Duration(minutes: 6);

/// Если рецепт тот же — не слать чаще этого интервала (снижает шум в эфире).
const Duration kImmuneGossipSameRecipeMinInterval = Duration(minutes: 45);

/// Порог: значения поля `ttl` на wire больше этого считаются legacy recipe-TTL, а не hop-TTL.
const int kImmuneWireLegacyRecipeTtlThreshold = 64;

/// Приоритет иммунного чанка в gossip (между обычными и срочными).
/// 0 = low, 5 = normal, 10 = urgent.
const int kImmuneChunkGossipPriority = 5;

/// Feature flag: иммунные чанки + gossip (приём, relay, эмит после успеха).
/// Лимиты (rate, hop TTL, emit cooldown) ограничивают нагрузку на mesh.
const bool kImmuneChunkFeatureEnabled = true;
