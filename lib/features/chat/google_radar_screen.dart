// lib/features/chat/google_radar_screen.dart
import 'dart:typed_data';
import 'package:flutter/material.dart';
import 'package:nearby_connections/nearby_connections.dart';
import 'package:memento_mori_app/ghost_input/ghost_controller.dart';
import 'package:memento_mori_app/ghost_input/ghost_keyboard.dart';

class GoogleRadarScreen extends StatefulWidget {
  final String myUsername;
  const GoogleRadarScreen({super.key, required this.myUsername});

  @override
  State<GoogleRadarScreen> createState() => _GoogleRadarScreenState();
}

class _GoogleRadarScreenState extends State<GoogleRadarScreen> {
  final Strategy strategy = Strategy.P2P_CLUSTER;
  Map<String, String> endpointMap = {};
  String? connectedEndpointId;
  List<String> logs = [];
  final GhostController _msgGhost = GhostController();

  void _startRadar() async {
    try {
      await Nearby().startDiscovery(
        widget.myUsername,
        strategy,
        onEndpointFound: (id, name, serviceId) {
          _log("SIGNAL FOUND: $name");
          showModalBottomSheet(
              context: context,
              builder: (builder) {
                return Container(
                  color: Colors.grey[900],
                  child: ListTile(
                    title: Text("Connect to $name?", style: const TextStyle(color: Colors.white)),
                    trailing: IconButton(
                        icon: const Icon(Icons.link, color: Colors.green),
                        onPressed: () {
                          Navigator.pop(context);
                          _requestConnection(id, name);
                        }),
                  ),
                );
              });
        },
        onEndpointLost: (id) => _log("SIGNAL LOST: $id"),
      );

      await Nearby().startAdvertising(
        widget.myUsername,
        strategy,
        onConnectionInitiated: (id, info) {
          _log("INCOMING: ${info.endpointName}");
          _acceptConnection(id);
        },
        onConnectionResult: (id, status) {
          if (status == Status.CONNECTED) {
            _log("SECURE GOOGLE LINK ESTABLISHED");
            setState(() => connectedEndpointId = id);
            Nearby().stopAdvertising();
          }
        },
        onDisconnected: (id) => setState(() => connectedEndpointId = null),
      );
      _log("GOOGLE RADAR ACTIVE...");
    } catch (e) {
      _log("ERROR: $e");
    }
  }

  void _requestConnection(String id, String name) {
    Nearby().requestConnection(
      widget.myUsername,
      id,
      onConnectionInitiated: (id, info) => _acceptConnection(id),
      onConnectionResult: (id, status) {
        if (status == Status.CONNECTED) {
          setState(() {
            connectedEndpointId = id;
            endpointMap[id] = name;
          });
          _log("CONNECTED TO $name");
        }
      },
      onDisconnected: (id) => setState(() => connectedEndpointId = null),
    );
  }

  void _acceptConnection(String id) {
    Nearby().acceptConnection(
      id,
      onPayLoadRecieved: (endId, payload) {
        if (payload.type == PayloadType.BYTES) {
          String msg = String.fromCharCodes(payload.bytes!);
          _log("${endpointMap[endId] ?? 'Anon'}: $msg");
        }
      },
    );
  }

  void _sendMessage() {
    if (connectedEndpointId == null) return;
    final text = _msgGhost.value;
    if (text.isEmpty) return;
    Nearby().sendBytesPayload(connectedEndpointId!, Uint8List.fromList(text.codeUnits));
    _log("Me: $text");
    _msgGhost.clear();
  }

  void _log(String text) => setState(() => logs.insert(0, text));

  @override
  void dispose() {
    Nearby().stopAdvertising();
    Nearby().stopDiscovery();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: Colors.black,
      appBar: AppBar(
        title: const Text("G-NET RADAR"),
        backgroundColor: Colors.grey[900],
        actions: [
          IconButton(icon: const Icon(Icons.radar, color: Colors.greenAccent), onPressed: _startRadar)
        ],
      ),
      body: Column(
        children: [
          Container(
            color: connectedDevicesColor(),
            width: double.infinity,
            padding: const EdgeInsets.all(8),
            child: Text(connectedEndpointId != null ? "CONNECTED" : "DISCONNECTED",
                textAlign: TextAlign.center, style: const TextStyle(color: Colors.white, fontWeight: FontWeight.bold)),
          ),
          Expanded(
            child: ListView.builder(
              reverse: true,
              itemCount: logs.length,
              itemBuilder: (c, i) => Padding(padding: const EdgeInsets.all(4), child: Text(">> ${logs[i]}", style: const TextStyle(color: Colors.greenAccent))),
            ),
          ),
          if (connectedEndpointId != null)
            Padding(
              padding: const EdgeInsets.all(8.0),
              child: Row(
                children: [
                  Expanded(
                    child: GestureDetector(
                      onTap: () {
                        showModalBottomSheet(
                          context: context,
                          isScrollControlled: true,
                          backgroundColor: Colors.transparent,
                          builder: (context) => GhostKeyboard(
                            controller: _msgGhost,
                            onSend: () {
                              _sendMessage();
                              setState(() {});
                              Navigator.pop(context);
                            },
                          ),
                        );
                      },
                      child: Container(
                        padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 12),
                        decoration: BoxDecoration(
                          color: Colors.grey[850],
                          borderRadius: BorderRadius.circular(8),
                        ),
                        child: AnimatedBuilder(
                          animation: _msgGhost,
                          builder: (_, __) => Text(
                            _msgGhost.value.isEmpty ? 'Сообщение...' : _msgGhost.value,
                            style: TextStyle(
                              color: _msgGhost.value.isEmpty ? Colors.white38 : Colors.white,
                            ),
                          ),
                        ),
                      ),
                    ),
                  ),
                  IconButton(
                    icon: const Icon(Icons.send, color: Colors.green),
                    onPressed: _sendMessage,
                  ),
                ],
              ),
            )
        ],
      ),
    );
  }

  Color connectedDevicesColor() => connectedEndpointId != null ? Colors.green[900]! : Colors.red[900]!;
}