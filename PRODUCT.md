# Product

<!-- impeccable:product-schema 1 -->

## Platform

web

## Stack

Delegated for the new read-only browser log: Python standard-library server on the Mac, with local static HTML/CSS/JavaScript; no framework, external assets, device firmware changes, or upload controls. The user approved a Mac-hosted implementation and asked not to disturb working boards.

## Users

The student team presenting the three-ESP32 OTA prototype and evaluators who need to see node versions and update outcomes, live or from a timestamped record.

## Product Purpose

Make the existing controller `/status` observations and future signed-update outcomes easy to inspect in a browser during a short, offline-capable demo. Success is an honest, readable record showing which board changed version, when the new boot became valid, and when a node was unreachable.

## Operating Context

The Mac temporarily joins `OTA-CLASS-DEMO` to query controller `192.168.4.1/status`; internet may be unavailable. The controller and two edges are already provisioned. The live-demo OTA sender is a separate command-line tool and sends an image only after explicit user action. The browser log must never send firmware or change boards.

## Capabilities and Constraints

- Listen on the Mac's loopback interface only, not on the Wi-Fi AP or public LAN.
- Read controller `/status` periodically; record status changes and valid first boots with timestamps. Offline/unregistered states must be visible and not fabricated into successes.
- A local event file is append-only evidence for this browser feature, not a cryptographic audit log. It cannot reconstruct past events it did not observe.
- OTA images and secrets remain outside the web server's served paths. No POST update endpoint in the browser interface.
- The Mac→controller path is plaintext; Noise protects controller→edge links only. Edge failure rollback and exact first-boot self-signature re-verification are not established claims.

## Evidence on Hand

`NOISE_RUNTIME_TEST.md` records the real one-shot hardware run; `LIVE_DEMO.md` describes reserved future signed versions. Controller `/status` reports controller and authenticated edge version/OTA states, heap/stack telemetry and RTT. Earlier negative tests and controller rollback appear in `SECURE_OTA.md` and `ROLLBACK_TEST.md`. No existing persistent browser log exists.

## Product Principles

- Present device state as observed, never as inferred success.
- Prefer legible proof and timestamps over decoration.
- Never offer a browser action that could accidentally update firmware.
- Work offline and fail clearly when the Mac is not on the demo AP.
