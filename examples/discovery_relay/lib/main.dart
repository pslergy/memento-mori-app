import 'package:flutter/material.dart';
import 'package:discovery_relay_pack/discovery_relay_pack.dart';

void main() => runApp(const MyApp());

class MyApp extends StatelessWidget {
  const MyApp({super.key});

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: 'Discovery & Relay Pack Demo',
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
  DiscoveryRelayPack? _pack;
  final List<String> _logs = [];
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
    DiscoveryRelayPack.initialize(
      config: DiscoveryConfig(onLog: _addLog),
    ).then((pack) {
      if (mounted) {
        setState(() {
          _pack = pack;
          _loading = false;
        });
        pack.onBeaconReceived.listen((msg) => _addLog('Beacon: $msg'));
      }
    });
  }

  @override
  void dispose() {
    _pack?.dispose();
    super.dispose();
  }

  void _encode() {
    if (_pack == null) return;
    final bits = _pack!.encodeMessage('HELLO');
    _addLog('Encoded ${bits.length} bits');
  }

  void _simulate() {
    if (_pack == null) return;
    _pack!.simulateReceive('NEARBY_DEVICE');
    _addLog('Simulated receive');
  }

  Future<void> _connect() async {
    if (_pack == null) return;
    final ok = await _pack!.connect(
      RouterInfo(id: 'r1', ssid: 'DemoRouter', isOpen: true),
    );
    _addLog('Connect: $ok, ${_pack!.connectedRouter?.ssid}');
  }

  void _disconnect() {
    if (_pack == null) return;
    _pack!.disconnect();
    _addLog('Disconnected');
  }

  @override
  Widget build(BuildContext context) {
    if (_loading) {
      return const Scaffold(
        body: Center(child: CircularProgressIndicator()),
      );
    }

    return Scaffold(
      appBar: AppBar(title: const Text('Discovery & Relay Pack')),
      body: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Card(
              color: Colors.purple.shade900,
              child: Padding(
                padding: const EdgeInsets.all(12),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    const Text('Problem solved:', style: TextStyle(fontWeight: FontWeight.bold)),
                    const Text('Proximity discovery without BLE. Router relay when P2P fails.'),
                    const SizedBox(height: 8),
                    Text('Connected: ${_pack?.connectedRouter?.ssid ?? "none"}'),
                  ],
                ),
              ),
            ),
            const SizedBox(height: 8),
            Wrap(
              spacing: 8,
              children: [
                ElevatedButton(onPressed: _encode, child: const Text('Encode')),
                ElevatedButton(onPressed: _simulate, child: const Text('Simulate RX')),
                ElevatedButton(onPressed: _connect, child: const Text('Connect Router')),
                ElevatedButton(onPressed: _disconnect, child: const Text('Disconnect')),
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
