import 'dart:convert';
import 'dart:typed_data';

import 'package:flutter/material.dart';
import 'package:nearby_connections/nearby_connections.dart';
import 'package:permission_handler/permission_handler.dart';

class NearbyRadarScreen extends StatefulWidget {
  final String myUsername; // Мы передадим имя из профиля
  const NearbyRadarScreen({super.key, required this.myUsername});

  @override
  State<NearbyRadarScreen> createState() => _NearbyRadarScreenState();
}

class _NearbyRadarScreenState extends State<NearbyRadarScreen> {
  final Strategy strategy = Strategy.P2P_CLUSTER; // Режим "многие ко многим"
  Map<String, String> endpointMap = {}; // ID устройства -> Имя пользователя
  String? connectedEndpointId; // С кем мы сейчас говорим
  List<String> logs = []; // Лог событий (или чат)
  final TextEditingController _msgController = TextEditingController();

  @override
  void initState() {
    super.initState();
    _checkPermissions();
  }

  // 1. Запрос прав (без этого не заработает)
  void _checkPermissions() async {
    // Запрашиваем пачку прав для Bluetooth и Геолокации
    await [
      Permission.location,
      Permission.bluetooth,
      Permission.bluetoothAdvertise,
      Permission.bluetoothConnect,
      Permission.bluetoothScan,
      Permission.nearbyWifiDevices
    ].request();
  }

  // 2. Начинаем вещать о себе и искать других
  void _startRadar() async {
    try {
      // РЕЖИМ ОБНАРУЖЕНИЯ (Я ищу)
      bool a = await Nearby().startDiscovery(
        widget.myUsername,
        strategy,
        onEndpointFound: (id, name, serviceId) {
          // Нашли кого-то!
          _log("SIGNAL FOUND: $name ($id)");
          // Предлагаем пользователю подключиться
          showModalBottomSheet(
              context: context,
              builder: (builder) {
                return Container(
                  color: Colors.grey[900],
                  child: Column(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      ListTile(
                        title: Text("Connect to $name?", style: const TextStyle(color: Colors.white)),
                        trailing: IconButton(
                          icon: const Icon(Icons.link, color: Colors.green),
                          onPressed: () {
                            Navigator.pop(context);
                            _requestConnection(id, name);
                          },
                        ),
                      ),
                    ],
                  ),
                );
              }
          );
        },
        onEndpointLost: (id) {
          _log("SIGNAL LOST: $id");
        },
      );

      // РЕЖИМ РЕКЛАМЫ (Меня ищут)
      bool b = await Nearby().startAdvertising(
        widget.myUsername,
        strategy,
        onConnectionInitiated: (id, info) {
          // Кто-то хочет ко мне подключиться
          _log("INCOMING CONNECTION: ${info.endpointName}");
          _acceptConnection(id); // Автоматически принимаем (или можно спрашивать)
        },
        onConnectionResult: (id, status) {
          if (status == Status.CONNECTED) {
            _log("SECURE LINK ESTABLISHED via BLUETOOTH/WIFI");
            setState(() {
              connectedEndpointId = id;
            });
            // Останавливаем поиск, чтобы экономить батарею и стабилизировать связь
            Nearby().stopAdvertising();
            Nearby().stopDiscovery();
          } else {
            _log("CONNECTION FAILED: $status");
          }
        },
        onDisconnected: (id) {
          setState(() {
            connectedEndpointId = null;
          });
          _log("LINK SEVERED");
        },
      );

      if (a && b) _log("RADAR ACTIVE. SCANNING FREQUENCIES...");
    } catch (e) {
      _log("RADAR ERROR: $e");
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
          Nearby().stopAdvertising();
          Nearby().stopDiscovery();
        }
      },
      onDisconnected: (id) => setState(() => connectedEndpointId = null),
    );
  }

  void _acceptConnection(String id) {
    Nearby().acceptConnection(
      id,
      onPayLoadRecieved: (endId, payload) {
        // Пришло сообщение!
        if (payload.type == PayloadType.BYTES) {
          String msg = String.fromCharCodes(payload.bytes!);
          _log("${endpointMap[endId] ?? 'Unknown'}: $msg");
        }
      },
    );
  }

  void _sendMessage() {
    if (connectedEndpointId == null || _msgController.text.isEmpty) return;
    String msg = _msgController.text;

    // Отправляем байты напрямую на устройство
    Nearby().sendBytesPayload(connectedEndpointId!, Uint8List.fromList(msg.codeUnits));

    _log("Me: $msg");
    _msgController.clear();
  }

  void _log(String text) {
    setState(() {
      logs.insert(0, text); // Добавляем в начало списка
    });
  }

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
        title: const Text("OFF-GRID RADAR"),
        backgroundColor: Colors.grey[900],
        actions: [
          IconButton(
            icon: const Icon(Icons.radar, color: Colors.greenAccent),
            onPressed: _startRadar,
          )
        ],
      ),
      body: Column(
        children: [
          // Зона статуса
          Container(
            padding: const EdgeInsets.all(8),
            color: connectedEndpointId != null ? Colors.green[900] : Colors.red[900],
            width: double.infinity,
            child: Text(
              connectedEndpointId != null
                  ? "STATUS: CONNECTED (P2P)"
                  : "STATUS: DISCONNECTED (Tap Radar Icon)",
              textAlign: TextAlign.center,
              style: const TextStyle(color: Colors.white, fontWeight: FontWeight.bold),
            ),
          ),

          // Лог чата/событий
          Expanded(
            child: ListView.builder(
              reverse: true, // Новые снизу
              itemCount: logs.length,
              itemBuilder: (context, index) {
                return Padding(
                  padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 4),
                  child: Text(logs[index], style: const TextStyle(color: Colors.greenAccent, fontFamily: 'Courier')),
                );
              },
            ),
          ),

          // Поле ввода
          if (connectedEndpointId != null)
            Padding(
              padding: const EdgeInsets.all(8.0),
              child: Row(
                children: [
                  Expanded(
                    child: TextField(
                      controller: _msgController,
                      style: const TextStyle(color: Colors.white),
                      decoration: const InputDecoration(
                        hintText: "Enter encoded message...",
                        hintStyle: TextStyle(color: Colors.white54),
                        filled: true,
                        fillColor: Colors.grey,
                      ),
                    ),
                  ),
                  IconButton(
                    icon: const Icon(Icons.send, color: Colors.greenAccent),
                    onPressed: _sendMessage,
                  )
                ],
              ),
            ),
        ],
      ),
    );
  }
}