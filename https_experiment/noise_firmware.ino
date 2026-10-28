// Three-node OTA with application-level Ed25519 verification (no hardware Secure Boot).
// Compile with -DNODE_ROLE=0 (controller), 1 (edge 1), or 2 (edge 2).
// Compile with -DFW_VERSION=1, 2, ... to see updates happen.
#include <Arduino.h>
#include <WiFi.h>
#include <Update.h>
#include <sodium.h>
#include <esp_ota_ops.h>
#include <Preferences.h>
#include <esp_https_server.h>
#include "TrustedPublicKey.h" // Public Ed25519 verifier; signing key stays on laptop.
#include "NoiseLink.h"
#include "IdentityStore.h" // Loads the local X25519 secret from persistent NVS.
// OTA relay + Noise frames nest several KB of buffers; runtime status reports
// stack margin. Arduino's weak default loop stack is only 8 KB.
SET_LOOP_TASK_STACK_SIZE(16384)

#ifndef NODE_ROLE
#define NODE_ROLE 0
#endif
#ifndef FW_VERSION
#define FW_VERSION 1
#endif
#ifndef FORCE_SELF_TEST_FAILURE
#define FORCE_SELF_TEST_FAILURE 0
#endif
#ifndef CONFIG_BOOTLOADER_APP_ROLLBACK_ENABLE
#error This rollback build requires an Arduino ESP32 core with bootloader app rollback enabled.
#endif
// Arduino's default hook confirms an OTA image before setup() can test Wi-Fi.
// Defer confirmation until our first-boot diagnostics complete in setup().
extern "C" bool verifyRollbackLater(void) { return true; }
#if NODE_ROLE < 0 || NODE_ROLE > 2
#error NODE_ROLE must be 0, 1, or 2
#endif

static const char *AP_NAME = "OTA-CLASS-DEMO";
static const char *AP_PASSWORD = "demo-ota-1234"; // demonstration only, NOT a security boundary
static const IPAddress gateway(192, 168, 4, 1);
static IPAddress edge1(0, 0, 0, 0);
static IPAddress edge2(0, 0, 0, 0);
static unsigned long lastRegister = 0;
static const uint16_t port = 80; // Laptop-facing HTTP ONLY on controller.
static const size_t MAX_IMAGE = 0x140000; // default 4MB partition table: 1.25MB OTA slots
static const unsigned long IDLE_TIMEOUT_MS = 12000;
static const size_t MANIFEST_SIZE = 109;
static const size_t SIGNED_HEADER_SIZE = 45;
static bool cryptoReady = false;
static bool noiseReady = false;
static bool tlsReady = false;
static httpd_handle_t tlsServer = nullptr;
static String tlsCert, tlsKey; // Persist for the entire server lifetime; NVS, NOT the OTA binary.
static bool startHttpsServer();
#ifdef TLS_USB_BOOTSTRAP
extern bool provisionHttpsIdentity(); // NEVER linked into OTA builds
#endif
#ifdef NOISE_USB_BOOTSTRAP
extern bool provisionBootIdentity(); // only linked into USB bootstrap builds
#endif
static bool pendingEdgeVerification = false;
static unsigned long edgeVerificationStarted = 0;
WiFiServer webServer(port);
WiFiServer peerServer(NODE_ROLE == 0 ? 8081 : 8080);

static const char *otaStateName(esp_ota_img_states_t state) {
  switch (state) {
    case ESP_OTA_IMG_NEW: return "new";
    case ESP_OTA_IMG_PENDING_VERIFY: return "pending";
    case ESP_OTA_IMG_VALID: return "valid";
    case ESP_OTA_IMG_INVALID: return "invalid";
    case ESP_OTA_IMG_ABORTED: return "aborted";
    default: return "unknown";
  }
}

static int hexDigit(char ch) {
  if (ch >= '0' && ch <= '9') return ch - '0';
  if (ch >= 'a' && ch <= 'f') return ch - 'a' + 10;
  return -1;
}

