# Testbench

## Files

| File | Description |
|------|-------------|
| `simulation/tb_unified_readout.sv` | Mixed-mode runtime reconfiguration testbench |
| `timing.xdc` | Synthesis clock constraint (333 MHz / 3 ns period) |

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
- `python/design_freeze/unified/tb_mixed_input.mem` — input IQ stream
- `python/design_freeze/unified/tb_mixed_meta.mem` — per-shot profile + T
- `python/design_freeze/unified/tb_mixed_pred.mem` — expected predictions

> **Before simulating:** Set the `UNIFIED_DIR` and `GOLDEN_DIR` localparams at the top of `tb_unified_readout.sv` to the **absolute path** of these directories on your machine.

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
create_clock -period 3.000 -name clk [get_ports clk]
```

Constrains the design to **333 MHz** (3 ns period). Synthesis WNS = +0.195 ns on `xc7z045ffg900-2`. The design is clocked at **500 MHz** in the QICK platform (2 ns period); full implementation with place & route is required to close timing at that frequency.
