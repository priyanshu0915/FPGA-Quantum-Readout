// ============================================================================
// dlo_mac_unified.sv  --  Stage 2 Unified Dual-Filter DLO Multiply-Accumulate
//
// Reads all 8 premixed 10-bit signed weights per sample (80 bits/word):
//   [9:0]=A0, [19:10]=B0, [29:20]=A1, [39:30]=B1,
//   [49:40]=A2, [59:50]=B2, [69:60]=A3, [79:70]=B3
// Computes acc[f] = sum_t (I[t]*A_f[t] + Q[t]*B_f[t]) for f = 0..3.
// Latency: 5 clock cycles from last input sample to `done` (uses RAMB36 DOA_REG).
// ============================================================================
`timescale 1ns / 1ps

module dlo_mac_unified #(
    parameter integer N_PROFILES = 4,
    parameter integer T_MAX      = 4096,
    parameter integer IN_BITS    = 16,
    parameter integer DLO_BITS   = 10,
    parameter integer ACC_BITS   = 37,
    parameter         ROM_FILE   = "unified_dlo_q0.mem"
) (
    input  wire                         clk,
    input  wire                         rst_n,
    input  wire [1:0]                   profile_sel,
    input  wire [12:0]                  cfg_T,
    input  wire                         in_valid,
    input  wire signed [IN_BITS-1:0]    i_in,
    input  wire signed [IN_BITS-1:0]    q_in,
    output wire                         done,
    output wire [1:0]                   done_profile,
    output wire signed [4*ACC_BITS-1:0] acc_flat
);

    localparam integer CNT_W  = $clog2(T_MAX);      // 12 bits for 4096
    localparam integer ADDR_W = 2 + CNT_W;          // 14 bits (16384 words)
    localparam integer PW     = IN_BITS + DLO_BITS; // 26 bits

    // 4-bank 80-bit DLO ROM: 8 x 10-bit signed weights per sample
    (* rom_style = "block" *) reg [8*DLO_BITS-1:0] rom [0:N_PROFILES*T_MAX-1];
    initial begin
        $readmemh(ROM_FILE, rom);
    end

    reg  [CNT_W-1:0] cnt;
    reg  [CNT_W-1:0] rem_cnt;
    reg  [1:0]       shot_prof_r;
    reg              in_shot_r;

    wire       is_first = !in_shot_r;
    wire [1:0] act_prof = is_first ? profile_sel : shot_prof_r;
    wire       is_last  = is_first ? (cfg_T <= 13'd1) : (rem_cnt == {{(CNT_W-1){1'b0}}, 1'b1});

    always @(posedge clk) begin
        if (!rst_n) begin
            cnt         <= {CNT_W{1'b0}};
            rem_cnt     <= {CNT_W{1'b0}};
            shot_prof_r <= 2'b00;
            in_shot_r   <= 1'b0;
        end else if (in_valid) begin
            if (is_last) begin
                cnt       <= {CNT_W{1'b0}};
                rem_cnt   <= {CNT_W{1'b0}};
                in_shot_r <= 1'b0;
            end else if (is_first) begin
                shot_prof_r <= profile_sel;
                in_shot_r   <= 1'b1;
                cnt         <= {{(CNT_W-1){1'b0}}, 1'b1};
                rem_cnt     <= cfg_T[CNT_W-1:0] - {{(CNT_W-1){1'b0}}, 1'b1};
            end else begin
                cnt     <= cnt + {{(CNT_W-1){1'b0}}, 1'b1};
                rem_cnt <= rem_cnt - {{(CNT_W-1){1'b0}}, 1'b1};
            end
        end
    end

    reg v1, v2, v3, v4, v5;
    reg f1, f2, f3, f4;
    reg l1, l2, l3, l4, l5;
    reg [1:0] p1, p2, p3, p4, p5;

    always @(posedge clk) begin
        if (!rst_n) begin
            {v1, v2, v3, v4, v5} <= 5'b0;
            {f1, f2, f3, f4}     <= 4'b0;
            {l1, l2, l3, l4, l5} <= 5'b0;
            {p1, p2, p3, p4, p5} <= 10'b0;
        end else begin
            v1 <= in_valid;             v2 <= v1;  v3 <= v2;  v4 <= v3;  v5 <= v4;
            f1 <= in_valid && is_first; f2 <= f1;  f3 <= f2;  f4 <= f3;
            l1 <= in_valid && is_last;  l2 <= l1;  l3 <= l2;  l4 <= l3;  l5 <= l4;
            p1 <= act_prof;             p2 <= p1;  p3 <= p2;  p4 <= p3;  p5 <= p4;
        end
    end

    // Stage 1 & 2: Synchronous 80-bit BRAM read + internal DOA_REG output register
    wire [ADDR_W-1:0]        rom_addr = {act_prof, cnt};
    reg  [8*DLO_BITS-1:0]    rom_dout, rom_dout_r;
    reg  signed [IN_BITS-1:0] i_d1, q_d1, i_d2, q_d2;

    always @(posedge clk) begin
        if (in_valid) begin
            rom_dout <= rom[rom_addr];
            i_d1     <= i_in;
            q_d1     <= q_in;
        end
        if (v1) begin
            rom_dout_r <= rom_dout;
            i_d2       <= i_d1;
            q_d2       <= q_d1;
        end
    end

    // Stages 3, 4, 5: Dual-filter premixed MAC (4 features)
    genvar f;
    generate
        for (f = 0; f < 4; f = f + 1) begin : g_feat
            wire signed [DLO_BITS-1:0] a_f = rom_dout_r[(2*f + 0)*DLO_BITS +: DLO_BITS];
            wire signed [DLO_BITS-1:0] b_f = rom_dout_r[(2*f + 1)*DLO_BITS +: DLO_BITS];

            (* use_dsp = "yes" *) reg signed [PW-1:0]       pa_r, pb_r;
            (* use_dsp = "no" *) reg signed [PW:0]         s_r;
            (* use_dsp = "yes" *) reg signed [ACC_BITS-1:0] acc_r;

            wire signed [ACC_BITS-1:0] s_ext = {{(ACC_BITS-(PW+1)){s_r[PW]}}, s_r};

            always @(posedge clk) begin
                if (v2) begin
                    pa_r <= i_d2 * a_f;
                    pb_r <= q_d2 * b_f;
                end

                if (v3) begin
                    s_r <= pa_r + pb_r;
                end

                if (!rst_n) begin
                    acc_r <= {ACC_BITS{1'b0}};
                end else if (v4) begin
                    if (f4)
                        acc_r <= s_ext;
                    else
                        acc_r <= acc_r + s_ext;
                end
            end

            assign acc_flat[f*ACC_BITS +: ACC_BITS] = acc_r;
        end
    endgenerate

    assign done         = l5;
    assign done_profile = p5;

endmodule