# Why Memento Mori Is *Not* Signal or Matrix

Memento Mori is often compared to Signal or Matrix.
This comparison is understandable — and fundamentally incorrect.

This document explains **why**.

---

## 1. Different Problem Class

**Signal and Matrix solve communication *on the Internet*.**
Memento Mori solves communication **when the Internet is absent, degraded, monitored, or deliberately suppressed**.

| Aspect                  | Signal / Matrix | Memento Mori             |
| ----------------------- | --------------- | ------------------------ |
| Internet required       | Yes             | No                       |
| Continuous connectivity | Assumed         | Not assumed              |
| Central coordination    | Required        | None                     |
| Cloud dependency        | Core            | Optional / Opportunistic |
| Offline survivability   | Limited         | Foundational             |

---

## 2. Transport Assumptions

### Signal / Matrix

* Assume stable IP connectivity
* Assume background networking is allowed
* Assume OS cooperation
* Focus on cryptography *over transport*

### Memento Mori

* Assume **radio silence**
* Assume **OS hostility**
* Assume **battery kill heuristics**
* Focus on **transport survivability first**, crypto second

> In Memento Mori, **encryption is useless if transport never survives long enough to deliver a packet**.

---

## 3. Control Plane vs Autonomy

Signal and Matrix rely on:

* Servers
* Push notifications
* Long-lived connections
* Federated or centralized routing logic

Memento Mori relies on:

* **No control plane**
* Local, opportunistic decisions
* Autonomous nodes
* Store-and-forward DTN behavior

There is no concept of:

* “online”
* “offline”
* “server availability”

Only **local reachability**.

---

## 4. Operating System Reality

Signal and Matrix are optimized for:

* Flagship devices
* Predictable background execution
* OS-approved network usage

Memento Mori is designed for:

* Budget Android devices
* Vendor-modified firmware (Xiaomi, Tecno, Huawei)
* Shared HAL contention (Bluetooth / Audio / Wi-Fi)
* Aggressive process termination

This is why Memento Mori has a **Tactical Orchestrator** and Signal does not.

---

## 5. Identity Model

### Signal / Matrix

* Identity anchored to servers
* Registration-dependent
* Recovery requires infrastructure

### Memento Mori

* **Ghost identity**
* Fully offline
* No registration
* No authority
* Atomic merge when internet appears

Identity exists **before** the network, not because of it.

---

## 6. Threat Model

Signal / Matrix defend against:

* Network eavesdroppers
* Server compromise
* Metadata leakage (to a degree)

Memento Mori additionally defends against:

* Network absence
* Infrastructure collapse
* RF monitoring
* OS-level interference
* Forced isolation
* Local-only coordination

These are **orthogonal threat models**.

---

## 7. Explicit Non-Competition

Memento Mori is **not trying to replace** Signal or Matrix.

If you have:

* stable internet
* trusted infrastructure
* modern devices

👉 Use Signal or Matrix.

If you have:

* no internet
* partial connectivity
* censorship
* disaster scenarios
* hostile environments

👉 Memento Mori exists for *that* gap.

---

## 8. Summary

Signal and Matrix are **secure messengers**.

Memento Mori is a **survivable communication substrate**.

They overlap in cryptography,
but diverge completely in **assumptions, architecture, and intent**.

---

*Memento Mori — Communication when assumptions collapse.*
