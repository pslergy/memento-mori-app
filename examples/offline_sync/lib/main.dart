import 'package:flutter/material.dart';
import 'package:offline_sync_pack/offline_sync_pack.dart';

void main() => runApp(const MyApp());

class MyApp extends StatelessWidget {
  const MyApp({super.key});

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: 'Offline Sync Pack Demo',
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
  OfflineSyncPack? _pack;
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
    OfflineSyncPack.initialize(
      buildHeads: () async => {'scope1': {'authorA': 3, 'authorB': 1}},
      getEntriesByRange: (scope, authorId, from, to) async {
        _addLog('getEntries: $scope $authorId $from-$to');
        return [];
      },
      saveEntries: (scope, entries) async {
        _addLog('saveEntries: $scope, ${entries.length} entries');
        return entries.length;
      },
      config: CrdtSyncConfig(onLog: _addLog),
      sendToPeer: (peer, payload) async {
        _addLog('CRDT sent to $peer: ${payload.length} chars');
      },
    ).then((pack) {
      if (mounted) setState(() {
        _pack = pack;
        _loading = false;
      });
    });
  }

  Future<void> _merge() async {
    if (_pack == null) return;
    await _pack!.merge('AA:BB:CC:DD:EE:FF');
    _addLog('Merge (digest exchange) started');
  }

  Future<void> _processIncoming() async {
    if (_pack == null) return;
    await _pack!.processIncoming('AA:BB:CC', {
      'type': 'HEAD_EXCHANGE',
      'isReply': false,
      'heads': {'scope1': {'authorA': 1}},
    });
    _addLog('Processed HEAD_EXCHANGE');
  }

  @override
  Widget build(BuildContext context) {
    if (_loading) {
      return const Scaffold(
        body: Center(child: CircularProgressIndicator()),
      );
    }

    return Scaffold(
      appBar: AppBar(title: const Text('Offline Sync Pack')),
      body: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Card(
              color: Colors.orange.shade900,
              child: const Padding(
                padding: EdgeInsets.all(12),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text('Problem solved:', style: TextStyle(fontWeight: FontWeight.bold)),
                    Text('Offline sync without server. CRDT anti-entropy + transport.'),
                  ],
                ),
              ),
            ),
            const SizedBox(height: 8),
            Wrap(
              spacing: 8,
              children: [
                ElevatedButton(onPressed: _merge, child: const Text('Merge (Start Sync)')),
                ElevatedButton(onPressed: _processIncoming, child: const Text('Process Incoming')),
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
