import 'package:flutter_test/flutter_test.dart';
import 'package:memento_mori_app/core/double_ratchet/dr_dh_peer_pins.dart';
import 'package:shared_preferences/shared_preferences.dart';

void main() {
  test('DrDhPeerPins TOFU then reject other key', () async {
    SharedPreferences.setMockInitialValues({});
    expect(await DrDhPeerPins.getPin('alice'), isNull);
    expect(await DrDhPeerPins.verifyOrPin('alice', 'keyA'), isTrue);
    expect(await DrDhPeerPins.getPin('alice'), 'keyA');
    expect(await DrDhPeerPins.verifyOrPin('alice', 'keyA'), isTrue);
    expect(await DrDhPeerPins.verifyOrPin('alice', 'keyB'), isFalse);
    await DrDhPeerPins.clearPin('alice');
    expect(await DrDhPeerPins.getPin('alice'), isNull);
    expect(await DrDhPeerPins.verifyOrPin('alice', 'keyB'), isTrue);
  });
}
