# SPDX-License-Identifier: Apache-2.0
#
# Calightra Open-Source FPGA Synthesis & Place-and-Route Makefile
# Toolchain: sv2v + yosys + nextpnr-ice40 / nextpnr-ecp5

TOP_ULX3S  ?= ulx3s_top
TOP_SPI    ?= calightra_spi_top
TOP_CORE   ?= calightra_fpga_top
VF         ?= calightra_ice40.vf

DEFINES    := --define CALIGHTRA_PHASE1 \
              --define CALIGHTRA_NO_COUNTERMEASURES \
              --define CALIGHTRA_NO_BP \
              --define RV_FPGA_OPTIMIZE \
              --define CALIGHTRA_ICE40

.PHONY: all sv2v ice40 ecp5 pnr-ecp5 ulx3s-85f blocks clean

all: ice40 pnr-ecp5 ulx3s-85f

sv2v: $(TOP_SPI).v

$(TOP_SPI).v: $(VF) calightra_fpga_top.sv calightra_spi_ram_bridge.sv
	python3 run_sv2v.py --vf $(VF) --top $(TOP_SPI) --out $(TOP_SPI).v $(DEFINES)

$(TOP_ULX3S).v: $(VF) ulx3s_top.sv calightra_fpga_top.sv calightra_spi_ram_bridge.sv
	python3 run_sv2v.py --vf $(VF) --top $(TOP_ULX3S) --out $(TOP_ULX3S).v $(DEFINES)

ice40: $(TOP_SPI).v
	yosys -p "read_verilog -sv $(TOP_SPI).v; synth_ice40 -top $(TOP_SPI) -dsp -json $(TOP_SPI)_ice40.json; stat" | tee yosys_spi_top_ice40.log

ecp5: $(TOP_SPI).v
	yosys -p "read_verilog -sv $(TOP_SPI).v; synth_ecp5 -top $(TOP_SPI) -json $(TOP_SPI)_ecp5.json; stat" | tee yosys_spi_top_ecp5.log

pnr-ecp5: ecp5
	nextpnr-ecp5 --45k --package CABGA381 --json $(TOP_SPI)_ecp5.json --textcfg $(TOP_SPI)_ecp5.config --lpf-allow-unconstrained | tee nextpnr_spi_top_ecp5.log

ulx3s-85f: $(TOP_ULX3S).v ulx3s_v20.lpf
	yosys -p "read_verilog -sv $(TOP_ULX3S).v; synth_ecp5 -top $(TOP_ULX3S) -json $(TOP_ULX3S)_85f.json; stat" | tee yosys_ulx3s_85f.log
	nextpnr-ecp5 --85k --package CABGA381 --lpf ulx3s_v20.lpf --json $(TOP_ULX3S)_85f.json --textcfg calightra_ulx3s_85f.config | tee nextpnr_ulx3s_85f.log
	ecppack --compress calightra_ulx3s_85f.config calightra_ulx3s_85f.bit

blocks:
	python3 synth_blocks.py el2_veer hmac_ctrl aes_clp_wrapper ecc_top calightra_spi_ram_bridge

clean:
	rm -f *.v *.json *.config *.bit *.asc *.log *.stat
