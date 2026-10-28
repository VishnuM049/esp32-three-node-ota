# Can we encrypt laptop → controller? Feasibility report only

**Yes, technically. No code or ESP32 firmware has been changed for this proposal.** Current live controller v8 accepts laptop HTTP on `192.168.4.1:80`; controller↔edges use Noise KK. Even though an edge hop is encrypted, the exact firmware bytes were available in the *earlier plaintext laptop request* on the same AP. The current Ed25519 signature still prevents an unauthorized/modified binary from being accepted; authenticity and confidentiality are different properties.

## Preferred incremental option: pinned HTTPS for the Mac uploader

1. Give the controller a **separate** TLS server certificate/private key and HTTPS listener. Pin the certificate or a local CA on the Mac; make the certificate valid for `192.168.4.1` (IP SAN) or an explicitly resolved local name. The uploader must **validate** the certificate (`curl --cacert ...`, pinned public key, or equivalent): `curl -k`/`--insecure` would permit a fake AP/controller to intercept the upload.
2. Send the unchanged signed `OTA1` manifest and binary through HTTPS, then keep the existing pinned Noise controller→edge channel and every destination's independent Ed25519/role/version/full-hash verification. Migrate/remove the plaintext update route; leaving an open HTTP fallback weakens the claim that Mac uploads are always private. A plaintext read-only status endpoint is a separate policy decision, not a firmware upload path.
3. If the presenter also wants uploader **client authentication**, use mTLS/pinned client certificate or another well-reviewed authentication mechanism. HTTPS server verification alone encrypts the upload and authenticates the controller **to the Mac**; it does not prove that an arbitrary AP client is the authorized developer. Signed firmware still limits what image an attacker can successfully install, but not DoS or bandwidth usage.
4. Provision and store TLS private material so the first deployment does **not** send a private key in a firmware image over the existing plaintext Mac→controller upload. USB provisioning into separate controller NVS is one option; physical flash extraction remains possible because these boards have no hardware Secure Boot/flash encryption. Do not reuse the Ed25519 firmware signing private key or the controller's X25519 Noise identity as a TLS server key.
5. Rebuild controller, measure full `.bin` against the **1,310,720-byte** OTA slot and measure real heap/stack during TLS + Noise forwarding. The earlier controller's minimum free heap during edge OTA was about **165 KB**; that does *not* prove mbedTLS handshake buffering and simultaneous TCP streams will fit reliably. Use a staged migration/recovery plan, not a quick presentation-day change.
6. Negative tests: reject a wrong/expired/unpinned server cert, reject plaintext POST after migration, verify a passive capture of the *laptop* upload lacks firmware bytes, and repeat signed-image rejection/rollback and memory tests. Do not claim this improvement before those tests pass.

ESP32's software stack includes TLS/mbedTLS facilities, and Mac `curl` can run offline against a local AP; no public internet service is required. **Feasible does not mean already implemented or proven to fit.** The current prepared edge v8/controller v9 one-use presentation images are unchanged and must not be confused with a TLS build.

## Other option: Noise on Mac → controller

Add a distinct, pinned **Mac X25519 identity** and a Mac-side Noise KK client, plus a Noise-only controller upload listener. This reuses the project's handshake family but requires a new Mac implementation, provisioning a fourth identity/pin, protocol design, and hardware interoperability/negative tests. Do not wrap an ad-hoc cipher around the HTTP upload or silently label it Noise.

## What each option would *really* prove

- **HTTPS/Noise on both hops:** hides firmware from a passive observer of the Wi-Fi AP, assuming correct Mac authentication of the controller and no other plaintext copy. The controller still decrypts/sees the firmware, so it is **two protected hops**, not end-to-end confidentiality from laptop to edge against a compromised controller.
- **True laptop→edge confidentiality:** encrypt the image specifically to each edge so **only that edge** has the decryption key; the controller forwards opaque ciphertext. This requires a separate end-to-end envelope/key architecture and destination-side signature/hash checks. Neither this nor the pinned HTTPS option is implemented today.
- **Firmware authenticity today:** already comes from the developer Ed25519 signature checked at each destination. It does not depend on HTTPS or Noise transport confidentiality.

**Recommendation:** preserve the working, locally prepared one-shot demo and explain its exact controller→edge encryption scope. Treat Mac→controller encryption as a subsequent controlled iteration, not a last-minute modification to presentation firmware.