static bool decodeManifest(const String &hex, uint8_t *out) {
  if (hex.length() != MANIFEST_SIZE * 2) return false;
  for (size_t i = 0; i < MANIFEST_SIZE; ++i) {
    int hi = hexDigit(hex[2 * i]), lo = hexDigit(hex[2 * i + 1]);
    if (hi < 0 || lo < 0) return false;
    out[i] = (uint8_t)((hi << 4) | lo);
  }
  return true;
}

static uint32_t le32(const uint8_t *in) {
  return (uint32_t)in[0] | ((uint32_t)in[1] << 8) |
         ((uint32_t)in[2] << 16) | ((uint32_t)in[3] << 24);
}

static bool verifySignedMetadata(const uint8_t *manifest, uint8_t expectedRole,
                                 size_t contentLength, uint32_t minVersion, String &reason) {
  if (!cryptoReady) { reason = "Crypto unavailable"; return false; }
  if (memcmp(manifest, "OTA1", 4) != 0) { reason = "Wrong manifest format"; return false; }
  if (manifest[4] != expectedRole) { reason = "Wrong target role"; return false; }
  if (le32(manifest + 9) != contentLength) { reason = "Signed length mismatch"; return false; }
  if (le32(manifest + 5) <= minVersion) { reason = "Old or repeated version"; return false; }
  if (crypto_sign_verify_detached(manifest + SIGNED_HEADER_SIZE, manifest,
                                   SIGNED_HEADER_SIZE, OTA_TRUSTED_PUBLIC_KEY) != 0) {
    reason = "Invalid developer signature";
    return false;
  }
  return true;
}

static bool readLine(WiFiClient &client, String &line, unsigned long timeoutMs) {
  line = "";
  unsigned long last = millis();
  while (millis() - last < timeoutMs) {
    int c = client.read();
    if (c < 0) { delay(2); continue; }
    last = millis();
    if (c == '\n') { line.trim(); return true; }
    if (line.length() >= 255) return false;
    if (c != '\r') line += (char)c;
  }
  return false;
}

static void reply(WiFiClient &client, int status, const String &message) {
  String body = message + "\n";
  client.printf("HTTP/1.1 %d %s\r\nContent-Type: text/plain\r\nContent-Length: %u\r\nConnection: close\r\n\r\n",
                status, status == 200 ? "OK" : "Error", (unsigned)body.length());
  client.print(body);
  client.flush();
}

// Read exactly 'count' binary bytes; never keep the whole firmware in RAM.
static bool copyBytes(WiFiClient &from, NoiseLink *to, size_t count, bool flash,
                      crypto_hash_sha256_state *hash = nullptr) {
  uint8_t buf[1024];
  size_t remaining = count;
  unsigned long last = millis();
  while (remaining) {
    int available = from.available();
    if (available <= 0) {
      if (millis() - last > IDLE_TIMEOUT_MS) return false;
      delay(2);
      continue;
    }
    size_t wanted = min(remaining, min((size_t)available, sizeof(buf)));
    int n = from.read(buf, wanted);
    if (n <= 0) continue;
    last = millis();
    if (flash && Update.write(buf, n) != (size_t)n) return false;
    if (hash && crypto_hash_sha256_update(hash, buf, n) != 0) return false;
    if (to) {
      uint8_t record[1 + sizeof(buf)];
      record[0] = 0x11; // authenticated UPDATE_DATA
      memcpy(record + 1, buf, n);
      if (!to->send(record, (size_t)n + 1)) return false;
    }
    remaining -= n;
  }
  return true;
}

static String queryEdgeStatus(uint8_t role, IPAddress address) {
  if (!noiseReady) return "crypto_unavailable";
  if (address == IPAddress(0, 0, 0, 0)) return "unregistered";
  unsigned long started = millis();
  WiFiClient channel;
  if (!channel.connect(address, 8080, 1500)) return "offline";
  NoiseLink secure;
  if (!secure.begin(channel, role, true)) return "auth_failed";
  uint8_t command = 0x20, answer[NoiseLink::MAX_PLAIN];
  size_t size = 0;
  if (!secure.send(&command, 1) || !secure.receive(answer, size) ||
      size != 15 || answer[0] != 0x21 || answer[1] != role) return "bad_status";
  return String("v") + String(le32(answer + 2)) + "_ota" + String(answer[6]) +
         "_minheap" + String(le32(answer + 7)) + "_stack" + String(le32(answer + 11)) +
         "_rttms" + String(millis() - started);
}

