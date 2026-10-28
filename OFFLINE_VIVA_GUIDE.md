# HISTORICAL offline guide — v8/v7/v7 signed + Noise milestone

**Today's boards have advanced to controller v11 / edges v9 with HTTPS laptop uploads and automatic edge re-registration demonstrated on the new builds.** For current stage commands and accurate viva scope see [`HTTPS_LIVE_DEMO.md`](HTTPS_LIVE_DEMO.md), [`HOST_LINK_ENCRYPTION_REPORT.md`](HOST_LINK_ENCRYPTION_REPORT.md), and [`HTTPS_RUNTIME_TEST.md`](HTTPS_RUNTIME_TEST.md). **Do not execute the v8/v7 commands below**; this document remains useful for the signed-manifest/Noise architecture and historical failure comparisons.

**Read this on the Mac without internet.** Exact hardware run: `NOISE_RUNTIME_TEST.md`. One-use future image instructions: `LIVE_DEMO.md`. Claim-by-claim submitted abstract audit: `ABSTRACT_CLAIM_REPORT.md`. This guide does **not** authorize reflashing or reusing a spent image.

## 1. The 45-second explanation

> "Three ESP32s form a star. The controller creates a local Wi-Fi access point; two edges join it. The laptop signs a firmware image with the developer's Ed25519 private key and uploads it to the controller. For an edge target, the controller relays the *same signed image* through an authenticated Noise KK channel using X25519 and ChaCha20-Poly1305. The edge independently checks the signature, target role, signed version and length, and full image hash before activating a separate OTA partition. On reboot it confirms a healthy boot and reports its version over an authenticated link. We updated both edges and the controller on real boards. Encryption protects controller-to-edge, not the laptop-to-controller HTTP upload. This is application-level security, not hardware Secure Boot."

You can stop there in a short demo. If asked for proof, show the actual **before → after version change and valid boot** in `/status` and the Mac-local browser log. Don't claim a packet capture, all negative tests on the final encrypted firmware, or tested edge failure rollback.

## 2. The network, without internet

```text
                        Wi-Fi demo AP (NO internet required)
Mac laptop  -- HTTP port 80, PLAINTEXT -->  controller ESP32 192.168.4.1
                                                | Noise KK, authenticated/encrypted
                                          +-----+------+
                                          |            |
                                    edge1 ESP32   edge2 ESP32
                                    port 8080     port 8080
                          (edge registration -> controller Noise port 8081)

Browser log: http://127.0.0.1:8765/ on the Mac ONLY (read-only, not an upload server)
```

The controller creates `OTA-CLASS-DEMO` (password `demo-ota-1234`); edges join as Wi-Fi stations and get **dynamic** `192.168.4.x` addresses. A matching MAC or Wi-Fi IP is *not* the Noise identity. Public keys pinned by role are. The Mac joins this AP temporarily; **there is no cloud, DNS, external update server, or internet dependency during the demonstration**. Connecting the Mac to the demo AP may disconnect its normal internet. The web log loads its CSS/JS locally; the signing library and images are already present on this Mac. Wi-Fi password alone is not the security claim.

## 3. Two different cryptographic jobs

| Job | Tool/key | Who holds the secret? | What it does **not** do |
|---|---|---|---|
| **Developer authorization of firmware** | Ed25519 digital signature over the signed manifest | The developer's Ed25519 private signing key lives **on the Mac**, not on the ESP32s or in Git. ESP32s embed only the public verifier. | A signature does **not** conceal image bytes. |
| **Controller↔edge channel** | Noise `KK_25519_ChaChaPoly_SHA256`: X25519 static identities and ephemeral handshake, ChaCha20-Poly1305 authenticated encryption, SHA-256 handshake hash | A **different** X25519 static private identity is in each board's NVS; each peer pins the other's public key for its role. Fresh ephemeral keys are made by Noise-C per connection. | This channel does **not** encrypt the Mac→controller HTTP request or protect keys from physical flash extraction. |
| **Image integrity** | SHA-256 of the entire binary, embedded within the Ed25519-signed metadata | No extra secret needed. | SHA-256 by itself does **not** prove who made an image. |

Why not use the Ed25519 key to encrypt? It is a signature key, with a separate purpose and mathematical operation. X25519 establishes authenticated session keys; ChaCha20-Poly1305 then encrypts and authenticates individual records. Don't call the X25519 static key a firmware-signing key.

**Important safety detail:** The one-time USB bootstrap images had device static private identities so they could provision NVS. Newer OTA binaries contain **public pins only** and load their own private identity from NVS after boot. If an OTA binary had embedded that secret, the plaintext Mac upload could leak it to an AP observer. The local build/sender scan for the three provisioned raw private-key byte sequences; this is defense in depth, not a formal secrecy proof. NVS is not encrypted at rest; no Secure Boot, flash encryption, secure element, or eFuse anti-rollback is claimed.

