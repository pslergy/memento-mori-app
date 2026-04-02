/// License validation interface for MeshStack SDK.
///
/// Community: use [NoOpMeshLicenseProvider].
/// Commercial: use [KeyLicenseProvider] with purchased key.
abstract class MeshLicenseProvider {
  /// Validates the license. Returns true if valid.
  Future<bool> validateLicense(String key);

  /// Human-readable status for debugging.
  String get status => 'unknown';
}
