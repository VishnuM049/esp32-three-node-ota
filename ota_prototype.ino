// Three-node OTA with application-level Ed25519 verification (no hardware Secure Boot).
// Compile with -DNODE_ROLE=0 (controller), 1 (edge 1), or 2 (edge 2).
// Compile with -DFW_VERSION=1, 2, ... to see updates happen.
#include <Arduino.h>
#include <WiFi.h>
#include <Update.h>
#include <sodium.h>
#include "TrustedPublicKey.h" // Public key only. Private signing key stays on laptop.

#ifndef NODE_ROLE
#define NODE_ROLE 0
#endif
#ifndef FW_VERSION
#define FW_VERSION 1
#endif
#if NODE_ROLE < 0 || NODE_ROLE > 2
#error NODE_ROLE must be 0, 1, or 2
#endif

static const char *AP_NAME = "OTA-CLASS-DEMO";
static const char *AP_PASSWORD = "demo-ota-1234"; // demonstration only, NOT a security boundary
static const IPAddress gateway(192, 168, 4, 1);
static IPAddress edge1(0, 0, 0, 0);
static IPAddress edge2(0, 0, 0, 0);
static unsigned long lastRegister = 0;
static const uint16_t port = NODE_ROLE == 0 ? 80 : 8080;
static const size_t MAX_IMAGE = 0x140000; // default 4MB partition table: 1.25MB OTA slots
static const unsigned long IDLE_TIMEOUT_MS = 12000;
static const size_t MANIFEST_SIZE = 109;
static const size_t SIGNED_HEADER_SIZE = 45;
static bool cryptoReady = false;
WiFiServer server(port);

static int hexDigit(char ch) {
  if (ch >= '0' && ch <= '9') return ch - '0';
  if (ch >= 'a' && ch <= 'f') return ch - 'a' + 10;
  return -1;
}