static void handle(WiFiClient &client) {
  client.setTimeout(12);
  String line;
  if (!readLine(client, line, 3000)) return;
  int firstSpace = line.indexOf(' '), secondSpace = line.indexOf(' ', firstSpace + 1);
  if (firstSpace < 0 || secondSpace < 0) { reply(client, 400, "Bad request"); return; }
  String method = line.substring(0, firstSpace);
  String path = line.substring(firstSpace + 1, secondSpace);
  size_t length = 0;
  bool hasLength = false, hasManifest = false, headersEnded = false;
  String manifestHex;
  for (int i = 0; i < 32; i++) {
    if (!readLine(client, line, 3000)) { reply(client, 400, "Bad headers"); return; }
    if (line.isEmpty()) { headersEnded = true; break; }
    int colon = line.indexOf(':');
    if (colon < 0) { reply(client, 400, "Malformed header"); return; }
    String name = line.substring(0, colon);
    name.toLowerCase();
    String value = line.substring(colon + 1);
    value.trim();
    if (name == "content-length") {
      if (hasLength || value.isEmpty() || value.length() > 9) { reply(client, 400, "Bad length"); return; }
      for (unsigned j = 0; j < value.length(); j++) {
        if (value[j] < '0' || value[j] > '9') { reply(client, 400, "Bad length"); return; }
      }
      length = (size_t)value.toInt();
      hasLength = true;
    } else if (name == "x-ota-manifest") {
      if (hasManifest) { reply(client, 400, "Duplicate manifest"); return; }
      manifestHex = value;
      hasManifest = true;
    }
  }
  if (!headersEnded) { reply(client, 400, "Too many headers"); return; }

  if (method == "GET" && path == "/status") {
    String state = "role=" + String(NODE_ROLE) + " version=" + String(FW_VERSION);
    state += " noise=" + String(noiseReady ? 1 : 0) +
             " tls=" + String(tlsReady ? 1 : 0) +
             " edge1=" + edge1.toString() + " edge2=" + edge2.toString();
    state += " edge1_secure=" + queryEdgeStatus(1, edge1);
    state += " edge2_secure=" + queryEdgeStatus(2, edge2);
    esp_ota_img_states_t imageState;
    if (esp_ota_get_state_partition(esp_ota_get_running_partition(), &imageState) == ESP_OK)
      state += " ota=" + String(otaStateName(imageState));
    else state += " ota=unknown";
    const esp_partition_t *lastBad = esp_ota_get_last_invalid_partition();
    state += " last_invalid=" + String(lastBad ? lastBad->label : "none");
    state += " heap=" + String(ESP.getFreeHeap()) + " minheap=" + String(ESP.getMinFreeHeap());
    state += " stack_margin=" + String(uxTaskGetStackHighWaterMark(nullptr));
    reply(client, 200, state);
    return;
  }
  // This controller build permits plaintext *status only*. No HTTP update fallback.
  // TLS uploads are handled on port 443 by ESP-IDF's HTTPS server below.
  reply(client, 403, "Firmware uploads require verified HTTPS port 443");
  return;

}

static esp_err_t tlsReply(httpd_req_t *req, const char *status, const char *message) {
  httpd_resp_set_status(req, status);
  httpd_resp_set_type(req, "text/plain");
  return httpd_resp_sendstr(req, message);
}

