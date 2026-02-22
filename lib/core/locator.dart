// lib/core/locator.dart
//
// Staged DI: BOOT (SAFE) → CORE (after permissions) → SESSION (after permissions, before mesh use).
// Permission UI must not touch CORE or SESSION; only SAFE or nothing.

import 'package:get_it/get_it.dart';
import 'MeshOrchestrator.dart';
import 'api_service.dart';
import 'decoy/app_mode.dart';
import 'decoy/mode_scoped_vault.dart';
import 'decoy/storage_paths.dart';
import 'decoy/routine_runner.dart';
import 'decoy/timed_panic_controller.dart';
import 'decoy/vault_interface.dart';
import 'encryption_service.dart';
import 'local_db_service.dart';
import 'mesh_service.dart';
import 'ultrasonic_service.dart';
import 'gossip_manager.dart';
import 'bluetooth_service.dart';
import 'discovery_context_service.dart';
import 'connection_phase.dart';
import 'node_mode.dart';
import 'connection_stabilizer.dart';
import 'repeater_service.dart';
import 'ghost_transfer_manager.dart';
import 'peer_cache_service.dart';
import 'network_phase_context.dart';
import 'storage_service.dart';
import 'transport/transport_config.dart';
import 'transport/lora_transport.dart';

final GetIt locator = GetIt.instance;

/// Mesh/Ghost: current user id — from ApiService when registered, else from Vault (Ghost).
/// Use in mesh code so Ghost works without ApiService.
Future<String> getCurrentUserIdSafe() async {
  if (locator.isRegistered<ApiService>()) {
    return locator<ApiService>().currentUserId;
  }
  final id = await Vault.read('user_id');
  return id ?? 'GHOST_NODE';
}

// ——— BOOT / SAFE ———
// No CORE (DB, Vault) or SESSION (Mesh, Panic). Permission screen may run with only this.

/// Call in main() before runApp. Registers nothing that requires DB/Vault/Mesh.
/// Permission UI must not resolve CORE or SESSION.
void setupLocatorSafe() {
  // Optional: Logger, DeviceInfo, AppLifecycleObserver — currently no-op to avoid touching existing code.
}

// ——— CORE (after permissions granted) ———
// Vault, LocalDatabaseService, EncryptionService. Required before any screen that uses DB/Vault.

void _registerCoreForMode(AppMode mode) {
  locator.registerLazySingleton<VaultInterface>(() => ModeScopedVault(mode));
  locator.registerLazySingleton<LocalDatabaseService>(
      () => LocalDatabaseService.raw(
            dbFileName: dbFileNameForMode(mode),
            vault: locator<VaultInterface>(),
            dbDirectorySuffix: dbDirectorySuffixForMode(mode),
          ));
  locator.registerLazySingleton<EncryptionService>(
      () => EncryptionService(locator<VaultInterface>()));
}

/// Call only after permissions are granted (e.g. from PermissionGate). Registers Vault, DB, Encryption.
void setupCoreLocator(AppMode mode) {
  locator.reset();
  _registerCoreForMode(mode);
}

/// Регистрирует CORE без reset(), чтобы не терять данные Vault (например, Ghost после регистрации).
/// Вызывать из Splash, когда coreMissing — тогда идентичность, записанная до перехода на Splash, сохранится.
void ensureCoreLocator(AppMode mode) {
  if (locator.isRegistered<VaultInterface>() &&
      locator.isRegistered<LocalDatabaseService>() &&
      locator.isRegistered<EncryptionService>()) {
    return;
  }
  if (!locator.isRegistered<VaultInterface>()) {
    locator.registerLazySingleton<VaultInterface>(() => ModeScopedVault(mode));
  }
  if (!locator.isRegistered<LocalDatabaseService>()) {
    locator.registerLazySingleton<LocalDatabaseService>(
      () => LocalDatabaseService.raw(
        dbFileName: dbFileNameForMode(mode),
        vault: locator<VaultInterface>(),
        dbDirectorySuffix: dbDirectorySuffixForMode(mode),
      ),
    );
  }
  if (!locator.isRegistered<EncryptionService>()) {
    locator.registerLazySingleton<EncryptionService>(
      () => EncryptionService(locator<VaultInterface>()),
    );
  }
}

// ——— SESSION (after permissions; used by PostPermissionsScreen and Splash) ———
// Mesh, GhostTransferManager, TimedPanicController. Do not register before CORE.

