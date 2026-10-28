# Mac-local browser log (read-only; no ESP32 changes)

From `~/iot_project_abstracts/ota_prototype/` on the Mac:

```sh
python3 web_log/server.py
```

Open **http://127.0.0.1:8765/** in a browser on that same Mac. Keep this Terminal process running during the demonstration; Ctrl-C stops it. It binds to loopback only, serves explicitly named static assets, and **has no update/upload endpoint**. No image, manifest or private key is exposed or sent by this page. A `POST` is refused.

- On normal Wi-Fi the page truthfully shows **not connected to the demo AP**. To see live data, power controller then edges and connect the Mac to `OTA-CLASS-DEMO` (`demo-ota-1234`). If registration is missing after a controller reboot, unplug/replug edge power only. The server GETs `http://192.168.4.1/status` about every eight seconds; controller status in turn queries edges over Noise. Browser refreshes its **local** cache every three seconds. It never triggers an OTA.
- The page shows the *last observed* firmware versions, OTA state, heap/stack margin, and authenticated edge RTT. Offline snapshots are marked stale. Timestamped status changes and observations persist in ignored, Mac-local `noise_experiments/web_log_events.jsonl` (mode 0600). The one-shot `host_signing/send_noise_demo_next.sh` sender also writes **started**, **accepted**, **confirmed** or **ambiguous** entries to that same log when run; the web page never initiates those uploads.
- Start the page **before** the live `edge1` update from `LIVE_DEMO.md`. Show controller v8 / edges v7, then send edge1 once in a separate Terminal; browser log should show v7→v8, pending (if sampled) and valid. Repeat for edge2 if desired. Do not resend a version for rehearsal.
- This is a **presentation log, not a tamper-proof audit log**. It records future observations after it starts, plus sender events written while the page may be closed. It cannot reconstruct unrecorded historical attack attempts or prove confidentiality from a packet capture. Earlier actual hardware evidence remains in `NOISE_RUNTIME_TEST.md`, `SECURE_OTA.md`, and `ROLLBACK_TEST.md`.

Offline self-tests: `cd web_log && python3 -m unittest -q`. If port 8765 is in use, run `python3 web_log/server.py --port 8766` and open `http://127.0.0.1:8766/`. The dashboard deliberately works without internet or third-party Python packages.
