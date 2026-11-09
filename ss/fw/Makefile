# SPDX-License-Identifier: Apache-2.0

CC      := riscv64-unknown-elf-gcc
OBJCOPY := riscv64-unknown-elf-objcopy
OBJDUMP := riscv64-unknown-elf-objdump

CFLAGS  := -march=rv32imc_zicsr_zifencei -mabi=ilp32 -Os -ffreestanding -nostdlib \
           -Wall -Wextra -fno-builtin -fno-stack-protector
LDFLAGS := -T link.ld -nostdlib -Wl,--gc-sections

all: mcu_rom.bin mcu_rom.dis mcu_rom.hex

mcu_rom.elf: start.S mcu_boot.c link.ld
	$(CC) $(CFLAGS) $(LDFLAGS) -o $@ start.S mcu_boot.c

mcu_rom.bin: mcu_rom.elf
	$(OBJCOPY) -O binary $< $@

mcu_rom.dis: mcu_rom.elf
	$(OBJDUMP) -d -M no-aliases $< > $@

# Generate 64-bit word hex file for FPGA $readmemh initialization
mcu_rom.hex: mcu_rom.bin
	python3 -c 'data = open("mcu_rom.bin", "rb").read(); data += b"\x00" * ((8 - len(data) % 8) % 8); open("mcu_rom.hex", "w").write("\n".join("%016x" % int.from_bytes(data[i:i+8], "little") for i in range(0, len(data), 8)) + "\n")'

clean:
	rm -f mcu_rom.elf mcu_rom.bin mcu_rom.dis mcu_rom.hex

.PHONY: all clean
