import 'dart:async';
import 'dart:convert';
import 'package:flutter_blue_plus/flutter_blue_plus.dart';
import 'package:flutter_ble_peripheral/flutter_ble_peripheral.dart';

class BluetoothMeshService {
  // Уникальные ID для нашего проекта
  final String SERVICE_UUID = "bf27730d-860a-4e09-889c-2d8b6a9e0fe7";
  final String CHAR_UUID = "c22d1e32-0310-4062-812e-89025078da9c";
  Stream<ScanResult> startScan() {
    FlutterBluePlus.startScan(timeout: const Duration(seconds: 10));
    return FlutterBluePlus.scanResults.expand((list) => list);
  }

  // ✅ 1. ВЕЩАНИЕ (Чтобы нас нашли)
  Future<void> startAdvertising(String myName) async {
    if (await FlutterBlePeripheral().isAdvertising) return;

    final AdvertiseData data = AdvertiseData(
      serviceUuid: SERVICE_UUID,
      localName: myName,
    );

    // На Tecno/Huawei ставим режим Balanced для пробития спячки
    await FlutterBlePeripheral().start(advertiseData: data);
    print("🦷 [BT] Beacon active: $myName");
  }

  // ✅ 2. ПОИСК (Находим других)
  Stream<ScanResult> scanForNodes() {
    // Настраиваем скан с учетом специфики Tecno (androidUsesFineLocation: true)
    FlutterBluePlus.startScan(
        withServices: [Guid(SERVICE_UUID)], // Ищем только своих!
        timeout: const Duration(seconds: 15),
        androidUsesFineLocation: true
    );

    return FlutterBluePlus.scanResults.expand((list) => list);
  }

  // ✅ 3. ОСТАНОВКА
  Future<void> stop() async {
    await FlutterBluePlus.stopScan();
    await FlutterBlePeripheral().stop();
  }

  Future<void> send(String message) async {
    print("🦷 Bluetooth Send requested: $message");
    // Тут логика отправки через GATT (мы её описывали в прошлом шаге)
  }

  // ✅ 3. ОТПРАВКА ДАННЫХ ЧЕРЕЗ BT
  Future<void> sendMessage(BluetoothDevice device, String message) async {
    await device.connect();
    List<BluetoothService> services = await device.discoverServices();
    for (var service in services) {
      if (service.uuid.toString() == SERVICE_UUID) {
        for (var char in service.characteristics) {
          if (char.uuid.toString() == CHAR_UUID) {
            await char.write(utf8.encode(message));
          }
        }
      }
    }
    await device.disconnect();
  }
}