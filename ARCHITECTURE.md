# Memento Mori — Architecture Overview

> *This document describes the architectural principles, system layers, and design rationale behind the Memento Mori project.*
>
> **This is not an API reference.**
> This is a map of intent, constraints, and hard-earned trade-offs.

---

## 1. Architectural Philosophy

Memento Mori is designed under the assumption that **the network is hostile, unreliable, or absent**, and that **the operating system itself is an adversarial environment**.

Core assumptions:

* Connectivity is **intermittent**
* Power is **scarce**
* Hardware resources are **shared and contested**
* The OS may **terminate background work arbitrarily**
* Central coordination **cannot be trusted**

As a result, the system prioritizes:

* **Survivability over convenience**
* **Determinism over throughput**
* **Local autonomy over global optimization**
* **Explicit orchestration over implicit background execution**

---

## 2. High-Level System Model

At a high level, Memento Mori is a **Delay-Tolerant Mesh System (DTN)** composed of autonomous nodes.

Each node is both:

* a **router**
* a **store-and-forward relay**
* an **identity anchor**
* a **transport negotiator**

There is **no permanent control plane**.

All coordination is **local, opportunistic, and reversible**.

---

## 3. Layered Architecture

```
┌───────────────────────────────────────────┐
│ UI Layer (Radar, Chat, Control Surfaces) │
├───────────────────────────────────────────┤
│ Application Logic (State, Messaging)     │
├───────────────────────────────────────────┤
│ Tactical Mesh Orchestrator (FSM)          │
├───────────────────────────────────────────┤
│ Transport Abstraction Layer               │
│  ├─ Acoustic Sonar (Ultrasonic BFSK)      │
│  ├─ BLE Control Plane (Zero-Connect)      │
│  ├─ Wi-Fi Direct (Burst Data Plane)       │
├───────────────────────────────────────────┤
│ Security & Identity Layer                 │
│  ├─ Ghost Identity (Offline)              │
│  ├─ Local Encryption (AES-GCM)            │
├───────────────────────────────────────────┤
│ Persistence Layer (SQLite WAL)            │
├───────────────────────────────────────────┤
│ OS / Hardware Abstraction (Android HAL)   │
└───────────────────────────────────────────┘
```

---

## 4. Tactical Mesh Orchestrator (Core)

The **TacticalMeshOrchestrator** is the heart of the system.

It is implemented as a **deterministic finite-state machine (FSM)** responsible for:

* Transport activation and shutdown
* Hardware resource arbitration
* Permission-aware sequencing
* Energy-aware duty cycling
* Failure recovery and escalation

### Why an Orchestrator Exists

Mobile operating systems do not allow:

* concurrent Bluetooth + Audio + Wi-Fi usage reliably
* unbounded background execution
* implicit long-running mesh behavior

Therefore:

> **All radios are mutually exclusive by design.**

The orchestrator enforces **hardware interlocks** to prevent:

* Bluetooth GATT status 133 deadlocks
* Audio driver starvation
* Wi-Fi Direct negotiation races
* OS battery-kill heuristics

No transport layer is allowed to operate independently.

---

## 5. Transport Layers

### 5.1 Acoustic Sonar (L2 Discovery)

Purpose:

* Air-gapped discovery
* Radio-silent environments
* Last-resort signaling

Characteristics:

* BFSK modulation (18–20 kHz)
* CPU-based Goertzel detection
* Very low bandwidth
* High survivability

Used for:

* Neighbor presence detection
* Initial wake-up signaling
* Emergency rendezvous

---

### 5.2 BLE Control Plane (Zero-Connect)

Purpose:

* Lightweight topology inference
* Neighbor validation
* Escalation trigger

Key design choice:

* **No GATT connections**
* State is encoded directly in advertising packets

Benefits:

* Minimal power usage
* No connection overhead
* Works under aggressive OS constraints

BLE is used to decide **whether Wi-Fi is worth turning on**.

---

### 5.3 Wi-Fi Direct (Burst Data Plane)

Purpose:

* High-throughput message flushing

Characteristics:

* Short-lived
* Opportunistic
* Explicitly orchestrated

Workflow:

1. BLE confirms viable neighbor
2. Wi-Fi Direct group forms
3. Message queue is flushed
4. Wi-Fi is shut down immediately

Wi-Fi **never scans continuously**.

---

## 6. Identity & Security Model

### 6.1 Ghost Identity

Each node maintains a fully functional **offline identity**:

* Ed25519 keypair
* Stored locally
* No external authority required

The node is operational **without internet access**.

---

### 6.2 Identity Transmigration

When connectivity becomes available:

* Offline identity is **atomically bound**
* No history is rewritten
* No forks are created
* No centralized identity provider is required

This prevents:

* identity loss
* replay forks
* partial merges

---

## 7. Persistence Strategy

* SQLite with **WAL mode**
* Encrypted payloads
* Append-first semantics

Rationale:

* Power loss tolerance
* Crash survivability
* Predictable IO behavior

---

## 8. Failure Model & Recovery Strategy

Memento Mori is designed with the assumption that failures are normal,
frequent, and often unrecoverable in the short term.

The system explicitly models the following failure classes:

- Transport failure (BLE / Wi-Fi / Audio unavailable or unstable)
- Process termination by the OS
- Partial message delivery
- Power loss at arbitrary execution points
- Duplicate message propagation
- Stale or contradictory topology information

Recovery principles:

- No failure blocks future progress
- All operations are retryable or discardable
- Message delivery is idempotent
- Duplication is preferred over loss
- Time (TTL) is used as a garbage collector

The system does not attempt to guarantee immediate delivery.
Instead, it guarantees eventual consistency under continued node presence.

---

## 9. Explicit Non-Goals

The following are **intentionally excluded**:

* Push notifications as a core mechanism
* Continuous background scanning
* Cloud-dependent routing
* Centralized telemetry or analytics
* User tracking or behavioral profiling

If a proposed feature violates these constraints, it will be rejected.

---

## 10. Architectural Stability

This architecture is considered **foundational**.

While implementations may evolve, the following are stable invariants:

* Deterministic orchestration
* Transport exclusivity
* Offline-first identity
* Opportunistic escalation
* Zero-knowledge defaults

Changes to these principles require strong justification.

---

## 11. Authorship & Intent

Memento Mori was initiated and architected as an independent research project focused on **resilient, censorship-resistant communication**.

This architecture reflects real-world constraints encountered across diverse Android devices and hostile operating conditions.

Understanding *why* these decisions exist is as important as understanding *how* they are implemented.

---

*Memento Mori — Survive the silence.*
