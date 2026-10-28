# HTTPS Mac → controller, then Noise → edge

**Hardware-tested candidate, not a production-security audit.** Full hardware evidence, including a failed edge1 v8 first boot followed by confirmed recovery and later successes: [`HTTPS_RUNTIME_TEST.md`](HTTPS_RUNTIME_TEST.md). Current last independently verified board state: controller **v11 valid**, edge1 **v9 valid**, edge2 **v9 valid**, both authenticated. The original v8/edge-v7 `/status` baseline and original one-shot senders no longer match the installed boards. No image may be resent merely to recreate a version transition.

## Scope

- Mac firmware uploads go to `https://192.168.4.1:443/update` or `/edge1|/edge2` with `curl --cacert private_keys/host_tls/server.crt`; the cert has IP SAN `192.168.4.1`. The Mac must validate it—never `-k`. TLS server key is a **separate** local ECDSA P-256 identity provisioned into controller NVS via a **USB-only, key-bearing v10 image**; **v11 signed OTA is key-free** and loads the same NVS identity. Neither the TLS key nor static Noise identities are in the signed OTA image. Physical flash extraction is out of scope.
- Plaintext HTTP port 80 retains **read-only GET `/status`** for diagnostics and the Mac-local browser log. Plaintext firmware POSTs return **403**; there is no plaintext firmware-upload fallback. Status is not encrypted or tamper-proof.
- Controller receives plaintext *after TLS termination*, then forwards the unchanged Ed25519-signed manifest and streamed image over authenticated Noise KK to an edge, where role/version/signature/full SHA-256 checks run independently. **Both network hops are protected against a passive AP observer if TLS cert verification and Noise pins hold; this is not end-to-end secrecy against a malicious controller.** No packet-capture evidence yet.

## Local build and checked sender paths

- `./build_https_candidate.sh --usb` generates a **USB-ONLY SECRET-BEARING** controller v10 image; it is **already installed**, and must never be OTA-uploaded, committed or shared. The ignored file `noise_experiments/https_controller_v10_usb_private_build/*.ino.bin` contains the local TLS private key. Do not regenerate or rotate the key.
- `./build_https_candidate.sh --ota-v11` makes a signed, **already spent** key-free v11 image. The v11 first-boot self-test confirmed TLS startup and valid OTA state. Do not resend v11.
- Older experiment senders (`https_experiment/send_https_edge.sh` for edge v8, `https_experiment/send_https_controller_v11.sh` for controller v11) have strict version gates and should now refuse on current v11/v9/v9 hardware. The reconnect branch's v9 edge candidates have also been sent and confirmed. Future presentation images must be strictly newer and independently verified before sending.

## Tested vs outstanding

Verified on actual boards: correct TLS certificate accepted; wrong trust anchor rejected; plaintext HTTP POST refused; signed edge OTA reached valid on each edge over HTTPS + Noise; signed controller OTA v10→v11 reached `ota=valid`; both v9 edges auto re-registered after two controller-only resets and after v11 OTA reboot. Earlier edge1 v8 pending boot rolled back under concurrent status polling: keep that failure visible rather than claiming all uploads succeed. Subsequent successful test changed both polling and firmware timeout/reconnect behavior, so a single root cause was **not** proven. Compiled firmware fit 1,310,720-byte OTA slots; controller minimum free heap during edge OTA ~98–107 KB, but no TLS-task stack measurement or exhaustive stress test was performed.

Unproven: packet capture of the complete transfer; live Noise wrong-pin/replay/tamper negative suite; failure-driven edge rollback injection; secure key-at-rest protection; unattended recovery from *every* AP outage; independent restore or off-Mac encrypted backup of the current complete state. Keep signing and identity keys, full-flash backups, and USB images out of Git.