// Read and relay small chunks. The TLS library terminates the Mac hop;
// NoiseLink immediately re-encrypts a separately authenticated edge hop.
static bool tlsCopy(httpd_req_t *req, NoiseLink *edge, size_t length, bool flash,
                    crypto_hash_sha256_state *hash = nullptr) {
  uint8_t chunk[1024];
  size_t left = length;
  while (left) {
    int n = httpd_req_recv(req, (char *)chunk, min(left, sizeof(chunk)));
    if (n <= 0) return false; // timeout/close: never activate partial image
    if (flash && Update.write(chunk, n) != (size_t)n) return false;
    if (hash && crypto_hash_sha256_update(hash, chunk, n) != 0) return false;
    if (edge) {
      uint8_t record[1 + sizeof(chunk)];
      record[0] = 0x11;
      memcpy(record + 1, chunk, n);
      if (!edge->send(record, n + 1)) return false;
    }
    left -= n;
  }
  return true;
}

static esp_err_t tlsUpdate(httpd_req_t *req) {
  size_t length = req->content_len;
  if (!length || length > MAX_IMAGE) return tlsReply(req, "400 Bad Request", "Bad image length");
  if (httpd_req_get_hdr_value_len(req, "X-OTA-Manifest") != MANIFEST_SIZE * 2)
    return tlsReply(req, "403 Forbidden", "Missing or malformed signed manifest");
  char manifestHex[MANIFEST_SIZE * 2 + 1];
  if (httpd_req_get_hdr_value_str(req, "X-OTA-Manifest", manifestHex, sizeof(manifestHex)) != ESP_OK)
    return tlsReply(req, "403 Forbidden", "Missing or malformed signed manifest");
  uint8_t manifest[MANIFEST_SIZE];
  if (!decodeManifest(String(manifestHex), manifest))
    return tlsReply(req, "403 Forbidden", "Malformed signed manifest");
  bool forEdge = strcmp(req->uri, "/edge1") == 0 || strcmp(req->uri, "/edge2") == 0;
  uint8_t targetRole = strcmp(req->uri, "/edge1") == 0 ? 1 : 2;
  String reason;
  if (!verifySignedMetadata(manifest, forEdge ? targetRole : NODE_ROLE,
                            length, forEdge ? 0 : FW_VERSION, reason))
    return tlsReply(req, "403 Forbidden", reason.c_str());

  if (forEdge) {
    if (!noiseReady) return tlsReply(req, "503 Service Unavailable", "Noise unavailable");
    IPAddress dest = targetRole == 1 ? edge1 : edge2;
    if (dest == IPAddress(0, 0, 0, 0))
      return tlsReply(req, "503 Service Unavailable", "Edge unregistered");
    WiFiClient downstream;
    if (!downstream.connect(dest, 8080, 3000))
      return tlsReply(req, "503 Service Unavailable", "Edge offline");
    NoiseLink secure;
    if (!secure.begin(downstream, targetRole, true))
      return tlsReply(req, "503 Service Unavailable", "Edge Noise authentication failed");
    uint8_t beginRecord[1 + MANIFEST_SIZE];
    beginRecord[0] = 0x10;
    memcpy(beginRecord + 1, manifest, MANIFEST_SIZE);
    if (!secure.send(beginRecord, sizeof(beginRecord)) || !tlsCopy(req, &secure, length, false))
      return tlsReply(req, "500 Internal Server Error", "Encrypted forwarding interrupted");
    uint8_t finish = 0x12, result[NoiseLink::MAX_PLAIN];
    size_t resultSize = 0;
    if (!secure.send(&finish, 1) || !secure.receive(result, resultSize) ||
        resultSize != 2 || result[0] != 0x13 || result[1] != 0)
      return tlsReply(req, "500 Internal Server Error", "Edge did not accept image");
    return tlsReply(req, "200 OK", "Authenticated edge accepted signed image; rebooting");
  }

  if (!Update.begin(length, U_FLASH))
    return tlsReply(req, "500 Internal Server Error", "Could not start OTA");
  crypto_hash_sha256_state hash;
  uint8_t digest[crypto_hash_sha256_BYTES];
  bool good = crypto_hash_sha256_init(&hash) == 0 &&
              tlsCopy(req, nullptr, length, true, &hash) &&
              crypto_hash_sha256_final(&hash, digest) == 0 &&
              sodium_memcmp(digest, manifest + 13, sizeof(digest)) == 0 &&
              Update.end(false);
  if (!good) {
    Update.abort();
    return tlsReply(req, "403 Forbidden", "Image incomplete, corrupt or rejected");
  }
  esp_err_t sent = tlsReply(req, "200 OK", "Signed image accepted; rebooting");
  delay(350);
  ESP.restart();
  return sent;
}

