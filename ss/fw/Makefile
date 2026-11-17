# SPDX-License-Identifier: Apache-2.0

CC        := riscv64-unknown-elf-gcc
OBJCOPY   := riscv64-unknown-elf-objcopy
OBJDUMP   := riscv64-unknown-elf-objdump

CPTRA_ROM ?= ../../fw/fake-caliptra-rom.bin

CFLAGS    := -march=rv32imc_zicsr_zifencei -mabi=ilp32 -Os -ffreestanding -nostdlib \
             -Wall -Wextra -fno-builtin -fno-stack-protector
LDFLAGS   := -T link.ld -nostdlib -Wl,--gc-sections

all: mcu_rom.bin mcu_rom.dis mcu_rom.hex cptra_rom_b0.hex cptra_rom_b1.hex cptra_rom_b2.hex

mcu_rom.elf: start.S mcu_boot.c link.ld
	$(CC) $(CFLAGS) $(LDFLAGS) -o $@ start.S mcu_boot.c

mcu_rom.bin: mcu_rom.elf
	$(OBJCOPY) -O binary $< $@

mcu_rom.dis: mcu_rom.elf
	$(OBJDUMP) -d -M no-aliases $< > $@

# Generate 1024-word (8 KB) 64-bit hex file for FPGA $readmemh initialization
mcu_rom.hex: mcu_rom.bin
	python3 -c 'd = open("mcu_rom.bin", "rb").read(); assert len(d) <= 8192; d = d.ljust(8192, b"\x00"); open("mcu_rom.hex", "w").write("\n".join("%016x" % int.from_bytes(d[i:i+8], "little") for i in range(0, 8192, 8)) + "\n")'

# Split 96 KB Caliptra Core ROM into three 4096 x 64-bit (32 KB) EBR banks
cptra_rom_b0.hex cptra_rom_b1.hex cptra_rom_b2.hex: $(CPTRA_ROM)
	python3 -c 'd = open("$(CPTRA_ROM)", "rb").read(); assert len(d) <= 98304; d = d.ljust(98304, b"\x00"); [open(f"cptra_rom_b{b}.hex", "w").write("\n".join("%016x" % int.from_bytes(d[b*32768+i:b*32768+i+8], "little") for i in range(0, 32768, 8)) + "\n") for b in range(3)]'

clean:
	rm -f mcu_rom.elf mcu_rom.bin mcu_rom.dis mcu_rom.hex cptra_rom_b0.hex cptra_rom_b1.hex cptra_rom_b2.hex

.PHONY: all clean
