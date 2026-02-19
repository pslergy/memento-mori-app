<div align="center">

# Memento Mori
### High-Resilience Tactical Mesh Messenger

[![License: GPL v3](https://img.shields.io/badge/License-GPLv3-blue.svg)](LICENSE)
[![Platform](https://img.shields.io/badge/Platform-Android-green.svg)](https://flutter.dev)
[![Status](https://img.shields.io/badge/Status-Research%20Alpha-orange.svg)]()
[![Architecture](https://img.shields.io/badge/Arch-Offline--First-blueviolet)]()
[![Website](https://img.shields.io/badge/Website-GitHub%20Pages-blue.svg)](https://pslergy.github.io/memento-mori-app/)

**Autonomous. Decentralized. Uncensorable.**
*Designed for environments with total network degradation.*

<p align="center">
  <img src="assets/screenshots/1.jpg" width="200"/>
  <img src="assets/screenshots/2.jpg" width="200"/>
  <img src="assets/screenshots/3.jpg" width="200"/>
  <img src="assets/screenshots/4.jpg" width="200"/>
</p>

</div>

---

> ⚠️ **RESEARCH PREVIEW (ALPHA)**
>
> **Memento Mori is currently under active engineering development.**
> The protocol implementation and routing logic are designed for research into **Delay-Tolerant Networks (DTN)**.
> While functional, it is subject to breaking changes.

---

## 💀 The Mission

**Memento Mori** is a fault-tolerant, autonomous mesh infrastructure designed to operate where traditional internet fails.
It implements a **shadow communication layer** leveraging a combination of acoustic signaling, radio-based discovery, and peer-to-peer Wi-Fi to ensure message delivery in hostile, monitored, or disaster-struck environments.

---

## 🧠 Engineering Innovations

### 1. Solving Android Fragmentation (The "Huawei Problem")
Standard Android APIs fail on fragmented hardware due to aggressive battery optimization (killing background processes). Memento Mori implements a custom **Hardware Abstraction Layer**:

*   **Vendor-Specific Strategies:** Reverse-engineered BLE behavior to bypass OS restrictions on **Huawei/Xiaomi** devices. Implemented an **Inverted Connection Logic** (Passive Peripheral vs Active Central) to ensure stability where standard libraries fail.
*   **Finite State Machine (FSM):** Deterministic management of Bluetooth/Wi-Fi radios to prevent OS-level deadlocks (GATT 133 error).
*   **Biological Burst-Mode:** Nodes synchronize wake cycles to exchange data in short, high-throughput bursts, saving up to **90% battery**.

### 2. Multi-Layer Hybrid Transport
The app dynamically switches transport layers based on tactical conditions:

*   **🦇 Acoustic Sonar (L2):** Air-gapped discovery using ultrasonic BFSK modulation (18–20 kHz). Works in radio silence or RF-monitored zones using the Goertzel algorithm.
*   **📡 BLE Control Plane:** Zero-connect topology inference. Nodes broadcast routing tables and gradient state directly in advertising packets.
*   **⚡ Wi-Fi Direct (Data Plane):** Automatic escalation. When a BLE link is verified, a high-bandwidth Wi-Fi group is formed to flush the message queue instantly.

### 3. Distributed Architecture (DTN)
*   **Store-and-Forward:** Messages are stored in a local encrypted **Outbox** and delivered when a path becomes available (Delay-Tolerant Networking).
*   **Gossip Protocol:** Epidemic message propagation ensures eventual consistency across the mesh without a central coordinator.
*   **CRDTs (Conflict-free Replicated Data Types):** Mathematical guarantee of data convergence during network partitions.

---

## 🛡️ Security & Privacy

*   **Decoy Mode:** Dual-password architecture. One password opens the "Real" vault, another opens a "Decoy" (fake) vault. Both interfaces look identical to protect against coercion.
*   **Panic Wipe:** "Shake-to-Kill" feature instantly erases sensitive encryption keys and databases in emergencies.
*   **Ghost Identity:** Fully offline identity (Ed25519) stored in SQLite (WAL mode). Can be cryptographically bound to a persistent cloud ID later without history loss.
*   **E2EE:** AES-GCM encryption for all local storage and transport layers.

---

## 🗺️ Roadmap & Status

*   [x] **Core:** BLE zero-connect discovery & advertising parsing
*   [x] **Core:** Hardware Interlock (FSM) for Huawei/Samsung stability
*   [x] **Transport:** Acoustic Sonar layer (BFSK signaling)
*   [x] **Transport:** Wi-Fi Direct auto-negotiation
*   [x] **Sync:** Gossip Protocol & Store-and-Forward Outbox
*   [x] **Security:** Decoy Mode (Dual Vault) & Panic Wipe
*   [ ] **Routing:** Advanced Gradient Descent for multi-hop reliability
*   [ ] **Security:** Double Ratchet Algorithm (Forward Secrecy)
*   [ ] **Network:** LoRa WAN hardware integration (USB / UART)

---

## 🛠 Tech Stack

*   **Language:** Dart (Flutter) + Kotlin (Native Channels)
*   **Architecture:** Clean Architecture + BLoC
*   **Database:** SQLite (Drift FFI, WAL mode)
*   **Crypto:** pointycastle / cryptography (Ed25519, AES-GCM)
*   **Signal Processing:** Goertzel Algorithm (DSP)

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

❤️ Support the Research
Memento Mori is an independent open-source research project developed without corporate backing.
If you find this work valuable for privacy research or off-grid communication, please consider supporting:
👉 Sponsor on GitHub
📚 Documentation
ARCHITECTURE.md — High-level system design and orchestrator logic.
WHY_NOT_SIGNAL.md — Comparison with Signal/Matrix/Briar.
SECURITY.md — Threat model and encryption details.
🤝 Contributing
Contributions are welcome, especially in:
DSP / audio signal processing optimization
Android HAL quirks (Samsung vs Pixel vs Xiaomi)
Cryptographic review
Please read CONTRIBUTING.md before opening issues.
📄 License
Licensed under the GNU General Public License v3.0.
See the LICENSE file for details.
Disclaimer: Provided as-is for educational and defensive research purposes. Authors are not responsible for misuse.
<div align="center">
<sub><b>Memento Mori Project</b></sub><br>
<sub>High-Resilience Distributed Systems Research</sub><br>
<sub>Created by <b>Pslergy</b></sub>
</div>
```
</div>
