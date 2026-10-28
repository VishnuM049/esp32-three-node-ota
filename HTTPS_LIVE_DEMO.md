# Multi-round signed HTTPS + Noise presentation — prepared, NOT sent

**Last independently verified physical state:** controller **v11** (`ota=valid noise=1 tls=1`); edge1 and edge2 **v9** (`ota2=valid`, authenticated). A user-run controller power-off/on while both edges remained powered returned this same healthy three-node status. Firmware upload Mac→controller uses **certificate-verified HTTPS**; controller→edge uses **pinned Noise KK**. Read-only `/status` remains plaintext HTTP. See [`HTTPS_RUNTIME_TEST.md`](HTTPS_RUNTIME_TEST.md) for exact successes, the earlier failed v8 edge first boot, and gaps.

## Nine local, role-specific, one-use images

| Presentation round | Edge1 | Edge2 | Optional controller update **last** |
|---|---|---|---|
| 1 | v9→**v10** | v9→**v10** | v11→**v12** |
| 2 | v10→**v11** | v10→**v11** | v12→**v13** |
| 3 | v11→**v12** | v11→**v12** | v13→**v14** |

All nine `.bin` + 109-byte `.manifest` pairs are **locally compiled and signed but not uploaded**. They live under ignored `noise_experiments/`, not on GitHub. They fit their 1,310,720-byte OTA slots and are scanned for all known provisioned Noise/TLS private keys. These versions may be sent to their **specific role once, in increasing order**. Skipping a future version makes it unusable on that board without intentional recovery; never replay an installed version. A version-only rebuild shows signed OTA progression, **not a new application feature**. You may stagger edge1 and edge2 on separate occasions. The controller update is optional and only permitted after **both** edges reach the round's target, to avoid interrupting a demonstration with an AP reboot.

## Offline preparation (does NOT consume an image)

```sh
cd ~/iot_project_abstracts/ota_prototype
./host_signing/offline_https_demo_check.sh
```

This checks all nine local image/manifest signatures, roles/versions, complete image hashes, partition fit, absence of known private-key bytes, TLS certificate/key pair, Git ignore rules and local tests. It **does not** query or alter boards, change Wi-Fi, flash, or send OTA. It cannot determine whether a signed image has since been used: only real authenticated status can do that.

Before each actual update, supply stable power to all three ESP32s, power controller first, allow 30–60 seconds, join `OTA-CLASS-DEMO` (`demo-ota-1234`) and check once with a sufficiently generous timeout:

```sh
curl --noproxy '*' --connect-timeout 4 --max-time 35 http://192.168.4.1/status
```

Initially require **controller v11 valid** and both edges **v9 `ota2` authenticated** in that same response. Do not mistake a five-second `/status` timeout for proof of firmware failure: that endpoint queries both Noise peers synchronously and replies only afterward. If 35 seconds still fails, **STOP** instead of repeatedly hammering it; diagnose separately. Read-only `/status` does not prove TLS certificate verification—the sender does that before any upload.

## For each presentation step

From this repository **while the Mac is on the demo AP**:

```sh
./host_signing/send_https_demo_ladder.sh --plan edge1   # read-only: show the next valid image
./host_signing/send_https_demo_ladder.sh --send edge1   # asks you to type SEND edge1 v10 (first round)
# Wait for edge1_secure=v10_ota2_ confirmed. Edge2 and controller unchanged.
./host_signing/send_https_demo_ladder.sh --send edge2   # separately, now or later
# Optional LAST, only after both edge v10 valid:
./host_signing/send_https_demo_ladder.sh --send controller  # v11->v12; AP reboots
```

The same `--plan/--send` commands select **the next role-specific version** in later rounds from current status; they do not blindly select a hard-coded filename. If both edges are v11 and controller v12, `--send controller` selects v13; if only edge1 is v11, it refuses the controller round until edge2 catches up. `--plan` verifies local artifacts and the controller's certificate but **does not POST firmware**. `--send` checks both authenticated/valid edges, current role/version, controller TLS/valid state, public-key signature and full image hash, known private-key absence and certificate verification; asks for an explicit typed confirmation; uploads **exactly once** over HTTPS. The destination independently checks before activation. The edge gets a **quiet first-boot registration window** before authenticated `ota2` polling. For highest reliability, leave `python3 web_log/server.py` **stopped while an edge is pending first-boot verification**; the sender still records local events, which the read-only page can show afterward at `http://127.0.0.1:8765/`.

**`ota1` is pending, not successful.** `ota2` on edges or `ota=valid` on controller is confirmed boot. Controller HTTPS uploads reboot its AP; the Mac may roam to its normal network. Rejoin the AP and GET `/status` before doing anything else. A curl timeout or Wi-Fi roam after POST is an **ambiguous outcome**—never automatically retry. Neither sender nor browser log changes Mac Wi-Fi. Restore normal Wi-Fi after the demonstration.

## Honest scope and recovery

The controller sees plaintext between TLS termination and Noise relay: **two protected network hops, not laptop→edge end-to-end secrecy from a malicious controller**. `/status` is plaintext/read-only; a local browser event log is not a tamper-proof security audit. The previously observed edge1 v8 pending boot rolled back; later v9 and controller v11 signed OTAs succeeded, with v9 edges automatically rejoining after two controller resets, a controller OTA reboot, and one user-performed controller power-off/on. That is bounded evidence, **not a guarantee** for every outage. Packet capture, deliberate edge failure-rollback injection, physical key-extraction resistance and full live Noise attack negatives remain untested. A locally verified controller v8 flash snapshot is Git-ignored but not a tested restoration. Keep Mac signing, Noise and TLS private keys out of Git and never put USB-bootstrap secrets in network OTA images.

**Do not follow the older `LIVE_DEMO.md` or resend obsolete edge v8/controller v9 images.** Before presenting, ensure your Mac has the ignored private keys and all nine local signed artifacts; a GitHub clone alone does not contain them.
