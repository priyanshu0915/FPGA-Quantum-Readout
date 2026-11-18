# RTL Design — SystemVerilog Source Files

This directory contains the four synthesizable SystemVerilog modules that make up the unified qubit readout pipeline.

## Module Hierarchy

```
unified_readout_top
├── dlo_mac_unified       × 5  (one per qubit lane)
├── normalizer_unified    × 5
└── classifier_poly_unified × 5
```

## Files

| File | Stage | Latency | Description |
|------|-------|---------|-------------|
| `unified_readout_top.sv` | Top | — | Profile MUX, AXI4-Stream I/O, pipeline alignment registers |
| `dlo_mac_unified.sv` | 1–2 | 5 cycles | 4-feature dual-filter DLO matched-filter MAC |
| `normalizer_unified.sv` | 3–7 | 5 cycles | Integer bit-shift normalizer (3-stage barrel shift) |
| `classifier_poly_unified.sv` | 8–14 | 7 cycles | 47-term NG-RC quadratic polynomial classifier |

**Total pipeline latency: 17 clock cycles (≈ 34 ns at 500 MHz)**

## Key Design Parameters

All parameters are set at instantiation time in `unified_readout_top.sv`:

| Parameter | Default | Description |
|-----------|---------|-------------|
| `DIR` | `"./"` | Path prefix for `$readmemh` ROM files |
| `T_SC` | 500 | Integration window for SC qubits (samples) |
| `T_SPIN` | 1600 | Integration window for spin qubits (samples) |
| `T_MAX` | 4096 | Maximum supported integration window |
| `IN_BITS` | 16 | ADC word width (I and Q, signed) |
| `DLO_BITS` | 10 | DLO filter weight precision |
| `F_BITS` | 12 | Normalized feature fractional bits (1.0 = 2¹²) |
| `W_BITS` | 12 | Classifier weight precision |
| `ACC_BITS` | 37 | Accumulator width |
| `SCORE_BITS` | 27 | Classifier score accumulator width |

## Ports — `unified_readout_top`

| Port | Dir | Width | Description |
|------|-----|-------|-------------|
| `clk` | in | 1 | System clock (up to 333 MHz synthesized) |
| `rst_n` | in | 1 | Active-low synchronous reset |
| `trig_profile_sel` | in | 2 | Per-shot profile select from QICK tProcessor |
| `soft_override_en` | in | 1 | Enable PS/AXI-Lite parameter override |
| `soft_profile_sel` | in | 2 | Software profile override |
| `soft_cfg_T` | in | 13 | Software integration length override |
| `soft_active_mask` | in | 5 | Software qubit-active mask override |
| `s_axis_tvalid` | in | 1 | AXI4-Stream input valid (RF-ADC data) |
| `s_axis_tready` | out | 1 | Always asserted (backpressure-free) |
| `s_axis_tdata` | in | 32 | `{Q[15:0], I[15:0]}` from RF-ADC |
| `m_axis_tvalid` | out | 1 | Prediction output valid |
| `m_axis_tdata` | out | 8 | `{3'b0, pred[4:0]}` — one bit per qubit |

## ROM File Loading

Each submodule loads its weights via `$readmemh` at elaboration time. The `DIR` parameter in `unified_readout_top` is the common prefix. When running simulation, set `DIR` to the absolute or relative path of `python/design_freeze/unified/` in your checkout.

**Example (Vivado simulation settings):**
```
unified_readout_top.DIR = "/home/user/FPGA-Quantum-Readout/python/design_freeze/unified/"
```

## References

- DLO filter theory: Gambetta et al., Phys. Rev. A 77, 012112 (2008). https://doi.org/10.1103/PhysRevA.77.012112
- NG-RC classifier: Gauthier et al., Nature Communications 12, 5564 (2021). https://doi.org/10.1038/s41467-021-25801-2
- DSP48E1 MAC: Xilinx UG479. https://docs.xilinx.com/r/en-US/ug479_7Series_DSP48E1
