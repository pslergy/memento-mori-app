# Memento Mori

### Autonomous Shadow Mesh Infrastructure

**Resilient Decentralized Communication for Extreme Environments**

Memento Mori is not just a messenger.
It is a fault-tolerant, autonomous mesh infrastructure designed to operate under *total network degradation*.

The project implements a **“shadow communication layer”** beneath the traditional Internet, leveraging a synergistic combination of **acoustic signaling**, **radio-based discovery**, and **cloud gateways** when available.

It is built for environments where connectivity is intermittent, hostile, monitored, or deliberately suppressed.

---

## 🧠 Core Engineering Innovation

### Tactical Orchestrator (Decision Engine)

The primary challenge of mobile mesh networks is not routing — it is **surviving the operating system**.

Aggressive power management, background execution limits, and shared hardware resources (Bluetooth, Audio, Wi-Fi) make naïve mesh implementations unstable or unusable.

Memento Mori solves this via the **Tactical Orchestrator**, a deterministic decision engine coordinating all subsystems.

### Key Logic Components

#### Biological Burst-Mode

Instead of continuous scanning, nodes synchronize *wake cycles*.

* Devices wake simultaneously
* Exchange data in short, high-throughput **Burst Windows**
* Return to deep idle

Result: **up to 90% energy savings** compared to constant discovery models.

---

#### Hardware Interlock Orchestration

Mobile chipsets cannot safely run Bluetooth, Audio (FFT/Sonar), and Wi-Fi Direct concurrently.

The orchestrator enforces **exclusive HAL access**, preventing:

* BLE GATT deadlocks (Android Status 133)
* Audio driver starvation
* Vendor-specific chipset crashes (MediaTek, Spreadtrum)

Subsystems are **time-sliced**, not parallelized.

---

#### GridScore Heuristic (Routing Intelligence)

Routing decisions are based on a dynamic neighbor score:

* **Hops to Internet** (Gradient propagation)
* **Battery Level**
* **Queue Pressure** (message backlog)

This creates a self-optimizing mesh that naturally prefers stable, energy-sufficient uplinks.

---

## 🚀 Multi-Layer Transport Stack

### Heterogeneous, Adaptive, Opportunistic

Memento Mori dynamically switches transport layers depending on tactical conditions.

---

### 1️⃣ Acoustic L2 Layer — *Sonar Link*

**Use case:**
Node discovery in radio silence, BLE-restricted environments, or heavily monitored zones.

**Technology:**

* Custom protocol over BFSK modulation
* Goertzel algorithm for efficient frequency detection on mobile CPUs
* No DSP acceleration required

**Dynamic Frequency Selection (DFS):**

* Real-time FFT spectrum analysis
* Automatic selection of quiet ultrasonic bands (18–20 kHz)

This layer enables **air-gapped discovery** without RF emissions.

---

### 2️⃣ Control Plane — *BLE Signaling*

**Zero-Connect Discovery**

* Gradient state (hop count)
* Data availability flag
  Encoded directly in BLE Advertising packets

Nodes infer topology **without establishing connections**.

**GATT Hardening**

* Defensive connection profile
* Backoff and reset strategy to mitigate Android GATT Status 133
* BLE is used for signaling only, not bulk data

---

### 3️⃣ Data Plane — *Wi-Fi Direct & TCP*

**Escalation Path**

* When an uplink is detected via BLE
* Wi-Fi Direct group is automatically formed
* Accumulated Outbox is flushed at high speed

**Socket Binding Fix**

* Explicit bind to `0.0.0.0:55555`
* Resolves “isolated socket” issues on vendor-modified Android firmware

This ensures reliable data transfer even on heavily customized ROMs.

---

## 🧬 Identity & Data Integrity

### Identity Transmigration Protocol

Solves the classic offline identity problem.

#### Ghost State

* Local Ed25519 keypair generation
* Messages incubated in SQLite (WAL mode)
* Fully functional offline identity

#### Landing Pass

* Cryptographic commitment allowing later identity binding
* No trust required at message creation time

#### Atomic Merge

* Backend (Node.js + Prisma)
* Atomic ownership transfer from `ghostId` → `authId`
* Idempotent, duplication-safe

Offline history survives reconnection **without forks or loss**.

---

## 🔐 Security & Anti-Forensics

* **Camouflage Mode**
  App fully disguises itself as a functional calculator.

* **Panic Trigger**

  * Coercion PIN
  * Shake-to-Wipe (accelerometer)
    Instant destruction of keys and database.

* **Offline Entropy Injection**
  Random padding added to packets to resist traffic analysis by packet size.

---

## 🛠 Tech Stack & Engineering Trade-offs

* **Flutter (Dart)**
  Fast iteration, deterministic FSM orchestration, cross-platform UI.

* **Native Kotlin**
  Critical paths only:

  * FFT / Goertzel
  * Wi-Fi Direct
  * Low-level socket control

* **SQLite (WAL Mode)**
  Chosen over Hive/Realm for:

  * Strict ACID guarantees
  * Crash-safe message queues
  * Deterministic replay during merges

---

## 👨‍🔬 Research Goals

Memento Mori explores the practical limits of **Delay-Tolerant Networks (DTN)** on modern mobile hardware.

Primary focus areas:

* Autonomy under OS constraints
* Stealth and low observability
* Survivability in adversarial environments

This is both an applied system and a research platform.

---

## 👤 Author

**Pslergy**
Senior Software Architect
Distributed Systems · Mesh Networks · Hardware Interop
