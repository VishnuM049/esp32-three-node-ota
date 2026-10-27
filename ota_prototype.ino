// Three-node OTA transport prototype. NOT SECURE: no image signature check yet.
// Compile with -DNODE_ROLE=0 (controller), 1 (edge 1), or 2 (edge 2).
// Compile with -DFW_VERSION=1, 2, ... to see updates happen.
#include <Arduino.h>
#include <WiFi.h>
#include <Update.h>

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
WiFiServer server(port);

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
static bool copyBytes(WiFiClient &from, WiFiClient *to, size_t count, bool flash) {
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
  bool hasLength = false;
  for (int i = 0; i < 32; i++) {
    if (!readLine(client, line, 3000)) { reply(client, 400, "Bad headers"); return; }
    if (line.isEmpty()) break;
    if (line.startsWith("Content-Length:") || line.startsWith("content-length:")) {
      String value = line.substring(line.indexOf(':') + 1);
      value.trim();
      if (value.isEmpty() || value.length() > 9) { reply(client, 400, "Bad length"); return; }
      for (unsigned j = 0; j < value.length(); j++) {
        if (value[j] < '0' || value[j] > '9') { reply(client, 400, "Bad length"); return; }
      }
      length = (size_t)value.toInt();
      hasLength = true;
    }
  }

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
    reply(client, 400, "POST /update (or /edge1, /edge2 on controller) with Content-Length and firmware .bin");
    return;
  }

  if (NODE_ROLE == 0 && (path == "/edge1" || path == "/edge2")) {
    IPAddress dest = path == "/edge1" ? edge1 : edge2;
    if (dest == IPAddress(0, 0, 0, 0)) { reply(client, 503, "Edge not registered yet"); return; }
    WiFiClient downstream;
    if (!downstream.connect(dest, 8080, 3000)) { reply(client, 503, "Edge offline"); return; }
    downstream.printf("POST /update HTTP/1.1\r\nHost: edge\r\nContent-Type: application/octet-stream\r\nContent-Length: %u\r\nConnection: close\r\n\r\n", (unsigned)length);
    Serial.printf("Forwarding %u bytes to %s\n", (unsigned)length, dest.toString().c_str());
    if (!copyBytes(client, &downstream, length, false)) { downstream.stop(); reply(client, 500, "Forwarding failed"); return; }
    // The edge responds only after it has written and checked the image.
    if (!readLine(downstream, line, IDLE_TIMEOUT_MS)) { reply(client, 500, "No edge response"); return; }
    if (line.indexOf(" 200 ") < 0) { reply(client, 500, "Edge rejected image: " + line); return; }
    reply(client, 200, "Edge accepted image; rebooting");
    return;
  }
  if (path != "/update") { reply(client, 404, "Unknown path"); return; }

  Serial.printf("Receiving %u bytes into OTA slot\n", (unsigned)length);
  if (!Update.begin(length, U_FLASH)) {
    reply(client, 500, "Could not start OTA; check partition layout"); return;
  }
  if (!copyBytes(client, nullptr, length, true) || !Update.end(true)) {
    Serial.printf("OTA error: %s\n", Update.errorString());
    Update.abort();
    reply(client, 500, "OTA write or image validation failed");
    return;
  }
  reply(client, 200, "Firmware received; rebooting");
  Serial.println("OTA complete. Rebooting...");
  delay(350);
  ESP.restart();
}

void setup() {
  Serial.begin(115200);
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
