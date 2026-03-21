import 'dart:async';

import 'package:flutter/material.dart';
import 'package:ble_reliability_pack/ble_reliability_pack.dart';

void main() => runApp(const MyApp());

class MyApp extends StatelessWidget {
  const MyApp({super.key});

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: 'BLE Reliability Pack Demo',
      theme: ThemeData.dark(),
      home: const DemoScreen(),
    );
  }
}

class DemoScreen extends StatefulWidget {
  const DemoScreen({super.key});

  @override
  State<DemoScreen> createState() => _DemoScreenState();
}

class _DemoScreenState extends State<DemoScreen> {
  BleReliabilityPack? _pack;
  final List<String> _logs = [];
  String _roleState = 'IDLE';
  bool _loading = true;
  String? _error;

  void _addLog(String msg) {
    setState(() {
      _logs.insert(0, '${DateTime.now().toString().substring(11, 19)} $msg');
      if (_logs.length > 30) _logs.removeLast();
    });
  }

  @override
  void initState() {
    super.initState();
    _initPack();
  }

  Future<void> _initPack() async {
    try {
      final pack = await BleReliabilityPack.initialize(
        config: BleReliabilityConfig(
          schedulerConfig: BleSchedulerConfig(operationTimeout: Duration(seconds: 5)),
          onLog: _addLog,
        ),
        guardHandlers: BleGuardHandlers(
          startScan: () async => _addLog('Guard: scan started (simulated)'),
          stopScan: () async => _addLog('Guard: scan stopped (simulated)'),
          startAdvertise: () async => _addLog('Guard: advertise started (simulated)'),
          stopAdvertise: () async => _addLog('Guard: advertise stopped (simulated)'),
        ),
        roleHandlers: BleRoleHandlers(
          startScan: () async => _addLog('Orchestrator: scan (simulated)'),
          stopScan: () async => _addLog('Orchestrator: stop scan (simulated)'),
          startAdvertise: () async => _addLog('Orchestrator: advertise (simulated)'),
          stopAdvertise: () async => _addLog('Orchestrator: stop advertise (simulated)'),
          connect: (id) async => _addLog('Orchestrator: connect $id (simulated)'),
          disconnect: () async => _addLog('Orchestrator: disconnect (simulated)'),
        ),
      );
      pack.orchestrator?.onStateChanged.listen((s) {
        if (mounted) setState(() => _roleState = s.displayName);
      });
      setState(() {
        _pack = pack;
        _loading = false;
      });
    } catch (e) {
      setState(() {
        _error = e.toString();
        _loading = false;
      });
    }
  }

  @override
  void dispose() {
    _pack?.dispose();
    super.dispose();
  }

  Future<void> _demoScheduler() async {
    if (_pack == null) return;
    _addLog('--- Scheduler: enqueue 2 writes ---');
    await _pack!.scheduleWrite(() async {
      await Future.delayed(const Duration(milliseconds: 100));
    });
    await _pack!.scheduleWrite(() async {
      await Future.delayed(const Duration(milliseconds: 80));
    });
    _addLog('Scheduler: both writes done');
  }

  Future<void> _demoReliability() async {
    if (_pack == null) return;
    const peer = 'AA:BB:CC:DD';
    _pack!.setPeerCooldown(peer);
    _addLog('Reliability: cooldown set for peer');
    final inCooldown = _pack!.isPeerInCooldown(peer);
    _addLog('Reliability: isPeerInCooldown = $inCooldown');
    try {
      final quietMs = await _pack!.getPreConnectQuietMs();
      _addLog('Reliability: preConnectQuietMs = $quietMs (vendor-aware)');
    } catch (e) {
      _addLog('Reliability: getPreConnectQuietMs needs Android (simulated: 200ms)');
    }
  }

  Future<void> _demoGuard() async {
    if (_pack == null) return;
    await _pack!.startSmartScan();
    _addLog('Guard: startSmartScan (throttled if rapid)');
  }

  Future<void> _demoOrchestrator() async {
    if (_pack == null) return;
    await _pack!.startScanning();
    await Future.delayed(const Duration(milliseconds: 500));
    await _pack!.stopScanning();
    _addLog('Orchestrator: scan -> idle');
  }

  @override
  Widget build(BuildContext context) {
    if (_loading) {
      return const Scaffold(
        body: Center(child: CircularProgressIndicator()),
      );
    }
    if (_error != null) {
      return Scaffold(
        body: Center(child: Text('Error: $_error')),
      );
    }

    return Scaffold(
      appBar: AppBar(title: const Text('BLE Reliability Pack')),
      body: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Card(
              color: Colors.blue.shade900,
              child: Padding(
                padding: const EdgeInsets.all(12),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    const Text('Problem solved:', style: TextStyle(fontWeight: FontWeight.bold)),
                    const Text('GATT_BUSY, Huawei/Xiaomi quirks, background throttle, role crashes.'),
                    const SizedBox(height: 8),
                    Text('Role: $_roleState | Queue: ${_pack?.scheduler.queueDepth ?? 0}'),
                  ],
                ),
              ),
            ),
            const SizedBox(height: 8),
            Wrap(
              spacing: 8,
              runSpacing: 4,
              children: [
                ElevatedButton(onPressed: _demoScheduler, child: const Text('1. Scheduler')),
                ElevatedButton(onPressed: _demoReliability, child: const Text('2. Reliability')),
                ElevatedButton(onPressed: _demoGuard, child: const Text('3. Guard')),
                ElevatedButton(onPressed: _demoOrchestrator, child: const Text('4. Orchestrator')),
              ],
            ),
            const SizedBox(height: 12),
            const Text('Logs:', style: TextStyle(fontWeight: FontWeight.bold)),
            Expanded(
              child: ListView.builder(
                itemCount: _logs.length,
                itemBuilder: (_, i) => Text(_logs[i], style: const TextStyle(fontSize: 11)),
              ),
            ),
          ],
        ),
      ),
    );
  }
}