void _registerMeshAndTransport() {
  locator.registerLazySingleton(() => ConnectionPhaseController());
  locator.registerLazySingleton(() => NodeModeController());
  locator.registerLazySingleton(() => ApiService());
  locator.registerLazySingleton(() => MeshService());
  locator.registerLazySingleton(() => GossipManager());
  locator.registerLazySingleton(() => UltrasonicService());
  locator.registerLazySingleton(() => BluetoothMeshService());
  locator.registerLazySingleton(() => DiscoveryContextService());
  locator.registerLazySingleton(() => ConnectionStabilizer());
  locator.registerLazySingleton(() => RepeaterService());
  locator.registerLazySingleton(() => GhostTransferManager());
  locator.registerLazySingleton(() => PeerCacheService());
  locator.registerLazySingleton(() => NetworkPhaseContext());
  locator.registerLazySingleton(() => TacticalMeshOrchestrator());
  locator.registerLazySingleton(() => RoutineRunner());

  if (TransportConfig.enableLoRa) {
    locator.registerLazySingleton<LoRaTransport>(() => LoRaTransport());
  }
}

void _registerPanicIfReal(AppMode mode) {
  if (mode == AppMode.REAL) {
    locator.registerLazySingleton(() => TimedPanicController());
  }
}

/// Call after setupCoreLocator(mode). Registers mesh/transport and panic (REAL). Do not call from Permission UI.
void setupSessionLocator(AppMode mode) {
  assert(
    locator.isRegistered<VaultInterface>() &&
        locator.isRegistered<LocalDatabaseService>() &&
        locator.isRegistered<EncryptionService>(),
    'Call setupCoreLocator(mode) before setupSessionLocator.',
  );
  _registerMeshAndTransport();
  _registerPanicIfReal(mode);
}

// ——— Guard helpers (for screens / mesh start) ———

/// True if CORE (Vault, DB, Encryption) is registered. Use before any DB/Vault/Encryption access.
bool get isCoreReady =>
    locator.isRegistered<VaultInterface>() &&
    locator.isRegistered<LocalDatabaseService>() &&
    locator.isRegistered<EncryptionService>();

/// True if MeshService is registered. Use before starting mesh or resolving mesh-dependent services.
bool get isMeshReady => locator.isRegistered<MeshService>();

/// True if full SESSION is ready (Mesh + Orchestrator). Use before startMeshNetwork.
bool get isSessionReady =>
    isCoreReady &&
    locator.isRegistered<MeshService>() &&
    locator.isRegistered<TacticalMeshOrchestrator>();

// ——— Battle audit: log missing services for a screen/function ———

/// Call when a screen or function needs a service that might be missing (Ghost/Offline).
/// Logs which services are missing so we can trace UI/network guards.
void logMissingFor(String screenOrFunction,
    {bool requireCore = true,
    bool requireMesh = false,
    bool requireApi = false}) {
  final missing = <String>[];
  if (requireCore && !isCoreReady) {
    if (!locator.isRegistered<VaultInterface>()) missing.add('VaultInterface');
    if (!locator.isRegistered<LocalDatabaseService>())
      missing.add('LocalDatabaseService');
    if (!locator.isRegistered<EncryptionService>())
      missing.add('EncryptionService');
  }
  if (requireMesh && !locator.isRegistered<MeshService>())
    missing.add('MeshService');
  if (requireApi && !locator.isRegistered<ApiService>())
    missing.add('ApiService');
  if (missing.isEmpty) return;
  print(
      '[GetIt] $screenOrFunction — missing: ${missing.join(", ")} (Ghost/Offline safe)');
}

// ——— Legacy / fallback (single-shot full setup for tests or recovery) ———

/// Full registration in one go. Prefer staged setup in production.
void setupLocatorForMode(AppMode mode) {
  locator.reset();
  _registerCoreForMode(mode);
  _registerMeshAndTransport();
  _registerPanicIfReal(mode);
}

void setupLocator() {
  locator.reset();
  locator.registerLazySingleton<VaultInterface>(
      () => ModeScopedVault(AppMode.REAL));
  locator.registerLazySingleton(() => LocalDatabaseService.raw(
      dbFileName: dbFileNameForMode(AppMode.REAL),
      vault: locator<VaultInterface>(),
      dbDirectorySuffix: dbDirectorySuffixForMode(AppMode.REAL)));
  locator.registerLazySingleton(
      () => EncryptionService(locator<VaultInterface>()));
  _registerMeshAndTransport();
}
