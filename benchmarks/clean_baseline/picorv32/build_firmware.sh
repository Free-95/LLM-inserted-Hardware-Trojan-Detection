#!/bin/bash
# Rebuilds firmware.hex from source. Requires a RISC-V cross compiler that can
# target rv32im/ilp32, e.g. Ubuntu's `gcc-riscv64-linux-gnu` package (yes, it
# can target rv32 too via -march/-mabi), or a dedicated riscv32-unknown-elf-gcc.
set -e

CC=${CC:-riscv64-linux-gnu-gcc}
OBJCOPY=${OBJCOPY:-riscv64-linux-gnu-objcopy}

"$CC" -march=rv32im -mabi=ilp32 -nostdlib -nostartfiles -ffreestanding \
    -fno-pic -fno-pie -O1 -fno-builtin -Wall \
    -Wl,-T,link.ld -Wl,--no-relax -Wl,-no-pie -static \
    -o fw.elf start.S main.c

"$OBJCOPY" -O binary --only-section=.text --only-section=.sdata fw.elf fw.bin

python3 - << 'PYEOF'
import struct
data = open("fw.bin", "rb").read()
if len(data) % 4:
    data += b"\x00" * (4 - len(data) % 4)
words = struct.unpack("<%dI" % (len(data) // 4), data)
with open("firmware.hex", "w") as f:
    for w in words:
        f.write("%08x\n" % w)
print(f"wrote firmware.hex: {len(words)} words, {len(data)} bytes")
PYEOF

echo "Done"
