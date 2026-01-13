# Memento Mori  
### Resilient Offline-First Messaging System for Network-Degraded Environments

**Memento Mori** is a research-driven, privacy-preserving messaging system designed to operate under **partial or total network failure**.  
The project explores resilient communication techniques for environments affected by censorship, internet shutdowns, or unstable connectivity.

The system combines **cloud relays, peer-to-peer mesh networking, and experimental out-of-band discovery mechanisms** to guarantee message delivery under adverse conditions.

---

## 🧠 System Architecture Overview

Memento Mori is built as a **delay-tolerant, multi-transport communication system** with an offline-first design.

At a high level, the system consists of:

### 1. Out-of-Band Node Discovery (Cold Start Mitigation)
An experimental ultrasonic signaling mechanism is used to enable **initial peer discovery** when RF-based discovery is slow, restricted, or unavailable.

### 2. Hybrid Transport Layer
The messenger dynamically selects the most reliable transport available:
- **Cloud Relay:** Encrypted WebSockets for global reach
- **Mesh Transport:** Wi-Fi Direct and Bluetooth Low Energy (BLE)
- **Store-and-Forward:** Opportunistic message carrying for disconnected nodes (DTN)

### 3. Probabilistic Routing & Synchronization
Messages propagate using **gossip-based epidemic spreading** with deduplication and anti-entropy mechanisms to prevent broadcast storms.

### 4. Identity & Security Layer
- Offline-generated cryptographic identities
- Deferred cloud binding via a custom “Landing Pass” protocol
- End-to-End Encryption (E2EE) by default

---

## 🚀 Key Engineering Features

### Hybrid Link Protocol (v2.x)
The transport layer continuously adapts to connectivity conditions:
- Automatic fallback between Cloud, Mesh, and DTN paths
- Encrypted Outbox for gateway nodes bridging isolated segments
- Resilient reconnection logic under frequent network churn

---

### Experimental Acoustic Discovery (Sonar Link)
> **Status:** Research / Experimental

- Ultrasonic signaling (~19 kHz) for out-of-band discovery
- BFSK modulation with Goertzel-based detection (Kotlin, native layer)
- Frame structure: `Preamble | Length | Payload | CRC-8`
- Used exclusively for discovery and key exchange (not bulk data)

**Goal:** Reduce cold-start latency in RF-denied or congested environments.

---

### Probabilistic Gossip Protocol
- Epidemic message spreading with configurable retransmission probability
- Hash-based deduplication stored in SQLite (WAL mode)
- Anti-entropy synchronization to reduce redundant traffic

**Observed behavior:**
- Scales to ~500–1000 nodes without saturating the mesh
- Broadcast volume reduced by ~60–70% through deduplication

---

### OS-Level Resilience (Android)
A major engineering challenge was maintaining background connectivity on devices with aggressive power management (Huawei, Tecno, Xiaomi).

**Implemented solutions:**
- Foreground-bound Kotlin service hosting a TCP stack
- Explicit socket binding (`0.0.0.0:55555`)
- Automatic socket recovery and thread-pool supervision
- Deterministic chat routing via alphabetized ID sorting

This architecture ensures **stable background networking** even under non-standard Android implementations.

---

## 🔐 Security & Privacy

- **End-to-End Encryption:** AES-256-GCM
- **Identity:** Ed25519 key pairs generated offline
- **Key Derivation:** PBKDF2
- **Zero-Knowledge Design:** No server-side message access
- **Secure UI:** Sensitive screens protected via `FLAG_SECURE`

### Deferred Identity Binding (“Landing Pass”)
Users can operate fully offline and later bind their cryptographic identity to a cloud account **without losing message history**.

---

## 🕊️ Anti-Forensics & Data Safety

- Application masquerading as a calculator
- Gesture- or PIN-triggered silent data wipe
- Encrypted local storage with hardware-fallback strategies
- Resilient vault layer for unstable KeyStore implementations

---

## 🛠 Tech Stack

**Mobile**
- Flutter (Dart, Cubit)
- Native Kotlin (Wi-Fi P2P, BLE, TCP Services)
- SQLite (WAL mode)

**Backend**
- Node.js (Express)
- PostgreSQL + PostGIS
- WebSockets

**Cryptography**
- AES-256-GCM
- Ed25519
- SHA-256

---

## 📊 System Constraints & Observations

- Designed for intermittent connectivity and long network partitions
- Optimized for low-bandwidth and high-latency links
- Target mesh size: hundreds to ~1000 nodes
- Message delivery guaranteed via store-and-forward semantics

---

## 🖥️ Backend Architecture

The backend infrastructure acts as a **relay and identity anchor**, not a central authority.

**Responsibilities:**
- Identity verification and handshake validation
- Encrypted message relay for gateway nodes
- Traffic obfuscation to resist DPI-based blocking

> **Note:** Backend source code is private to reduce attack surface and protect routing logic.  
> Client-side cryptography remains open for public verification.

---

## 🧪 Research & Roadmap

- Improved acoustic channel robustness
- Adaptive gossip probabilities based on node density
- Formal modeling of delivery guarantees under partitioned networks
- Privacy-preserving proximity discovery

---

## 👨‍💻 Author

**Pslergy**  
*Focus: Distributed Systems, Mobile OS Internals, Privacy-Preserving Architectures*

This project is part of a broader engineering portfolio exploring resilient networking, offline-first systems, and secure communication under extreme constraints.
