#include "NoiseLink.h"
#include "IdentityStore.h"
#include "LinkPublicPins.h" // Public pins ONLY. Static private key is stored in NVS.
#include <string.h>

#ifndef NODE_ROLE
#error NODE_ROLE must be defined for each role-specific build.
#endif
static_assert(NODE_ROLE == NOISE_LOCAL_ROLE, "Wrong X25519 identity for this firmware role");

NoiseLink::~NoiseLink() { close(); }

void NoiseLink::close() {
  ready_ = false;
  if (send_) { noise_cipherstate_free(send_); send_ = nullptr; }
  if (receive_) { noise_cipherstate_free(receive_); receive_ = nullptr; }
  if (client_) { client_->stop(); client_ = nullptr; }
}

bool NoiseLink::readExact(uint8_t *out, size_t len) {
  const unsigned long start = millis();
  size_t done = 0;
  while (done < len && millis() - start < 12000) {
    int available = client_->available();
    if (available <= 0) { if (!client_->connected()) break; delay(2); continue; }
    int n = client_->read(out + done, min(len - done, (size_t)available));
    if (n > 0) done += (size_t)n;
    else delay(2);
  }
  return done == len;
}

bool NoiseLink::writeExact(const uint8_t *in, size_t len) {
  const unsigned long start = millis();
  size_t done = 0;
  while (done < len && millis() - start < 12000) {
    int n = client_->write(in + done, len - done);
    if (n > 0) done += (size_t)n;
    else if (!client_->connected()) break;
    else delay(2);
  }
  return done == len;
}

bool NoiseLink::readFrame(uint8_t *out, size_t &len, size_t max) {
  uint8_t prefix[2];
  if (!readExact(prefix, 2)) return false;
  len = ((size_t)prefix[0] << 8) | prefix[1];
  return len > 0 && len <= max && readExact(out, len);
}

bool NoiseLink::writeFrame(const uint8_t *data, size_t len, size_t max) {
  if (len == 0 || len > max || len > MAX_FRAME) return false;
  // Prefix and ciphertext in ONE write: tiny separate TCP writes can trigger
  // Nagle/delayed-ACK stalls on every 1 KB OTA record.
  uint8_t frame[2 + MAX_FRAME];
  frame[0] = (uint8_t)(len >> 8);
  frame[1] = (uint8_t)len;
  memcpy(frame + 2, data, len);
  return writeExact(frame, len + 2);
}

bool NoiseLink::begin(WiFiClient &client, uint8_t edgeRole, bool initiator) {
  if ((edgeRole != 1 && edgeRole != 2) || client_) return false;
#if NODE_ROLE != 0
  if (edgeRole != NODE_ROLE) return false;
#endif
  const uint8_t *localPrivate = localNoisePrivate();
  if (!localPrivate) return false; // no identity = NO encrypted connection
  client_ = &client;
  const uint8_t *peer = nullptr;
#if NODE_ROLE == 0
  peer = edgeRole == 1 ? NOISE_PINNED_EDGE1 : NOISE_PINNED_EDGE2;
#else
  peer = NOISE_PINNED_CONTROLLER;
#endif
  const char *prologue = edgeRole == 1 ? "ESP32-OTA-LINK-v1/edge1" : "ESP32-OTA-LINK-v1/edge2";
  NoiseHandshakeState *hs = nullptr;
  int err = noise_handshakestate_new_by_name(&hs, "Noise_KK_25519_ChaChaPoly_SHA256",
                 initiator ? NOISE_ROLE_INITIATOR : NOISE_ROLE_RESPONDER);
  if (err != NOISE_ERROR_NONE || !hs) {
    if (hs) noise_handshakestate_free(hs);
    close();
    return false;
  }
  bool ok = noise_handshakestate_set_prologue(hs, prologue, strlen(prologue)) == NOISE_ERROR_NONE &&
    noise_dhstate_set_keypair_private(noise_handshakestate_get_local_keypair_dh(hs),
                                     localPrivate, 32) == NOISE_ERROR_NONE &&
    noise_dhstate_set_public_key(noise_handshakestate_get_remote_public_key_dh(hs),
                                 peer, 32) == NOISE_ERROR_NONE &&
    noise_handshakestate_start(hs) == NOISE_ERROR_NONE;
  uint8_t packet[512], empty = 0, payload[1];
  NoiseBuffer message, data;
  for (int step = 0; ok && step < 2; ++step) {
    bool writing = (step == 0) == initiator;
    if (writing) {
      noise_buffer_set_output(message, packet, sizeof(packet));
      noise_buffer_set_input(data, &empty, 0);
      ok = noise_handshakestate_write_message(hs, &message, &data) == NOISE_ERROR_NONE &&
           writeFrame(packet, message.size, sizeof(packet));
    } else {
      size_t length = 0;
      ok = readFrame(packet, length, sizeof(packet));
      if (ok) {
        noise_buffer_set_input(message, packet, length);
        noise_buffer_set_output(data, payload, sizeof(payload));
        ok = noise_handshakestate_read_message(hs, &message, &data) == NOISE_ERROR_NONE &&
             data.size == 0; // NO handshake application payloads
      }
    }
  }
  if (ok) ok = noise_handshakestate_split(hs, &send_, &receive_) == NOISE_ERROR_NONE &&
               send_ && receive_;
  noise_handshakestate_free(hs);
  if (!ok) { close(); return false; }
  ready_ = true;
  return true;
}

bool NoiseLink::send(const uint8_t *plain, size_t len) {
  if (!ready_ || !plain || !len || len > MAX_PLAIN) { close(); return false; }
  uint8_t record[MAX_FRAME];
  memcpy(record, plain, len);
  NoiseBuffer buffer;
  noise_buffer_set_inout(buffer, record, len, sizeof(record));
  if (noise_cipherstate_encrypt(send_, &buffer) != NOISE_ERROR_NONE ||
      !writeFrame(record, buffer.size, sizeof(record))) { close(); return false; }
  return true;
}

bool NoiseLink::receive(uint8_t *plain, size_t &len) {
  len = 0;
  if (!ready_ || !plain) { close(); return false; }
  uint8_t record[MAX_FRAME];
  size_t frameLen = 0;
  if (!readFrame(record, frameLen, sizeof(record)) || frameLen < 17) { close(); return false; }
  NoiseBuffer buffer;
  noise_buffer_set_inout(buffer, record, frameLen, sizeof(record));
  if (noise_cipherstate_decrypt(receive_, &buffer) != NOISE_ERROR_NONE ||
      buffer.size == 0 || buffer.size > MAX_PLAIN) { close(); return false; }
  memcpy(plain, record, buffer.size);
  len = buffer.size;
  return true;
}
