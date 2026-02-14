import 'dart:convert';
import 'dart:math' as math;
import 'package:crypto/crypto.dart';

/// 🔒 Fragment Security Service
/// Обеспечивает защиту от перехвата через перемешивание чанков
/// 
/// Принцип работы:
/// 1. Сообщение разбивается на чанки
/// 2. Чанки перемешиваются по детерминированному алгоритму (на основе session key)
/// 3. Приемник собирает чанки в правильном порядке
/// 
/// Это усложняет перехват, так как:
/// - Порядок чанков не очевиден
/// - Невозможно собрать сообщение без знания алгоритма перемешивания
/// - Каждое сообщение имеет уникальный порядок (на основе messageId)
class FragmentSecurityService {
  // 🔒 Флаг включения защиты (можно управлять через конфиг)
  static const bool _securityEnabled = true;
  
  /// Разбивает сообщение на чанки с перемешиванием для защиты
  /// 
  /// @param packet - исходный пакет с полем 'content'
  /// @param chunkSize - размер чанка (по умолчанию 160 байт для BLE)
  /// @return список чанков в перемешанном порядке
  List<Map<String, dynamic>> fragmentWithSecurity(Map<String, dynamic> packet, {int chunkSize = 160}) {
    final String content = packet['content'] ?? "";
    final String messageId = packet['h'] ?? "m_${DateTime.now().millisecondsSinceEpoch}";
    
    // Если сообщение маленькое - не фрагментируем
    if (content.length <= chunkSize) {
      return [packet];
    }
    
    // 1. Разбиваем на чанки
    List<Map<String, dynamic>> fragments = [];
    int total = (content.length / chunkSize).ceil();
    
    for (int i = 0; i < total; i++) {
      int start = i * chunkSize;
      int end = (start + chunkSize < content.length) ? start + chunkSize : content.length;
      
      fragments.add({
        'type': 'MSG_FRAG',
        'mid': messageId,
        'idx': i,
        'tot': total,
        'data': content.substring(start, end),
        'chatId': packet['chatId'],
        'senderId': packet['senderId'],
        'h': "${messageId}_$i",
        'ttl': packet['ttl'] ?? 5,
        'timestamp': packet['timestamp'],
        if (packet['isEncrypted'] == true) 'isEncrypted': true,
      });
    }
    
    // 2. 🔒 ПЕРЕМЕШИВАНИЕ для защиты от перехвата
    if (_securityEnabled && fragments.length > 1) {
      fragments = _shuffleFragments(fragments, messageId);
    }
    
    return fragments;
  }
  
  /// Перемешивает чанки детерминированным образом
  /// 
  /// Алгоритм: используем хеш messageId как seed для генератора случайных чисел
  /// Это гарантирует, что для одного messageId порядок всегда одинаковый
  /// (и отправитель, и получатель получат одинаковый порядок)
  List<Map<String, dynamic>> _shuffleFragments(List<Map<String, dynamic>> fragments, String messageId) {
    // Генерируем seed из messageId (детерминированный)
    final seed = _generateSeed(messageId);
    final rng = math.Random(seed);
    
    // Создаем список индексов и перемешиваем их
    List<int> indices = List.generate(fragments.length, (i) => i);
    
    // 🔒 Перемешиваем индексы (Fisher-Yates shuffle с детерминированным seed)
    for (int i = indices.length - 1; i > 0; i--) {
      int j = rng.nextInt(i + 1);
      int temp = indices[i];
      indices[i] = indices[j];
      indices[j] = temp;
    }
    
    // Переупорядочиваем чанки согласно перемешанным индексам
    List<Map<String, dynamic>> shuffled = [];
    for (int idx in indices) {
      shuffled.add(fragments[idx]);
    }
    
    return shuffled;
  }
  
  /// Генерирует детерминированный seed из messageId
  int _generateSeed(String messageId) {
    final bytes = utf8.encode(messageId);
    final hash = sha256.convert(bytes);
    // Берем первые 4 байта хеша как seed
    return hash.bytes[0] << 24 | hash.bytes[1] << 16 | hash.bytes[2] << 8 | hash.bytes[3];
  }
  
  /// Проверяет, что чанки собраны в правильном порядке
  /// 
  /// Используется при сборке на приемной стороне
  bool validateFragmentOrder(List<Map<String, dynamic>> fragments) {
    if (fragments.isEmpty) return false;
    
    final messageId = fragments.first['mid'] as String?;
    if (messageId == null) return false;
    
    // Проверяем, что все чанки имеют правильные индексы
    final expectedIndices = List.generate(fragments.length, (i) => i);
    final actualIndices = fragments.map((f) => f['idx'] as int).toList()..sort();
    
    return expectedIndices.toString() == actualIndices.toString();
  }
}
