import 'dart:typed_data';

import 'package:flutter/material.dart';
import 'package:ble_payload_pack/ble_payload_pack.dart';

void main() => runApp(const MyApp());

class MyApp extends StatelessWidget {
  const MyApp({super.key});

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: 'BLE Payload Pack Demo',
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
  BlePayloadPack? _pack;
  final List<String> _logs = [];
  double _progress = 0.0;
  String _status = 'Idle';
  bool _busy = false;
  bool _loading = true;

  void _addLog(String msg) {
    setState(() {
      _logs.insert(0, '${DateTime.now().toString().substring(11, 19)} $msg');
      if (_logs.length > 25) _logs.removeLast();
    });
  }

  @override
  void initState() {
    super.initState();
    BlePayloadPack.initialize(
      config: PayloadConfig(onLog: _addLog),
    ).then((pack) {
      if (mounted) setState(() {
        _pack = pack;
        _loading = false;
      });
    });
  }

  Future<void> _simulateWrite(Uint8List chunk) async {
    await Future.delayed(const Duration(milliseconds: 5));
  }

  Future<void> _demoSend() async {
    if (_pack == null || _busy) return;
    setState(() {
      _busy = true;
      _progress = 0.0;
      _status = 'Sending...';
    });

    final payload = Uint8List.fromList('Hello BLE Payload Pack!'.codeUnits);
    try {
      await for (final p in _pack!.sendLargePayload(payload, _simulateWrite)) {
        if (mounted) setState(() {
          _progress = p.progress;
          _status = '${p.chunkIndex + 1}/${p.totalChunks}';
        });
      }
      _addLog('Send complete');
    } finally {
      if (mounted) setState(() {
        _busy = false;
        _progress = 1.0;
        _status = 'Done';
      });
    }
  }

  Future<void> _demoSplitAssemble() async {
    if (_pack == null || _busy) return;
    setState(() => _busy = true);
    const text = 'Split and assemble with FEC.';
    final chunks = _pack!.splitPayload(
      Uint8List.fromList(text.codeUnits),
      messageId: 'demo1',
    );
    _addLog('Split: ${text.length} bytes -> ${chunks.length} chunks');
    final assembled = _pack!.assemblePayload(chunks);
    final result = String.fromCharCodes(assembled);
    _addLog('Assembled: "$result" (ok: ${result == text})');
    setState(() => _busy = false);
  }

  @override
  Widget build(BuildContext context) {
    if (_loading) {
      return const Scaffold(
        body: Center(child: CircularProgressIndicator()),
      );
    }

    return Scaffold(
      appBar: AppBar(title: const Text('BLE Payload Pack')),
      body: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Card(
              color: Colors.green.shade900,
              child: Padding(
                padding: const EdgeInsets.all(12),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    const Text('Problem solved:', style: TextStyle(fontWeight: FontWeight.bold)),
                    const Text('MTU limits, packet loss. Chunk + frame + FEC + CRC.'),
                    const SizedBox(height: 8),
                    Text('$_status'),
                    LinearProgressIndicator(value: _progress),
                  ],
                ),
              ),
            ),
            const SizedBox(height: 8),
            Wrap(
              spacing: 8,
              children: [
                ElevatedButton(
                  onPressed: _busy ? null : _demoSend,
                  child: const Text('Send Large Payload'),
                ),
                ElevatedButton(
                  onPressed: _busy ? null : _demoSplitAssemble,
                  child: const Text('Split & Assemble'),
                ),
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
