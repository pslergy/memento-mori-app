<div align="center">

# 💀 Memento Mori  
### Autonomous Shadow Mesh Infrastructure

[![License: GPL v3](https://img.shields.io/badge/License-GPLv3-blue.svg)](LICENSE)
[![Platform](https://img.shields.io/badge/Platform-Android-green.svg)](https://flutter.dev)
[![Status](https://img.shields.io/badge/Status-Research%20Alpha-orange.svg)]()
[![Website](https://img.shields.io/badge/Website-GitHub%20Pages-blue.svg)](https://pslergy.github.io/memento-mori-app/)
[![GitHub Sponsors](https://img.shields.io/badge/Sponsor-GitHub-pink.svg)](https://github.com/sponsors/pslergy)

**Resilient Decentralized Communication for Extreme Environments**  
*Offline-First • Delay-Tolerant • Privacy-Preserving*

<br>

<img src="assets/screenshots/1.jpg" width="220" alt="Radar UI"/>
<img src="assets/screenshots/2.jpg" width="220" alt="Chat UI"/>
<img src="assets/screenshots/3.jpg" width="220" alt="Mesh Settings"/>

</div>

---

## ⚠️ RESEARCH PREVIEW (ALPHA)

> **Memento Mori is currently under active engineering development.**  
> The protocol implementation and routing logic are designed for research of **Delay-Tolerant Networks (DTN)**.  
> While the core transport layer is functional, this software is **not recommended for mission-critical use** without independent validation.

---

## 💀 The Mission

**Memento Mori** is a fault-tolerant autonomous mesh infrastructure designed to operate under **total network degradation**.

The project implements a **shadow communication layer** beneath the traditional Internet, leveraging:

- Acoustic signaling  
- Radio-based discovery  
- Opportunistic cloud gateways  

It is built for environments where connectivity is intermittent, hostile, monitored, or deliberately suppressed.

---

## 🧠 Core Engineering Innovations

### 1️⃣ Advanced Hardware Interlock (Solving Android Fragmentation)

Standard Android APIs often fail on fragmented hardware (Huawei, Xiaomi, Samsung) due to aggressive battery optimization.

Memento Mori implements a custom **Hardware Abstraction Layer (HAL)**:

- **Vendor-Specific Strategies**  
  Reverse-engineered BLE behavior to bypass background restrictions on Huawei/Honor devices.  
  Uses inverted logic (Passive Peripheral vs Active Central) where standard libraries fail.

- **Finite State Machine (FSM)**  
  Deterministic management of Bluetooth/Wi-Fi radios to prevent OS-level deadlocks (GATT 133 error).

- **Biological Burst-Mode**  
  Nodes synchronize wake cycles to exchange data in short high-throughput bursts — reducing battery usage by up to **90%**.

---

### 2️⃣ Multi-Layer Hybrid Transport

Dynamic transport switching based on tactical conditions:

- 🦇 **Acoustic Sonar (L2)**  
  Air-gapped discovery using ultrasonic BFSK modulation (18–20 kHz).  
  Uses the Goertzel algorithm for detection.

- 📡 **BLE Control Plane**  
  Zero-connect topology inference.  
  Nodes broadcast gradient state (hop counts) directly in advertising packets.

- ⚡ **Wi-Fi Direct (Data Plane)**  
  Automatic escalation to high-bandwidth Wi-Fi groups once a BLE link is verified.

---

### 3️⃣ Distributed Consistency (DTN)

- **Store-and-Forward Architecture**  
  Encrypted local Outbox for delayed delivery.

- **Gossip Protocol**  
  Epidemic propagation ensures eventual consistency without a central coordinator.

- **CRDTs**  
  Mathematical convergence guarantee during network partitions.

---

### 4️⃣ High-Grade Security (Decoy & Panic)

- **Decoy Mode**  
  Dual-password architecture:
  - Real Vault
  - Decoy Vault (identical UI)

- **Panic Wipe**  
  Shake-to-Kill instantly erases keys, logs, and messages.

- **Ghost Identity**  
  Offline Ed25519 identities stored in encrypted SQLite (WAL mode).

---

## 🗺️ Roadmap

- [x] BLE zero-connect discovery  
- [x] Hardware Interlock FSM  
- [x] Acoustic Sonar (BFSK)  
- [x] Wi-Fi Direct Auto-Negotiation  
- [x] Gossip Protocol  
- [x] Store-and-Forward Outbox  
- [x] Decoy Mode  
- [x] Panic Wipe  
- [ ] Gradient-based multi-hop routing  
- [ ] Double Ratchet (E2EE)  
- [ ] LoRa WAN via USB/UART  
- [ ] Camouflage UI mode (Calculator disguise)

---

## 🛠 Tech Stack

- **Language:** Dart (Flutter) + Kotlin (Native Channels)
- **Architecture:** Clean Architecture + BLoC
- **Database:** SQLite (Drift, WAL Mode)
- **Cryptography:** `pointycastle`, `cryptography` (Ed25519, AES-GCM)
- **Signal Processing:** Goertzel Algorithm

---

## 🌐 Project Website

Static mission & documentation site hosted on GitHub Pages:

👉 https://pslergy.github.io/memento-mori-app/

---

## 📥 Getting Started

### Prerequisites

- Flutter SDK 3.x+
- Android device (API 26+ recommended)  
  *Emulators have limited Bluetooth and Wi-Fi Direct support.*

### Installation

```bash
git clone https://github.com/pslergy/memento-mori-app.git
cd memento-mori-app
flutter pub get
flutter run --release
❤️ Support the Project

Memento Mori is an independent open-source research project.

If you find this work valuable for:

Privacy research

Off-grid communication

Humanitarian technology

Consider supporting via GitHub Sponsors:

👉 https://github.com/sponsors/pslergy

📚 Documentation

ARCHITECTURE.md — System design & transport layers

WHY_NOT_SIGNAL.md — Architectural comparison

SECURITY.md — Threat model & cryptography

🤝 Contributing

Contributions are welcome.

Please read CONTRIBUTING.md before opening issues.

Areas of interest:

DSP optimization

Android HAL behavior

Cryptographic review

📄 License

Licensed under GNU GPL v3.0.
See LICENSE for details.

<div align="center">

Memento Mori Project
High-Resilience Distributed Systems Research
Created by Pslergy

</div> ```
