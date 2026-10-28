#pragma once
#include <stdint.h>

// Static X25519 secret lives in persistent NVS, provisioned over USB only.
// Signed OTA images must NOT contain this 32-byte private key.
bool initializeNoiseIdentity();
const uint8_t *localNoisePrivate(); // nullptr until successfully loaded and pin-checked
