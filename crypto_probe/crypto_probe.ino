// Compile-only probe: confirm the installed Arduino-ESP32 toolchain can link libsodium Ed25519.
// Invalid all-zero signature must be rejected. This sketch is NOT OTA firmware.
#include <Arduino.h>
#include <sodium.h>

void setup() {
  Serial.begin(115200);
  const unsigned char message[1] = {42};
  const unsigned char signature[crypto_sign_BYTES] = {0};
  const unsigned char publicKey[crypto_sign_PUBLICKEYBYTES] = {0};
  int init = sodium_init();
  int verified = crypto_sign_verify_detached(signature, message, sizeof(message), publicKey);
  Serial.printf("sodium_init=%d invalid_signature_rejected=%d\n", init, verified != 0);
}
void loop() { delay(1000); }
