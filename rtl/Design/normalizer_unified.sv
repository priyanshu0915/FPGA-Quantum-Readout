// ============================================================================
// normalizer_unified.sv  --  Stage 3 Unified Bit-Shift Normalizer
//
// Exact integer algorithm from freeze_design.py:
//   tmp = clip(acc + 2^n - mu, 0, 2^(n+1))
//   u   = (tmp << F_BITS) >> (n + 1)
//   v   = u - 2^(F_BITS - 1)
//
// Pipeline (5 clock cycles, >= 1.0 ns slack @ 333.3 MHz on 7z045-2):
//   s1: raw_r  = acc + 2^n - mu
//   s2: clip_r = clip(raw_r, 0, 2^(n+1))
//   s3: coarse barrel shift (granularity 8 bits: n[5:3]*8 + 1)
//   s4: mid barrel shift (granularity 2 bits: n[2:1]*2)
//   s5: fine 1-bit shift (n[0]) + subtract 2^(F_BITS - 1)
// ============================================================================
`timescale 1ns / 1ps

module normalizer_unified #(
    parameter integer N_PROFILES = 4,
    parameter integer ACC_BITS   = 37,
    parameter integer F_BITS     = 12,
    parameter         MU_FILE    = "unified_norm_mu_q0.mem",
    parameter         N_FILE     = "unified_norm_n_q0.mem"
) (
    input  wire                          clk,
    input  wire                          rst_n,
    input  wire [1:0]                    profile_sel,
    input  wire                          in_valid,
    input  wire signed [4*ACC_BITS-1:0]  acc_flat,
    output wire                          out_valid,
    output wire [1:0]                    out_profile,
    output wire signed [4*(F_BITS+1)-1:0] v_flat
);

    localparam integer VW = F_BITS + 1;

    (* rom_style = "distributed" *) reg [47:0] mu_rom [0:N_PROFILES*4-1];
    (* rom_style = "distributed" *) reg [7:0]  n_rom  [0:N_PROFILES*4-1];

    initial begin
        $readmemh(MU_FILE, mu_rom);
        $readmemh(N_FILE,  n_rom);
    end

    reg v1, v2, v3, v4, v5;
    reg [1:0] p1, p2, p3, p4, p5;

    always @(posedge clk) begin
        if (!rst_n) begin
            {v1, v2, v3, v4, v5} <= 5'b0;
            {p1, p2, p3, p4, p5} <= 10'b0;
        end else begin
            v1 <= in_valid; p1 <= profile_sel;
            v2 <= v1;       p2 <= p1;
            v3 <= v2;       p3 <= p2;
            v4 <= v3;       p4 <= p3;
            v5 <= v4;       p5 <= p4;
        end
    end

    genvar j;
    generate
        for (j = 0; j < 4; j = j + 1) begin : g_norm
            wire [3:0] bank_in = {profile_sel, j[1:0]};
            wire [3:0] bank_s1 = {p1, j[1:0]};
            wire [3:0] bank_s2 = {p2, j[1:0]};
            wire [3:0] bank_s3 = {p3, j[1:0]};
            wire [3:0] bank_s4 = {p4, j[1:0]};

            wire signed [47:0] acc_ext     = {{(48-ACC_BITS){acc_flat[(j+1)*ACC_BITS-1]}}, acc_flat[j*ACC_BITS +: ACC_BITS]};
            wire signed [47:0] mu_in       = $signed(mu_rom[bank_in]);
            wire [5:0]         n_in        = n_rom[bank_in][5:0];
            wire [5:0]         n_s1        = n_rom[bank_s1][5:0];
            wire [5:0]         n_s2        = n_rom[bank_s2][5:0];
            wire [5:0]         n_s3        = n_rom[bank_s3][5:0];
            wire               n_s4_bit0   = n_rom[bank_s4][0];

            wire signed [48:0] two_pow_n   = 49'sd1 <<< n_in;
            wire signed [48:0] two_pow_np1 = 49'sd1 <<< (n_s1 + 6'd1);

            reg signed [48:0]      raw_r;
            reg        [48:0]      clip_r;
            reg        [48+F_BITS:0] u_s3_r;
            reg        [48+F_BITS:0] u_s4_r;
            reg signed [VW-1:0]    v_r;

            wire [48+F_BITS:0] shifted_in = {{F_BITS{1'b0}}, clip_r} << F_BITS;
            wire [5:0]         sh_s3      = {n_s2[5:3], 3'b000} + 6'd1;
            wire [2:0]         sh_s4      = {n_s3[2:1], 1'b0};
            wire [48+F_BITS:0] u_final    = n_s4_bit0 ? (u_s4_r >> 1) : u_s4_r;

            always @(posedge clk) begin
                // Stage 1: acc + 2^n - mu
                if (in_valid)
                    raw_r <= acc_ext + two_pow_n - mu_in;

                // Stage 2: clip(raw_r, 0, 2^(n+1))
                if (v1) begin
                    if (raw_r < 49'sd0)
                        clip_r <= 49'd0;
                    else if (raw_r > two_pow_np1)
                        clip_r <= two_pow_np1[48:0];
                    else
                        clip_r <= raw_r[48:0];
                end

                // Stage 3: coarse barrel shift (granularity 8 bits)
                if (v2)
                    u_s3_r <= shifted_in >> sh_s3;

                // Stage 4: mid barrel shift (granularity 2 bits)
                if (v3)
                    u_s4_r <= u_s3_r >> sh_s4;

                // Stage 5: fine 1-bit shift + subtract 2^(F_BITS - 1)
                if (v4)
                    v_r <= $signed(u_final[VW-1:0]) - (13'sd1 <<< (F_BITS - 1));
            end

            assign v_flat[j*VW +: VW] = v_r;
        end
    endgenerate

    assign out_valid   = v5;
    assign out_profile = p5;

endmodule