## 4. Follow one update byte for byte

1. **Prepare on laptop:** compile a role-specific `.bin` and calculate SHA-256 over its bytes. Construct a **109-byte** `OTA1` manifest:
   `"OTA1"[4] || role[1] || version[4 LE] || length[4 LE] || image_sha256[32] || Ed25519_signature[64]`.
   The signature covers the **first 45 bytes**, which include the image hash, role, version, and length. Signing that hash binds the entire binary without sending the 1 MB image through Ed25519 as a separate signing input. The same manifest travels unchanged to its destination.
2. **Laptop to controller:** Mac sends HTTP POST to `/edge1` or `/edge2` on `192.168.4.1:80` with the binary body and manifest header. This hop is **plaintext HTTP**. For a controller-targeted image, POST to `/update`; there is no controller→edge forwarding on that path.
3. **Controller gate:** check manifest format, signature, target role and length *before* forwarding. It never creates a new developer signature. A registered edge address is trusted only after a matching Noise handshake **and** encrypted REGISTER record. The controller can reject bad metadata early but cannot waive the edge's own checks.
4. **Authenticated channel:** controller connects to the right edge's port 8080 and runs pinned Noise KK with role-specific prologue `ESP32-OTA-LINK-v1/edge1` or `/edge2`. Handshake has no application side effects; a fresh authenticated post-handshake record must arrive first. Records use a bounded two-byte length prefix. Library-managed keys/nonces/AEAD protect registration, status, firmware chunks, and response. Plain HTTP `/update` on an edge port is **not** accepted (a harmless GET got no HTTP response in the hardware run).
5. **Streaming:** controller sends encrypted UPDATE_BEGIN carrying the same 109-byte manifest, then UPDATE_DATA chunks of at most **1,024 binary bytes** plus a one-byte command, and UPDATE_COMMIT. No ESP32 holds the ~1 MB firmware in RAM. Each edge checks developer signature, role, strictly newer signed version, signed length, encrypted record order, streamed SHA-256 and total byte count. If interrupted, malformed, unauthenticated or hash-mismatched, the inactive update is aborted. Only after complete verification does `Update.end(false)` select the new image for boot.
6. **Accepted is not healthy:** edge replies with an authenticated transfer result; **that alone does not mean the new app booted**. After reboot, controller queries authenticated status again. `ota1` means *pending first-boot verification* and `ota2` means **valid/confirmed** on an edge. Controller prints `ota=valid`. The sender never retries an ambiguous timeout automatically.

**Rollback:** On a first OTA boot, the controller tests AP/crypto startup; edges also require authenticated registration with their pinned controller before confirming, within roughly 30 seconds. If the test fails, code attempts rollback to the previous partition. A deliberately failing signed controller v6 **did** roll back to v5 in hardware. Edge *failure-driven* rollback is coded but **not hardware-tested**. A successful first boot does not prove recovery from every later crash. Firmware signature and image hash are verified **before activation**, not rechecked on the running image during first boot as the abstract's proposed method literally says.

## 5. What was actually demonstrated

- Both edges independently rejected unsigned, wrong-role, replayed, forged-signature, and tampered images in the earlier signed-OTA hardware tests (`ROLLBACK_TEST.md`). The controller also rejected bad requests. Not every negative was rerun on the final Noise build.
- Initial MAC-checked USB bootstraps made controller v7 and both edges v6 Noise-capable. Both authenticated registration and status worked together.
- One signed v6→v7 OTA through the encrypted controller link to **each** edge succeeded. Each reported pending (`ota1`) then valid (`ota2`). Controller independently updated v7→v8 over the plaintext laptop hop and reported `ota=valid`.
- After controller v8 reboot the edges did **not** re-register unattended; manually unplugging/replugging both edges restored authentication. Final simultaneous status showed controller v8 valid; edge1 and edge2 v7 valid. Do **not** claim automatic reconnection or tested edge rollback.
- A plaintext `GET /update` at each edge Noise port received no HTTP response; both remained valid. This is a limited negative smoke test, not the full live Noise wrong-key/replay/tamper suite. Two upstream desktop Noise KK vectors and native negative tests passed separately.
- Runtime sketch telemetry after the edge OTA run: controller minimum free heap about **165 KB**, stack margin about **8.6 KB**; edge status queries about **213–215 KB** minimum free heap and about **10.8 KB** stack margin. No memory-exhaustion failure was observed in this run; these are not worst-case guarantees. Images fit the 1,310,720-byte OTA slot.

## 6. What you MUST prepare before leaving internet

