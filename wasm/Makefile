# SPDX-License-Identifier: Apache-2.0
# Copyright 2026 Calightra Contributors.

WASM_DIR      := $(dir $(realpath $(lastword $(MAKEFILE_LIST))))
REPO_DIR      := $(realpath $(WASM_DIR)/..)
CALIPTRA_RTL  ?= $(REPO_DIR)/caliptra-rtl
VF_FILE       ?= $(REPO_DIR)/sim/calightra_top.vf
OBJ_DIR       ?= $(WASM_DIR)/obj_wasm
WWW_DIR       ?= $(REPO_DIR)/www
JOBS          ?= $(shell nproc)

VERILATOR     ?= verilator
VERILATOR_INC ?= $(shell pkg-config --variable=includedir verilator 2>/dev/null || echo /usr/share/verilator/include)
EMCXX         ?= em++
OBJCACHE      ?= $(shell command -v ccache >/dev/null 2>&1 && echo ccache || echo "")

export CALIPTRA_ROOT               = $(CALIPTRA_RTL)
export CALIPTRA_PRIM_ROOT          = $(CALIPTRA_RTL)/src/caliptra_prim_generic
export CALIPTRA_PRIM_MODULE_PREFIX = caliptra_prim_generic
export CALIPTRA_AXI4PC_DIR         = $(REPO_DIR)/sim

SUPPRESS_FLAGS = \
	-Wno-WIDTH -Wno-UNOPTFLAT -Wno-LITENDIAN -Wno-CMPCONST \
	-Wno-MULTIDRIVEN -Wno-UNPACKED -Wno-UNSIGNED -Wno-REALCVT \
	-Wno-SELRANGE -Wno-PINMISSING -Wno-TIMESCALEMOD -Wno-BLKANDNBLK

VERILATOR_DEFINES = \
	+libext+.v+.sv \
	+define+RV_OPENSOURCE \
	+define+CALIGHTRA_PHASE1 \
	+define+CALIGHTRA_NO_COUNTERMEASURES \
	+define+RV_FPGA_OPTIMIZE

COMMON_CXXFLAGS = \
	-std=c++17 \
	-include stdint.h \
	-fno-exceptions \
	-faligned-new \
	-msimd128 \
	-mbulk-memory \
	-DVL_IGNORE_UNKNOWN_ARCH \
	-Wno-unused-parameter \
	-Wno-unused-variable \
	-Wno-sign-compare \
	-Wno-tautological-compare \
	-Wno-shadow \
	-Wno-parentheses-equality \
	-I$(OBJ_DIR) \
	-I$(VERILATOR_INC) \
	-I$(VERILATOR_INC)/vltstd \
	-I$(CALIPTRA_RTL)/src/integration/rtl/caliptra_reg

FAST_CXXFLAGS = -O3 $(COMMON_CXXFLAGS)
SLOW_CXXFLAGS = -O1 $(COMMON_CXXFLAGS)

EXPORTED_FUNCS = [\
'_malloc',\
'_free',\
'_calightra_init',\
'_calightra_destroy',\
'_calightra_step',\
'_calightra_last_error',\
'_calightra_take_uart',\
'_calightra_take_log',\
'_calightra_get_status_json',\
'_calightra_get_errors_json',\
'_calightra_get_keyvault_json',\
'_calightra_get_fuses_json',\
'_calightra_mailbox_start',\
'_calightra_mailbox_poll',\
'_calightra_mailbox_resp_ptr',\
'_calightra_mailbox_resp_len',\
'_calightra_set_prod_dbg_unlock_req',\
'_calightra_set_manuf_dbg_unlock_req',\
'_calightra_fw_pk_hashes'\
]

EXPORTED_RUNTIME = ['UTF8ToString','stringToUTF8','lengthBytesUTF8','HEAPU8']

