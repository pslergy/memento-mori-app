# Memento Mori: Tactical Anti-Censorship Messenger

**Memento Mori** is a high-resilience, privacy-focused tactical messenger designed for communication in environments with total internet shutdown or aggressive censorship. It implements a hybrid network topology to ensure message delivery through Cloud, Mesh (Wi-Fi Direct/BLE), and Acoustic channels.

---

## 🛡️ Core Philosophy: Privacy by Design
*   **Zero-Knowledge Architecture:** No central authority can read your messages.
*   **Censorship Resistance:** Designed to bypass national firewalls and work in completely isolated grids.
*   **Stealth Mode:** App masquerades as a fully functional calculator with a secondary encrypted entry point.

---

## 🚀 Key Engineering Features

### 1. Hybrid Link Protocol (V2.4)
The messenger dynamically switches between three transport layers:
*   **Cloud Link:** Secure WebSockets through obfuscated TLS (masquerading as standard Microsoft update traffic).
*   **Mesh Link (P2P):** Wi-Fi Direct and Bluetooth Low Energy (BLE) for peer-to-peer communication without routers.
*   **Sonar Link (Experimental):** Data transmission via ultrasonic sound pulses (Acoustic Modem).

### 2. Advanced Security Layer
*   **End-to-End Encryption (E2EE):** AES-256-GCM for messages and Ed25519 for identity verification.
*   **Identity Correlation Engine:** A custom handshake protocol that maps transient hardware IP addresses to static cryptographic User IDs in P2P groups.
*   **Self-Healing Server:** A Kotlin-based background TCP server with automatic socket recovery and thread-pool management.

### 3. Anti-Forensics & Stealth
*   **Activity-Alias Masquerading:** The app icon and entry point are disguised as a system calculator.
*   **Panic Protocol:** A gesture-based (accelerometer-triggered) or PIN-triggered "Silent Wipe" that purges all local SQLite data and Secure Storage keys.
*   **Unified Vault:** A resilient storage strategy with hardware-glitch fallback for non-standard Android implementations (Tecno/Huawei/Xiaomi).

---

## 🛠 Tech Stack
*   **Frontend:** Flutter (Dart) using Cubit for state management.
*   **Backend:** Node.js (Express), PostgreSQL, PostGIS for proximity-based discovery.
*   **Native Layer:** Kotlin (Wi-Fi P2pManager, ServerSocket, PowerManager API).
*   **Storage:** SQLite (WAL Mode enabled) for offline-first persistence.
*   **Crypto:** `cryptography` package for AES-GCM and SHA-256 hashing.

---


---

## 🖥️ Backend Architecture & Privacy
The Memento Mori server infrastructure is a robust system built on **Node.js (Express), PostgreSQL, and PostGIS** for geospatial indexing.

**Why is the backend repository private?**
To maintain the security of the relay network and protect the core signal-routing logic from adversarial analysis, the backend source code is kept in a **private repository**. 

**Key Infrastructure Responsibilities:**
*   **Identity Anchoring:** Secure verification of handshakes to prevent impersonation.
*   **Bridge Synchronization:** Managing the encrypted Outbox for nodes acting as internet gateways.
*   **DPI Deception:** Implementation of traffic obfuscation protocols to hide messenger activity from network analysis tools.

*Note: The client-side code is open-source to allow public verification of our End-to-End Encryption (E2EE) implementation.*

---

## 🎯 The "Tecno/Huawei" Case Study: Overcoming Hardware Isolation
During development, we encountered a critical issue where aggressive battery optimization and non-standard Android KeyStore implementations on Tecno and Huawei devices caused socket "ghosting" and data decryption failures.

**The Solution:**
1.  Implemented a **Deterministic ID Routing** logic using alphabetized ID sorting to ensure chatId consistency across nodes.
2.  Developed a **TCP Burst Strategy** with explicit UTF-8 synchronization to penetrate OS-level socket throttling.
3.  Architected a **Resilient Vault Layer** with automatic fallback mechanisms to ensure session persistence across process restarts.

---


## 🕊️ Ethical & Humanitarian Architecture
Memento Mori is built for scenarios where communication equals survival. 
We explicitly reject monetization of bridge access in conflict zones.

**Implemented Ethical Protocols:**
*   **Proof of Cooperation (PoC):** Priority routing is granted based on the node's contribution to the mesh network, not financial status.
*   **RF Stealth Handshake:** Bridge nodes use randomized transmission intervals to evade signal triangulation by military-grade sensors.
*   **Anti-Traffic Analysis:** Data padding and traffic mixing to protect the physical location of Starlink/Backhaul gateways.

## 💰 Monetization Strategy: Gossip Ad-Network
Memento Mori introduces a unique **Offline Advertising Protocol**. Using a Gossip-based synchronization, nodes exchange signed "Tactical Ad Packets" during P2P handshakes. This creates a decentralized ad network that earns revenue even when the global internet is unreachable.

---


Memento Mori is part of a broader engineering portfolio, including **Kismet** — a production-ready AI Social/Dating platform localized in 8 languages, featuring NASA-standard astronomical engines and high-concurrency infrastructure.

## 👨‍💻 Developer
**Pslergy**  
*Focus: Product Engineering, Cybersecurity, Distributed Systems.*