# Memento Mori Field Test Logs

## 2026-06-24 – GHOST ↔ GHOST BLE GATT relay (Huawei ↔ Xiaomi)

**Test summary:**
- **Local:** Huawei (peripheral-only vendor)
- **Remote:** Xiaomi (initiates GATT)
- **Result:** 2 pending messages delivered, outbox cleared, CRDT sync started.

<details>
<summary>Click to expand full log</summary>

Полный лог теста: (field_test_2026_06_23.log)

</details>

### Key moments in this log
1. **Discovery:** GHOST detects multiple peers via BLE manufacturer data (`0xFFFF`) even when `localName` is empty.
2. **Vendor adaptation:** `local=HUAWEI peer=UNKNOWN → peerInitiates` — the Huawei device correctly avoids initiating GATT and waits for the peer to connect (avoiding `GATT_BUSY`).
3. **Cascade control:** `Transfer already in progress` shows proper mutex handling, preventing duplicate connections.
4. **Fragmentation:** Message `temp_1773326054244` split into 2 fragments (60+32 bytes), reassembled successfully.
5. **Outbox pull:** Central device sends `OUTBOX_REQUEST`, server responds with 3 pending messages, all removed from outbox after confirmation.
6. **CRDT sync:** After outbox delivery, `HEAD_EXCHANGE` starts for 3 chats — confirms CRDT anti-entropy works.
7. **Gossip deduplication:** `Message temp_177 already exists in DB - skipping relay` — flood protection works.
