# Laptop → controller encryption: implemented HTTPS + hardware evidence

**Current installed setup (2026-10-28):** controller **v11 valid**, edges **v9 valid/Noise authenticated**. The Mac firmware uploader uses `https://192.168.4.1:443` and validates a locally pinned controller certificate with `curl --cacert private_keys/host_tls/server.crt`. The server's **separate** ECDSA P-256 private TLS identity was provisioned into NVS by **USB only**; the signed OTA controller v11 image contains no TLS or X25519 static private key. Developer Ed25519 signing key remains on the Mac. Controller→edge streaming is still pinned Noise KK; edge independently verifies signed manifest, role, increasing version, length and SHA-256. See [`HTTPS_RUNTIME_TEST.md`](HTTPS_RUNTIME_TEST.md) for successes, one failed/rolled-back v8 edge first boot and remaining tests.

**Live tests:** correct pinned certificate accepted; wrong trust anchor rejected (`curl` exit 60); one-byte plaintext HTTP firmware POST refused (403); one-byte HTTPS `/edge2` request with matching role/length but **forged Ed25519 signature** rejected (403), with all three valid versions unchanged; valid signed edge OTA over HTTPS + Noise reached valid on each edge (edge1 v9, edge2 v8 and v9); signed **controller v10→v11 over verified HTTPS** independently reached `ota=valid`. Both v9 edges auto re-registered after two controller-only resets and the controller OTA reboot. Size and runtime heap samples fit this test load; TLS task stack/worst-case heap stress have **not** been quantified.

## Precise confidentiality claim

- **Two protected hops against a passive observer on the demo Wi-Fi:** Mac→controller upload uses verified HTTPS; controller→edge uses authenticated Noise KK with AEAD. **No Wi-Fi packet capture has yet independently shown that the image bytes are absent**, so describe this as the tested authenticated-encryption architecture, not a measured packet-capture result.
- **Not end-to-end confidentiality from laptop to edge against a malicious controller:** controller terminates TLS, sees the plaintext signed image, and re-encrypts it for the edge. True edge-only decryption would require a different per-edge encrypted payload envelope and destination-side key handling.
- **Read-only `GET /status` remains plaintext HTTP** and is what the Mac-local browser log polls. The controller reports `tls=1` for its separate HTTPS upload listener; that status bit alone does not authenticate the controller to the Mac. No firmware POST fallback exists on port 80.
- **No hardware key-at-rest protection:** NVS and the USB-only bootstrap image contain TLS private material; physical flash extraction is outside the trust model. Anyone on the AP can try HTTPS and consume bandwidth, but cannot forge a developer-signed firmware image unless the Mac signing private key is compromised. Mutual TLS client authentication is **not implemented**.

## Still to test before stronger claims

1. Packet capture of laptop and controller→edge transfers under an observer on the local AP; confirm no firmware byte patterns visible outside endpoints.
2. TLS handshake stress, concurrent status, TLS server-task stack high-water, reset/interruption behavior and **full-image** hash-tamper/replay negatives. A short forged-signature HTTPS request, certificate mismatch and plaintext-port refusal were hardware-tested; do not generalize them to untested full transfers.
3. Failure-driven edge rollback injection and the full live Noise wrong-key/tamper/replay suite. Earlier edge1 v8 first boot **did roll back** after an accepted transfer, but the cause was not isolated and it was not an intentionally injected failure.
4. Verify encrypted off-Mac recovery of the current TLS secret and v8 controller full flash, and actually test restore on a spare board. Full snapshot is local and Git-ignored, not a substitute for a proven restore.

Three future one-use rounds (edge v10/v11/v12 and controller v12/v13/v14) are locally prepared and **unsent**; use [`HTTPS_LIVE_DEMO.md`](HTTPS_LIVE_DEMO.md) instead of old v8/edge-v7 HTTP senders. Do not run `curl -k` or transmit USB key-bearing images over any network.
