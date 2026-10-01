import hashlib, struct

K = [
0x428a2f98,0x71374491,0xb5c0fbcf,0xe9b5dba5,0x3956c25b,0x59f111f1,0x923f82a4,0xab1c5ed5,
0xd807aa98,0x12835b01,0x243185be,0x550c7dc3,0x72be5d74,0x80deb1fe,0x9bdc06a7,0xc19bf174,
0xe49b69c1,0xefbe4786,0x0fc19dc6,0x240ca1cc,0x2de92c6f,0x4a7484aa,0x5cb0a9dc,0x76f988da,
0x983e5152,0xa831c66d,0xb00327c8,0xbf597fc7,0xc6e00bf3,0xd5a79147,0x06ca6351,0x14292967,
0x27b70a85,0x2e1b2138,0x4d2c6dfc,0x53380d13,0x650a7354,0x766a0abb,0x81c2c92e,0x92722c85,
0xa2bfe8a1,0xa81a664b,0xc24b8b70,0xc76c51a3,0xd192e819,0xd6990624,0xf40e3585,0x106aa070,
0x19a4c116,0x1e376c08,0x2748774c,0x34b0bcb5,0x391c0cb3,0x4ed8aa4a,0x5b9cca4f,0x682e6ff3,
0x748f82ee,0x78a5636f,0x84c87814,0x8cc70208,0x90befffa,0xa4506ceb,0xbef9a3f7,0xc67178f2,
]

SHA256_H0 = [0x6a09e667,0xbb67ae85,0x3c6ef372,0xa54ff53a,0x510e527f,0x9b05688c,0x1f83d9ab,0x5be0cd19]
SHA224_H0 = [0xc1059ed8,0x367cd507,0x3070dd17,0xf70e5939,0xffc00b31,0x68581511,0x64f98fa7,0xbefa4fa4]

MASK = 0xFFFFFFFF
def rotr(x, n): return ((x >> n) | (x << (32-n))) & MASK

def compress(H, block512_bytes):
    assert len(block512_bytes) == 64
    w = list(struct.unpack('>16I', block512_bytes))
    for t in range(16, 64):
        s0 = rotr(w[t-15],7) ^ rotr(w[t-15],18) ^ (w[t-15] >> 3)
        s1 = rotr(w[t-2],17) ^ rotr(w[t-2],19) ^ (w[t-2] >> 10)
        w.append((w[t-16] + s0 + w[t-7] + s1) & MASK)
    a,b,c,d,e,f,g,h = H
    for t in range(64):
        S1 = rotr(e,6) ^ rotr(e,11) ^ rotr(e,25)
        ch = (e & f) ^ ((~e & MASK) & g)
        t1 = (h + S1 + ch + K[t] + w[t]) & MASK
        S0 = rotr(a,2) ^ rotr(a,13) ^ rotr(a,22)
        maj = (a & b) ^ (a & c) ^ (b & c)
        t2 = (S0 + maj) & MASK
        h = g; g = f; f = e; e = (d + t1) & MASK
        d = c; c = b; b = a; a = (t1 + t2) & MASK
    return [(x+y) & MASK for x,y in zip(H, [a,b,c,d,e,f,g,h])]

def pad_message(msg: bytes):
    """Standard SHA-256/224 padding, split into 64-byte (512-bit) blocks."""
    ml = len(msg) * 8
    msg = msg + b'\x80'
    while len(msg) % 64 != 56:
        msg += b'\x00'
    msg += struct.pack('>Q', ml)
    return [msg[i:i+64] for i in range(0, len(msg), 64)]

def digest_all_blocks(msg: bytes, mode256=True):
    """Returns list of 256-bit (8-word) chaining values, one per block processed
    (i.e. the core's `digest` output after each init/next step)."""
    H = list(SHA256_H0 if mode256 else SHA224_H0)
    blocks = pad_message(msg)
    results = []
    for blk in blocks:
        H = compress(H, blk)
        results.append(''.join('%08x' % w for w in H))
    return blocks, results

# Sanity check against hashlib for SHA-256 mode
for msg in [b'', b'abc', b'a'*1000, b'The quick brown fox jumps over the lazy dog']:
    blocks, results = digest_all_blocks(msg, mode256=True)
    assert results[-1] == hashlib.sha256(msg).hexdigest(), (msg, results[-1], hashlib.sha256(msg).hexdigest())
print("SHA-256 compression reference verified against hashlib.sha256 -- OK")

# Sanity check SHA-224 against hashlib (truncated upper 224 bits must match)
for msg in [b'', b'abc', b'a'*1000]:
    blocks, results = digest_all_blocks(msg, mode256=False)
    full = results[-1]
    truncated_224 = full[:56]  # 224 bits = 56 hex chars
    assert truncated_224 == hashlib.sha224(msg).hexdigest(), (msg, truncated_224, hashlib.sha224(msg).hexdigest())
print("SHA-224 compression reference verified against hashlib.sha224 -- OK")

import random

