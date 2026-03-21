// lib/core/immune/attempt_log.dart
//
// Модель записи попытки подключения к интернету через mesh.
// Используется для локального дневника (Этап 1).

/// Результат попытки подключения.
enum AttemptResult {
  /// Подключение успешно.
  success,

  /// Признаки блокировки DPI (зависание, TLS failure, таймаут).
  blockDetected,

  /// Общая ошибка (сеть, таймаут без характерных признаков DPI).
  failure,
}

/// Режим туннеля (packet-up, stream-one и т.д.).
enum TunnelMode {
  packetUp,
  streamOne,
  unknown,
}

/// Запись одной попытки подключения.
class AttemptLog {
  /// Уникальный ID (UUID или timestamp-based).
  final String id;

  /// SNI донор (microsoft.com, github.com и т.д.).
  final String donorSni;

  /// Режим туннеля.
  final TunnelMode mode;

  /// JSON-строка настроек паддинга (если есть).
  final String? paddingConfig;

  /// Время попытки.
  final DateTime timestamp;

  /// Код оператора связи (МТС, Мегафон, unknown).
  final String? operatorCode;

  /// Регион (опционально).
  final String? region;

  /// Результат попытки.
  final AttemptResult result;

  /// Детали при неудаче (тип блокировки, ошибка).
  final String? failureReason;

  /// Байт получено до ошибки (тело HTTP-ответа при 4xx/5xx или 0 при обрыве до ответа).
  final int? bytesTransferred;

  AttemptLog({
    required this.id,
    required this.donorSni,
    required this.mode,
    this.paddingConfig,
    required this.timestamp,
    this.operatorCode,
    this.region,
    required this.result,
    this.failureReason,
    this.bytesTransferred,
  });

  /// Из строки режима.
  static TunnelMode modeFromString(String? s) {
    if (s == null) return TunnelMode.unknown;
    switch (s.toLowerCase()) {
      case 'packet-up':
      case 'packet_up':
        return TunnelMode.packetUp;
      case 'stream-one':
      case 'stream_one':
        return TunnelMode.streamOne;
      default:
        return TunnelMode.unknown;
    }
  }

  String get modeString {
    switch (mode) {
      case TunnelMode.packetUp:
        return 'packet-up';
      case TunnelMode.streamOne:
        return 'stream-one';
      case TunnelMode.unknown:
        return 'unknown';
    }
  }

  /// Результат для хранения в БД.
  String get resultString {
    switch (result) {
      case AttemptResult.success:
        return 'success';
      case AttemptResult.blockDetected:
        return 'block';
      case AttemptResult.failure:
        return 'failure';
    }
  }

  static AttemptResult resultFromString(String? s) {
    if (s == null) return AttemptResult.failure;
    switch (s) {
      case 'success':
        return AttemptResult.success;
      case 'block':
        return AttemptResult.blockDetected;
      default:
        return AttemptResult.failure;
    }
  }

  Map<String, dynamic> toJson() => {
        'id': id,
        'donorSni': donorSni,
        'mode': modeString,
        'paddingConfig': paddingConfig,
        'timestamp': timestamp.millisecondsSinceEpoch,
        'operatorCode': operatorCode,
        'region': region,
        'result': resultString,
        'failureReason': failureReason,
        'bytesTransferred': bytesTransferred,
      };

  factory AttemptLog.fromJson(Map<String, dynamic> json) {
    final ts = json['timestamp'];
    return AttemptLog(
      id: json['id']?.toString() ?? '',
      donorSni: json['donorSni']?.toString() ?? '',
      mode: modeFromString(json['mode']?.toString()),
      paddingConfig: json['paddingConfig']?.toString(),
      timestamp: ts != null
          ? DateTime.fromMillisecondsSinceEpoch(
              ts is int ? ts : (ts as num).toInt())
          : DateTime.now(),
      operatorCode: json['operatorCode']?.toString(),
      region: json['region']?.toString(),
      result: resultFromString(json['result']?.toString()),
      failureReason: json['failureReason']?.toString(),
      bytesTransferred: _parseOptionalInt(json['bytesTransferred']),
    );
  }

  static int? _parseOptionalInt(dynamic v) {
    if (v == null) return null;
    if (v is int) return v;
    if (v is num) return v.toInt();
    return int.tryParse(v.toString());
  }
}
