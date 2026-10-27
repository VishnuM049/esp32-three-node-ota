// Compile-only probe: Ed25519, X25519 KX and ChaCha20-Poly1305 link in this toolchain.
// NOT an authenticated channel, Noise implementation, or OTA firmware. Never flash for a demo.
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
  unsigned char cpk[crypto_kx_PUBLICKEYBYTES], csk[crypto_kx_SECRETKEYBYTES];
  unsigned char spk[crypto_kx_PUBLICKEYBYTES], ssk[crypto_kx_SECRETKEYBYTES];
  unsigned char crx[crypto_kx_SESSIONKEYBYTES], ctx[crypto_kx_SESSIONKEYBYTES];
  unsigned char srx[crypto_kx_SESSIONKEYBYTES], stx[crypto_kx_SESSIONKEYBYTES];
  crypto_kx_keypair(cpk, csk);
  crypto_kx_keypair(spk, ssk);
  int kx = crypto_kx_client_session_keys(crx, ctx, cpk, csk, spk) |
           crypto_kx_server_session_keys(srx, stx, spk, ssk, cpk);
  unsigned char nonce[crypto_aead_chacha20poly1305_IETF_NPUBBYTES];
  randombytes_buf(nonce, sizeof(nonce));
  unsigned char plaintext[3] = {'o', 't', 'a'};
  unsigned char ciphertext[sizeof(plaintext) + crypto_aead_chacha20poly1305_IETF_ABYTES];
  unsigned char result[sizeof(plaintext)];
  unsigned long long clen = 0, mlen = 0;
  int enc = crypto_aead_chacha20poly1305_ietf_encrypt(ciphertext, &clen, plaintext, sizeof(plaintext),
                                                        nullptr, 0, nullptr, nonce, ctx);
  int dec = crypto_aead_chacha20poly1305_ietf_decrypt(result, &mlen, nullptr, ciphertext, clen,
                                                        nullptr, 0, nonce, srx);
  Serial.printf("kx=%d matching_direction_key=%d encrypt=%d decrypt=%d\n", kx,
                sodium_memcmp(ctx, srx, sizeof(ctx)) == 0, enc, dec);
}
void loop() { delay(1000); }
