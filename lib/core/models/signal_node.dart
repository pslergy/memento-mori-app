enum SignalType { cloud, mesh, bluetooth }

class SignalNode {
  final String id;
  final String name;
  final SignalType type;
  final bool isGroup;
  final String? metadata; // Например, MAC-адрес для Mesh или статус для Cloud

  SignalNode({
    required this.id,
    required this.name,
    required this.type,
    this.isGroup = false,
    this.metadata
  });
}