def emit_vectors(path):
    """
    Emits one test-case per logical message, each test case as:
      <mode: 1=sha256 0=sha224>
      <num_blocks N>
      N lines of 128-hex-char (512-bit) block
      N lines of 64-hex-char (256-bit) expected chaining-value/digest, one per block
    """
    messages = []

    # Known NIST test vectors (cross-checked against the independent compressor above,
    # not copied blind -- these match the original testbench's TC1/TC2/issue_test vectors).
    messages.append((b'abc', True))
    messages.append((b'abcdbcdecdefdefgefghfghighijhijkijkljklmklmnlmnomnopnopq', True))
    long_msg = (b'In the beginning God created the heaven and the earth,'
                b' more and moreboom, it has been a universal consensus '
                b'that data is tis a new technology that integrates decentralization,'
                b'In the area of IoT (Internet of Things), more and moreboom,'
                b' it has been a universal consensus that data is tis a new tech'
                b'nology that integrates decentralization,In the area of IoT (Inter'
                b'net of Things), more and moreboom')
    # (kept close to the original 9-block issue_test message; exact bytes don't need to
    # match since we derive the correct padding+digest ourselves)
    messages.append((long_msg, True))

    # Edge cases
    messages.append((b'', True))              # empty message
    messages.append((b'', False))              # empty, SHA-224 mode
    messages.append((b'a', True))
    messages.append((b'a' * 55, True))         # exactly fills one block minus padding byte
    messages.append((b'a' * 56, True))         # forces a second block (no room for length field)
    messages.append((b'a' * 64, True))         # exactly one full block of data
    messages.append((b'a' * 119, True))        # fills most of a 2nd block
    messages.append((b'a' * 120, True))        # forces a 3rd block
    messages.append((b'\x00' * 64, True))
    messages.append((b'\xff' * 64, True))

    # SHA-224 mode coverage (the ORIGINAL testbench never exercised mode=0 at all)
    messages.append((b'abc', False))
    messages.append((b'abcdbcdecdefdefgefghfghighijhijkijkljklmklmnlmnomnopnopq', False))
    messages.append((b'a' * 200, False))

    # Deterministic random coverage: varying lengths 0..300 bytes, both modes
    rng = random.Random(0x5EC0_FEED)
    for _ in range(40):
        ln = rng.randint(0, 300)
        msg = bytes(rng.getrandbits(8) for _ in range(ln))
        messages.append((msg, True))
    for _ in range(20):
        ln = rng.randint(0, 300)
        msg = bytes(rng.getrandbits(8) for _ in range(ln))
        messages.append((msg, False))

    with open(path, 'w') as f:
        f.write(str(len(messages)) + '\n')
        for msg, mode256 in messages:
            blocks, results = digest_all_blocks(msg, mode256)
            f.write(('1' if mode256 else '0') + '\n')
            f.write(str(len(blocks)) + '\n')
            for b in blocks:
                f.write(b.hex() + '\n')
            for r in results:
                f.write(r + '\n')
    print(f"wrote {len(messages)} test cases to {path}")

if __name__ == "__main__":
    emit_vectors("sha_vectors.txt")

def emit_vectors_v2(meta_path, blocks_path, digests_path):
    """
    meta file: one line per test case: "<mode:1/0> <num_blocks>" (decimal, space-separated).
    blocks/digests files: flat, in order, one 512-bit / 256-bit hex word per line,
    total lines = sum(num_blocks) across all test cases, loadable directly via $readmemh.
    """
    rng = random.Random(0x5EC0_FEED)
    messages = []
    messages.append((b'abc', True))
    messages.append((b'abcdbcdecdefdefgefghfghighijhijkijkljklmklmnlmnomnopnopq', True))
    long_msg = (b'In the beginning God created the heaven and the earth, more and moreboom, '
                b'it has been a universal consensus that data is tis a new technology that '
                b'integrates decentralization,In the area of IoT (Internet of Things), more '
                b'and moreboom, it has been a universal consensus that data is tis a new tech'
                b'nology that integrates decentralization,In the area of IoT (Internet of '
                b'Things), more and moreboom')
    messages.append((long_msg, True))
    messages.append((b'', True))
    messages.append((b'', False))
    messages.append((b'a', True))
    messages.append((b'a' * 55, True))
    messages.append((b'a' * 56, True))
    messages.append((b'a' * 64, True))
    messages.append((b'a' * 119, True))
    messages.append((b'a' * 120, True))
    messages.append((b'\x00' * 64, True))
    messages.append((b'\xff' * 64, True))
    messages.append((b'abc', False))
    messages.append((b'abcdbcdecdefdefgefghfghighijhijkijkljklmklmnlmnomnopnopq', False))
    messages.append((b'a' * 200, False))
    for _ in range(40):
        ln = rng.randint(0, 300)
        messages.append((bytes(rng.getrandbits(8) for _ in range(ln)), True))
    for _ in range(20):
        ln = rng.randint(0, 300)
        messages.append((bytes(rng.getrandbits(8) for _ in range(ln)), False))

    with open(meta_path, 'w') as mf, open(blocks_path, 'w') as bf, open(digests_path, 'w') as df:
        mf.write(f"{len(messages)}\n")
        for msg, mode256 in messages:
            blocks, results = digest_all_blocks(msg, mode256)
            mf.write(f"{1 if mode256 else 0} {len(blocks)}\n")
            for b in blocks:
                bf.write(b.hex() + "\n")
            for r in results:
                df.write(r + "\n")
    total_blocks = sum(1 for _ in open(blocks_path))
    print(f"wrote {len(messages)} test cases, {total_blocks} total blocks")
    return len(messages), total_blocks

if __name__ == "__main__":
    emit_vectors_v2("sha_meta.txt", "sha_blocks.hex", "sha_digests.hex")
