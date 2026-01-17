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

  // Оркестратор регистрируем ПОСЛЕДНИМ
  locator.registerLazySingleton(() => TacticalMeshOrchestrator());
}