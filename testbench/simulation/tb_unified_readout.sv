// ============================================================================
// tb_unified_readout.sv  --  Mixed-Mode Runtime Reconfiguration Testbench
//
// Streams 100 interleaved shots across all 4 profiles back-to-back:
//   Profile 0: Superconducting Single-Qubit   (T = 500,  mask = 5'b00001)
//   Profile 1: Superconducting 5-Qubit Bus    (T = 500,  mask = 5'b11111)
//   Profile 2: Spin-Qubit Single              (T = 1600, mask = 5'b00001)
//   Profile 3: Spin-Qubit 5-Qubit Bus         (T = 1600, mask = 5'b11111)
//
// Verifies bit-exact predictions and 17-cycle post-pulse latency in every mode.
// ============================================================================
`timescale 1ns / 1ps

module tb_unified_readout;

    // !! SET THESE TO YOUR LOCAL CHECKOUT PATH BEFORE SIMULATING !!
    // e.g. "C:/Users/you/FPGA-Quantum-Readout/constraints/unified/"
    localparam string UNIFIED_DIR = "D:/MSU/Qubit_readout_FPGA/constraints/unified/";
    localparam string GOLDEN_DIR  = "D:/MSU/Qubit_readout_FPGA/constraints/unified/golden/";
    localparam integer N_SHOTS    = 100;
    localparam integer MAX_SAMPS  = 200000;
    localparam real    CLK_PERIOD = 2.0; // 500 MHz

    reg         clk   = 1'b0;
    reg         rst_n = 1'b0;
    reg  [1:0]  trig_profile_sel = 2'b00;
    reg         s_axis_tvalid    = 1'b0;
    reg  [31:0] s_axis_tdata     = 32'd0;
    wire        s_axis_tready;
    wire        m_axis_tvalid;
    wire [7:0]  m_axis_tdata;

    always #(CLK_PERIOD / 2.0) clk = ~clk;

    unified_readout_top #(
        .DIR(UNIFIED_DIR)
    ) dut (
        .clk              (clk),
        .rst_n            (rst_n),
        .trig_profile_sel (trig_profile_sel),
        .soft_override_en (1'b0),
        .soft_profile_sel (2'b00),
        .soft_cfg_T       (13'd0),
        .soft_active_mask (5'd0),
        .s_axis_tvalid    (s_axis_tvalid),
        .s_axis_tready    (s_axis_tready),
        .s_axis_tdata     (s_axis_tdata),
        .m_axis_tvalid    (m_axis_tvalid),
        .m_axis_tdata     (m_axis_tdata)
    );

    reg [15:0] meta_mem [0:N_SHOTS-1];
    reg [31:0] in_mem   [0:MAX_SAMPS-1];
    reg [7:0]  pred_mem [0:N_SHOTS-1];

    integer cyc = 0;
    always @(posedge clk) cyc <= cyc + 1;

    integer shot_idx, t_idx, sample_ptr;
    integer last_sample_cyc;
    integer lat, lat_min = 9999, lat_max = 0;
    integer mismatches = 0;
    integer mode_pass [0:3];
    integer mode_tot  [0:3];

    reg [1:0]  cur_prof;
    reg [12:0] cur_T;
    reg [7:0]  exp_pred;

    initial begin
        $readmemh({GOLDEN_DIR, "tb_mixed_meta.mem"},  meta_mem);
        $readmemh({GOLDEN_DIR, "tb_mixed_input.mem"}, in_mem);
        $readmemh({GOLDEN_DIR, "tb_mixed_pred.mem"},  pred_mem);

        if (^meta_mem[0] === 1'bx) begin
            $fatal(1, "[ERROR] Failed to load tb_mixed_meta.mem! Check GOLDEN_DIR path.");
        end

        for (integer m = 0; m < 4; m = m + 1) begin
            mode_pass[m] = 0;
            mode_tot[m]  = 0;
        end

        repeat (10) @(posedge clk);
        rst_n <= 1'b1;
        repeat (5) @(posedge clk);

        sample_ptr = 0;

        for (shot_idx = 0; shot_idx < N_SHOTS; shot_idx = shot_idx + 1) begin
            cur_prof = meta_mem[shot_idx][14:13];
            cur_T    = meta_mem[shot_idx][12:0];
            exp_pred = pred_mem[shot_idx];
            mode_tot[cur_prof] = mode_tot[cur_prof] + 1;

            for (t_idx = 0; t_idx < cur_T; t_idx = t_idx + 1) begin
                @(posedge clk);
                trig_profile_sel <= cur_prof;
                s_axis_tvalid    <= 1'b1;
                s_axis_tdata     <= in_mem[sample_ptr];
                sample_ptr = sample_ptr + 1;
            end

            @(posedge clk);
            last_sample_cyc = cyc;
            s_axis_tvalid <= 1'b0;
            s_axis_tdata  <= 32'd0;

            while (!m_axis_tvalid) @(posedge clk);
            lat = cyc - last_sample_cyc;
            if (lat < lat_min) lat_min = lat;
            if (lat > lat_max) lat_max = lat;

            if (m_axis_tdata !== exp_pred) begin
                $display("[FAIL] Shot %0d (prof=%0d, T=%0d): got 5'b%05b, expected 5'b%05b",
                         shot_idx, cur_prof, cur_T, m_axis_tdata[4:0], exp_pred[4:0]);
                mismatches = mismatches + 1;
            end else begin
                mode_pass[cur_prof] = mode_pass[cur_prof] + 1;
            end

            repeat (5) @(posedge clk);
        end

        $display("\n=======================================================");
        $display(" UNIFIED MULTI-MODE READOUT VERIFICATION SUMMARY");
        $display("=======================================================");
        $display(" Profile 0 (SC Single)   : %0d / %0d PASS", mode_pass[0], mode_tot[0]);
        $display(" Profile 1 (SC 5-Qubit)  : %0d / %0d PASS", mode_pass[1], mode_tot[1]);
        $display(" Profile 2 (Spin Single) : %0d / %0d PASS", mode_pass[2], mode_tot[2]);
        $display(" Profile 3 (Spin 5-Qubit): %0d / %0d PASS", mode_pass[3], mode_tot[3]);
        $display(" Post-pulse latency      : %0d .. %0d cycles (expected 17)", lat_min, lat_max);
        $display(" Total mismatches        : %0d", mismatches);
        if (mismatches == 0 && lat_min == 17 && lat_max == 17)
            $display(" OVERALL RESULT          : PASS");
        else
            $display(" OVERALL RESULT          : FAIL");
        $display("=======================================================\n");
        $finish;
    end

endmodule