static bool decodeManifest(const String &hex, uint8_t out[MANIFEST_SIZE]) {
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

static bool verifySignedMetadata(const uint8_t manifest[MANIFEST_SIZE], uint8_t expectedRole,
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
static bool copyBytes(WiFiClient &from, WiFiClient *to, size_t count, bool flash,
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
      size_t written = 0;
      while (written < (size_t)n) {
        int w = to->write(buf + written, n - written);
        if (w > 0) { written += w; last = millis(); }
        else if (millis() - last > IDLE_TIMEOUT_MS) return false;
        else delay(2);
      }
    }
    remaining -= n;
  }
  return true;
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
    if (NODE_ROLE == 0) state += " edge1=" + edge1.toString() + " edge2=" + edge2.toString();
    reply(client, 200, state);
    return;
  }
  if (NODE_ROLE == 0 && method == "GET" && (path == "/register/1" || path == "/register/2")) {
    if (path == "/register/1") edge1 = client.remoteIP();
    else edge2 = client.remoteIP();
    Serial.printf("Registered %s from %s\n", path.c_str(), client.remoteIP().toString().c_str());
    reply(client, 200, "Registered " + path);
    return;
  }
  if (method != "POST" || !hasLength || !length || length > MAX_IMAGE) {
    reply(client, 400, "POST image with valid Content-Length required");
    return;
  }
  uint8_t manifest[MANIFEST_SIZE];
  if (!hasManifest || !decodeManifest(manifestHex, manifest)) {
    reply(client, 403, "Missing or malformed signed manifest");
    return;
  }
  String reason;
  if (NODE_ROLE == 0 && (path == "/edge1" || path == "/edge2")) {
    uint8_t targetRole = path == "/edge1" ? 1 : 2;
    if (!verifySignedMetadata(manifest, targetRole, length, 0, reason)) {
      reply(client, 403, reason); return;
    }
    IPAddress dest = targetRole == 1 ? edge1 : edge2;
    if (dest == IPAddress(0, 0, 0, 0)) { reply(client, 503, "Edge not registered yet"); return; }
    WiFiClient downstream;
    if (!downstream.connect(dest, 8080, 3000)) { reply(client, 503, "Edge offline"); return; }
    downstream.printf("POST /update HTTP/1.1\r\nHost: edge\r\nContent-Type: application/octet-stream\r\nContent-Length: %u\r\nX-OTA-Manifest: %s\r\nConnection: close\r\n\r\n", (unsigned)length, manifestHex.c_str());
    Serial.printf("Forwarding %u bytes to %s\n", (unsigned)length, dest.toString().c_str());
    if (!copyBytes(client, &downstream, length, false)) { downstream.stop(); reply(client, 500, "Forwarding failed"); return; }
    // The edge responds only after it has written and checked the image.
    if (!readLine(downstream, line, IDLE_TIMEOUT_MS)) { reply(client, 500, "No edge response"); return; }
    if (line.indexOf(" 200 ") < 0) { reply(client, 500, "Edge rejected image: " + line); return; }
    reply(client, 200, "Edge accepted image; rebooting");
    return;
  }
  if (path != "/update") { reply(client, 404, "Unknown path"); return; }
  if (!verifySignedMetadata(manifest, NODE_ROLE, length, FW_VERSION, reason)) {
    reply(client, 403, reason); return;
  }

  Serial.printf("Receiving signed v%u (%u bytes) into OTA slot\n", (unsigned)le32(manifest + 5), (unsigned)length);
  if (!Update.begin(length, U_FLASH)) {
    reply(client, 500, "Could not start OTA; check partition layout"); return;
  }
  crypto_hash_sha256_state hash;
  unsigned char receivedDigest[crypto_hash_sha256_BYTES];
  if (crypto_hash_sha256_init(&hash) != 0 ||
      !copyBytes(client, nullptr, length, true, &hash) ||
      crypto_hash_sha256_final(&hash, receivedDigest) != 0) {
    Update.abort();
    reply(client, 500, "OTA upload failed or incomplete");
    return;
  }
  if (sodium_memcmp(receivedDigest, manifest + 13, sizeof(receivedDigest)) != 0) {
    Update.abort();
    reply(client, 403, "Image SHA-256 does not match signed manifest");
    return;
  }
  // end() activates the partition. NEVER call it before signature + full hash checks.
  if (!Update.end(false)) {
    Serial.printf("OTA error: %s\n", Update.errorString());
    Update.abort();
    reply(client, 500, "OTA image validation failed");
    return;
  }
  reply(client, 200, "Signed image accepted; rebooting");
  Serial.println("OTA complete. Rebooting...");
  delay(350);
  ESP.restart();
}

void setup() {
  Serial.begin(115200);
  cryptoReady = sodium_init() >= 0;
  if (!cryptoReady) Serial.println("ERROR: libsodium unavailable; ALL updates will be rejected");
  delay(300);
  Serial.printf("Boot: role=%d version=%d flash=%u\n", NODE_ROLE, FW_VERSION, ESP.getFlashChipSize());
  if (NODE_ROLE == 0) {
    WiFi.mode(WIFI_AP);
    if (!WiFi.softAP(AP_NAME, AP_PASSWORD)) Serial.println("ERROR: AP did not start");
    Serial.print("Controller address: "); Serial.println(WiFi.softAPIP());
  } else {
    WiFi.mode(WIFI_STA);
    WiFi.begin(AP_NAME, AP_PASSWORD);
    Serial.printf("Edge %d joining controller", NODE_ROLE);
    while (WiFi.status() != WL_CONNECTED) { delay(500); Serial.print('.'); }
    Serial.print("\nEdge address: "); Serial.println(WiFi.localIP());
  }
  server.begin();
  Serial.printf("Listening on port %d\n", port);
}

void loop() {
  WiFiClient client = server.available();
  if (client) { handle(client); client.stop(); }
  if (NODE_ROLE != 0) {
    if (WiFi.status() != WL_CONNECTED) { WiFi.reconnect(); delay(500); }
    else if (millis() - lastRegister > 5000) {
      lastRegister = millis();
      WiFiClient registration;
      if (registration.connect(gateway, 80, 1000)) {
        registration.printf("GET /register/%d HTTP/1.1\r\nHost: controller\r\nConnection: close\r\n\r\n", NODE_ROLE);
        registration.flush();
        registration.stop();
      }
    }
  }
  delay(2);
}
