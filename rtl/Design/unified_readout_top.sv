// ============================================================================
// unified_readout_top.sv  --  Unified Single/Multi-Qubit & SC/Spin QICK Top
//
// Modes (selected dynamically per-shot via trig_profile_sel[1:0] or soft regs):
//   2'b00: Superconducting Single-Qubit   (T = 500,  mask = 5'b00001)
//   2'b01: Superconducting 5-Qubit Bus    (T = 500,  mask = 5'b11111)
//   2'b10: Spin-Qubit Single              (T = 1600, mask = 5'b00001)
//   2'b11: Spin-Qubit 5-Qubit Bus         (T = 1600, mask = 5'b11111)
//
// Latency: 5 (dlo_mac) + 5 (normalizer) + 7 (classifier_poly) = 17 clocks.
// ============================================================================
`timescale 1ns / 1ps

module unified_readout_top #(
    parameter         DIR          = "D:/MSU/Qubit_readout_FPGA/constraints/unified/",
    parameter integer T_SC         = 500,
    parameter integer T_SPIN       = 1600,
    parameter integer T_MAX        = 4096,
    parameter integer IN_BITS      = 16,
    parameter integer DLO_BITS     = 10,
    parameter integer ACC_BITS     = 37,
    parameter integer F_BITS       = 12,
    parameter integer W_BITS       = 12,
    parameter integer SCORE_BITS   = 27
) (
    input  wire                 clk,
    input  wire                 rst_n,

    // Hardware profile select from QICK tProcessor (switches seamlessly between shots)
    input  wire [1:0]           trig_profile_sel,

    // Optional PS / AXI-Lite runtime overrides (tie low if using default profile table)
    input  wire                 soft_override_en,
    input  wire [1:0]           soft_profile_sel,
    input  wire [12:0]          soft_cfg_T,
    input  wire [4:0]           soft_active_mask,

    // RF-ADC AXI4-Stream Input: {Q[15:0], I[15:0]}
    input  wire                 s_axis_tvalid,
    output wire                 s_axis_tready,
    input  wire [2*IN_BITS-1:0] s_axis_tdata,

    // QICK tProcessor External Condition AXI4-Stream Output: {3'b0, pred[4:0]}
    output wire                 m_axis_tvalid,
    output wire [7:0]           m_axis_tdata
);

    localparam integer N_QUBITS = 5;
    localparam integer N_PAIRS  = 26;
    localparam integer VW       = F_BITS + 1;

    assign s_axis_tready = 1'b1;

    wire signed [IN_BITS-1:0] i_in = s_axis_tdata[IN_BITS-1:0];
    wire signed [IN_BITS-1:0] q_in = s_axis_tdata[2*IN_BITS-1:IN_BITS];

    // Resolve active profile, integration length T, and active channel mask
    wire [1:0]  eff_profile = soft_override_en ? soft_profile_sel : trig_profile_sel;

    wire [12:0] default_T    = eff_profile[1] ? T_SPIN[12:0] : T_SC[12:0];
    wire [4:0]  default_mask = eff_profile[0] ? 5'b11111     : 5'b00001;

    wire [12:0] eff_T    = soft_override_en ? soft_cfg_T       : default_T;
    wire [4:0]  eff_mask = soft_override_en ? soft_active_mask : default_mask;

    // Pipeline profile_sel alongside the 10-cycle MAC+Normalizer latency and
    // mask_pipe alongside the full 17-cycle MAC+Normalizer+Classifier latency
    reg [1:0] prof_pipe [0:9];
    reg [4:0] mask_pipe [0:16];
    integer s;
    always @(posedge clk) begin
        if (!rst_n) begin
            for (s = 0; s < 10; s = s + 1) prof_pipe[s] <= 2'b00;
            for (s = 0; s < 17; s = s + 1) mask_pipe[s] <= 5'b00000;
        end else begin
            prof_pipe[0] <= eff_profile;
            for (s = 1; s < 10; s = s + 1)
                prof_pipe[s] <= prof_pipe[s-1];

            mask_pipe[0] <= eff_mask;
            for (s = 1; s < 17; s = s + 1)
                mask_pipe[s] <= mask_pipe[s-1];
        end
    end

    wire [1:0] prof_at_norm = prof_pipe[4];
    wire [1:0] prof_at_cls  = prof_pipe[9];
    wire [4:0] mask_at_cls  = mask_pipe[9];
    wire [4:0] mask_at_out  = mask_pipe[16];

    // Cross-qubit quadratic pair index tables (matches config.json -> bus5)
    localparam integer BUS5_PAIR_I [0:4][0:25] = '{
        '{0,0,0,0,1,1,1,2,2,3, 0,0,1,1, 0,0,1,1, 0,0,1,1, 0,0,1,1},
        '{4,4,4,4,5,5,5,6,6,7, 4,4,5,5, 4,4,5,5, 4,4,5,5, 4,4,5,5},
        '{8,8,8,8,9,9,9,10,10,11, 8,8,9,9, 8,8,9,9, 8,8,9,9, 8,8,9,9},
        '{12,12,12,12,13,13,13,14,14,15, 12,12,13,13, 12,12,13,13, 12,12,13,13, 12,12,13,13},
        '{16,16,16,16,17,17,17,18,18,19, 16,16,17,17, 16,16,17,17, 16,16,17,17, 16,16,17,17}
    };
    localparam integer BUS5_PAIR_J [0:4][0:25] = '{
        '{0,1,2,3,1,2,3,2,3,3, 4,5,4,5, 8,9,8,9, 12,13,12,13, 16,17,16,17},
        '{4,5,6,7,5,6,7,6,7,7, 0,1,0,1, 8,9,8,9, 12,13,12,13, 16,17,16,17},
        '{8,9,10,11,9,10,11,10,11,11, 0,1,0,1, 4,5,4,5, 12,13,12,13, 16,17,16,17},
        '{12,13,14,15,13,14,15,14,15,15, 0,1,0,1, 4,5,4,5, 8,9,8,9, 16,17,16,17},
        '{16,17,18,19,17,18,19,18,19,19, 0,1,0,1, 4,5,4,5, 8,9,8,9, 12,13,12,13}
    };

    wire [N_QUBITS-1:0]             acc_done_vec;
    wire [N_QUBITS-1:0]             v_valid_vec;
    wire signed [4*N_QUBITS*VW-1:0] v_all_flat;
    wire [N_QUBITS-1:0]             cls_valid_vec;
    wire [N_QUBITS-1:0]             raw_pred_vec;

    genvar q;
    generate
        for (q = 0; q < N_QUBITS; q = q + 1) begin : g_qubit
            localparam [7:0] Q_CHAR = 8'd48 + q[7:0];

            wire signed [4*ACC_BITS-1:0] acc_q;
            wire signed [4*VW-1:0]       v_q;

            dlo_mac_unified #(
                .T_MAX(T_MAX), .IN_BITS(IN_BITS), .DLO_BITS(DLO_BITS), .ACC_BITS(ACC_BITS),
                .ROM_FILE({DIR, "unified_dlo_q", Q_CHAR, ".mem"})
            ) u_mac (
                .clk(clk), .rst_n(rst_n),
                .profile_sel(eff_profile), .cfg_T(eff_T),
                .in_valid(s_axis_tvalid), .i_in(i_in), .q_in(q_in),
                .done(acc_done_vec[q]), .done_profile(), .acc_flat(acc_q)
            );

            normalizer_unified #(
                .ACC_BITS(ACC_BITS), .F_BITS(F_BITS),
                .MU_FILE({DIR, "unified_norm_mu_q", Q_CHAR, ".mem"}),
                .N_FILE ({DIR, "unified_norm_n_q",  Q_CHAR, ".mem"})
            ) u_norm (
                .clk(clk), .rst_n(rst_n),
                .profile_sel(prof_at_norm),
                .in_valid(acc_done_vec[q]), .acc_flat(acc_q),
                .out_valid(v_valid_vec[q]), .out_profile(), .v_flat(v_q)
            );

            // Zero out inactive channels using shot-aligned mask
            assign v_all_flat[q*4*VW +: 4*VW] = mask_at_cls[q] ? v_q : {(4*VW){1'b0}};

            classifier_poly_unified #(
                .N_QUBITS(N_QUBITS), .N_PAIRS(N_PAIRS),
                .F_BITS(F_BITS), .W_BITS(W_BITS), .SCORE_BITS(SCORE_BITS),
                .PAIR_I(BUS5_PAIR_I[q]), .PAIR_J(BUS5_PAIR_J[q]),
                .W_FILE  ({DIR, "unified_cls_w_q",   Q_CHAR, ".mem"}),
                .THR_FILE({DIR, "unified_cls_thr_q", Q_CHAR, ".mem"})
            ) u_cls (
                .clk(clk), .rst_n(rst_n),
                .profile_sel(prof_at_cls),
                .in_valid(v_valid_vec[0]),
                .v_all_flat(v_all_flat),
                .out_valid(cls_valid_vec[q]),
                .out_profile(),
                .score(),
                .pred(raw_pred_vec[q])
            );
        end
    endgenerate

    assign m_axis_tvalid = cls_valid_vec[0];
    assign m_axis_tdata  = {3'b000, (raw_pred_vec & mask_at_out)};

endmodule