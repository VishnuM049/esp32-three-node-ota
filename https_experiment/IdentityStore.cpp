#include "IdentityStore.h"
#include "LinkPublicPins.h" // Public role pins only; safe in signed OTA images.
#include <Preferences.h>
#include <sodium.h>

static uint8_t privateIdentity[32];
static bool identityReady = false;

bool initializeNoiseIdentity() {
  identityReady = false;
  sodium_memzero(privateIdentity, sizeof(privateIdentity));
  Preferences store;
  if (!store.begin("ota-link", true)) return false;
  bool loaded = store.getBytesLength("identity") == sizeof(privateIdentity) &&
                store.getBytes("identity", privateIdentity, sizeof(privateIdentity)) == sizeof(privateIdentity);
  store.end();
  if (!loaded) { sodium_memzero(privateIdentity, sizeof(privateIdentity)); return false; }
  uint8_t derived[32];
  bool valid = crypto_scalarmult_curve25519_base(derived, privateIdentity) == 0 &&
               sodium_memcmp(derived, NOISE_LOCAL_PUBLIC, sizeof(derived)) == 0;
  sodium_memzero(derived, sizeof(derived));
  if (!valid) { sodium_memzero(privateIdentity, sizeof(privateIdentity)); return false; }
  identityReady = true;
  return true;
}

const uint8_t *localNoisePrivate() {
  return identityReady ? privateIdentity : nullptr;
}
