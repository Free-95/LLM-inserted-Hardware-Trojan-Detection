# Generates vectors.hex. Requires: pip install cryptography --break-system-packages
import random
from cryptography.hazmat.primitives.ciphers import Cipher, algorithms, modes

def aes128_encrypt_block(key: bytes, pt: bytes) -> bytes:
    enc = Cipher(algorithms.AES(key), modes.ECB()).encryptor()
    return enc.update(pt) + enc.finalize()

vectors = []

def add_int(state_int, key_int):
    s_hex = "%032x" % (state_int & ((1 << 128) - 1))
    k_hex = "%032x" % (key_int & ((1 << 128) - 1))
    ct = aes128_encrypt_block(bytes.fromhex(k_hex), bytes.fromhex(s_hex))
    vectors.append((s_hex, k_hex, ct.hex()))

# Known-answer vectors (FIPS-197 / common NIST KATs)
add_int(0x3243f6a8885a308d313198a2e0370734, 0x2b7e151628aed2a6abf7158809cf4f3c)
add_int(0x00112233445566778899aabbccddeeff, 0x000102030405060708090a0b0c0d0e0f)
add_int(0x0, 0x0)
add_int(0x0, 0x1)
add_int(0x1, 0x0)

# Structural edge cases
add_int((1 << 128) - 1, (1 << 128) - 1)
add_int(0xaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa, 0x55555555555555555555555555555)
add_int(0x55555555555555555555555555555, 0xaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa)

base_key = 0x000102030405060708090a0b0c0d0e0f
base_pt = 0x00112233445566778899aabbccddeeff
for bit in [0, 1, 7, 8, 31, 32, 63, 64, 95, 96, 120, 127]:
    add_int(base_pt ^ (1 << bit), base_key)
for bit in [0, 1, 15, 16, 47, 48, 79, 80, 111, 112, 126, 127]:
    add_int(base_pt, base_key ^ (1 << bit))

rng = random.Random(0xA5A5_1234)
for _ in range(150):
    add_int(rng.getrandbits(128), rng.getrandbits(128))

with open("vectors.hex", "w") as f:
    for s, k, e in vectors:
        f.write(s + "\n")
        f.write(k + "\n")
        f.write(e + "\n")

print(f"wrote vectors.hex: {len(vectors)} vectors, {len(vectors)*3} lines")
