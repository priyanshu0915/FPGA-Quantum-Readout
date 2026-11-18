# Python — Design Exploration, Training & Design-Freeze Notebooks

This directory contains the full Python pipeline from raw data exploration to generating the FPGA-ready `.mem` weight files.

## Workflow

```
Raw Dataset (not in repo)
        │
        ▼
step0_inspection            → Inspect raw IQ traces, verify dataset structure
step1_2_filters_baselines   → Baseline classifiers, matched-filter exploration
step3_ngrc_classifier       → Train NG-RC quadratic polynomial classifier
step4_fixed_point           → Fixed-point quantization sweep (bit widths, accuracy)
step5_crosstalk             → Single-qubit baseline with crosstalk analysis
step5c_boxcar_vs_dualfilter → Compare boxcar integration vs. dual-filter
step5_multiqubit_pipeline   → 5-qubit pipeline assembly
step6_baselines             → Final baselines comparison
step7                       → Extended analysis
step8_compare_3_approaches  → Compare linear / poly / NG-RC classifiers
        │
        ▼
gen_synth_datasets          → Generate synthetic 5-qubit bus datasets
dataset_label               → Label and curate dataset splits
        │
        ▼
freeze_design               → Quantize best model → .mem files (per variant)
pack_unified_profiles       → Merge 4 variants into unified 4-profile ROMs
        │
        ▼
make_test_suite             → Per-variant golden testbench vectors
make_mixed_tb               → Mixed-mode (all 4 profiles) golden vectors
verify_mem_files            → Bit-exact Python verification of .mem files
```

## Key Notebooks

### `freeze_design.ipynb`
Converts the trained floating-point model into integer `.mem` files for FPGA. Implements the exact integer algorithm:
```python
acc[k] = sum_t(I[t]*A[k][t] + Q[t]*B[k][t])          # DLO MAC
tmp = clip(acc + 2**n - mu, 0, 2**(n+1))
u   = (tmp << F_BITS) >> (n + 1)
v   = u - 2**(F_BITS - 1)                              # Normalized feature
score = sum_i(w[i] * o[i])                              # Polynomial classifier
pred  = score > threshold
```
Reference: `design_spec.md` in each `constraints/<variant>/` folder.

### `pack_unified_profiles.ipynb`
Packs the four variant weight files into unified 4-profile ROM images:
- `unified_dlo_q[0-4].mem` — 4-profile × T_MAX depth, 80-bit width
- `unified_norm_mu_q[0-4].mem`, `unified_norm_n_q[0-4].mem` — 16 entries each (4 profiles × 4 features)
- `unified_cls_w_q[0-4].mem` — 4-profile × 47 weights
- `unified_cls_thr_q[0-4].mem` — 4-profile thresholds

Output goes to `design_freeze/unified/`.

### `make_mixed_tb.ipynb`
Generates 100 interleaved golden test shots across all 4 profiles. Writes:
- `design_freeze/unified/golden/tb_mixed_input.mem` — concatenated IQ sample stream
- `design_freeze/unified/golden/tb_mixed_meta.mem` — per-shot `{profile[1:0], T[12:0]}`
- `design_freeze/unified/golden/tb_mixed_pred.mem` — expected qubit predictions

These files are the **ground truth** for the RTL testbench `tb_unified_readout.sv`.

### `verify_mem_files.ipynb`
Loads the frozen `.mem` files and runs the integer algorithm in Python to confirm bit-exact agreement with the golden prediction vectors — **no raw dataset required**.

## `design_freeze/` Directory

Contains the generated `.mem` files for each design variant. These are committed to the repository so that:
1. The RTL simulation can be run without installing Python or the dataset
2. Third parties can verify bit-exact agreement between the Python model and RTL

| Variant | Description |
|---------|-------------|
| `unified/` | Active design — all 4 profiles packed into single ROMs |
| `bus5/` | Superconducting 5-qubit bus |
| `spin_bus5/` | Spin-qubit 5-qubit bus |
| `spin_single/` | Spin-qubit single |

## Dependencies

```bash
pip install -r ../requirements.txt
```

| Package | Version | Use |
|---------|---------|-----|
| `numpy` | ≥1.24 | Array math, fixed-point simulation |
| `scipy` | ≥1.10 | Signal processing, filter design |
| `matplotlib` | ≥3.7 | Plotting |
| `pandas` | ≥2.0 | Data management |
| `scikit-learn` | ≥1.3 | Classifier training, cross-validation |
| `jupyter` | ≥7.0 | Notebook environment |

## References

- NG-RC Algorithm: Gauthier, D. J., et al. *Next generation reservoir computing.* Nature Communications 12, 5564 (2021). https://doi.org/10.1038/s41467-021-25801-2
- DLO Filter: Gambetta, J., et al. *Qubit-photon interactions in a cavity.* Phys. Rev. A 77, 012112 (2008). https://doi.org/10.1103/PhysRevA.77.012112
- Fixed-point training: Courbariaux, M., et al. arXiv:1412.7024 (2015). https://arxiv.org/abs/1412.7024
