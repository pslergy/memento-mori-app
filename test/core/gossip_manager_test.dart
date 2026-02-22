import 'dart:convert';
import 'package:flutter_test/flutter_test.dart';
import 'package:memento_mori_app/core/models/signal_node.dart';
import 'package:mocktail/mocktail.dart';
import 'package:fake_async/fake_async.dart';

// Импорты твоего проекта
import 'package:memento_mori_app/core/gossip_manager.dart';
import 'package:memento_mori_app/core/local_db_service.dart';
import 'package:memento_mori_app/core/mesh_service.dart';
import 'package:memento_mori_app/core/locator.dart';
import 'package:memento_mori_app/features/chat/conversation_screen.dart'; // Для ChatMessage

// 1. Создаем фальшивые версии твоих сервисов
class MockDB extends Mock implements LocalDatabaseService {}
class MockMesh extends Mock implements MeshService {}
class FakeChatMessage extends Fake implements ChatMessage {}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  late GossipManager gossipManager;
  late MockDB mockDb;
  late MockMesh mockMesh;

  // Регистрация типов для mocktail (обязательно для кастомных классов)
  setUpAll(() {
    registerFallbackValue(FakeChatMessage());
  });

  // Этот блок выполняется перед КАЖДЫМ тестом
  setUp(() async { // 🔥 Добавили async
    mockDb = MockDB();
    mockMesh = MockMesh();

    // 🔥 КРИТИЧЕСКИЙ ФИКС: Ждем, пока локатор полностью очистится
    await locator.reset();

    locator.registerSingleton<LocalDatabaseService>(mockDb);
    locator.registerSingleton<MeshService>(mockMesh);


    when(() => mockMesh.nearbyNodes).thenReturn([]);
    when(() => mockMesh.isP2pConnected).thenReturn(true);

    gossipManager = GossipManager();
  });

  group('GossipProtocol: Deduplication & TTL', () {

    test('Should DROP duplicate packets (Anti-Entropy logic)', () async {
      final packet = {'h': 'pulse_123', 'content': 'test', 'chatId': 'GLOBAL'};

      // Имитируем ситуацию: БД говорит, что уже видела этот пакет
      when(() => mockDb.isPacketSeen('pulse_123')).thenAnswer((_) async => true);

      await gossipManager.processEnvelope(packet);

      // Проверяем: метод saveMessage НЕ должен быть вызван (verifyNever)
      verifyNever(() => mockDb.saveMessage(any(), any()));
      print("✅ Deduplication test passed: Duplicate dropped.");
    });

    test('Should DECREMENT TTL on each hop', () async {
      final packet = {'h': 'new_pulse', 'ttl': 5, 'content': 'hello', 'chatId': 'GLOBAL'};

      // 🔥 Создаем фейковую ноду
      final fakeNode = SignalNode(
          id: 'peer_1',
          name: 'Test Node',
          type: SignalType.mesh,
          metadata: '192.168.49.1'
      );

      when(() => mockDb.isPacketSeen('new_pulse')).thenAnswer((_) async => false);
      when(() => mockDb.saveMessage(any(), any())).thenAnswer((_) async => {});

      // 🔥 ГЛАВНЫЙ ФИКС: Возвращаем список с одним соседом, чтобы логика пошла дальше
      when(() => mockMesh.nearbyNodes).thenReturn([fakeNode]);
      when(() => mockMesh.isHost).thenReturn(false);

      await gossipManager.processEnvelope(packet);

      // Теперь TTL обязан стать 4
      expect(packet['ttl'], 4);
      print("✅ TTL Decay test passed: 5 -> 4 with simulated neighbor.");
    });
  });

  group('GossipProtocol: Epidemic Cycle', () {
    test('Should scan outbox and try to infect neighbors every 30s', () {
      // fakeAsync позволяет "промотать" время без ожидания
      fakeAsync((async) {
        when(() => mockDb.getPendingFromOutbox()).thenAnswer((_) async => [
          {'id': 'msg_1', 'chatRoomId': 'GLOBAL', 'content': 'payload'}
        ]);
        when(() => mockMesh.nearbyNodes).thenReturn([]);

        gossipManager.startEpidemicCycle();

        // Проматываем 31 секунду
        async.elapse(const Duration(seconds: 31));

        // Проверяем: менеджер должен был полезть в БД за сообщениями
        verify(() => mockDb.getPendingFromOutbox()).called(1);

        gossipManager.stop();
        print("✅ Epidemic Cycle test passed: Timer triggered successfully.");
      });
    });
  });
}