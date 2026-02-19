<div align="center">

# Memento Mori
### Autonomous Shadow Mesh Infrastructure

[![License: GPL v3](https://img.shields.io/badge/License-GPLv3-blue.svg)](LICENSE)
[![Platform](https://img.shields.io/badge/Platform-Android-green.svg)](https://flutter.dev)
[![Status](https://img.shields.io/badge/Status-Research%20Alpha-orange.svg)]()
[![Website](https://img.shields.io/badge/Website-GitHub%20Pages-blue.svg)](https://pslergy.github.io/memento-mori-app/)
[![GitHub Sponsors](https://img.shields.io/badge/Sponsor-GitHub-pink.svg)](https://github.com/sponsors/pslergy)

**Resilient Decentralized Communication for Extreme Environments**
<br>
*Offline-First • Delay-Tolerant • Privacy-Preserving*

<p align="center">
  <!-- Screenshots placeholders -->
  <img src="assets/screenshots/1.jpg" width="220" alt="Radar UI"/>
  <img src="assets/screenshots/2.jpg" width="220" alt="Chat UI"/>
  <img src="assets/screenshots/3.jpg" width="220" alt="Mesh Settings"/>
</p>
</div>

---

> ⚠️ **RESEARCH PREVIEW (ALPHA)**
>
> **Memento Mori is currently under active engineering development.**
> The protocol implementation and routing logic are designed for research of **Delay-Tolerant Networks (DTN)**.
> While the core transport layer is functional, this software is not yet recommended for mission-critical use without prior validation.

---

## 💀 The Mission

**Memento Mori** is a fault-tolerant, autonomous mesh infrastructure designed to operate under **total network degradation**.

The project implements a **shadow communication layer** beneath the traditional Internet, leveraging a combination of acoustic signaling, radio-based discovery, and cloud gateways (when available). It is built for environments where connectivity is intermittent, hostile, monitored, or deliberately suppressed.

---

## 🧠 Core Engineering Innovations

### 1. Advanced Hardware Interlock (Solving Android Fragmentation)
Standard Android APIs often fail on fragmented hardware (Huawei, Xiaomi, Samsung) due to aggressive battery optimization. Memento Mori implements a custom **Hardware Abstraction Layer (HAL)**:

*   **Vendor-Specific Strategies:** Reverse-engineered BLE behavior to bypass background restrictions on **Huawei/Honor** devices. Implemented an inverted logic (Passive Peripheral vs Active Central) to ensure stability where standard libraries fail.
*   **Finite State Machine (FSM):** Deterministic management of Bluetooth/Wi-Fi radios to prevent OS-level deadlocks (GATT 133 error).
*   **Biological Burst-Mode:** Nodes synchronize wake cycles to exchange data in short, high-throughput bursts, saving up to **90% battery**.

### 2. Multi-Layer Hybrid Transport
The app dynamically switches transport layers based on tactical conditions:

*   **🦇 Acoustic Sonar (L2):** Air-gapped discovery using ultrasonic BFSK modulation (18–20 kHz). Works in radio silence or RF-monitored zones using the Goertzel algorithm.
*   **📡 BLE Control Plane:** Zero-connect topology inference. Nodes broadcast gradient state (hop counts) directly in advertising packets without establishing heavy connections.
*   **⚡ Wi-Fi Direct (Data Plane):** Automatic escalation. When a BLE link is verified, a high-bandwidth Wi-Fi group is formed to flush the message queue instantly.

### 3. Distributed Consistency (DTN)
*   **Store-and-Forward Architecture:** Messages are stored in a local encrypted **Outbox** and delivered when a path becomes available (Delay-Tolerant Networking).
*   **Gossip Protocol:** Epidemic message propagation ensures eventual consistency across the mesh without a central coordinator.
*   **CRDTs (Conflict-free Replicated Data Types):** Mathematical guarantee of data convergence during network partitions.

### 4. High-Grade Security (Decoy & Panic)
*   **Decoy Mode:** Dual-password architecture. One password opens the "Real" vault, another opens a "Decoy" (fake) vault. Both UIs look identical to protect against coercion.
*   **Panic Wipe:** "Shake-to-Kill" feature instantly erases sensitive data (keys, logs, messages) in emergencies.
*   **Ghost Identity:** Offline identities (Ed25519) are generated locally and stored in encrypted SQLite (WAL mode).

---

## 🗺️ Roadmap & Status

- [x] **Core:** BLE zero-connect discovery & advertising parsing
- [x] **Stability:** Hardware Interlock (FSM) for Huawei/Samsung
- [x] **Transport:** Acoustic Sonar (BFSK) & Wi-Fi Direct Auto-Negotiation
- [x] **Sync:** Gossip Protocol & Store-and-Forward Outbox
- [x] **Security:** Decoy Mode & Panic Wipe
- [ ] **Routing:** Advanced Gradient Descent for multi-hop efficiency
- [ ] **E2EE:** Double Ratchet Algorithm implementation
- [ ] **Hardware:** LoRa WAN integration via USB/UART
- [ ] **UI:** Camouflage mode (calculator disguise)

---

## 🛠 Tech Stack

*   **Language:** Dart (Flutter) + Kotlin (Native Channels)
*   **Architecture:** Clean Architecture + BLoC
*   **Database:** SQLite (Drift, WAL Mode)
*   **Cryptography:** `pointycastle`, `cryptography` (Ed25519, AES-GCM)
*   **Signal Processing:** Goertzel Algorithm (Sonar/Audio)

---

## 🌐 Project Website

The project has a static site (mission, status, use cases, roadmap) hosted on **GitHub Pages**:

👉 **[https://pslergy.github.io/memento-mori-app/](https://pslergy.github.io/memento-mori-app/)**

---

## 📥 Getting Started

### Prerequisites
*   Flutter SDK 3.x+
*   Android device (API 26+ recommended)
    *Emulators are limited due to Bluetooth and Wi-Fi Direct requirements.*

### Installation
```bash
git clone https://github.com/pslergy/memento-mori-app.git
cd memento-mori-app
flutter pub get
flutter run --release


---

## ❤️ Support the Project

**Memento Mori** is an independent open-source research project developed without corporate backing.

If you find this work valuable for **privacy research**, **off-grid communication**, or **humanitarian tech**, consider supporting via GitHub Sponsors:

👉 **[https://github.com/sponsors/pslergy](https://github.com/sponsors/pslergy)**

---

## 📚 Documentation

This repository is accompanied by a set of architectural documents:

*   [**ARCHITECTURE.md**](ARCHITECTURE.md) — High-level system design, transport layers, and orchestrator logic.
*   [**WHY_NOT_SIGNAL.md**](WHY_NOT_SIGNAL_OR_MATRIX.md) — Architectural comparison with Signal/Matrix/Briar.
*   [**SECURITY.md**](SECURITY.md) — Threat model and encryption details.

---

### 🤝 Contributing

Contributions are welcome! Please read [CONTRIBUTING.md](CONTRIBUTING.md) before opening issues.
<br>
*Areas of interest: DSP optimization, Android HAL quirks, Cryptographic review.*

---

## 📄 License

Licensed under the **GNU General Public License v3.0**. See the [LICENSE](LICENSE) file for details.

> **Disclaimer:** Provided as-is for educational and defensive research purposes. Authors are not responsible for misuse.

<br>

<div align="center">
  <sub><b>Memento Mori Project</b></sub><br>
  <sub>High-Resilience Distributed Systems Research</sub><br>
  <sub>Created by <b>Pslergy</b></sub>
</div>
