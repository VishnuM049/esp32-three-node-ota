/* Native, OFFLINE Noise-C KK negative tests. Test keys only; no real device secrets.
 * This tests the narrowed desktop C port, NOT ESP32 runtime or a network link.
 */
#include <noise/protocol.h>
#include <sodium.h>
#include <stdio.h>
#include <string.h>

#define REQUIRE(call) do { int result_ = (call); if (result_ != NOISE_ERROR_NONE) { \
    fprintf(stderr, "%s:%d: %s returned %d\n", __FILE__, __LINE__, #call, result_); return 1; \
} } while (0)
#define EXPECT(call, code) do { int result_ = (call); if (result_ != (code)) { \
    fprintf(stderr, "%s:%d: %s returned %d, expected %d\n", __FILE__, __LINE__, #call, result_, (code)); return 1; \
} } while (0)

static const uint8_t controller_private[32] = {
    0xe6,0x1e,0xf9,0x91,0x9c,0xde,0x45,0xdd,0x5f,0x82,0x16,0x64,0x04,0xbd,0x08,0xe3,
    0x8b,0xce,0xb5,0xdf,0xdf,0xde,0xd0,0xa3,0x4c,0x8d,0xf7,0xed,0x54,0x22,0x14,0xd1
};
static const uint8_t edge_private[32] = {
    0x4a,0x3a,0xcb,0xfd,0xb1,0x63,0xde,0xc6,0x51,0xdf,0xa3,0x19,0x4d,0xec,0xe6,0x76,
    0xd4,0x37,0x02,0x9c,0x62,0xa4,0x08,0xb4,0xc5,0xea,0x91,0x14,0x24,0x6e,0x48,0x93
};
static const uint8_t wrong_edge_private[32] = {
    0xbb,0xdb,0x4c,0xdb,0xd3,0x09,0xf1,0xa1,0xf2,0xe1,0x45,0x69,0x67,0xfe,0x28,0x8c,
    0xad,0xd6,0xf7,0x12,0xd6,0x5d,0xc7,0xb7,0x79,0x3d,0x5e,0x63,0xda,0x6b,0x37,0x5b
};

static int test_session(int wrong_pin, int wrong_prologue, int tamper_handshake)
{
    NoiseHandshakeState *controller = NULL, *edge = NULL;
    NoiseCipherState *ctx = NULL, *crx = NULL, *etx = NULL, *erx = NULL;
    uint8_t controller_pub[32], edge_pub[32], wrong_pub[32];
    uint8_t msg[128], empty[1] = {0}, plaintext[128], replay[128];
    NoiseBuffer packet, payload;
    size_t replay_len;
    crypto_scalarmult_curve25519_base(controller_pub, controller_private);
    crypto_scalarmult_curve25519_base(edge_pub, edge_private);
    crypto_scalarmult_curve25519_base(wrong_pub, wrong_edge_private);
    REQUIRE(noise_handshakestate_new_by_name(&controller,
        "Noise_KK_25519_ChaChaPoly_SHA256", NOISE_ROLE_INITIATOR));
    REQUIRE(noise_handshakestate_new_by_name(&edge,
        "Noise_KK_25519_ChaChaPoly_SHA256", NOISE_ROLE_RESPONDER));
    REQUIRE(noise_handshakestate_set_prologue(controller, "ota:edge1", 9));
    REQUIRE(noise_handshakestate_set_prologue(edge,
        wrong_prologue ? "ota:edge2" : "ota:edge1", 9));
    REQUIRE(noise_dhstate_set_keypair_private(
        noise_handshakestate_get_local_keypair_dh(controller), controller_private, 32));
    REQUIRE(noise_dhstate_set_keypair_private(
        noise_handshakestate_get_local_keypair_dh(edge), edge_private, 32));
    REQUIRE(noise_dhstate_set_public_key(
        noise_handshakestate_get_remote_public_key_dh(controller),
        wrong_pin ? wrong_pub : edge_pub, 32));
    REQUIRE(noise_dhstate_set_public_key(
        noise_handshakestate_get_remote_public_key_dh(edge), controller_pub, 32));
    REQUIRE(noise_handshakestate_start(controller));
    REQUIRE(noise_handshakestate_start(edge));
    noise_buffer_set_output(packet, msg, sizeof(msg));
    noise_buffer_set_input(payload, empty, 0);
    REQUIRE(noise_handshakestate_write_message(controller, &packet, &payload));
    if (tamper_handshake) msg[packet.size - 1] ^= 1;
    noise_buffer_set_output(payload, plaintext, sizeof(plaintext));
    if (wrong_pin || wrong_prologue || tamper_handshake) {
        EXPECT(noise_handshakestate_read_message(edge, &packet, &payload), NOISE_ERROR_MAC_FAILURE);
        puts(wrong_pin ? "PASS: wrong pinned edge key rejected" :
             wrong_prologue ? "PASS: wrong role prologue rejected" :
                              "PASS: tampered handshake rejected");
        noise_handshakestate_free(controller);
        noise_handshakestate_free(edge);
        return 0;
    }
    REQUIRE(noise_handshakestate_read_message(edge, &packet, &payload));
    noise_buffer_set_output(packet, msg, sizeof(msg));
    noise_buffer_set_input(payload, empty, 0);
    REQUIRE(noise_handshakestate_write_message(edge, &packet, &payload));
    noise_buffer_set_output(payload, plaintext, sizeof(plaintext));
    REQUIRE(noise_handshakestate_read_message(controller, &packet, &payload));
    REQUIRE(noise_handshakestate_split(controller, &ctx, &crx));
    REQUIRE(noise_handshakestate_split(edge, &etx, &erx));
    memcpy(msg, "ota", 3);
    noise_buffer_set_inout(packet, msg, 3, sizeof(msg));
    REQUIRE(noise_cipherstate_encrypt(ctx, &packet));
    replay_len = packet.size;
    memcpy(replay, msg, replay_len);
    REQUIRE(noise_cipherstate_decrypt(erx, &packet));
    if (packet.size != 3 || memcmp(msg, "ota", 3)) {
        fprintf(stderr, "Decrypted record did not match\n"); return 1;
    }
    noise_buffer_set_inout(packet, replay, replay_len, sizeof(replay));
    EXPECT(noise_cipherstate_decrypt(erx, &packet), NOISE_ERROR_MAC_FAILURE);
    puts("PASS: duplicate authenticated transport record rejected");
    memcpy(msg, "two", 3);
    noise_buffer_set_inout(packet, msg, 3, sizeof(msg));
    REQUIRE(noise_cipherstate_encrypt(ctx, &packet));
    msg[0] ^= 1;
    EXPECT(noise_cipherstate_decrypt(erx, &packet), NOISE_ERROR_MAC_FAILURE);
    puts("PASS: tampered authenticated transport record rejected");
    noise_cipherstate_free(ctx); noise_cipherstate_free(crx);
    noise_cipherstate_free(etx); noise_cipherstate_free(erx);
    noise_handshakestate_free(controller); noise_handshakestate_free(edge);
    return 0;
}

int main(void)
{
    if (sodium_init() < 0 || noise_init() != NOISE_ERROR_NONE) return 1;
    return test_session(1, 0, 0) || test_session(0, 1, 0) ||
           test_session(0, 0, 1) || test_session(0, 0, 0);
}
