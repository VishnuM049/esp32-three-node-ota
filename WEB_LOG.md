# Read-only Mac-local browser log

Run from this repository on the **same Mac**:

```sh
python3 web_log/server.py
# Browser on this Mac: http://127.0.0.1:8765/
```

It binds to loopback only, serves local assets, and **does not accept or send firmware**. `POST /update` on the browser log is refused. It GETs the controller's **plaintext, read-only** `http://192.168.4.1/status` roughly every eight seconds when the Mac is on `OTA-CLASS-DEMO`; the dashboard itself caches and refreshes locally. The installed controller now reports `tls=1` if its separate **HTTPS firmware-upload listener** is ready. The page distinguishes that from the older controller v8's **plaintext HTTP firmware upload**, and explicitly notes that `/status` remains plaintext. A controller-reported flag by itself is **not** a certificate-verification test; the Mac one-shot sender must validate the pinned certificate.

The page shows observed versions, OTA state, authenticated edge RTT and diagnostic heap/stack margin. Offline snapshots are marked stale. Observed changes and sender events are kept in ignored, private Mac-local `noise_experiments/web_log_events.jsonl`; the page cannot reconstruct events it missed or prove AP confidentiality. This is **not** a tamper-proof audit log. No private key, manifest, image or USB backup is served.

**Current last verified hardware (2026-10-28):** controller v11 `ota=valid` with `noise=1 tls=1`; edge1/edge2 v9 `ota2` authenticated. **Live Mac-local API check passed:** with the Mac on the demo AP and all three boards powered, `/api/state` returned `connected=true`, controller v11 TLS/Noise/valid, and both edge v9 valid/authenticated. The new frontend scope text and seven offline tests passed; a separate visual browser check on the AP was not performed. For repeated/staggered presentations, the next signed **edge v10/v11/v12 and controller v12/v13/v14** images are prepared under ignored `noise_experiments/` (see `HTTPS_LIVE_DEMO.md`). Older `LIVE_DEMO.md` sender commands for controller v8/edge v7 are historical and will deliberately refuse. Do not restart the failed edge1 v8 upload.

**Polling caution:** During the initial experimental edge1 v8 first-boot test, the browser log's eight-second status polling and the sender's three-second polling both queried a controller that synchronously polls edges, possibly contributing to registration delay and rollback. Later successful updates paused the browser log and left a quiet 20–45-second post-upload period for first-boot authentication. The root cause was not isolated. Keep the browser log optional; for highest demo reliability, let the new signed one-shot sender finish and confirm first, then start or refresh the page. The log does not alter boards, and the lack of a log entry does not mean a transfer failed.

Offline tests: `python3 -m unittest discover -s web_log -p 'test_*.py' -q`. If port 8765 is occupied, use `python3 web_log/server.py --port 8766` and open `http://127.0.0.1:8766/`. No internet or third-party Python packages are required to view the page.
