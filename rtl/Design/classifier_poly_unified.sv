// ============================================================================
// classifier_poly_unified.sv  --  Stage 4/5 Unified NG-RC Polynomial Classifier
//
// Computes 47-term quadratic polynomial expansion across all 5 qubit lanes:
//   o = [ 2^F, v_0..v_19 (20 linear), q_0..q_25 (26 quadratic monomials) ]
//   score = sum_{i=0..46} (w[profile][i] * o[i])
//   pred  = (score > thr[profile])
//
// Latency: 7 clock cycles (s1: quad MREG -> s2: quad PREG & shift ->
//          s3: weight MREG -> s4: ternary reduction -> s5: mid-tree reg ->
//          s6: final sum reg -> s7: threshold compare)
// ============================================================================
`timescale 1ns / 1ps

module classifier_poly_unified #(
    parameter integer N_PROFILES = 4,
    parameter integer N_QUBITS   = 5,
    parameter integer N_PAIRS    = 26,
    parameter integer F_BITS     = 12,
    parameter integer W_BITS     = 12,
    parameter integer SCORE_BITS = 27,
    parameter integer PAIR_I [0:N_PAIRS-1] = '{0,0,0,0,1,1,1,2,2,3, 0,0,1,1, 0,0,1,1, 0,0,1,1, 0,0,1,1},
    parameter integer PAIR_J [0:N_PAIRS-1] = '{0,1,2,3,1,2,3,2,3,3, 4,5,4,5, 8,9,8,9, 12,13,12,13, 16,17,16,17},
    parameter         W_FILE     = "unified_cls_w_q0.mem",
    parameter         THR_FILE   = "unified_cls_thr_q0.mem"
) (
    input  wire                                    clk,
    input  wire                                    rst_n,
    input  wire [1:0]                              profile_sel,
    input  wire                                    in_valid,
    input  wire signed [4*N_QUBITS*(F_BITS+1)-1:0] v_all_flat,
    output wire                                    out_valid,
    output wire [1:0]                              out_profile,
    output wire signed [SCORE_BITS-1:0]            score,
    output wire                                    pred
);

    localparam integer N_LIN     = 4 * N_QUBITS;           // 20
    localparam integer N_WEIGHTS = 1 + N_LIN + N_PAIRS;    // 47
    localparam integer VW        = F_BITS + 1;             // 13
    localparam integer OW        = F_BITS + 2;             // 14
    localparam integer QPROD_W   = 2 * VW;                 // 26
    localparam integer PW        = W_BITS + OW;            // 26
    localparam integer SI        = PW + 7;                 // 33-bit exact internal sum

    (* rom_style = "distributed" *) reg [W_BITS-1:0] w_rom   [0:N_PROFILES*N_WEIGHTS-1];
    (* rom_style = "distributed" *) reg [47:0]       thr_rom [0:N_PROFILES-1];

    initial begin
        $readmemh(W_FILE,   w_rom);
        $readmemh(THR_FILE, thr_rom);
    end

    // Unpack 20 normalized features
    wire signed [VW-1:0] v_arr [0:N_LIN-1];
    genvar idx;
    generate
        for (idx = 0; idx < N_LIN; idx = idx + 1) begin : g_unpack
            assign v_arr[idx] = v_all_flat[idx*VW +: VW];
        end
    endgenerate

    // 7-stage pipeline valid & profile_sel chain
    reg v1, v2, v3, v4, v5, v6, v7;
    reg [1:0] p1, p2, p3, p4, p5, p6, p7;

    always @(posedge clk) begin
        if (!rst_n) begin
            {v1, v2, v3, v4, v5, v6, v7} <= 7'b0;
            {p1, p2, p3, p4, p5, p6, p7} <= 14'b0;
        end else begin
            v1 <= in_valid;  p1 <= profile_sel;
            v2 <= v1;        p2 <= p1;
            v3 <= v2;        p3 <= p2;
            v4 <= v3;        p4 <= p3;
            v5 <= v4;        p5 <= p4;
            v6 <= v5;        p6 <= p5;
            v7 <= v6;        p7 <= p6;
        end
    end

    // ------------------------------------------------------------------------
    // Stage 1 & 2: Quadratic Monomial Expansion (MREG + PREG)
    // ------------------------------------------------------------------------
    (* use_dsp = "yes" *) reg signed [QPROD_W-1:0] quad_m [0:N_PAIRS-1];
    reg signed [QPROD_W-1:0] quad_p [0:N_PAIRS-1];
    reg signed [VW-1:0]      v_d1   [0:N_LIN-1];
    reg signed [VW-1:0]      v_d2   [0:N_LIN-1];

    integer i, p;
    always @(posedge clk) begin
        if (in_valid) begin
            for (i = 0; i < N_LIN; i = i + 1)
                v_d1[i] <= v_arr[i];
            for (p = 0; p < N_PAIRS; p = p + 1)
                quad_m[p] <= v_arr[PAIR_I[p]] * v_arr[PAIR_J[p]];
        end
        if (v1) begin
            for (i = 0; i < N_LIN; i = i + 1)
                v_d2[i] <= v_d1[i];
            for (p = 0; p < N_PAIRS; p = p + 1)
                quad_p[p] <= quad_m[p];
        end
    end

    // Assemble 47-element aligned operand vector o_vec[0..46]
    localparam signed [OW-1:0] BIAS = 1 <<< F_BITS;
    wire signed [OW-1:0] o_vec [0:N_WEIGHTS-1];
    assign o_vec[0] = BIAS;

    generate
        for (idx = 0; idx < N_LIN; idx = idx + 1) begin : g_olin
            assign o_vec[1 + idx] = v_d2[idx];
        end
        for (idx = 0; idx < N_PAIRS; idx = idx + 1) begin : g_oquad
            wire signed [QPROD_W-1:0] q_sh = quad_p[idx] >>> F_BITS;
            assign o_vec[1 + N_LIN + idx] = q_sh[OW-1:0];
        end
    endgenerate

    // ------------------------------------------------------------------------
    // Stage 3: Weighted Product Multiply (Explicit 4:1 LUT MUX + DSP48 MREG)
    // ------------------------------------------------------------------------
    (* use_dsp = "yes" *) reg signed [PW-1:0] prod_m [0:N_WEIGHTS-1];
    reg signed [W_BITS-1:0] w_active [0:N_WEIGHTS-1];

    generate
        for (idx = 0; idx < N_WEIGHTS; idx = idx + 1) begin : g_wsel
            always @(*) begin
                case (p2)
                    2'd0:    w_active[idx] = w_rom[0 * N_WEIGHTS + idx];
                    2'd1:    w_active[idx] = w_rom[1 * N_WEIGHTS + idx];
                    2'd2:    w_active[idx] = w_rom[2 * N_WEIGHTS + idx];
                    default: w_active[idx] = w_rom[3 * N_WEIGHTS + idx];
                endcase
            end
        end
    endgenerate

    always @(posedge clk) begin
        if (v2) begin
            for (i = 0; i < N_WEIGHTS; i = i + 1) begin
                prod_m[i] <= w_active[i] * o_vec[i];
            end
        end
    end

    // ------------------------------------------------------------------------
    // Stage 4: Ternary Fabric Adder Reduction (16 groups of 3 terms)
    // ------------------------------------------------------------------------
    localparam integer N_GRP = 16;
    (* use_dsp = "no" *) reg signed [SI-1:0] part_sum [0:N_GRP-1];

    function automatic signed [SI-1:0] get_prod(input integer k);
        begin
            if (k < N_WEIGHTS)
                get_prod = {{(SI-PW){prod_m[k][PW-1]}}, prod_m[k]};
            else
                get_prod = {SI{1'b0}};
        end
    endfunction

    integer g;
    always @(posedge clk) begin
        if (v3) begin
            for (g = 0; g < N_GRP; g = g + 1) begin
                part_sum[g] <= get_prod(g*3 + 0) + get_prod(g*3 + 1) + get_prod(g*3 + 2);
            end
        end
    end

    // ------------------------------------------------------------------------
    // Stage 5: Mid-Tree Register (4 partial sums of 4 terms in CARRY4 fabric)
    // ------------------------------------------------------------------------
    (* use_dsp = "no" *) reg signed [SI-1:0] s5_a0_r, s5_a1_r, s5_a2_r, s5_a3_r;

    always @(posedge clk) begin
        if (v4) begin
            s5_a0_r <= (part_sum[0]  + part_sum[1])  + (part_sum[2]  + part_sum[3]);
            s5_a1_r <= (part_sum[4]  + part_sum[5])  + (part_sum[6]  + part_sum[7]);
            s5_a2_r <= (part_sum[8]  + part_sum[9])  + (part_sum[10] + part_sum[11]);
            s5_a3_r <= (part_sum[12] + part_sum[13]) + (part_sum[14] + part_sum[15]);
        end
    end

    // ------------------------------------------------------------------------
    // Stage 6: Final 4-Input Sum Register
    // ------------------------------------------------------------------------
    (* use_dsp = "no" *) reg signed [SI-1:0] score_full_r;

    always @(posedge clk) begin
        if (v5) begin
            score_full_r <= (s5_a0_r + s5_a1_r) + (s5_a2_r + s5_a3_r);
        end
    end

    // ------------------------------------------------------------------------
    // Stage 7: Full-Width Threshold Decision
    // ------------------------------------------------------------------------
    wire signed [SI-1:0] thr_s = $signed(thr_rom[p6][SI-1:0]);

    reg signed [SCORE_BITS-1:0] score_r;
    reg                         pred_r;

    always @(posedge clk) begin
        if (v6) begin
            score_r <= score_full_r[SCORE_BITS-1:0];
            pred_r  <= (score_full_r > thr_s);
        end
    end

    assign out_valid   = v7;
    assign out_profile = p7;
    assign score       = score_r;
    assign pred        = pred_r;

endmodule