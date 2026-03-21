import 'mesh_license_provider.dart';

/// Validates a purchased license key.
///
/// In a production implementation, this would call a license server
/// or verify a signed key. This is an interface placeholder —
/// do not add blocking enforcement logic here.
class KeyLicenseProvider implements MeshLicenseProvider {
  KeyLicenseProvider({required this.key});

  final String key;

  @override
  Future<bool> validateLicense(String key) async {
    // Placeholder: implement your validation logic (e.g. call license server).
    // Do not block or throw — return false for invalid keys.
    return this.key.isNotEmpty;
  }

  @override
  String get status => key.isEmpty ? 'invalid' : 'commercial';
}
