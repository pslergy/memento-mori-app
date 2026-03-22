# Security Policy — Threat Model and Cryptography

This document describes **what we protect**, **against whom**, and **what limits exist**. It is not a formal certification — it’s a transparent description of design intent.

---

## 1. Assets we protect

| Asset | Protection mechanism |
|-------|----------------------|
| **DM message content** | AES-GCM (baseline) or Double Ratchet (optional). Keys in Keystore/Keychain. |
| **Local data at rest** | OS-level encryption (file-based or full-disk). Keys separate from content. |
| **In-transit confidentiality** | TLS for cloud paths; application-layer encryption for mesh (transports carry only opaque ciphertext). |

---

## 2. Adversaries considered

| Adversary | Mitigation |
|-----------|------------|
| **Passive network observer** (ISP, Wi‑Fi operator) | TLS protects cloud paths; mesh ciphertext is opaque without keys. |
| **Active network attacker** | App-layer crypto with integrity checks (HMAC, AEAD). Replay protection via message IDs and sequence numbers. |
| **Malicious relay / gossip node** | May see metadata (who talks, when, sizes). Cannot decrypt content without keys. DR_DH authentication uses Ed25519 + TOFU. |
| **Compromised device** | Out of scope. If the device is rooted or malware runs in app context, no messenger can protect keys or screen content. |

---

## 3. Explicit non-goals

| Non-goal | Rationale |
|----------|-----------|
| **Hiding the fact of communication** | BLE/Wi‑Fi radio activity is observable. We do not implement RF-layer concealment. |
| **Mix-network anonymity** | This is a messenger, not Tor. No onion routing or cover traffic. |
| **Server-blind metadata for cloud features** | When cloud APIs are used, the backend sees account-level metadata consistent with client-server apps. |
| **Protection against forensic extraction** | If an adversary obtains physical access to a powered-on, unlocked device, data can be extracted. |

---

## 4. Cryptography

### 4.1 Baseline (all chats)

- **Cipher:** AES-256-GCM
- **Key derivation:** PBKDF2 with per-chat salt
- **Properties:** No forward secrecy. Compromise of the long-term chat key decrypts all messages.

### 4.2 Optional Double Ratchet (DM chats)

Implemented in phases (see `DOUBLE_RATCHET_DESIGN.md`):

| Component | Algorithm |
|-----------|-----------|
| Key agreement | X25519 |
| Root KDF | HKDF-SHA256 |
| Message encryption | AES-256-GCM |
| Authentication (wire v2) | Ed25519 signatures over canonical JSON |
| Peer identity | TOFU pinning of signing key (local storage) |

**Session bootstrap:**

- `DR_DH_INIT` / `DR_DH_ACK` packets sent via mesh or cloud
- HMAC binding to legacy chat key (optional authentication helper)
- When `drDhRootKdf: 2` is negotiated, HKDF input is strengthened

**Not implemented:** Centralized pre-key directory (X3DH). First contact requires both devices online simultaneously or a mesh meeting.

### 4.3 Algorithms (reference only)

PBKDF2, AES-GCM, SHA-256, HMAC-SHA256, HKDF-SHA256, X25519, Ed25519. Parameters (iteration counts, KDF versions) are defined in code and may evolve.

---

## 5. Network resilience (implications for security)

The client includes mechanisms to maintain connectivity under adversarial network conditions:

- **Backend channel rotation:** Multiple `BackendChannel` entries with automatic failover.
- **Tunnel donors:** `Host` header substitution to resemble benign traffic.
- **Native TLS stack (Cronet / URLSession):** Alters JA3 fingerprint to match common browsers.
- **QUIC support:** UDP-based transport that some filtering systems handle less reliably.

These are **operational resilience** features, not cryptographic guarantees. They do not affect E2EE confidentiality or integrity.

---

## 6. Operational hygiene (for developers)

- Do **not** commit API keys, signing certificates, or production URLs that are not already public.
- Release builds **must not** log key material or plaintext message content.
- Rotate compromised signing or transport credentials through your deployment process (details out of scope for this file).

---

## 7. Reporting vulnerabilities

**Do not** open public GitHub issues for security reports.

Use:
- GitHub **Security Advisories** (private), or
- Maintainer contact as published on the repository or maintainer profile.

We practice responsible disclosure and respond on a best-effort basis. No bug bounty is implied.

---

## 8. Summary table

| Protected | Not protected |
|-----------|---------------|
| Message content from passive interception | Fact of communication (timing, presence) |
| Keys in Keystore/Keychain | Data on unlocked, compromised device |
| In-transit confidentiality (TLS + app-layer crypto) | Physical forensic extraction |
| Cloud traffic confidentiality (TLS) | DPI under strict whitelist regimes |

---

## 9. Further reading

| File | Content |
|------|---------|
| `ARCHITECTURE.md` | System design and transport layers |
| `WHY_NOT_SIGNAL.md` | Architectural comparison |
| `lib/core/DOUBLE_RATCHET_DESIGN.md` | Ratchet implementation details |
| `docs/E2EE_PRIORITIES.md` | Deferred cryptographic features |

---

*This document contains no credentials, API keys, or deployment-specific data. Last updated: 2026-03.*