Use the **same Mac** with this local repository and ignored artifacts. GitHub has source and documents, **not** the private keys, local Python virtualenv, role-specific binaries or signed manifests. If you clone GitHub onto a different Mac at the venue, the live OTA demo will not be ready.

```sh
cd ~/iot_project_abstracts/ota_prototype
./host_signing/offline_demo_check.sh
```

This local check verifies all three *future* v8 edge/v9 controller `.bin`+manifest pairs, their signatures, slot fit, key-free image scan, locally installed dependencies and 19 offline tests. It **does not contact or change boards**, consume a version, switch Wi-Fi, or require internet. Look for `OFFLINE PREFLIGHT PASSED`. Take this guide and `LIVE_DEMO.md` as local files (and optionally print them). Charge the Mac; provide power to **all three** ESP32s at once. The locally encrypted signing/identity backup does not need iCloud at the venue. Do not run `build_noise_firmware.sh` or `noise_keys.py init` on stage.

## 7. Stage demo: safe order, literal commands

**Before audience arrives:** power controller first, then both edges. Allow ~20 seconds. If one is unregistered, check its power and unplug/replug its USB **power** once; never reflash just to fix registration. Do not run the one-shot OTA until both edges report valid and authenticated.

Terminal A (browser log, start early):

```sh
cd ~/iot_project_abstracts/ota_prototype
python3 web_log/server.py
```

Open `http://127.0.0.1:8765/` **on the same Mac**. If a web-log process is already running at port 8765, simply use it; do not launch a competing one. It reads status and records future changes; this page has **no upload button**. Its local event file is not a tamper-proof audit log and does not invent historical negative-test events.

Connect the Mac to `OTA-CLASS-DEMO` with password `demo-ota-1234` using Wi-Fi settings. Or on this Mac: `networksetup -setairportnetwork en0 OTA-CLASS-DEMO demo-ota-1234`. It is normal to see **no internet**. If Mac auto-switches to a remembered internet network, reconnect to demo AP. Check `ipconfig getifaddr en0` begins `192.168.4.` and refresh the web log.

Terminal B (baseline):

```sh
cd ~/iot_project_abstracts/ota_prototype
curl --noproxy '*' --max-time 20 http://192.168.4.1/status
```

Expected *before* live OTA: controller `role=0 version=8 noise=1 ... ota=valid`; **both** `edge1_secure=v7_ota2_...` and `edge2_secure=v7_ota2_...` in one response. `ota2` on an edge is valid, not a version number. Actual edge IPs are dynamic and may differ from earlier logs. If this baseline is absent, **STOP; do not guess or upload**.

Terminal B (one real version change):

```sh
./host_signing/send_noise_demo_next.sh edge1
```

Script validates image/signature, that no provisioned raw X25519 private key is embedded, current versions, both authenticated edges and the controller's healthy boot. It sends **exactly once**, prints the controller's authenticated acceptance, then polls for `edge1_secure=v8_ota2_`. The web log should display the edge1 v7→v8 transition and confirmed result. *This is the easiest complete live demonstration; stop here if time is short.*

If desired and still healthy, run `./host_signing/send_noise_demo_next.sh edge2` and see edge2 v7→v8. **Optional and riskier:** after both edges are v8 valid, `./host_signing/send_noise_demo_next.sh controller` updates controller v8→v9. It reboots the AP; you may have to power-cycle both edges manually, as in the earlier run. Leave controller v8 untouched for a low-risk presentation. Neither the dashboard nor the sender needs internet.

**Versions are single-use:** sending the same signed v8 edge target twice is rejected, not an idempotent demo. Do not run the prepared sender before the audience merely as rehearsal. If upload outcome or Wi-Fi is ambiguous, check `/status` and serial before *any* further action; no automatic retry. A browser log merely displays observations, not proof that the image is valid by itself.

## 8. If something goes wrong (no internet)

- **Web log says offline:** make sure it is running on the Mac and Mac has `192.168.4.x`; the page at `127.0.0.1` still opens without internet. Do not equate a blank log with a failed ESP update.
- **Controller AP missing:** verify controller power first; no image is being sent. The prior hardware run needed a controller reset to restore its AP, then manual edge power cycles. Avoid resetting during an upload.
- **Only one edge registered:** check its power and power-cycle that **edge only**. Edge IPs change; never hard-code old addresses.
- **Sender refuses:** read the exact error. Wrong version, unsigned manifest, missing files, or an unregistered edge are deliberate stop conditions. Do not bypass them for a smoother show.
- **HTTP upload timed out after sending:** outcome is **unknown**, not automatically failed. Inspect current version and OTA state. Never blindly resend; a previous accepted update could already have booted.
- **`ota1` persists:** pending first-boot verification; do not claim success yet. `ota2` or `ota=valid` after reboot is evidence of confirmed boot.
- **Mac rejoined internet Wi-Fi:** reconnect to demo AP; the signed images and page are local. No cloud access is necessary.
- **Battery/USB trouble:** keep boards powered; skip optional controller update and show recorded evidence instead of doing destructive tests.

