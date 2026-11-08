# SPDX-License-Identifier: Apache-2.0

VERILATOR = verilator
VERILATED_DIR := $(dir $(realpath $(lastword $(MAKEFILE_LIST))))
CALIPTRA_RTL_DIR ?= $(realpath $(VERILATED_DIR)../caliptra-rtl)
VF_FILE ?= $(CALIPTRA_RTL_DIR)/src/integration/config/caliptra_top_tb.vf
OUT_DIR ?= out

CFLAGS := -std=c++17 -O2 -fno-exceptions -fPIC
TIMING_CFLAGS := -std=c++20 -O2 -fcoroutines -fno-exceptions -fPIC
VERILATOR_MAKE_FLAGS ?= OPT_FAST="-Os"
VERILATOR_TRACE_FLAGS ?= --trace --trace-structs --timing

VERILATOR_CFLAGS = $(shell pkg-config --cflags verilator)
VERILATOR_INCLUDEDIR = $(shell pkg-config --variable=includedir verilator)
VERILATOR_OBJS = $(OUT_DIR)/verilated_threads.o $(OUT_DIR)/verilated.o \
  $(if $(findstring --trace,$(VERILATOR_TRACE_FLAGS)),$(OUT_DIR)/verilated_vcd_c.o) \
  $(if $(findstring --timing,$(VERILATOR_TRACE_FLAGS)),$(OUT_DIR)/verilated_timing.o)

LIB_OBJS = $(OUT_DIR)/caliptra_verilated.o

export CALIPTRA_ROOT = $(CALIPTRA_RTL_DIR)
export CALIPTRA_PRIM_ROOT = $(CALIPTRA_RTL_DIR)/src/caliptra_prim_generic
export CALIPTRA_PRIM_MODULE_PREFIX = caliptra_prim_generic
export CALIPTRA_AXI4PC_DIR = $(VERILATED_DIR)

suppress = -Wno-WIDTH -Wno-UNOPTFLAT -Wno-LITENDIAN -Wno-CMPCONST -Wno-MULTIDRIVEN -Wno-UNPACKED -Wno-UNSIGNED -Wno-REALCVT -Wno-SELRANGE -Wno-PINMISSING -Wno-TIMESCALEMOD -Wno-BLKANDNBLK

all: $(OUT_DIR)/boot_sim

$(OUT_DIR)/boot_sim: boot_sim.cpp $(OUT_DIR)/libcaliptra_verilated.a
	$(CXX) $(CFLAGS) -I$(VERILATED_DIR) -I$(CALIPTRA_RTL_DIR)/src/integration/rtl/caliptra_reg boot_sim.cpp $(OUT_DIR)/libcaliptra_verilated.a -pthread -o $@

$(OUT_DIR)/libcaliptra_verilated.a: $(OUT_DIR)/Vcaliptra_verilated__ALL.a $(OUT_DIR)/libverilated.a $(LIB_OBJS) $(VERILATOR_OBJS)
	cp $(OUT_DIR)/Vcaliptra_verilated__ALL.a $(OUT_DIR)/.libcaliptra_verilated.a
	ar rs $(OUT_DIR)/.libcaliptra_verilated.a $(LIB_OBJS) $(VERILATOR_OBJS)
	mv $(OUT_DIR)/.libcaliptra_verilated.a $(OUT_DIR)/libcaliptra_verilated.a

$(OUT_DIR):
	mkdir -p $(OUT_DIR)

$(VERILATOR_OBJS): $(OUT_DIR)/%.o: $(VERILATOR_INCLUDEDIR)/%.cpp | $(OUT_DIR)
	$(CXX) ${CFLAGS} $(VERILATOR_CFLAGS) -c $< -o $@

$(OUT_DIR)/verilated_timing.o: $(VERILATOR_INCLUDEDIR)/verilated_timing.cpp | $(OUT_DIR)
	$(CXX) ${TIMING_CFLAGS} $(VERILATOR_CFLAGS) -c $< -o $@

$(LIB_OBJS): $(OUT_DIR)/%.o: $(VERILATED_DIR)/%.cpp $(OUT_DIR)/Vcaliptra_verilated.h | $(OUT_DIR)
	$(CXX) -I$(OUT_DIR) ${CFLAGS} $(VERILATOR_CFLAGS) -c $< -o $@

$(OUT_DIR)/Vcaliptra_verilated.h: ${VERILATED_DIR}/caliptra_verilated.sv $(VF_FILE) | $(OUT_DIR)
	$(VERILATOR) --cc -CFLAGS "${CFLAGS}" \
	  $(VERILATOR_TRACE_FLAGS) \
	  +libext+.v+.sv +define+RV_OPENSOURCE +define+VERILATOR \
	  --timescale 1ns/1ps \
	  $(includes) \
	  -Mdir $(OUT_DIR) \
	  -MMD \
	  -Wno-fatal \
	  --clk core_clk \
	  $(suppress) \
	  -f $(VF_FILE) \
	  $(VERILATED_DIR)/caliptra_verilated.sv \
	  $(EXTRA_VERILATOR_FLAGS) \
	  --top-module caliptra_verilated

$(OUT_DIR)/Vcaliptra_verilated__ALL.a $(OUT_DIR)/libverilated.a &: $(OUT_DIR)/Vcaliptra_verilated.h
	$(MAKE) -j $(shell nproc) -e -C $(OUT_DIR) -f Vcaliptra_verilated.mk $(VERILATOR_MAKE_FLAGS) Vcaliptra_verilated__ALL.a libverilated.a

clean:
	rm -rf $(OUT_DIR)

# Convenience targets for Baseline, Phase 1, and Phase 2 builds & runs
.PHONY: baseline phase1 phase2 run-phase2 run-full-phase2

baseline:
	$(MAKE) OUT_DIR=out_baseline VF_FILE=$(CALIPTRA_RTL_DIR)/src/integration/config/caliptra_top_tb.vf

phase1:
	$(MAKE) OUT_DIR=out_phase1 VF_FILE=$(VERILATED_DIR)/calightra_top.vf \
	  VERILATOR_TRACE_FLAGS="" VERILATOR_MAKE_FLAGS='OPT_FAST="-O2"' \
	  EXTRA_VERILATOR_FLAGS="+define+CALIGHTRA_PHASE1 -O3 --x-assign fast --x-initial fast"

phase2:
	$(MAKE) OUT_DIR=out_phase2 VF_FILE=$(VERILATED_DIR)/calightra_top.vf \
	  VERILATOR_TRACE_FLAGS="" VERILATOR_MAKE_FLAGS='OPT_FAST="-O2"' \
	  EXTRA_VERILATOR_FLAGS="+define+CALIGHTRA_PHASE1 +define+CALIGHTRA_NO_COUNTERMEASURES -O3 --x-assign fast --x-initial fast"

run-phase2: phase2
	./out_phase2/boot_sim +rom=$(VERILATED_DIR)/../fw/caliptra-rom.bin

run-full-phase2: phase2
	./out_phase2/boot_sim +rom=$(VERILATED_DIR)/../fw/caliptra-rom.bin +fw=$(VERILATED_DIR)/../fw/image-bundle-mldsa.bin +full_boot
