// Test harness — Fake Router service. Simulates router availability.
// DO NOT import production mesh_core_engine. Isolated for testing.

/// Minimal fake for router/cloud connection simulation.
/// Simulates router availability, allows enabling/disabling cloud.
class FakeRouterService {
  bool _hasRouter = false;
  bool _hasInternet = false;

  bool get hasRouter => _hasRouter;
  bool get hasInternet => _hasInternet;
  bool get cloudAvailable => _hasRouter && _hasInternet;

  void setRouterAvailable(bool value) {
    _hasRouter = value;
  }

  void setInternetAvailable(bool value) {
    _hasInternet = value;
  }

  void enableCloud() {
    _hasRouter = true;
    _hasInternet = true;
  }

  void disableCloud() {
    _hasRouter = false;
    _hasInternet = false;
  }
}
