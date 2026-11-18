# Testbench

## Files

| File | Description |
|------|-------------|
| `simulation/tb_unified_readout.sv` | Mixed-mode runtime reconfiguration testbench |
| `timing.xdc` | Synthesis clock constraint (285.7 MHz / 3.5 ns period) |

## Testbench — `tb_unified_readout.sv`

### What it tests
Streams **100 interleaved shots** across all 4 readout profiles back-to-back:

| Profile | Type | T (samples) | Active mask |
|---------|------|-------------|-------------|
| 0 | Superconducting single-qubit | 500 | `5'b00001` |
| 1 | Superconducting 5-qubit bus  | 500 | `5'b11111` |
| 2 | Spin-qubit single             | 1600 | `5'b00001` |
| 3 | Spin-qubit 5-qubit bus        | 1600 | `5'b11111` |

### Checks performed
1. **Bit-exact predictions** — every output `m_axis_tdata` is compared against the golden reference (`tb_mixed_pred.mem`)
2. **Post-pulse latency** — measured from last input sample to `m_axis_tvalid`; must equal **exactly 17 clock cycles** for every shot

### Golden vector files
The testbench loads `.mem` files using `$readmemh`. These point to:
- `constraints/unified/golden/tb_mixed_input.mem` — input IQ stream
- `constraints/unified/golden/tb_mixed_meta.mem` — per-shot profile + T
- `constraints/unified/golden/tb_mixed_pred.mem` — expected predictions

> **Before simulating:** Edit the `UNIFIED_DIR` and `GOLDEN_DIR` `localparam`s directly at the top of `tb_unified_readout.sv` to the **absolute path** of `constraints/unified/` and `constraints/unified/golden/` on your machine (`UNIFIED_DIR` is passed automatically to `dut`'s `.DIR` parameter).

### Expected output (PASS condition)
```
=======================================================
 UNIFIED MULTI-MODE READOUT VERIFICATION SUMMARY
=======================================================
 Profile 0 (SC Single)   : 25 / 25 PASS
 Profile 1 (SC 5-Qubit)  : 25 / 25 PASS
 Profile 2 (Spin Single) : 25 / 25 PASS
 Profile 3 (Spin 5-Qubit): 25 / 25 PASS
 Post-pulse latency      : 17 .. 17 cycles (expected 17)
 Total mismatches        : 0
 OVERALL RESULT          : PASS
=======================================================
```

## Timing Constraint — `timing.xdc`

```tcl
create_clock -period 3.500 -name clk [get_ports clk]
```

Closed post-synthesis timing at **285.7 MHz** (3.5 ns period, WNS = +0.195 ns, 59.5 ns latency for 17 cycles) on Zynq-7000 (`xc7z045ffg900-2`). The RTL is architected for **500 MHz** (2.0 ns period, 34 ns latency) on Zynq UltraScale+ RFSoC (QICK ZCU111/ZCU216).
