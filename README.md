# FPGA Quantum Readout — Unified Multi-Mode Qubit State Classifier

[![License: MIT](https://img.shields.io/badge/License-MIT-yellow.svg)](LICENSE)
[![HDL: SystemVerilog](https://img.shields.io/badge/HDL-SystemVerilog-blue)]()
[![Target: Xilinx Zynq-7000 (xc7z045)](https://img.shields.io/badge/Target-Zynq--7000%20xc7z045-orange)]()
[![Tool: Vivado 2026.1](https://img.shields.io/badge/Vivado-2026.1-green)]()

A fully pipelined FPGA qubit readout processor that classifies the quantum state of up to **5 qubits in real time**, with a fixed **17-clock-cycle latency**. The RTL is architected for **500 MHz** (34 ns post-pulse latency) on Zynq UltraScale+ RFSoC (QICK ZCU111/ZCU216) and closes post-synthesis timing at **285.7 MHz** (3.5 ns clock period, 59.5 ns latency, WNS = +0.195 ns) on Zynq-7000 (`xc7z045ffg900-2`). The design supports four dynamically-switchable measurement profiles — superconducting single-qubit, superconducting 5-qubit bus, spin-qubit single, and spin-qubit 5-qubit bus — without any dead time between shots.

---

## Table of Contents
1. [Background](#background)
2. [Architecture Overview](#architecture-overview)
3. [Pipeline Stages](#pipeline-stages)
4. [Measurement Profiles](#measurement-profiles)
5. [Repository Structure](#repository-structure)
6. [Prerequisites](#prerequisites)
7. [Quick Start — RTL Simulation](#quick-start--rtl-simulation)
8. [Quick Start — Python Verification](#quick-start--python-verification)
9. [Synthesis Results](#synthesis-results)
10. [Reproducing the Design Freeze](#reproducing-the-design-freeze)
11. [Citations](#citations)

---

## Background

Real-time qubit state classification is a key bottleneck in quantum computing experiments. Conventional heterodyne readout pipelines perform matched filtering on the RF-ADC output stream and apply a threshold classifier in software, introducing latency that limits qubit reset and feedback cycles.

This project implements the **Dual Linear Optimal (DLO) filter** followed by an **NG-RC polynomial classifier** entirely in FPGA fabric, targeting the [QICK (Quantum Instrumentation Control Kit)](https://github.com/openquantumhardware/qick) platform [1] (architected for Zynq UltraScale+ RFSoC and verified post-synthesis on Xilinx Zynq-7000 `xc7z045ffg900-2`).

The classification algorithm is derived from the **Next-Generation Reservoir Computing (NG-RC)** framework [2] adapted for fixed-point hardware, the matched-filter bank follows the dual-filter approach of [3], and the hardware-efficient FPGA readout architecture builds on recent ML-accelerated quantum state discrimination work [4, 5].

---

## Architecture Overview

```
RF-ADC Stream (AXI4-S, 32-bit I+Q @ 500 MSPS)
        │
        ▼
┌───────────────────────────────────────────────────────────────┐
│  unified_readout_top.sv                                       │
│                                                               │
│  ┌────────────────┐   ┌──────────────────┐   ┌────────────┐  │
│  │ dlo_mac_unified│──▶│normalizer_unified│──▶│classifier_ │  │
│  │  (5× parallel) │   │  (5× parallel)   │   │poly_unified│  │
│  │  Stage 1–2     │   │  Stage 3–7       │   │ Stage 8–14 │  │
│  │  Latency: 5 cy │   │  Latency: 5 cy   │   │ Latency: 7 │  │
│  └────────────────┘   └──────────────────┘   └────────────┘  │
│                                                               │
│  Profile MUX: trig_profile_sel[1:0] (per-shot, zero latency)  │
└───────────────────────────────────────────────────────────────┘
        │
        ▼
  QICK tProcessor Condition (AXI4-S, 8-bit pred[4:0])
  Total latency: 17 clock cycles (34 ns @ 500 MHz RFSoC / 59.5 ns @ 285.7 MHz Zynq-7000)
```

---

## Pipeline Stages

| Stage | Module | Clocks | Description |
|-------|--------|--------|-------------|
| 1–2 | `dlo_mac_unified` | 5 | BRAM-based dual-filter matched-filter MAC. Accumulates `I[t]·A[t] + Q[t]·B[t]` for 4 filter features over T samples. 80-bit packed weight ROM (8×10-bit signed per sample). |
| 3–7 | `normalizer_unified` | 5 | Bit-shift normalizer. Computes `v = clip(acc + 2^n − μ, 0, 2^(n+1)) << F >> (n+1) − 2^(F−1)` using a 3-stage barrel shift (coarse → mid → fine). |
| 8–14 | `classifier_poly_unified` | 7 | 47-term quadratic NG-RC polynomial classifier. Expands `[1, v₀..v₁₉, v_i·v_j (26 cross-terms)]`, computes weighted score, compares to threshold. |

Each qubit lane packs all 4 operating profiles into a single profile-switched weight ROM (4096 × 80-bit), saving 4× BRAM compared to separate per-profile memories.

---

## Measurement Profiles

| Profile ID | `trig_profile_sel` | Type | Integration T | Active Qubits |
|------------|--------------------|------|---------------|---------------|
| 0 | `2'b00` | Superconducting single-qubit | 500 bins | Q0 only |
| 1 | `2'b01` | Superconducting 5-qubit bus  | 500 bins | Q0–Q4 |
| 2 | `2'b10` | Spin-qubit single             | 1600 bins | Q0 only |
| 3 | `2'b11` | Spin-qubit 5-qubit bus        | 1600 bins | Q0–Q4 |

The profile is selected **per-shot** via the `trig_profile_sel` port driven by the QICK tProcessor. An optional `soft_override_en` port allows PS/AXI-Lite runtime reconfiguration.

---

## Repository Structure

```
.
├── rtl/
│   └── Design/
│       ├── unified_readout_top.sv       # Top-level: profile MUX + 5× qubit lanes
│       ├── dlo_mac_unified.sv           # Stage 1–2: Dual-filter matched-filter MAC
│       ├── normalizer_unified.sv        # Stage 3–7: Bit-shift normalizer
│       └── classifier_poly_unified.sv   # Stage 8–14: NG-RC polynomial classifier
│
├── testbench/
│   ├── simulation/
│   │   └── tb_unified_readout.sv        # Mixed-mode verification testbench (100 shots × 4 profiles)
│   └── timing.xdc                       # 285.7 MHz (3.5 ns) synthesis clock constraint
│
├── constraints/                         # Single source of truth: frozen weight .mem files + specs
│   ├── unified/                         # Active unified design (all 4 profiles in one ROM)
│   │   ├── unified_dlo_q[0-4].mem       # DLO filter weights (4 profiles × T × 80-bit)
│   │   ├── unified_norm_mu_q[0-4].mem   # Normalizer mean μ (4 profiles × 4 features)
│   │   ├── unified_norm_n_q[0-4].mem    # Normalizer shift n (4 profiles × 4 features)
│   │   ├── unified_cls_w_q[0-4].mem     # Classifier weights (4 profiles × 47 terms)
│   │   ├── unified_cls_thr_q[0-4].mem   # Classifier thresholds (4 profiles)
│   │   ├── unified_meta.json            # Profile table (T, active_mask, N_WEIGHTS)
│   │   └── golden/                      # Golden verification vectors
│   │       ├── tb_mixed_input.mem       # 100 interleaved shots input stream
│   │       ├── tb_mixed_meta.mem        # Per-shot profile + T metadata
│   │       └── tb_mixed_pred.mem        # Expected predictions (bit-exact reference)
│   ├── bus5/                            # 5-qubit SC bus variant
│   ├── spin_bus5/                       # 5-qubit spin bus variant
│   ├── spin_single/                     # Single spin-qubit variant
│   └── single/                          # Single SC qubit variant
│
├── python/
│   ├── freeze_design.ipynb              # Quantizes trained model → .mem files
│   ├── pack_unified_profiles.ipynb      # Packs all 4 profiles into unified ROMs
│   ├── make_mixed_tb.ipynb              # Generates golden testbench vectors
│   ├── make_test_suite.ipynb            # Generates per-variant test suites
│   ├── verify_mem_files.ipynb           # Python bit-exact verification of .mem files
│   ├── gen_synth_datasets.ipynb         # Generates synthetic 5-qubit datasets
│   ├── step3_ngrc_classifier.ipynb      # NG-RC classifier training
│   ├── step4_fixed_point.ipynb          # Fixed-point quantization analysis
│   └── [step1–step8 analysis notebooks] # Full design exploration pipeline
│
├── reports/                             # Vivado synthesis reports (gitignored, regenerate via Vivado)
│   ├── timing.txt
│   ├── util.txt
│   └── util_hier.txt
│
├── requirements.txt                     # Python dependencies
└── README.md
```

---

## Prerequisites

### For RTL Simulation
- **Vivado 2022.1 or later** (free WebPACK license is sufficient for simulation)  
  Download: https://www.xilinx.com/support/download.html
- Target device: `xc7z045ffg900-2` (Zynq-7000, verified post-synthesis at 285.7 MHz); architected for Zynq UltraScale+ RFSoC (500 MHz) on [QICK platforms](https://github.com/openquantumhardware/qick) (ZCU111/ZCU216)

> **Note:** Any SystemVerilog-capable simulator (ModelSim, QuestaSim, Icarus Verilog ≥ 11, Verilator) can run the testbench. Only Vivado is needed for synthesis/implementation.

### For Python Notebooks
```bash
python -m venv .venv
# Windows
.venv\Scripts\activate
# Linux/macOS
source .venv/bin/activate

pip install -r requirements.txt
```

**Python dependencies:** `numpy`, `scipy`, `matplotlib`, `pandas`, `scikit-learn`, `jupyter`, `ipykernel`

---

## Quick Start — RTL Simulation

The testbench streams **100 interleaved shots** across all 4 profiles and checks:
- **Bit-exact predictions** against the golden reference (`tb_mixed_pred.mem`)
- **Post-pulse latency = exactly 17 clock cycles** for every shot

### Vivado (Recommended)

1. **Clone the repository:**
   ```bash
   git clone https://github.com/priyanshu0915/FPGA-Quantum-Readout.git
   cd FPGA-Quantum-Readout
   ```

2. **Open Vivado and create a simulation project:**
   - **Sources:** Add all files under `rtl/Design/` and `testbench/simulation/`
   - **Constraints:** Add `testbench/timing.xdc`
   - **Top module for simulation:** `tb_unified_readout`

3. **Set the `.mem` directory paths** (critical — the testbench must find the `.mem` files):

   `tb_unified_readout.sv` declares `localparam string UNIFIED_DIR` and `GOLDEN_DIR` at the top of the module (and automatically passes `UNIFIED_DIR` into `dut`'s `.DIR` parameter). Because SystemVerilog `localparam` values cannot be overridden via Vivado Verilog options, edit those two lines directly at the top of `testbench/simulation/tb_unified_readout.sv` before running simulation:

   ```systemverilog
   localparam string UNIFIED_DIR = "<your_local_path>/constraints/unified/";
   localparam string GOLDEN_DIR  = "<your_local_path>/constraints/unified/golden/";
   ```

4. **Run behavioral simulation** (`Run Simulation → Run Behavioral Simulation`)

5. **Expected console output:**
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

### ModelSim / QuestaSim (Alternative)

```bash
vlog -sv rtl/Design/dlo_mac_unified.sv
vlog -sv rtl/Design/normalizer_unified.sv
vlog -sv rtl/Design/classifier_poly_unified.sv
vlog -sv rtl/Design/unified_readout_top.sv
vlog -sv testbench/simulation/tb_unified_readout.sv

vsim tb_unified_readout -do "run -all; quit"
```

> Set `UNIFIED_DIR` and `GOLDEN_DIR` localparams in `tb_unified_readout.sv` to your local paths before compiling.

---

## Quick Start — Python Verification

The notebooks can verify the fixed-point algorithm **without raw datasets** using only the frozen `.mem` files:

```bash
cd python
jupyter notebook verify_mem_files.ipynb
```

This notebook:
1. Loads `../constraints/unified/*.mem` files
2. Replicates the integer pipeline (DLO → Normalizer → Classifier)
3. Checks predictions against `../constraints/unified/golden/` reference vectors
4. Confirms bit-exact agreement with the RTL

---

## Synthesis Results

Synthesized with **Vivado 2026.1** targeting `xc7z045ffg900-2` (Zynq-7000). The RTL is architected for **500 MHz** (34 ns post-pulse latency) on Zynq UltraScale+ RFSoC (QICK ZCU111/ZCU216) and closes post-synthesis timing at **285.7 MHz** (3.5 ns period, 59.5 ns latency) on Zynq-7000.

### Resource Utilization (Post-Synthesis)

| Resource | Used | Available | Utilization |
|----------|------|-----------|-------------|
| Slice LUTs | 7,076 | 218,600 | 3.24% |
| Slice Registers (FF) | 4,841 | 437,200 | 1.11% |
| Block RAM Tiles | 200 | 545 | 36.70% |
| DSP48E1 | 420 | 900 | 46.67% |

> BRAM is dominated by the 5 qubit lanes × 40 RAMB36E1 each (4096-deep × 80-bit DLO filter ROM packing all 4 profiles per lane = 200 BRAMs total).  
> DSP usage: 12 DSP48E1 per MAC lane × 5 + 72 DSP48E1 per classifier lane × 5 = **420 DSP48E1** total.

### Timing (Post-Synthesis, 285.7 MHz / 3.5 ns constraint)

| Metric | Value |
|--------|-------|
| Target device | `xc7z045ffg900-2` (Zynq-7000) |
| Clock period constraint | 3.500 ns (285.714 MHz) |
| WNS (Worst Negative Slack) | +0.195 ns ✅ |
| WHS (Worst Hold Slack) | +0.004 ns ✅ |
| Post-pulse latency | 17 cycles (59.5 ns @ 285.7 MHz; 34.0 ns @ 500 MHz RFSoC) |
| Timing violations | **0** |

> All timing constraints are met post-synthesis on Zynq-7000 (`xc7z045ffg900-2`). Full reports are generated locally in `reports/` (gitignored; regenerate via Vivado).

### Classification Fidelity (Fixed-Point Hardware vs. 64-Bit Float)

| Profile | Mode | Fixed-Point Fidelity | Baseline Comparison | Delta vs. Float64 |
|---------|------|----------------------|---------------------|-------------------|
| 0 | Superconducting Single-Qubit (`sc_single`) | **96.13%** | — | within ±0.004% |
| 1 | Superconducting 5-Qubit Bus (`sc_bus5`) | **88.18%** | 87.63% (linear baseline) | within ±0.004% |
| 2 | Spin-Qubit Single (`spin_single`) | **99.70%** | — | within ±0.004% |
| 3 | Spin-Qubit 5-Qubit Bus (`spin_bus5`) | **99.73%** | — | within ±0.004% |

> All four fixed-point hardware profiles match the 64-bit floating-point software reference within ±0.004%.

---

## Reproducing the Design Freeze

If you have access to the raw training datasets (not provided in this repo), you can retrain and re-freeze the design:

1. **Explore and train:** Run `python/step1_2_filters_baselines.ipynb` through `python/step8_compare_3_approaches.ipynb` in order.
2. **Fixed-point quantization:** `python/step4_fixed_point.ipynb`
3. **Freeze weights to `.mem`:** `python/freeze_design.ipynb`
4. **Pack unified 4-profile ROMs:** `python/pack_unified_profiles.ipynb`
5. **Generate testbench vectors:** `python/make_mixed_tb.ipynb`
6. **Verify:** `python/verify_mem_files.ipynb`

The frozen `.mem` files committed in `constraints/unified/` are the **bit-exact reference outputs** of this pipeline.

---

## Citations

If you use this work, please cite the following:

**[1] QICK — Quantum Instrumentation Control Kit**  
Stefanazzi, L., et al. (2022). *The QICK (Quantum Instrumentation Control Kit): Scalable control hardware for superconducting quantum computing systems.* Review of Scientific Instruments, 93(4), 044709.  
https://doi.org/10.1063/5.0076249  
GitHub: https://github.com/openquantumhardware/qick

**[2] Next-Generation Reservoir Computing (NG-RC)**  
Gauthier, D. J., Bollt, E., Griffith, A., & Barbosa, W. A. (2021). *Next generation reservoir computing.* Nature Communications, 12, 5564.  
https://doi.org/10.1038/s41467-021-25801-2

**[3] Optimal Readout & Dual-Filter Matched Filtering**  
Gambetta, J., et al. (2007). *Qubit-photon interactions in a cavity: Measurement-induced dephasing and number splitting.* Physical Review A, 77, 012112.  
https://doi.org/10.1103/PhysRevA.77.012112

**[4] QubiCML — FPGA-Based ML Quantum State Discrimination**  
Vora, N. R., et al. (2024 / 2026). *ML-Powered FPGA-based Real-Time Quantum State Discrimination Enabling Mid-circuit Measurements (QubiCML).* arXiv:2406.18807 / ACM GLSVLSI '26.  
https://arxiv.org/abs/2406.18807

**[5] HERQULES — Hardware-Efficient Qubit Readout**  
Maurya, S., et al. (2023). *Scaling Qubit Readout with Hardware Efficient Machine Learning Architectures (HERQULES).* Proceedings of the 50th Annual International Symposium on Computer Architecture (ISCA '23).

**[6] Fixed-Point Quantization for Neural Classifiers**  
Courbariaux, M., Bengio, Y., & David, J. P. (2015). *Training deep neural networks with low precision multiplications.* arXiv:1412.7024.  
https://arxiv.org/abs/1412.7024

**[7] Xilinx 7-Series DSP48E1 Primitive**  
Xilinx/AMD. (2023). *7 Series DSP48E1 Slice User Guide (UG479).*  
https://docs.xilinx.com/r/en-US/ug479_7Series_DSP48E1

---

## License

MIT License — see [LICENSE](LICENSE) for details.

## Author

Priyanshu — The Maharaja Sayajirao University of Baroda  
*FPGA Quantum Readout Project, 2026*
