// lib/core/locator.dart
import 'package:get_it/get_it.dart';
import 'MeshOrchestrator.dart';
import 'api_service.dart';
import 'encryption_service.dart';
import 'local_db_service.dart';
import 'mesh_service.dart';
import 'ultrasonic_service.dart';
import 'gossip_manager.dart';
import 'bluetooth_service.dart'; // 🔥 Не забудь импорт!
import 'discovery_context_service.dart'; // 🔥 Discovery Context Service
import 'connection_stabilizer.dart'; // 🔥 Connection Stabilizer
import 'repeater_service.dart'; // 🔥 Repeater/Repair Service
import 'ghost_transfer_manager.dart'; // 🔥 Оптимизированный Ghost Transfer Manager


final GetIt locator = GetIt.instance;

void setupLocator() {
  locator.registerLazySingleton(() => ApiService());
  locator.registerLazySingleton(() => EncryptionService());
  locator.registerLazySingleton(() => LocalDatabaseService());
  locator.registerLazySingleton(() => MeshService());
  locator.registerLazySingleton(() => GossipManager());
  locator.registerLazySingleton(() => UltrasonicService());

  // 🔥 РЕГИСТРИРУЕМ БЛЮТУЗ (его не было в списке!)
  locator.registerLazySingleton(() => BluetoothMeshService());
  
  // 🔥 Discovery Context Service - единый источник правды для обнаружения
  locator.registerLazySingleton(() => DiscoveryContextService());
  
  // 🔥 Connection Stabilizer - локальный менеджер для стабилизации подключений
  locator.registerLazySingleton(() => ConnectionStabilizer());
  
  // 🔥 Repeater/Repair Service - автоматическая ретрансляция и восстановление соединений
  locator.registerLazySingleton(() => RepeaterService());
  
  // 🔥 Ghost Transfer Manager - оптимизированная очередь передачи сообщений
  locator.registerLazySingleton(() => GhostTransferManager());

  // Оркестратор регистрируем ПОСЛЕДНИМ
  locator.registerLazySingleton(() => TacticalMeshOrchestrator());
}