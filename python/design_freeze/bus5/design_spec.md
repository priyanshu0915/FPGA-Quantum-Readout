# Design freeze v1 - mode `bus5`

SYNTHETIC 5-qubit multiplexed bus built from real single-qubit shots, crosstalk strength 1.0

## Frozen parameters
- qubits: 5, accumulation length T = 500 bins, EMA alpha = 0.05
- input 16-bit signed; weight-table words 10-bit signed; accumulator 34-bit signed (worst case, empirical 27)
- normalized features: 1.0 = 2^12, range [-2^11, +2^11] (13-bit signed)
- classifier weights 12-bit signed (6 fractional bits); scores/threshold stored as 48-bit signed

## Integer algorithm (bit-exact reference: freeze_design.py / verify_mem_files.py)
```
acc[q][k] = sum_t ( I[t]*A[q][k][t] + Q[t]*B[q][k][t] )   k = MF_I, MF_Q, RMF_I, RMF_Q
tmp = clip(acc + 2^n - mu, 0, 2^(n+1));  u = (tmp << F) >> (n+1);  v = u - 2^(F-1)
product = (v_i * v_j) >> F      (arithmetic shift)
score = sum_i w_i * o_i ;  o = [2^F, v_flat..., products...]
decision = score > thr
```

## Memory per qubit
- `dlo_qN.mem`: depth 500, width 80 bits (8 packed words)
- `norm_mu_qN.mem`, `norm_n_qN.mem`: 4 entries each
- `<variant>/cls_w_qN.mem`, `cls_thr_qN.mem`

## Hardware work per sample per qubit
- 8 multiply-accumulates (4 features x 2 terms); 0 table columns are identically zero in this mode (baseband single-qubit data drops to 4 effective MACs)

## Measured on the TEST split (float vs fixed)
- `lin`: fixed F = 0.8763, fixed-minus-float = -0.020 +/- 0.007 pts, 21 weights + 0 products per qubit
- `poly`: fixed F = 0.8818, fixed-minus-float = +0.002 +/- 0.009 pts, 47 weights + 26 products per qubit

## NOT verified yet
- latency and clock rate (no RTL yet)
- LUT/DSP/BRAM use (no synthesis yet)
- real ADC sample period (QICK rate not confirmed; bins are not yet nanoseconds)
- real multi-qubit crosstalk (bus5 is synthetic)
- separate contribution of WMF vs WRMF on the bus