static bool startHttpsServer() {
  Preferences store;
  if (!store.begin("ota-tls", true)) return false;
  tlsCert = store.getString("cert", "");
  tlsKey = store.getString("key", "");
  store.end();
  if (tlsCert.length() < 200 || tlsCert.length() > 3000 ||
      tlsKey.length() < 200 || tlsKey.length() > 3000 ||
      !tlsCert.startsWith("-----BEGIN CERTIFICATE-----") ||
      !tlsKey.startsWith("-----BEGIN PRIVATE KEY-----")) {
    tlsCert = ""; tlsKey = "";
    Serial.println("TLS NVS certificate/key missing; NO firmware upload listener");
    return false;
  }
  httpd_ssl_config_t conf = HTTPD_SSL_CONFIG_DEFAULT();
  conf.servercert = (const uint8_t *)tlsCert.c_str();
  conf.servercert_len = tlsCert.length() + 1;
  conf.prvtkey_pem = (const uint8_t *)tlsKey.c_str();
  conf.prvtkey_len = tlsKey.length() + 1;
  conf.httpd.stack_size = 16384;
  conf.httpd.max_open_sockets = 2; // bound concurrent TLS RAM consumption
  if (httpd_ssl_start(&tlsServer, &conf) != ESP_OK) return false;
  httpd_uri_t update = { .uri = "/update", .method = HTTP_POST, .handler = tlsUpdate,
                         .user_ctx = nullptr, .is_websocket = false, .handle_ws_control_frames = false,
                         .supported_subprotocol = nullptr };
  if (httpd_register_uri_handler(tlsServer, &update) != ESP_OK) {
    httpd_ssl_stop(tlsServer); tlsServer = nullptr; return false;
  }
  update.uri = "/edge1";
  if (httpd_register_uri_handler(tlsServer, &update) != ESP_OK) {
    httpd_ssl_stop(tlsServer); tlsServer = nullptr; return false;
  }
  update.uri = "/edge2";
  if (httpd_register_uri_handler(tlsServer, &update) != ESP_OK) {
    httpd_ssl_stop(tlsServer); tlsServer = nullptr; return false;
  }
  Serial.printf("HTTPS upload listener: 443; heap=%u\n", (unsigned)ESP.getFreeHeap());
  return true;
}

