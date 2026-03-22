# Why we are not “Signal in Flutter”

Signal is the reference design for centralized, server-assisted E2EE messengers. This project optimizes for a **different connectivity model and threat landscape**.

This is not a claim that Signal is “bad.” It’s an acknowledgment that our requirements differ.

---

## 1. Primary problem

| Signal-class messengers | This project |
|-------------------------|--------------|
| Assume a **reachable central service** for registration, pre-keys, and delivery | Assumes **intermittent connectivity** and values **device-to-device** paths |
| Strong **asynchronous first message** via uploaded pre-keys | **Deferred** centralized pre-key server; first crypto agreement biased toward **live or relayed** `DR_DH` exchange |
| Single app identity model tied to the service | **Ghost / cloud** modes; local-first storage paths |

---

## 2. Trust model

| Aspect | Signal | This project |
|--------|--------|--------------|
| **Key distribution** | Server directory + Safety Numbers | TOFU (trust-on-first-use) on signed `DR_DH` payloads; local storage |
| **Device change** | Automatic sync via server | Manual trust reset or re-authentication |
| **Multi-device** | Native, centralized | Not prioritized (deferred) |

We do **not** commit to the same server role as Signal. There is no global key transparency or server-mediated identity verification beyond the cloud account layer.

---

## 3. Transport

| Transport | Signal | This project |
|-----------|--------|--------------|
| **Primary** | Centralized servers | Cloud + BLE + (planned) Wi‑Fi Direct |
| **Direct paths** | None | Mesh (peer-to-peer) |
| **Metadata exposure** | Server sees contact graph and timing | Mesh neighbors see timing and presence; cloud sees account-level metadata when used |

---

## 4. Cryptography (high level)

We use modern primitives: **AES-GCM**, **X25519**, **Ed25519**, **HKDF**, **HMAC**. However:

- **Baseline:** AES-GCM per chat key (no forward secrecy)
- **Optional:** Double Ratchet stack for DM chats (`dm_*` IDs) with:
  - X25519 session bootstrap (`DR_DH_INIT` / `DR_DH_ACK`)
  - Ed25519 signatures with TOFU pinning
  - HKDF ratchet with configurable root KDF version (`drDhRootKdf: 2`)

**What we explicitly do NOT implement (by default plan):**

- Centralized pre-key directory (full X3DH)
- Automatic multi-device session sync
- Signal-protocol wire compatibility

These are deferred because they assume a trusted, always-available server — a different operational model. See `docs/E2EE_PRIORITIES.md`.

---

## 5. When a Signal-like server stack would make sense

If product requirements explicitly need:

- First message to an **offline** stranger with **no** mesh path, or
- Seamless **multi-device** session sync without manual re-handshake,

then a central pre-key service becomes justified. That is **phase 8+** territory and not the current default plan.

---

## 6. Summary

**We are not Signal by design.** Different connectivity assumptions, trust model, and server responsibilities.

The goal is a **resilient hybrid mesh + cloud messenger** with documented crypto phases, not a protocol clone.

---

## 7. Further reading

| File | Content |
|------|---------|
| `ARCHITECTURE.md` | System design and transport layers |
| `SECURITY.md` | Threat model and cryptography limits |
| `lib/core/DOUBLE_RATCHET_DESIGN.md` | Ratchet implementation details |
| `docs/E2EE_PRIORITIES.md` | Deferred cryptographic features |

---

*This document is safe to publish. It contains no credentials, API keys, or deployment-specific data.*
