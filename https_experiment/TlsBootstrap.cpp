// USB FLASH ONLY. Includes local TLS private key; NEVER compile into an OTA image.
#include <Arduino.h>
#include <Preferences.h>
#include "TlsBootstrapPrivate.h" // generated under ignored noise_experiments/

bool provisionHttpsIdentity() {
  Preferences store;
  if (!store.begin("ota-tls", false)) return false;
  // Never overwrite an existing, possibly intentional TLS identity silently.
  String cert = store.getString("cert", "");
  String key = store.getString("key", "");
  bool okay = false;
  if (cert.isEmpty() && key.isEmpty()) {
    okay = store.putString("cert", TLS_BOOTSTRAP_CERT) == strlen(TLS_BOOTSTRAP_CERT) &&
           store.putString("key", TLS_BOOTSTRAP_KEY) == strlen(TLS_BOOTSTRAP_KEY);
  } else {
    okay = cert == TLS_BOOTSTRAP_CERT && key == TLS_BOOTSTRAP_KEY;
  }
  store.end();
  return okay;
}
