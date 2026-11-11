# SPDX-License-Identifier: Apache-2.0

export CALIPTRA_SS_ROOT := $(abspath ../../caliptra-ss)

VERILATOR ?= verilator
TOP       := calightra_ss_verilated
OBJ_DIR   := obj_dir_ss

VFLAGS := --cc --exe \
          --top-module $(TOP) \
          --Mdir $(OBJ_DIR) \
          --no-timing \
          --clk core_clk \
          --autoflush \
          -O3 \
          --x-assign fast \
          --x-initial fast \
          -CFLAGS "-O2" \
          -Wno-fatal \
          -Wno-UNOPTFLAT \
          -Wno-WIDTHTRUNC \
          -Wno-WIDTHEXPAND \
          -Wno-CASEINCOMPLETE \
          -Wno-IMPLICIT \
          -Wno-PINMISSING \
          -Wno-SYNCASYNCNET \
          -Wno-LATCH \
          -Wno-MULTIDRIVEN \
          -Wno-ASCRANGE \
          -Wno-ALWCOMBORDER \
          -Wno-CMPCONST \
          -Wno-SYMRSVDWORD \
          -DCALIGHTRA_PHASE1 \
          -DCALIGHTRA_NO_COUNTERMEASURES \
          -DCALIGHTRA_NO_BP \
          -DCALIPTRA_MODE_SUBSYSTEM

all: $(OBJ_DIR)/V$(TOP)

$(OBJ_DIR)/V$(TOP).mk: calightra_ss_top.vf calightra_ss_verilated.sv ../rtl/calightra_ss_axi_xbar.sv ../rtl/calightra_i3c_ctrl.sv
	$(VERILATOR) $(VFLAGS) -f calightra_ss_top.vf ss_boot_sim.cpp

$(OBJ_DIR)/V$(TOP): $(OBJ_DIR)/V$(TOP).mk ss_boot_sim.cpp
	$(MAKE) -j 8 -C $(OBJ_DIR) -f V$(TOP).mk OPT_FAST="-O2" OPT_SLOW="-O0"

run: $(OBJ_DIR)/V$(TOP)
	$(MAKE) -C ../mcu-rom
	$(MAKE) -C ../fw
	./$(OBJ_DIR)/V$(TOP) --stop-at-recovery

run-recovery: $(OBJ_DIR)/V$(TOP)
	$(MAKE) -C ../mcu-rom
	$(MAKE) -C ../fw
	./$(OBJ_DIR)/V$(TOP) --cptra-rom=../../fw/fake-caliptra-rom.bin --bundle=../../fw/fake-image-bundle-mldsa.bin --max-cycles=60000000

run-recovery-full: $(OBJ_DIR)/V$(TOP)
	$(MAKE) -C ../mcu-rom
	$(MAKE) -C ../fw
	./$(OBJ_DIR)/V$(TOP) --max-cycles=70000000

clean:
	rm -rf $(OBJ_DIR)

.PHONY: all run run-recovery run-recovery-full clean
