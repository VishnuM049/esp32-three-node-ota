// USB-BOOTSTRAP-ONLY. This translation unit contains the device's static
// X25519 PRIVATE key. Never include it or BootstrapPrivate.h in OTA builds.
#include <Arduino.h>
#include <Preferences.h>
#include <sodium.h>
#include "BootstrapPrivate.h" // ignored secret header, USB build ONLY

#ifndef NODE_ROLE
#error NODE_ROLE must match the provisioned local identity
#endif
static_assert(NOISE_LOCAL_ROLE == NODE_ROLE, "Wrong USB bootstrap secret for role");

bool provisionBootIdentity() {
  Preferences store;
  if (!store.begin("ota-link", false)) return false;
  size_t len = store.getBytesLength("identity");
  bool okay = false;
  if (len == sizeof(NOISE_LOCAL_PRIVATE)) {
    uint8_t existing[sizeof(NOISE_LOCAL_PRIVATE)];
    okay = store.getBytes("identity", existing, sizeof(existing)) == sizeof(existing) &&
           sodium_memcmp(existing, NOISE_LOCAL_PRIVATE, sizeof(existing)) == 0;
    sodium_memzero(existing, sizeof(existing));
    // Never silently rotate a mismatched identity; use an explicit USB recovery plan.
  } else if (len == 0) {
    okay = store.putBytes("identity", NOISE_LOCAL_PRIVATE, sizeof(NOISE_LOCAL_PRIVATE)) ==
           sizeof(NOISE_LOCAL_PRIVATE);
  }
  store.end();
  return okay;
}
