import 'package:memento_mori_app/core/models/signal_node.dart';

bool _tacticalHasBroadcastNick(String rawName) {
  final name = rawName.trim();
  final pipe = name.indexOf('|');
  if (pipe < 0 || pipe + 1 >= name.length) return false;
  return name.substring(pipe + 1).trim().isNotEmpty;
}

/// Основной заголовок: ник из маяка (`M_…|nick`), иначе имя телефона в Bluetooth, иначе тактика/mesh.
/// Соединение по-прежнему идёт по [SignalNode.id], не по этой строке.
String nearbyNodePrimaryLabel(SignalNode n) {
  if (_tacticalHasBroadcastNick(n.name)) {
    return nearbyNodeDisplayTitle(n.name);
  }
  final plat = n.blePlatformName?.trim() ?? '';
  if (plat.isNotEmpty) return plat;
  if (n.type == SignalType.mesh) {
    final t = n.name.trim();
    if (t.isNotEmpty && t != 'WiFi_Node') return t;
  }
  return nearbyNodeDisplayTitle(n.name);
}

/// Вторая строка: транспорт; при показе ника из маяка не дублируем ник и не подставляем сырой [SignalNode.id].
String nearbyNodeSubtitleLine(SignalNode n) {
  final transport = n.type == SignalType.mesh
      ? 'Wi‑Fi Direct'
      : 'Bluetooth LE';
  final tacticalTitle = nearbyNodeDisplayTitle(n.name);
  final hint = tacticalMeshSubtitleHint(n.name);
  final plat = n.blePlatformName?.trim() ?? '';
  if (_tacticalHasBroadcastNick(n.name)) {
    final parts = <String>[transport];
    if (plat.isNotEmpty && plat != tacticalTitle) {
      parts.add(plat);
    }
    if (hint != null) parts.add(hint);
    return parts.join(' · ');
  }
  if (plat.isNotEmpty && tacticalTitle.isNotEmpty && tacticalTitle != plat) {
    final extra = hint != null ? ' · $hint' : '';
    return '$transport · $tacticalTitle$extra';
  }
  if (hint != null) return '$transport · $hint';
  final shortId = n.id.length > 12 ? '${n.id.substring(0, 12)}…' : n.id;
  return '$transport · $shortId';
}

/// Key for merging rows when the same device appears with a new random BLE MAC
/// but the same tactical advertisement name (`M_hops_outbox_shortId…`).
String _tacticalBlePrefix(String raw) {
  final name = raw.trim();
  final pipe = name.indexOf('|');
  return pipe >= 0 ? name.substring(0, pipe) : name;
}

/// Заголовок в списке соседей: ник после `|`, иначе полное имя маяка.
String nearbyNodeDisplayTitle(String rawName) {
  final name = rawName.trim();
  final pipe = name.indexOf('|');
  if (pipe >= 0 && pipe + 1 < name.length) {
    final nick = name.substring(pipe + 1).trim();
    if (nick.isNotEmpty) return nick;
  }
  return name;
}

String nearbyNodeDisplayDedupeKey(SignalNode n) {
  final tactical = _tacticalBlePrefix(n.name);
  if (tactical.startsWith('M_') && tactical.length > 4) {
    return 't:$tactical';
  }
  if (n.id.startsWith('BRIDGE:')) return n.id;
  return 'i:${n.id}';
}

SignalNode _pickBetterNearbyDuplicate(SignalNode a, SignalNode b) {
  if (a.id.startsWith('BRIDGE:') != b.id.startsWith('BRIDGE:')) {
    return a.id.startsWith('BRIDGE:') ? a : b;
  }
  if (a.type == SignalType.mesh && b.type != SignalType.mesh) return a;
  if (b.type == SignalType.mesh && a.type != SignalType.mesh) return b;
  return b;
}

/// Collapse duplicate UI rows (MAC rotation, duplicate scan callbacks).
List<SignalNode> dedupeNearbyNodesForDisplay(List<SignalNode> nodes) {
  final byKey = <String, SignalNode>{};
  for (final n in nodes) {
    final key = nearbyNodeDisplayDedupeKey(n);
    final prev = byKey[key];
    if (prev == null) {
      byKey[key] = n;
    } else {
      byKey[key] = _pickBetterNearbyDuplicate(prev, n);
    }
  }
  final list = byKey.values.toList()
    ..sort((a, b) => a.name.toLowerCase().compareTo(b.name.toLowerCase()));
  return list;
}

/// Short hint from `M_2_1_ABCD` → "hops 2 · id ABCD" for subtitles.
String? tacticalMeshSubtitleHint(String name) {
  final t = _tacticalBlePrefix(name);
  if (!t.startsWith('M_')) return null;
  final parts = t.split('_');
  if (parts.length < 4) return null;
  final hops = parts[1];
  final short = parts[3];
  return 'Mesh beacon · hops $hops · $short (BLE address may change)';
}