EM_LDFLAGS = \
	-O3 \
	-msimd128 \
	-mbulk-memory \
	-fno-exceptions \
	-sMODULARIZE=1 \
	-sEXPORT_ES6=1 \
	-sEXPORT_NAME=createCalightraModule \
	-sALLOW_MEMORY_GROWTH=1 \
	-sINITIAL_MEMORY=67108864 \
	-sSTACK_SIZE=4194304 \
	-sENVIRONMENT=web,worker,node \
	-sEXPORTED_FUNCTIONS="$(EXPORTED_FUNCS)" \
	-sEXPORTED_RUNTIME_METHODS="$(EXPORTED_RUNTIME)"

.PHONY: all verilate link-stage clean

all: verilate
	$(MAKE) -j $(JOBS) -f $(WASM_DIR)/Makefile link-stage OBJ_DIR="$(OBJ_DIR)" WWW_DIR="$(WWW_DIR)"

$(OBJ_DIR)/Vcalightra_verilated_wasm_classes.mk: $(WASM_DIR)/calightra_verilated_wasm.sv $(VF_FILE)
	mkdir -p $(OBJ_DIR)
	$(VERILATOR) --cc \
		$(VERILATOR_DEFINES) \
		--timescale 1ns/1ps \
		-O3 --x-assign fast --x-initial fast \
		-Mdir $(OBJ_DIR) \
		-Wno-fatal \
		--clk core_clk \
		$(SUPPRESS_FLAGS) \
		-f $(VF_FILE) \
		$(WASM_DIR)/calightra_verilated_wasm.sv \
		--top-module calightra_verilated_wasm

verilate: $(OBJ_DIR)/Vcalightra_verilated_wasm_classes.mk

ifneq ($(wildcard $(OBJ_DIR)/Vcalightra_verilated_wasm_classes.mk),)
include $(OBJ_DIR)/Vcalightra_verilated_wasm_classes.mk

FAST_OBJS    := $(addprefix $(OBJ_DIR)/,$(addsuffix .wasm.o,$(VM_CLASSES_FAST) $(VM_SUPPORT_FAST)))
SLOW_OBJS    := $(addprefix $(OBJ_DIR)/,$(addsuffix .wasm.o,$(VM_CLASSES_SLOW) $(VM_SUPPORT_SLOW)))
GLOBAL_OBJS  := $(addprefix $(OBJ_DIR)/,$(addsuffix .wasm.o,$(VM_GLOBAL_FAST) $(VM_GLOBAL_SLOW)))
WRAPPER_OBJ  := $(OBJ_DIR)/calightra_wasm.wasm.o

ALL_WASM_OBJS := $(FAST_OBJS) $(SLOW_OBJS) $(GLOBAL_OBJS) $(WRAPPER_OBJ)

$(FAST_OBJS): $(OBJ_DIR)/%.wasm.o: $(OBJ_DIR)/%.cpp
	$(OBJCACHE) $(EMCXX) $(FAST_CXXFLAGS) -c $< -o $@

$(SLOW_OBJS): $(OBJ_DIR)/%.wasm.o: $(OBJ_DIR)/%.cpp
	$(OBJCACHE) $(EMCXX) $(SLOW_CXXFLAGS) -c $< -o $@

$(GLOBAL_OBJS): $(OBJ_DIR)/%.wasm.o: $(VERILATOR_INC)/%.cpp
	$(OBJCACHE) $(EMCXX) $(FAST_CXXFLAGS) -c $< -o $@

$(WRAPPER_OBJ): $(WASM_DIR)/calightra_wasm.cpp $(OBJ_DIR)/Vcalightra_verilated_wasm.h
	$(OBJCACHE) $(EMCXX) $(FAST_CXXFLAGS) -c $< -o $@

$(WWW_DIR)/calightra_verilated.js: $(ALL_WASM_OBJS)
	mkdir -p $(WWW_DIR)
	$(EMCXX) $(EM_LDFLAGS) $(ALL_WASM_OBJS) -o $@

link-stage: $(WWW_DIR)/calightra_verilated.js
endif

clean:
	rm -rf $(OBJ_DIR) $(WWW_DIR)/calightra_verilated.js $(WWW_DIR)/calightra_verilated.wasm
