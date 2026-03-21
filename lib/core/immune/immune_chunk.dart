// lib/core/immune/immune_chunk.dart
//
// Модель иммунного чанка — упакованный «рецепт» успешного обхода DPI.
// Распространяется через gossip.

import 'dart:convert';

import 'package:crypto/crypto.dart';

import 'immune_constants.dart';

/// Метаданные рецепта (оператор, регион, время суток).
class RecipeMeta {
  final String? operatorCode;
  final String? region;
  final int? hourOfDay; // 0-23
  final int successCount;
  final int attemptCount;
  final List<String> confirmedBy; // Node IDs
  final DateTime lastSuccessAt;

  RecipeMeta({
    this.operatorCode,
    this.region,
    this.hourOfDay,
    this.successCount = 1,
    this.attemptCount = 1,
    this.confirmedBy = const [],
    required this.lastSuccessAt,
  });

  double get successRate =>
      attemptCount > 0 ? successCount / attemptCount : 0.0;

  Map<String, dynamic> toJson() => {
        'op': operatorCode,
        'region': region,
        'hour': hourOfDay,
        'ok': successCount,
        'n': attemptCount,
        'by': confirmedBy,
        'ts': lastSuccessAt.millisecondsSinceEpoch,
      };

  factory RecipeMeta.fromJson(Map<String, dynamic> json) {
    final by = json['by'];
    return RecipeMeta(
      operatorCode: json['op']?.toString(),
      region: json['region']?.toString(),
      hourOfDay: json['hour'] is int ? json['hour'] : null,
      successCount: json['ok'] is int ? json['ok'] : 1,
      attemptCount: json['n'] is int ? json['n'] : 1,
      confirmedBy: by is List
          ? (by).map((e) => e.toString()).toList()
          : const [],
      lastSuccessAt: json['ts'] != null
          ? DateTime.fromMillisecondsSinceEpoch(
              (json['ts'] is int) ? json['ts'] : (json['ts'] as num).toInt())
          : DateTime.now(),
    );
  }
}

/// Технические параметры рецепта.
class RecipeParams {
  final String donorSni;
  final String mode; // packet-up, stream-one
  final String? paddingConfig;

  RecipeParams({
    required this.donorSni,
    required this.mode,
    this.paddingConfig,
  });

  Map<String, dynamic> toJson() => {
        'donor': donorSni,
        'mode': mode,
        'pad': paddingConfig,
      };

  factory RecipeParams.fromJson(Map<String, dynamic> json) => RecipeParams(
        donorSni: json['donor']?.toString() ?? '',
        mode: json['mode']?.toString() ?? 'unknown',
        paddingConfig: json['pad']?.toString(),
      );

  /// Каноническая строка для хеширования (дедупликация).
  String toCanonicalString() =>
      jsonEncode({'donor': donorSni, 'mode': mode, 'pad': paddingConfig});

  String get recipeHash {
    final bytes = utf8.encode(toCanonicalString());
    return sha256.convert(bytes).toString().substring(0, 16);
  }
}

/// Иммунный чанк — рецепт + метаданные.
class ImmuneChunk {
  final String id;
  final RecipeParams recipe;
  final RecipeMeta meta;
  final int ttlSeconds;
  final String? senderId;

  ImmuneChunk({
    required this.id,
    required this.recipe,
    required this.meta,
    this.ttlSeconds = 7200,
    this.senderId,
  });

  String get recipeHash => recipe.recipeHash;

  /// Поля для gossip: тип, рецепт, метаданные.
  /// Важно: mesh использует отдельное поле `ttl` как **число хопов** при relay;
  /// срок жизни рецепта — только [immuneTtlSec].
  Map<String, dynamic> toWire() => {
        'type': 'IMMUNE_CHUNK',
        'id': id,
        'recipe': recipe.toJson(),
        'meta': meta.toJson(),
        'immuneTtlSec': ttlSeconds,
        'gossipPriority': kImmuneChunkGossipPriority,
        if (senderId != null) 'senderId': senderId,
      };

  factory ImmuneChunk.fromWire(Map<String, dynamic> json) {
    final recipe = json['recipe'] is Map
        ? RecipeParams.fromJson(Map<String, dynamic>.from(json['recipe']))
        : RecipeParams(donorSni: '', mode: 'unknown');
    final meta = json['meta'] is Map
        ? RecipeMeta.fromJson(Map<String, dynamic>.from(json['meta']))
        : RecipeMeta(lastSuccessAt: DateTime.now());

    final int recipeTtl = _parseRecipeTtlSeconds(json);

    return ImmuneChunk(
      id: json['id']?.toString() ?? '',
      recipe: recipe,
      meta: meta,
      ttlSeconds: recipeTtl,
      senderId: json['senderId']?.toString(),
    );
  }

  /// Срок жизни рецепта в секундах (не путать с mesh hop `ttl`).
  static int _parseRecipeTtlSeconds(Map<String, dynamic> json) {
    final direct = json['immuneTtlSec'];
    if (direct is int) return direct;
    if (direct is num) return direct.toInt();

    final t = json['ttl'];
    if (t is int && t > kImmuneWireLegacyRecipeTtlThreshold) return t;
    if (t is num && t.toInt() > kImmuneWireLegacyRecipeTtlThreshold) {
      return t.toInt();
    }

    return kImmuneChunkBaseTtlSeconds;
  }
}