static void handlePeer(WiFiClient &client) {
  client.setTimeout(3000);
  uint8_t role = NODE_ROLE;
  if (NODE_ROLE == 0) {
    // Untrusted registration hint is ONLY used to select the expected pinned key.
    if (client.readBytes(&role, 1) != 1 || (role != 1 && role != 2)) return;
  }
  NoiseLink secure;
  if (!secure.begin(client, role, false)) return;
  uint8_t record[NoiseLink::MAX_PLAIN];
  size_t size = 0;
  if (!secure.receive(record, size)) return;
  if (NODE_ROLE == 0) {
    if (size != 1 || record[0] != 0x01) return; // REGISTER
    const uint8_t ok = 0x02; // REGISTER_OK
    if (!secure.send(&ok, 1)) return;
    if (role == 1) edge1 = client.remoteIP();
    else edge2 = client.remoteIP();
    Serial.printf("Authenticated edge %d from %s\n", role, client.remoteIP().toString().c_str());
    return;
  }
  if (record[0] == 0x20 && size == 1) { // STATUS_REQUEST
    uint8_t replyData[15] = {0x21, NODE_ROLE, 0, 0, 0, 0, 255, 0, 0, 0, 0, 0, 0, 0, 0};
    uint32_t version = FW_VERSION;
    for (int i = 0; i < 4; ++i) replyData[2 + i] = (uint8_t)(version >> (8 * i));
    esp_ota_img_states_t state;
    if (esp_ota_get_state_partition(esp_ota_get_running_partition(), &state) == ESP_OK)
      replyData[6] = (uint8_t)state;
    uint32_t minHeap = ESP.getMinFreeHeap(); // includes this live Noise handshake
    uint32_t stackMargin = uxTaskGetStackHighWaterMark(nullptr);
    for (int i = 0; i < 4; ++i) {
      replyData[7 + i] = (uint8_t)(minHeap >> (8 * i));
      replyData[11 + i] = (uint8_t)(stackMargin >> (8 * i));
    }
    secure.send(replyData, sizeof(replyData));
    return;
  }
  if (record[0] != 0x10 || size != 1 + MANIFEST_SIZE) return; // UPDATE_BEGIN
  // Keep authenticated signed metadata intact while record[] is reused for chunks.
  uint8_t manifest[MANIFEST_SIZE];
  memcpy(manifest, record + 1, sizeof(manifest));
  size_t expected = (size_t)le32(manifest + 9);
  String reason;
  if (!expected || expected > MAX_IMAGE ||
      !verifySignedMetadata(manifest, NODE_ROLE, expected, FW_VERSION, reason)) {
    uint8_t reject[] = {0x13, 1};
    secure.send(reject, sizeof(reject));
    return;
  }
  if (!Update.begin(expected, U_FLASH)) {
    uint8_t reject[] = {0x13, 1};
    secure.send(reject, sizeof(reject));
    return;
  }
  crypto_hash_sha256_state hash;
  bool good = crypto_hash_sha256_init(&hash) == 0;
  size_t received = 0;
  bool committed = false;
  while (good && secure.receive(record, size)) {
    if (record[0] == 0x11 && size > 1 && size <= 1025) { // UPDATE_DATA
      size_t n = size - 1;
      if (n > expected - received || Update.write(record + 1, n) != n ||
          crypto_hash_sha256_update(&hash, record + 1, n) != 0) { good = false; break; }
      received += n;
    } else if (record[0] == 0x12 && size == 1 && received == expected) {
      unsigned char digest[crypto_hash_sha256_BYTES];
      good = crypto_hash_sha256_final(&hash, digest) == 0 &&
             sodium_memcmp(digest, manifest + 13, sizeof(digest)) == 0 &&
             Update.end(false);
      committed = good;
      break;
    } else { good = false; break; }
  }
  if (!committed) Update.abort(); // includes disconnect, AEAD error, hash mismatch
  uint8_t result[] = {0x13, (uint8_t)(committed ? 0 : 1)};
  secure.send(result, sizeof(result));
  if (committed) {
    Serial.println("Signed encrypted update accepted; rebooting");
    delay(350);
    ESP.restart();
  }
}

