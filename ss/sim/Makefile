# SPDX-License-Identifier: Apache-2.0

export CALIPTRA_SS_ROOT := $(abspath ../../caliptra-ss)

VERILATOR ?= verilator
TOP       := calightra_ss_verilated
OBJ_DIR   := obj_dir_ss

VFLAGS := --cc --exe --build -j 8 \
          --top-module $(TOP) \
          --Mdir $(OBJ_DIR) \
          --timing \
          --autoflush \
          -O1 \
          -CFLAGS "-O1" \
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
          -DCALIGHTRA_NO_BP

all: $(OBJ_DIR)/V$(TOP)

$(OBJ_DIR)/V$(TOP): calightra_ss_top.vf calightra_ss_verilated.sv ../rtl/calightra_ss_axi_xbar.sv ss_boot_sim.cpp
	$(VERILATOR) $(VFLAGS) -f calightra_ss_top.vf ss_boot_sim.cpp

run: $(OBJ_DIR)/V$(TOP)
	$(MAKE) -C ../fw
	./$(OBJ_DIR)/V$(TOP)

clean:
	rm -rf $(OBJ_DIR)

.PHONY: all run clean
