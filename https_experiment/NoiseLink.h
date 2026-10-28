#pragma once
#include <Arduino.h>
#include <WiFi.h>
#include <noise/protocol.h>
#include <stddef.h>
#include <stdint.h>

// Noise-C owns ephemeral keys, protocol transcript, AEAD and directional nonces.
// We only add bounded TCP framing and pinned, role-specific device identities.
class NoiseLink {
public:
  static constexpr size_t MAX_PLAIN = 1025; // command byte + <=1024 data
  static constexpr size_t MAX_FRAME = MAX_PLAIN + 16; // ChaChaPoly tag
  NoiseLink() = default;
  ~NoiseLink();
  NoiseLink(const NoiseLink &) = delete;
  NoiseLink &operator=(const NoiseLink &) = delete;
  bool begin(WiFiClient &client, uint8_t edgeRole, bool initiator);
  bool send(const uint8_t *plain, size_t len);
  bool receive(uint8_t *plain, size_t &len); // caller supplies MAX_PLAIN bytes
  bool live() const { return ready_; }
private:
  WiFiClient *client_ = nullptr;
  NoiseCipherState *send_ = nullptr;
  NoiseCipherState *receive_ = nullptr;
  bool ready_ = false;
  bool readExact(uint8_t *out, size_t len);
  bool writeExact(const uint8_t *in, size_t len);
  bool readFrame(uint8_t *out, size_t &len, size_t max);
  bool writeFrame(const uint8_t *data, size_t len, size_t max);
  void close();
};