void setup() {
  Serial.begin(115200);
  cryptoReady = sodium_init() >= 0;
  bool provisioned = cryptoReady;
#ifdef NOISE_USB_BOOTSTRAP
  if (provisioned) provisioned = provisionBootIdentity();
#endif
  noiseReady = provisioned && initializeNoiseIdentity() &&
               noise_init() == NOISE_ERROR_NONE;
  if (!noiseReady) Serial.println("ERROR: NVS identity, pins or crypto unavailable; peer traffic rejected");
  delay(300);
  Serial.printf("Boot: role=%d version=%d flash=%u\n", NODE_ROLE, FW_VERSION, ESP.getFlashChipSize());
  bool networkReady = false;
  if (NODE_ROLE == 0) {
    WiFi.mode(WIFI_AP);
    bool started = WiFi.softAP(AP_NAME, AP_PASSWORD);
    networkReady = started && WiFi.softAPIP() == gateway;
    if (!networkReady) Serial.println("ERROR: AP did not start correctly");
    Serial.print("Controller address: "); Serial.println(WiFi.softAPIP());
  } else {
    WiFi.mode(WIFI_STA);
    WiFi.begin(AP_NAME, AP_PASSWORD);
    Serial.printf("Edge %d joining controller", NODE_ROLE);
    unsigned long start = millis();
    while (WiFi.status() != WL_CONNECTED && millis() - start < 10000) {
      delay(500);
      Serial.print('.');
    }
    networkReady = WiFi.status() == WL_CONNECTED;
    Serial.print("\nEdge address: "); Serial.println(WiFi.localIP());
  }
  if (NODE_ROLE == 0) {
    webServer.begin(); // /status GET only; firmware POSTs are always rejected.
#ifdef TLS_USB_BOOTSTRAP
    bool provisionedTls = provisionHttpsIdentity();
#else
    bool provisionedTls = true;
#endif
    tlsReady = networkReady && provisionedTls && startHttpsServer();
    networkReady = networkReady && tlsReady; // never confirm OTA without HTTPS.
  }
  peerServer.begin();
  Serial.printf("HTTP controller=%d, Noise peer=%d (network ready: %s)\n",
                NODE_ROLE == 0 ? 80 : 0, NODE_ROLE == 0 ? 8081 : 8080,
                networkReady ? "yes" : "no");

  const esp_partition_t *running = esp_ota_get_running_partition();
  esp_ota_img_states_t otaState;
  if (esp_ota_get_state_partition(running, &otaState) == ESP_OK &&
      otaState == ESP_OTA_IMG_PENDING_VERIFY) {
    // Controller: AP and crypto startup. Edge: ALSO require a real authenticated
    // registration to the pinned controller before confirming the new OTA slot.
    bool passed = cryptoReady && noiseReady && networkReady && !FORCE_SELF_TEST_FAILURE;
    if (passed && NODE_ROLE != 0) {
      pendingEdgeVerification = true;
      edgeVerificationStarted = millis();
      Serial.println("First-boot edge self-test waiting for authenticated controller registration");
    } else if (passed) {
      Serial.println("First-boot controller self-test passed; confirming OTA image");
      if (esp_ota_mark_app_valid_cancel_rollback() != ESP_OK)
        Serial.println("ERROR: could not confirm new OTA image");
    } else {
      Serial.println("First-boot self-test FAILED; reverting to previous OTA slot");
      esp_err_t err = esp_ota_mark_app_invalid_rollback_and_reboot();
      Serial.printf("ERROR: rollback failed: %d (USB recovery may be needed)\n", (int)err);
    }
  }
}

void loop() {
  if (NODE_ROLE == 0) {
    WiFiClient request = webServer.available();
    if (request) { handle(request); request.stop(); }
  }
  WiFiClient peer = peerServer.available();
  if (peer) { if (noiseReady) handlePeer(peer); peer.stop(); }
  if (NODE_ROLE != 0) {
    if (WiFi.status() != WL_CONNECTED) { WiFi.reconnect(); delay(500); }
    else if (noiseReady && millis() - lastRegister > 5000) {
      lastRegister = millis();
      WiFiClient registration;
      if (registration.connect(gateway, 8081, 1000) &&
          registration.write((uint8_t)NODE_ROLE) == 1) {
        NoiseLink secure;
        uint8_t command = 0x01, response[NoiseLink::MAX_PLAIN];
        size_t size = 0;
        if (secure.begin(registration, NODE_ROLE, true) &&
            secure.send(&command, 1) && secure.receive(response, size) &&
            size == 1 && response[0] == 0x02) {
          // A first-boot edge is not confirmed until its controller pin works.
          if (pendingEdgeVerification) {
            if (esp_ota_mark_app_valid_cancel_rollback() == ESP_OK) {
              pendingEdgeVerification = false;
              Serial.println("Authenticated registration passed; OTA image confirmed");
            } else Serial.println("ERROR: could not confirm edge OTA image");
          }
        }
      }
      registration.stop();
    }
  }
  if (pendingEdgeVerification && millis() - edgeVerificationStarted > 30000) {
    pendingEdgeVerification = false;
    Serial.println("No authenticated controller within 30s; reverting OTA image");
    esp_err_t err = esp_ota_mark_app_invalid_rollback_and_reboot();
    Serial.printf("ERROR: edge rollback failed: %d (USB recovery may be needed)\n", (int)err);
  }
  delay(2);
}
