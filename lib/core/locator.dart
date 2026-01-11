import 'package:get_it/get_it.dart';
import 'encryption_service.dart';
import 'mesh_service.dart';
import 'api_service.dart';

final locator = GetIt.instance;

void setupLocator() {
  // Регистрируем сервис шифрования (обязательно!)
  locator.registerLazySingleton(() => EncryptionService());

  // Регистрируем остальные сервисы как синглтоны
  locator.registerLazySingleton(() => MeshService());
  locator.registerLazySingleton(() => ApiService());
}