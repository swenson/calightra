# SPDX-License-Identifier: Apache-2.0
#
# Calightra Open-Source FPGA Synthesis & Place-and-Route Makefile
# Toolchain: sv2v + yosys + nextpnr-ice40 / nextpnr-ecp5

TOP_SPI    ?= calightra_spi_top
TOP_CORE   ?= calightra_fpga_top
VF         ?= calightra_ice40.vf

DEFINES    := --define CALIGHTRA_PHASE1 \
              --define CALIGHTRA_NO_COUNTERMEASURES \
              --define CALIGHTRA_NO_BP \
              --define RV_FPGA_OPTIMIZE \
              --define CALIGHTRA_ICE40

.PHONY: all sv2v ice40 ecp5 pnr-ecp5 blocks clean

all: ice40 pnr-ecp5

sv2v: $(TOP_SPI).v

$(TOP_SPI).v: $(VF) calightra_fpga_top.sv calightra_spi_ram_bridge.sv
	python3 run_sv2v.py --vf $(VF) --top $(TOP_SPI) --out $(TOP_SPI).v $(DEFINES)

ice40: $(TOP_SPI).v
	yosys -p "read_verilog -sv $(TOP_SPI).v; synth_ice40 -top $(TOP_SPI) -dsp -json $(TOP_SPI)_ice40.json; stat" | tee yosys_spi_top_ice40.log

ecp5: $(TOP_SPI).v
	yosys -p "read_verilog -sv $(TOP_SPI).v; synth_ecp5 -top $(TOP_SPI) -json $(TOP_SPI)_ecp5.json; stat" | tee yosys_spi_top_ecp5.log

pnr-ecp5: ecp5
	nextpnr-ecp5 --45k --package CABGA381 --json $(TOP_SPI)_ecp5.json --textcfg $(TOP_SPI)_ecp5.config --lpf-allow-unconstrained | tee nextpnr_spi_top_ecp5.log

blocks:
	python3 synth_blocks.py el2_veer hmac_ctrl aes_clp_wrapper ecc_top calightra_spi_ram_bridge

clean:
	rm -f *.v *.json *.config *.asc *.log *.stat
