# Constraints — Per-Variant Frozen Weight Files & Design Specifications

This directory contains the hardware-ready frozen parameters for each design variant, organized by measurement mode.

## Variants

| Directory | Mode | Qubits | Integration T | Dataset |
|-----------|------|--------|---------------|---------|
| `unified/` | All 4 profiles packed together | 1 or 5 | 500 or 1600 | Combined |
| `bus5/` | Superconducting 5-qubit bus | 5 | 500 | Synthetic (from real SC single-qubit shots) |
| `spin_bus5/` | Spin-qubit 5-qubit bus | 5 | 1600 | Synthetic spin |
| `spin_single/` | Spin-qubit single-qubit | 1 | 1600 | Real spin |
| `single/` | Superconducting single-qubit | 1 | 500 | Real SC |

> **Active design for RTL simulation:** Use `unified/`. The other variants are reference builds for the individual-mode RTL (not the unified top).

## File Types

### Weight / Parameter Files (`.mem`)
Hex-encoded binary data loaded by `$readmemh` in the RTL at elaboration time.

| File Pattern | Depth | Width | Description |
|--------------|-------|-------|-------------|
| `unified_dlo_q[0-4].mem` | 4 × T_MAX | 80-bit | DLO filter weights: 8 packed 10-bit signed words per sample per profile |
| `unified_norm_mu_q[0-4].mem` | 16 | 48-bit | Normalizer mean μ (4 profiles × 4 features) |
| `unified_norm_n_q[0-4].mem` | 16 | 8-bit | Normalizer shift n (4 profiles × 4 features) |
| `unified_cls_w_q[0-4].mem` | 4 × 47 | 12-bit | Classifier weights (4 profiles × 47 terms) |
| `unified_cls_thr_q[0-4].mem` | 4 | 48-bit | Classifier thresholds (one per profile) |

### Golden Verification Vectors (`golden/`)
Pre-computed testbench stimulus and expected responses. Used by `testbench/simulation/tb_unified_readout.sv`.

| File | Description |
|------|-------------|
| `tb_mixed_input.mem` | Concatenated IQ sample stream for 100 test shots |
| `tb_mixed_meta.mem` | Per-shot metadata: `{profile[1:0], T[12:0]}` packed as 16-bit hex |
| `tb_mixed_pred.mem` | Expected predictions: `{3'b0, pred[4:0]}` per shot |

### Configuration (`config.json`)
Machine-readable hardware parameters for each variant:
```json
{
  "T_MAX": 4096,
  "N_WEIGHTS": 47,
  "profiles": [...]
}
```

### Design Specification (`design_spec.md`)
Human-readable specification including:
- Frozen integer algorithm (bit-exact reference)
- Memory layout per qubit
- Measured accuracy (float vs. fixed-point)
- Hardware work estimate per sample

## Integer Algorithm Reference

The exact bit-level computation implemented in the RTL and verified by `python/verify_mem_files.ipynb`:

```
# Stage 1-2: DLO Matched Filter (dlo_mac_unified.sv)
acc[q][k] = Σ_t ( I[t] × A[q,k,t] + Q[t] × B[q,k,t] )
  where k ∈ {MF_I, MF_Q, RMF_I, RMF_Q}

# Stage 3-7: Bit-Shift Normalizer (normalizer_unified.sv)
tmp = clip(acc + 2^n − μ,  0,  2^(n+1))
u   = (tmp << F_BITS) >> (n + 1)
v   = u − 2^(F_BITS−1)                 # v ∈ [−2^12, +2^12), Q12 format

# Stage 8-14: NG-RC Polynomial Classifier (classifier_poly_unified.sv)
o   = [2^F_BITS,  v_0..v_19,  v_i·v_j >> F_BITS  for 26 cross-pairs]
score = Σ_i ( w[profile][i] × o[i] )
pred  = (score > thr[profile])
```

## References

- DLO filter derivation: Gambetta, J., et al. *Qubit-photon interactions in a cavity: Measurement-induced dephasing and number splitting.* Phys. Rev. A 77, 012112 (2008). https://doi.org/10.1103/PhysRevA.77.012112
- NG-RC polynomial classifier: Gauthier, D. J., et al. *Next generation reservoir computing.* Nature Communications 12, 5564 (2021). https://doi.org/10.1038/s41467-021-25801-2
- QICK platform: Stefanazzi, L., et al. *The QICK (Quantum Instrumentation Control Kit).* Review of Scientific Instruments 93, 044709 (2022). https://doi.org/10.1063/5.0076249
