# SPDX-License-Identifier: Apache-2.0
#
# Calightra-SS Open-Source FPGA Synthesis & Place-and-Route Makefile
# Target: Radiona ULX3S-85F (Lattice ECP5-85F, LFE5U-85F-6BG381C)
# Toolchain: sv2v + yosys + nextpnr-ecp5 + ecppack

TOP_ULX3S ?= calightra_ss_ulx3s_top
VF        ?= calightra_ss_fpga.vf
LPF       ?= ../../fpga/ulx3s_v20.lpf

DEFINES   := --define CALIGHTRA_PHASE1 \
             --define CALIGHTRA_NO_COUNTERMEASURES \
             --define CALIGHTRA_NO_BP \
             --define RV_FPGA_OPTIMIZE \
             --define CALIGHTRA_ICE40

.PHONY: all sv2v ulx3s-85f clean

all: ulx3s-85f

sv2v: $(TOP_ULX3S).v

$(TOP_ULX3S).v: $(VF) calightra_ss_ulx3s_top.sv ../rtl/calightra_ss_axi_xbar.sv
	$(MAKE) -C ../fw
	python3 run_sv2v.py --vf $(VF) --top $(TOP_ULX3S) --out $(TOP_ULX3S).v $(DEFINES)

ulx3s-85f: $(TOP_ULX3S).v $(LPF)
	yosys -p "read_verilog -sv $(TOP_ULX3S).v; synth_ecp5 -top $(TOP_ULX3S) -json $(TOP_ULX3S)_85f.json; stat" 2>&1 | tee yosys_ss_ulx3s_85f.log
	nextpnr-ecp5 --85k --package CABGA381 --lpf $(LPF) --json $(TOP_ULX3S)_85f.json --textcfg calightra_ss_ulx3s_85f.config 2>&1 | tee nextpnr_ss_ulx3s_85f.log
	ecppack --compress calightra_ss_ulx3s_85f.config calightra_ss_ulx3s_85f.bit

clean:
	rm -f *.v *.json *.config *.bit *.log