## 9. Viva questions, precise short answers

1. **What is OTA?** Replacing firmware over a network rather than USB after initial provisioning.
2. **Why three boards?** A small star fleet tests independent destination verification rather than trusting a controller to bless images for others.
3. **What does the controller do?** Hosts local AP, receives laptop HTTP POST, relays an unchanged signed manifest and streamed image through Noise to the pinned edge, and queries authenticated edge status. For its own target, it verifies/stages its own signed image.
4. **Does the controller sign edge images?** No. Only the Mac holds the developer signing private key; each edge verifies with the public key built into its app.
5. **Why not trust a Wi-Fi MAC or IP?** They identify an interface/address, not the peer's cryptographic identity, and may change or be spoofed. The protocol pins public X25519 keys by role.
6. **What is a digital signature?** The developer signs metadata with the private key; anyone with the embedded public key can verify origin and unchanged signed fields, but cannot create a new valid signature.
7. **Why SHA-256 as well?** The signed manifest includes the expected *whole-file* SHA-256. The ESP hashes received chunks and compares; a changed byte or missing chunk changes the digest.
8. **Why Ed25519 and X25519 separately?** Ed25519 authorizes firmware; X25519 authenticates/derives session keys for encrypted transport. Do not reuse one identity for the other purpose.
9. **What is Noise KK?** A defined two-message handshake where both peers know each other's static public keys in advance. It mixes fresh ephemeral X25519 contributions, binds role-specific prologue, and produces directional transport cipher states. It is implemented via narrowed Noise-C, not a custom handshake.
10. **What is ChaCha20-Poly1305?** Authenticated encryption: ChaCha20 conceals record contents; Poly1305 authentication tags make modification detectable. Library-managed nonces/counters and fresh sessions prevent normal record replay in a session.
11. **Can an attacker send an older *validly signed* image?** Over the network, the receiver requires signed version `> FW_VERSION`, so a repeated/older image is rejected. This is application-level version checking, **not** irreversible physical eFuse anti-rollback.
12. **Can a compromised controller forge firmware?** Not without the developer's Ed25519 private key if edge verifier/key remain intact. It *can* withhold/delay data or lie in laptop-facing diagnostics. Physical reflashing of an edge is outside the software trust model.
13. **Why keep previous OTA partition?** Stage updates in an inactive slot; do not overwrite the current working app until verification. First-boot failure can revert to the previous slot.
14. **Was rollback shown?** Yes for the deliberately failing **controller** v6 reverting to v5 in an earlier run. Edge failure rollback remains untested on hardware.
15. **What was the one-time USB step for?** All three existing receivers lacked Noise identities/protocol. USB installed compatible fail-closed apps and provisioned distinct static X25519 secrets into each board's NVS. Later signed OTA images do **not** embed these private keys.
16. **Is every hop confidential?** No. Controller→edge is Noise-protected. Mac→controller HTTP is plaintext on the same AP. A passive whole-AP observer can recover firmware from the laptop upload; signatures still prevent installation of altered/unauthorized firmware.
17. **Why isn't the web log itself proof of security?** It displays controller observations and local sender events. It's not a signed, tamper-proof audit log and cannot show unrecorded past attempts.
18. **What happens without internet?** Nothing essential changes: the controller supplies the local Wi-Fi AP; scripts, keys, images, manifests and browser assets live on this Mac.
19. **What if the AP password leaks?** Wi-Fi password is not the identity or code-signing boundary. Pinned Noise keys protect the controller↔edge link and Ed25519 checks protect accepted firmware. An AP peer can still interfere with availability.
20. **What is incomplete?** Automatic edge re-registration after controller reboot did not work unattended; live-device Noise negative/tamper suite and edge rollback not tested; first-boot signature isn't reverified *again* after activation; physical key extraction is not prevented; Mac HTTP upload is plaintext.

## 10. Optional extension: encrypt Mac→controller, **NOT implemented**

It is technically possible (e.g., authenticated TLS/HTTPS on the controller with certificate pinning in the Mac uploader, then Noise to the edges), but it is a separate software change, new memory/flash test and new firmware rollout. HTTPS on that first hop would prevent a passive AP observer from reading the laptop upload **if** the Mac verifies the controller certificate (never `curl -k`). The controller still sees plaintext between the two secure hops, so this is **not** true laptop→edge end-to-end encryption against a malicious controller. For that stronger claim, the laptop must encrypt for the *edge* and only the edge may decrypt; controller would relay opaque ciphertext. See `HOST_LINK_ENCRYPTION_REPORT.md`. No current device implements either extension.
