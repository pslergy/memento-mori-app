import 'package:get_it/get_it.dart';
import 'api_service.dart';
import 'encryption_service.dart';
import 'gossip_manager.dart';
import 'local_db_service.dart';
import 'mesh_service.dart';
import 'ultrasonic_service.dart'; // 🔥 Убедись, что импорт есть

final GetIt locator = GetIt.instance;

void setupLocator() {
  locator.registerLazySingleton(() => GossipManager());
  locator.registerLazySingleton(() => ApiService());
  locator.registerLazySingleton(() => EncryptionService());
  locator.registerLazySingleton(() => LocalDatabaseService());
  locator.registerLazySingleton(() => MeshService());

  // 🔥 ДОБАВЬ ЭТУ СТРОКУ:
  locator.registerLazySingleton(() => UltrasonicService());
}