# Memento Mori Field Test Logs

## 2026-06-24 – GHOST ↔ GHOST BLE GATT relay (Huawei ↔ Xiaomi)

**Test summary:**
- **Local:** Huawei (peripheral-only vendor)
- **Remote:** Xiaomi (initiates GATT)
- **Result:** 2 pending messages delivered, outbox cleared, CRDT sync started.

<details>
<summary>Click to expand full log</summary>

Трейдинг как хобби:
[17:33:00] 🔍 [BT-SCAN] Configuring scan: duration=30s, role=GHOST, filter=NONE (check tactical names for both BRIDGE and GHOST)
[17:33:00] 🔍 [BT-SCAN] Received 5 scan result(s), updating discovery context...
[17:33:00] 🔍 [DEBUG] RAW SCAN DATA:
[17:33:00]    MAC: ••:••:••:••:AF:43
[17:33:00]    localName: 'EMPTY'
[17:33:00]    platformName: 'EMPTY'
[17:33:00]    effectiveName: 'EMPTY'
[17:33:00]    serviceUUIDs: [bf27730d-860a-4e09-889c-2d8b6a9e0fe7]
[17:33:00]    manufacturerData: {65535: [71, 72, 87, 192, 58, 28, 186, 254, 104, 158, 0]}
[17:33:00] 🔍 [BT-SCAN] ✅ Mesh device: '' (MAC: ••:••:••:••:AF:43, hops=99)
[17:33:00] 🧲 [Ghost] GHOST detected via manufacturerData fallback! (MAC: ••:••:••:••:AF:43)
[17:33:00] 🔍 [Ghost] Final connection check for GHOST ••:••:••:••:AF:43:
[17:33:00]    📋 Should connect: true (isBridge: false, pending: 2, peerHops: 99, myHops: 100)
[17:33:00]    📋 Cooldown: EXPIRED (key: MAC:48:A0:D4:35:AF:43, remaining: 0s)
[17:33:00]    📋 Transfer active: false
[17:33:00] 🔒 [CASCADE] Starting cascade to 35:AF:43 (active cascades: 1)
[17:33:00] 💾 [CASCADE-FIX] ScanResult saved IMMEDIATELY at cascade start (MAC: 35:AF:43)
[17:33:00] ⛓️ Engaging Cascade for node 48:A0:D4:35:AF:43
[17:33:00]    📋 Cooldown will be set ONLY after failed attempt (not before!)
[17:33:00] 🔍 [BT-SCAN] Summary: Found 1 mesh device(s)
[17:33:00] 🔍 [ROLE-CHECK] My role: GHOST, My hops: 100, My pending: 2
[17:33:00] 🔍 [ROLE-CHECK] Peer role: GHOST, Peer hops: 99
[17:33:00] ✅ [BT-SCAN] BLE scan started successfully (no filter - can see both BRIDGE and GHOST by tactical name)
[17:33:00] 🔍 [BT-SCAN] Received 1 scan result(s), updating discovery context...
[17:33:01] 📤 [GHOST↔GHOST] roleDecision=peer closer to internet, shouldConnect=true
[17:33:01] [BLE][ADAPTIVE][DEGRADED] reason=NO_RELAY
[17:33:01] [BLE-STRATEGY] local=HUAWEI peer=UNKNOWN → peerInitiates
[17:33:01] 📤 [GHOST↔GHOST] Strategy: not initiating GATT (restrictive vendor or passive), waiting for peer to connect
[17:33:01] 🔍 [BT-SCAN] Received 2 scan result(s), updating discovery context...
[17:33:01] 🔍 [DEBUG] RAW SCAN DATA:
[17:33:01]    MAC: ••:••:••:••:4D:83
[17:33:01]    localName: 'EMPTY'
[17:33:01]    platformName: 'EMPTY'
[17:33:01]    effectiveName: 'EMPTY'
[17:33:01]    serviceUUIDs: [bf27730d-860a-4e09-889c-2d8b6a9e0fe7]
[17:33:01]    manufacturerData: {65535: [71, 72, 87, 192, 58, 28, 186, 254, 104, 158, 0]}
[17:33:01] 🔍 [BT-SCAN] ✅ Mesh device: '' (MAC: ••:••:••:••:4D:83, hops=99)
[17:33:01] 🧲 [Ghost] GHOST detected via manufacturerData fallback! (MAC: ••:••:••:••:4D:83)
[17:33:01] 🔍 [Ghost] Final connection check for GHOST ••:••:••:••:4D:83:
[17:33:01]    📋 Should connect: true (isBridge: false, pending: 2, peerHops: 99, myHops: 100)
[17:33:01]    📋 Cooldown: EXPIRED (key: MAC:70:A3:83:33:4D:83, remaining: 0s)
[17:33:01]    📋 Transfer active: false
[17:33:01] 🔒 [CASCADE] Starting cascade to 33:4D:83 (active cascades: 1)
[17:33:01] 💾 [CASCADE-FIX] ScanResult saved IMMEDIATELY at cascade start (MAC: 33:4D:83)
[17:33:01] ⛓️ Engaging Cascade for node 70:A3:83:33:4D:83
[17:33:01]    📋 Cooldown will be set ONLY after failed attempt (not before!)
[17:33:01] 🔍 [BT-SCAN] Summary: Found 1 mesh device(s)
[17:33:01] 🔍 [ROLE-CHECK] My role: GHOST, My hops: 100, My pending: 2
[17:33:01] 🔍 [ROLE-CHECK] Peer role: GHOST, Peer hops: 99
[17:33:01] 📤 [GHOST↔GHOST] roleDecision=peer closer to internet, shouldConnect=true
[17:33:01] [BLE-STRATEGY] local=HUAWEI peer=UNKNOWN → peerInitiates
[17:33:01] 📤 [GHOST↔GHOST] Strategy: not initiating GATT (restrictive vendor or passive), waiting for peer to connect
[17:33:01] 🔍 [BT-SCAN] Received 3 scan result(s), updating discovery context...
[17:33:01] 🔍 [DEBUG] RAW SCAN DATA:
[17:33:01]    MAC: ••:••:••:••:4D:83

</details>

### Key moments in this log
1. **Discovery:** GHOST detects multiple peers via BLE manufacturer data (`0xFFFF`) even when `localName` is empty.
2. **Vendor adaptation:** `local=HUAWEI peer=UNKNOWN → peerInitiates` — the Huawei device correctly avoids initiating GATT and waits for the peer to connect (avoiding `GATT_BUSY`).
3. **Cascade control:** `Transfer already in progress` shows proper mutex handling, preventing duplicate connections.
4. **Fragmentation:** Message `temp_1773326054244` split into 2 fragments (60+32 bytes), reassembled successfully.
5. **Outbox pull:** Central device sends `OUTBOX_REQUEST`, server responds with 3 pending messages, all removed from outbox after confirmation.
6. **CRDT sync:** After outbox delivery, `HEAD_EXCHANGE` starts for 3 chats — confirms CRDT anti-entropy works.
7. **Gossip deduplication:** `Message temp_177 already exists in DB - skipping relay` — flood protection works.
