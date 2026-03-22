markdown
# Architecture — Memento Mori

This document describes the system design at a level useful for contributors and technical evaluators. It focuses on **how** the system works, not why we made certain trade-offs (see `WHY_NOT_SIGNAL.md` for that).

---

## 1. Core principles

- **Resilience first:** The system must function with **no internet**, using only device-to-device paths. Cloud connectivity is an enhancement, not a hard dependency.
- **Hybrid transport:** The same logical message can travel via cloud (when available) or mesh (when not). Transport selection is transparent to higher layers.
- **Privacy by design:** E2EE is mandatory for DM content. Metadata exposure is bounded by design (though not eliminated — see `SECURITY.md`).

---

## 2. Layered architecture
┌─────────────────────────────────────────────────────────────┐

UI (Flutter) │

│ — Chat views, profile, transport indicators │

├─────────────────────────────────────────────────────────────┤


│ App Services │

│ — API client, WebSocket manager, room state, event bus │

├─────────────────────────────────────────────────────────────┤



│ Mesh Core │

│ — Session graph, packet dispatch, gossip relay, CRDT sync │

│ — Roles: GHOST / CLIENT / BRIDGE (based on connectivity) │

├─────────────────────────────────────────────────────────────┤


│ Transport Layer │

│ — BLE GATT (primary mesh transport) │

│ — Wi‑Fi Direct (planned, for bulk data) │

│ — Cloud (HTTPS / WebSocket) │

├─────────────────────────────────────────────────────────────┤


│ Persistence │

│ — SQLite (messages, session state, CRDT logs) │

│ — Keystore / Keychain (crypto keys, identity material) │

└─────────────────────────────────────────────────────────────┘


text

All core services are registered via `get_it` and injected into feature modules. No direct platform dependencies leak into UI layers.

---

## 3. Transport matrix

| Transport | Use case | Constraints |
|-----------|----------|-------------|
| **Cloud (HTTPS)** | Account operations, REST API, push when online | Subject to network filtering; fallback via `backendChannels` rotation |
| **Cloud (WebSocket)** | Real-time delivery when online | Same constraints as HTTPS |
| **BLE (GATT)** | Neighbor messaging, discovery, multi-hop gossip | Limited bandwidth (~20 bytes per characteristic), high latency, device-specific reliability |
| **Wi‑Fi Direct**  | Bulk sync (history, media), fallback when BLE unstable | Requires group owner negotiation; power-intensive |
| **P2P TCP** (optional) | LAN / ad-hoc paths | Platform-dependent, often blocked by network policies |

**Key property:** Transports carry **opaque ciphertext** only. All application-level framing (message IDs, ratchet headers, CRDT payloads) is encrypted before reaching the transport layer.

---

## 4. Mesh routing

Two complementary mechanisms:

### 4.1 Gossip (epidemic)

- Packets are broadcast to all neighbors with a TTL.
- Deduplication via seen set (in-memory + persisted).
- Simple, robust, but creates O(N²) traffic in dense networks.

### 4.2 Gradient-based routing (planned)

- Each node maintains a **distance estimate** (in hops) to reachable destinations.
- Packets are forwarded only to neighbors with **lower** gradient (closer to target).
- Reduces airtime and battery consumption at scale.

Current implementation uses gossip with TTL limits. Gradient routing will be introduced when network density requires it.

---

## 5. CRDT-based history sync

Chat history is replicated using **CRDTs** (Conflict-Free Replicated Data Types). This allows two devices that haven't met recently to merge their divergent histories without a central coordinator.

**Protocol flow (CrdtReconciliation):**

1. **HEAD_EXCHANGE:** Peers exchange per-author maximum sequence numbers (`getHeads()`).
2. **Diff calculation:** Each peer determines which ranges the other is missing.
3. **REQUEST_RANGE / LOG_ENTRIES:** Missing entries are transferred and merged.

**Invariant:** Every message in a chat has a `(senderId, sequenceNumber)` that is monotonic per author. Forks are possible (due to concurrent offline sends) and are tracked via `fork_of_id`.

Messages that arrive only via gossip (bypassing CRDT append) may not be included in head exchange. This is a known limitation being addressed.

---

## 6. Identity and roles

### 6.1 Ghost vs cloud-linked identity

- **Ghost mode:** Local-only identity, no cloud account. Mesh features work; cloud APIs are unavailable.
- **Cloud-linked:** Standard account with server-side presence. All features available.

### 6.2 Network roles

Nodes self-assign roles based on connectivity:

| Role | Criteria | Behavior |
|------|----------|----------|
| **BRIDGE** | Has working internet | Relays messages between mesh and cloud; prioritized for gradient routing |
| **GHOST** | No internet, good battery | Participates in mesh, relays messages for others |
| **CLIENT** | No internet, low battery | Minimal relay participation, receives only |

Role negotiation happens via `NetworkMonitor` and influences routing decisions.

---

## 7. Transport selection and fallback

When sending a message:

1. **Encrypt** using appropriate crypto path (legacy AES-GCM or Double Ratchet).
2. **If cloud available:** Send via WebSocket/HTTPS. Track success.
3. **If cloud unavailable or fails:** Enqueue for mesh delivery.
4. **Mesh delivery:** Gossip to neighbors; BRIDGE nodes may forward to cloud later.

Backend channels (`backendChannels` in `SecurityConfig`) support multiple hosts/ports with automatic rotation on failure. The client returns to the primary channel after successful connectivity.

---

## 8. What this architecture does NOT provide

- **Guaranteed delivery under all network conditions.** Two devices that never meet and have no internet cannot exchange messages.
- **Concealment of radio activity.** BLE scanning reveals that devices are communicating.
- **Anonymity comparable to Tor.** This is a messenger, not a mix network.
- **Signal-compatible cryptography.** Our Double Ratchet implementation is custom; see `WHY_NOT_SIGNAL.md`.

---

## 9. Related documentation

| File | Content |
|------|---------|
| `WHY_NOT_SIGNAL.md` | Architectural comparison with Signal-class messengers |
| `SECURITY.md` | Threat model and cryptography details |


---

*This document intentionally omits implementation secrets, API keys, and deployment-specific endpoints.*
