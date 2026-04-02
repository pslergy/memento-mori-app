import 'mesh_license_provider.dart';

/// Community mode: no validation, always returns true.
class NoOpMeshLicenseProvider implements MeshLicenseProvider {
  @override
  Future<bool> validateLicense(String key) async => true;

  @override
  String get status => 'community';
}
