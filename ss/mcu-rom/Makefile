# SPDX-License-Identifier: Apache-2.0
#
# Build the real caliptra-mcu-sw (main-2.1) ROM, MCU Runtime test image, and
# MLDSA-87 + ECC-384 signed SoC Authorization Manifest for Calightra-SS.

MCU_SW_DIR ?= $(abspath ../../caliptra-mcu-sw)
TARGET     := riscv32imc-unknown-none-elf
ROM_CRATE  := caliptra-mcu-rom-calightra
ROM_ELF    := $(MCU_SW_DIR)/target/$(TARGET)/release/$(ROM_CRATE)
ROM_BIN    := caliptra-mcu-rom-calightra.bin
ROM_SIZE   := 65536
LD_SCRIPT  := $(abspath rom/rom.ld)

RISCV_CC   ?= riscv64-unknown-elf-gcc
OBJCOPY    ?= riscv64-unknown-elf-objcopy
MCU_RT_ELF := mcu_rt.elf
MCU_RT_BIN := mcu_rt.bin
SOC_MAN    := soc_manifest.bin

.PHONY: all clean setup

all: $(ROM_BIN) $(MCU_RT_BIN) $(SOC_MAN)

setup:
	@ln -sfn $(abspath .) $(MCU_SW_DIR)/platforms/calightra
	@grep -q "platforms/calightra/rom" $(MCU_SW_DIR)/Cargo.toml || \
		sed -i 's|"platforms/fpga/rom",|"platforms/fpga/rom",\n    "platforms/calightra/config",\n    "platforms/calightra/rom",\n    "platforms/calightra/gen-manifest",|' $(MCU_SW_DIR)/Cargo.toml
	@grep -q "platforms/calightra/gen-manifest" $(MCU_SW_DIR)/Cargo.toml || \
		sed -i 's|"platforms/calightra/rom",|"platforms/calightra/rom",\n    "platforms/calightra/gen-manifest",|' $(MCU_SW_DIR)/Cargo.toml

$(ROM_BIN): setup $(wildcard config/src/*.rs) $(wildcard rom/src/*) rom/rom.ld append_digest.py
	cd $(MCU_SW_DIR) && \
		CARGO_TARGET_RISCV32IMC_UNKNOWN_NONE_ELF_RUSTFLAGS="-C link-arg=-T$(LD_SCRIPT) -C link-arg=--gc-sections" \
		cargo build --release --target $(TARGET) -p $(ROM_CRATE)
	$(OBJCOPY) -O binary $(ROM_ELF) $(ROM_BIN)
	python3 append_digest.py $(ROM_BIN) $(ROM_SIZE)

$(MCU_RT_BIN): mcu_rt.S
	$(RISCV_CC) -march=rv32imc -mabi=ilp32 -nostdlib -Wl,-Ttext=0x21c00000 -o $(MCU_RT_ELF) mcu_rt.S
	$(OBJCOPY) -O binary $(MCU_RT_ELF) $(MCU_RT_BIN)
	truncate -s 256 $(MCU_RT_BIN)

$(SOC_MAN): setup $(MCU_RT_BIN) $(wildcard gen-manifest/src/*.rs) gen-manifest/Cargo.toml
	cd $(MCU_SW_DIR) && \
		cargo run --release -p calightra-gen-manifest -- $(abspath $(MCU_RT_BIN)) $(abspath $(SOC_MAN))

clean:
	rm -f $(ROM_BIN) $(MCU_RT_ELF) $(MCU_RT_BIN) $(SOC_MAN)
