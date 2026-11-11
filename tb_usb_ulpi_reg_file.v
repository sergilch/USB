//-----------------------------------------------------------------------------
// tb_usb_ulpi_reg_file.v - self-checking testbench for usb_ulpi_reg_file
//
// Run (Icarus Verilog):
//   iverilog -g2005 -o sim_rf usb_ulpi_reg_file.v tb_usb_ulpi_reg_file.v
//   vvp sim_rf
//
// Two kinds of checks:
//   * Directed tests against hard-coded expectations: reset values of all registers, the
//     SET / CLEAR aliases, reserved bits, read-only registers (ID, status, latch, debug),
//     unmapped addresses, the vendor range 30h-3Fh (routed to a stub slave: write
//     strobe / address / data, read data, also through the extended mirror, and
//     nothing outside 30h-3Fh), the extended set (00h-3Fh mirror the immediate set), the
//     self-clearing Reset bit with its one-tick soft_reset pulse, the configuration
//     outputs and the interrupt latch (enabled / masked edges, clear on read).  They run
//     with ce = 1 always and with ce = 1 tick in 8.
//   * Random lockstep test: random reads / writes / status changes (ce always, one in 8,
//     random 50 %) against an independently written reference model; the read answer
//     (rd_valid = reg_rd, reg_rdata) is checked in the read tick itself; after every tick
//     soft_reset and all configuration outputs must match.
//-----------------------------------------------------------------------------
`timescale 1ns/1ps

module tb_usb_ulpi_reg_file;

    reg clk = 1'b0;
    always #5 clk = ~clk;

    reg rst_n;
    reg ce = 1'b1;

    reg        reg_wr = 1'b0, reg_rd = 1'b0, reg_ext = 1'b0;
    reg [7:0]  reg_addr = 8'd0, reg_wdata = 8'd0;
    wire [7:0] reg_rdata;
    wire       rd_valid;

    reg        host_disc = 1'b0, a_vbus_vld = 1'b0, sess_vld = 1'b0, sess_end = 1'b0, id_gnd = 1'b0;
    reg [1:0]  linestate = 2'd0;

    wire [1:0] xcvrselect;
    wire       termselect, suspendm, soft_reset;
    wire [1:0] opmode;
    wire [7:0] ifc_ctrl, otg_ctrl;
    wire [4:0] ie_rise, ie_fall;

    // vendor slave stub: a distinct value per address, writes are checked per tick
    wire       vnd_wr;
    wire [3:0] vnd_addr;
    wire [7:0] vnd_wdata;
    function [7:0] vstub(input [3:0] a); vstub = {~a, a} ^ 8'h5A; endfunction
    wire [7:0] vnd_rdata = vstub(vnd_addr);

    usb_ulpi_reg_file dut (
        .clk        (clk),
        .rst_n      (rst_n),
        .ce         (ce),
        .reg_wr     (reg_wr),
        .reg_rd     (reg_rd),
        .reg_ext    (reg_ext),
        .reg_addr   (reg_addr),
        .reg_wdata  (reg_wdata),
        .reg_rdata  (reg_rdata),
        .rd_valid   (rd_valid),
        .host_disc  (host_disc),
        .a_vbus_vld (a_vbus_vld),
        .sess_vld   (sess_vld),
        .sess_end   (sess_end),
        .id_gnd     (id_gnd),
        .linestate  (linestate),
        .xcvrselect (xcvrselect),
        .termselect (termselect),
        .opmode     (opmode),
        .suspendm   (suspendm),
        .soft_reset (soft_reset),
        .ifc_ctrl   (ifc_ctrl),
        .otg_ctrl   (otg_ctrl),
        .ie_rise    (ie_rise),
        .ie_fall    (ie_fall),
        .vnd_wr     (vnd_wr),
        .vnd_addr   (vnd_addr),
        .vnd_wdata  (vnd_wdata),
        .vnd_rdata  (vnd_rdata)
    );
    integer vnd_writes = 0;

    integer errors  = 0;
    integer ce_mode = 0;
    integer ce_ph   = 0;
    integer seed_ce = 32'h13579BDF;
    integer seed    = 32'h2468ACE0;

    always @(negedge clk) begin
        case (ce_mode)
            0: ce <= 1'b1;
            1: begin
                   ce    <= (ce_ph == 7);
                   ce_ph <= (ce_ph + 1) % 8;
               end
            default: ce <= (({$random(seed_ce)} % 2) == 1);
        endcase
    end

    // ---------------- soft_reset pulse counter ----------------
    integer soft_cnt = 0;
    always @(posedge clk) if (rst_n && ce && soft_reset) soft_cnt = soft_cnt + 1;

    // ---------------- reference model (lockstep) ----------------
    reg [7:0] m_fc, m_ic, m_otg, m_ier, m_ief, m_scr;
    reg       m_rst;
    reg [4:0] m_p0, m_p1, m_p2, m_latch;
    reg [1:0] m_l0, m_l1;
    reg       model_on = 1'b0;

    reg [7:0] mv, mnew, mcur, mmask;
    reg [4:0] mev;
    integer   mb, mbase, mkind;

    function integer grp_base(input [7:0] a);        // base address of the RW group, -1 if none
        begin
            if      (a >= 8'h04 && a <= 8'h06) grp_base = 8'h04;
            else if (a >= 8'h07 && a <= 8'h09) grp_base = 8'h07;
            else if (a >= 8'h0A && a <= 8'h0C) grp_base = 8'h0A;
            else if (a >= 8'h0D && a <= 8'h0F) grp_base = 8'h0D;
            else if (a >= 8'h10 && a <= 8'h12) grp_base = 8'h10;
            else if (a >= 8'h16 && a <= 8'h18) grp_base = 8'h16;
            else                               grp_base = -1;
        end
    endfunction

    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            m_fc = 8'h45; m_ic = 8'h00; m_otg = 8'h06; m_ier = 8'h1F; m_ief = 8'h1F; m_scr = 8'h00;
            m_rst = 1'b0; m_p0 = 5'd0; m_p1 = 5'd0; m_p2 = 5'd0; m_l0 = 2'd0; m_l1 = 2'd0;
            m_latch = 5'd0;
        end else if (ce) begin
            // events of this tick
            mev = 5'd0;
            for (mb = 0; mb < 5; mb = mb + 1) begin
                if (m_p1[mb] && !m_p2[mb] && m_ier[mb]) mev[mb] = 1'b1;
                if (!m_p1[mb] && m_p2[mb] && m_ief[mb]) mev[mb] = 1'b1;
            end
            // value that a read of this tick returns
            mv    = 8'h00;
            mbase = grp_base(reg_addr);
            if (!reg_ext || (reg_addr[7:6] == 2'b00)) begin
                case (reg_addr)
                    8'h00: mv = 8'h24;
                    8'h01: mv = 8'h04;
                    8'h02: mv = 8'h07;
                    8'h03: mv = 8'h00;
                    8'h13: mv = {3'b000, m_p1};
                    8'h14: mv = {3'b000, m_latch};
                    8'h15: mv = {6'b000000, m_l1};
                    8'h30, 8'h31, 8'h32, 8'h33, 8'h34, 8'h35, 8'h36, 8'h37,
                    8'h38, 8'h39, 8'h3A, 8'h3B, 8'h3C, 8'h3D, 8'h3E, 8'h3F:
                           mv = vstub(reg_addr[3:0]);
                    default: begin
                        case (mbase)
                            8'h04:   mv = m_fc | (m_rst ? 8'h20 : 8'h00);
                            8'h07:   mv = m_ic;
                            8'h0A:   mv = m_otg;
                            8'h0D:   mv = m_ier;
                            8'h10:   mv = m_ief;
                            8'h16:   mv = m_scr;
                            default: mv = 8'h00;
                        endcase
                    end
                endcase
            end
            // write
            m_rst = 1'b0;
            if (reg_wr && (!reg_ext || (reg_addr[7:6] == 2'b00)) && (mbase >= 0)) begin
                mkind = reg_addr - mbase;
                case (mbase)
                    8'h04:   begin mcur = m_fc;  mmask = 8'h5F; end
                    8'h07:   begin mcur = m_ic;  mmask = 8'hFF; end
                    8'h0A:   begin mcur = m_otg; mmask = 8'hFF; end
                    8'h0D:   begin mcur = m_ier; mmask = 8'h1F; end
                    8'h10:   begin mcur = m_ief; mmask = 8'h1F; end
                    default: begin mcur = m_scr; mmask = 8'hFF; end
                endcase
                case (mkind)
                    0:       mnew = reg_wdata & mmask;
                    1:       mnew = (mcur | reg_wdata) & mmask;
                    default: mnew = mcur & ~reg_wdata;
                endcase
                case (mbase)
                    8'h04:   begin m_fc = mnew; if ((mkind != 2) && reg_wdata[5]) m_rst = 1'b1; end
                    8'h07:   m_ic  = mnew;
                    8'h0A:   m_otg = mnew;
                    8'h0D:   m_ier = mnew;
                    8'h10:   m_ief = mnew;
                    default: m_scr = mnew;
                endcase
            end
            // latch (an event wins over the clear on read), synchronizer, read answer
            m_latch = ((reg_rd && (!reg_ext || (reg_addr[7:6] == 2'b00)) && (reg_addr == 8'h14)) ? 5'd0 : m_latch) | mev;
            m_p2 = m_p1;
            m_p1 = m_p0;
            m_p0 = {id_gnd, sess_end, sess_vld, a_vbus_vld, host_disc};
            m_l1 = m_l0;
            m_l0 = linestate;
            // the read answer is combinational: compare it in the read tick itself
            // (pre-edge values; the DUT registers update after this block)
            if (rst_n && model_on) begin
                if (vnd_wr !== (reg_wr && (!reg_ext || (reg_addr[7:6] == 2'b00)) && (reg_addr[7:4] == 4'h3))) begin
                    errors = errors + 1;
                    $display("ERROR @%0t: vnd_wr = %b for wr %b ext %b addr %02h", $time, vnd_wr, reg_wr, reg_ext, reg_addr);
                end else if (vnd_wr) begin
                    vnd_writes = vnd_writes + 1;
                    if (vnd_addr !== reg_addr[3:0] || vnd_wdata !== reg_wdata) begin
                        errors = errors + 1;
                        $display("ERROR @%0t: vendor write addr %h data %02h, expected %h %02h", $time, vnd_addr, vnd_wdata, reg_addr[3:0], reg_wdata);
                    end
                end
                if (rd_valid !== reg_rd) begin
                    errors = errors + 1;
                    $display("ERROR @%0t: rd_valid = %b, reg_rd = %b (same-tick answer expected)", $time, rd_valid, reg_rd);
                end
                if (reg_rd && (reg_rdata !== mv)) begin
                    errors = errors + 1;
                    $display("ERROR @%0t: reg_rdata = %02h, model %02h", $time, reg_rdata, mv);
                end
            end
            model_on = 1'b1;
        end
    end

    // lockstep comparison, settled values at the falling edge
    integer lock_checks = 0;
    always @(negedge clk) begin
        if (rst_n && model_on) begin
            lock_checks = lock_checks + 1;
            if ((xcvrselect !== m_fc[1:0]) || (termselect !== m_fc[2]) || (opmode !== m_fc[4:3]) ||
                (suspendm !== m_fc[6]) || (soft_reset !== m_rst)) begin
                errors = errors + 1;
                $display("ERROR @%0t: Function Control outputs differ from the model (fc=%02h)", $time, m_fc);
            end
            if ((ifc_ctrl !== m_ic) || (otg_ctrl !== m_otg) || (ie_rise !== m_ier[4:0]) || (ie_fall !== m_ief[4:0])) begin
                errors = errors + 1;
                $display("ERROR @%0t: configuration outputs differ from the model", $time);
            end
        end
    end

    // ---------------- directed access tasks ----------------
    // One-tick pulse: applied at a falling edge, sampled by the next ce edge, removed afterwards.
    // p_rdv / p_rdata: the read answer at that edge (same-tick answer, pre-edge values).
    reg       p_rdv;
    reg [7:0] p_rdata;
    task pulse(input wr, input rd, input ext, input [7:0] addr, input [7:0] wdata);
        begin
            @(negedge clk);
            reg_wr    = wr;
            reg_rd    = rd;
            reg_ext   = ext;
            reg_addr  = addr;
            reg_wdata = wdata;
            @(posedge clk);
            while (!ce) @(posedge clk);
            p_rdv   = rd_valid;
            p_rdata = reg_rdata;
            @(negedge clk);
            reg_wr = 1'b0;
            reg_rd = 1'b0;
        end
    endtask

    task wr_reg(input [7:0] addr, input [7:0] d);
        begin
            pulse(1'b1, 1'b0, 1'b0, addr, d);
        end
    endtask

    task wr_ext(input [7:0] addr, input [7:0] d);
        begin
            pulse(1'b1, 1'b0, 1'b1, addr, d);
        end
    endtask

    // read and compare; the answer is valid in the read tick itself (same-tick answer)
    task rd_chk(input ext, input [7:0] addr, input [7:0] expected);
        begin
            pulse(1'b0, 1'b1, ext, addr, 8'h00);
            if (p_rdv !== 1'b1) begin
                errors = errors + 1;
                $display("ERROR @%0t: no rd_valid in the tick of a read of %s%02h", $time, ext ? "ext " : "", addr);
            end
            if (p_rdata !== expected) begin
                errors = errors + 1;
                $display("ERROR @%0t: read %s%02h = %02h, expected %02h", $time, ext ? "ext " : "", addr, p_rdata, expected);
            end
        end
    endtask

    task wait_ticks(input integer n);
        integer k;
        begin
            for (k = 0; k < n; k = k + 1) begin
                @(posedge clk);
                while (!ce) @(posedge clk);
            end
            @(negedge clk);
        end
    endtask

    task set_status(input hd, input vv, input sv, input se, input idg);
        begin
            @(negedge clk);
            host_disc  = hd;
            a_vbus_vld = vv;
            sess_vld   = sv;
            sess_end   = se;
            id_gnd     = idg;
        end
    endtask

    integer sc0;

    task directed;
        integer a;
        begin
            // ---- reset values ----
            rd_chk(0, 8'h00, 8'h24); rd_chk(0, 8'h01, 8'h04); rd_chk(0, 8'h02, 8'h07); rd_chk(0, 8'h03, 8'h00);
            rd_chk(0, 8'h04, 8'h45); rd_chk(0, 8'h05, 8'h45); rd_chk(0, 8'h06, 8'h45);
            rd_chk(0, 8'h07, 8'h00); rd_chk(0, 8'h08, 8'h00); rd_chk(0, 8'h09, 8'h00);
            rd_chk(0, 8'h0A, 8'h06); rd_chk(0, 8'h0B, 8'h06); rd_chk(0, 8'h0C, 8'h06);
            rd_chk(0, 8'h0D, 8'h1F); rd_chk(0, 8'h0E, 8'h1F); rd_chk(0, 8'h0F, 8'h1F);
            rd_chk(0, 8'h10, 8'h1F); rd_chk(0, 8'h11, 8'h1F); rd_chk(0, 8'h12, 8'h1F);
            rd_chk(0, 8'h13, 8'h00); rd_chk(0, 8'h14, 8'h00); rd_chk(0, 8'h15, 8'h00);
            rd_chk(0, 8'h16, 8'h00); rd_chk(0, 8'h17, 8'h00); rd_chk(0, 8'h18, 8'h00);
            rd_chk(0, 8'h19, 8'h00); rd_chk(0, 8'h2F, 8'h00); rd_chk(0, 8'h3F, vstub(4'hF));
            if ((xcvrselect !== 2'b01) || (termselect !== 1'b1) || (opmode !== 2'b00) || (suspendm !== 1'b1) ||
                (ifc_ctrl !== 8'h00) || (otg_ctrl !== 8'h06) || (ie_rise !== 5'h1F) || (ie_fall !== 5'h1F)) begin
                errors = errors + 1;
                $display("ERROR: configuration outputs after reset");
            end

            // ---- scratch register and its aliases ----
            wr_reg(8'h16, 8'hA5);
            rd_chk(0, 8'h16, 8'hA5); rd_chk(0, 8'h17, 8'hA5); rd_chk(0, 8'h18, 8'hA5);
            wr_reg(8'h17, 8'h0F);   rd_chk(0, 8'h16, 8'hAF);          // SET
            wr_reg(8'h18, 8'h81);   rd_chk(0, 8'h16, 8'h2E);          // CLEAR
            wr_reg(8'h16, 8'h00);   wr_reg(8'h17, 8'hFF);   rd_chk(0, 8'h16, 8'hFF);
            wr_reg(8'h18, 8'hF0);   rd_chk(0, 8'h17, 8'h0F);
            wr_reg(8'h16, 8'h00);

            // ---- interface control and OTG control ----
            wr_reg(8'h07, 8'h5A);   rd_chk(0, 8'h07, 8'h5A);
            wr_reg(8'h08, 8'h81);   rd_chk(0, 8'h09, 8'hDB);
            wr_reg(8'h09, 8'hFF);   rd_chk(0, 8'h07, 8'h00);
            wr_reg(8'h0A, 8'h00);   rd_chk(0, 8'h0A, 8'h00);
            wr_reg(8'h0B, 8'hFF);   rd_chk(0, 8'h0C, 8'hFF);
            wr_reg(8'h0C, 8'h01);   rd_chk(0, 8'h0A, 8'hFE);
            wr_reg(8'h07, 8'hA7);   wr_reg(8'h0A, 8'h3C);
            wait_ticks(1);
            if ((ifc_ctrl !== 8'hA7) || (otg_ctrl !== 8'h3C)) begin
                errors = errors + 1;
                $display("ERROR: ifc_ctrl / otg_ctrl outputs (%02h / %02h)", ifc_ctrl, otg_ctrl);
            end
            wr_reg(8'h07, 8'h00);   wr_reg(8'h0A, 8'h06);

            // ---- interrupt enables: only bits [4:0] exist ----
            wr_reg(8'h0D, 8'hFF);   rd_chk(0, 8'h0D, 8'h1F);
            wr_reg(8'h0F, 8'h0F);   rd_chk(0, 8'h0D, 8'h10);
            wr_reg(8'h0E, 8'h01);   rd_chk(0, 8'h0F, 8'h11);
            wr_reg(8'h10, 8'hE5);   rd_chk(0, 8'h10, 8'h05);
            wr_reg(8'h11, 8'hFF);   rd_chk(0, 8'h12, 8'h1F);
            wr_reg(8'h0D, 8'h00);   wr_reg(8'h10, 8'h00);              // all edges masked

            // ---- Function Control and the self-clearing Reset bit ----
            sc0 = soft_cnt;
            wr_reg(8'h04, 8'h00);   wait_ticks(2);   rd_chk(0, 8'h04, 8'h00);
            wr_reg(8'h05, 8'h06);   wait_ticks(2);   rd_chk(0, 8'h06, 8'h06);
            wr_reg(8'h04, 8'hFF);   wait_ticks(3);                      // bit 7 reserved, Reset requested
            rd_chk(0, 8'h04, 8'h5F);
            if (soft_cnt != sc0 + 1) begin
                errors = errors + 1;
                $display("ERROR: soft_reset pulses after writing Reset = 1: %0d, expected 1", soft_cnt - sc0);
            end
            wr_reg(8'h05, 8'h20);   wait_ticks(3);                      // SET with Reset = 1 requests it again
            if (soft_cnt != sc0 + 2) begin
                errors = errors + 1;
                $display("ERROR: soft_reset pulses after SET of Reset: %0d, expected 2", soft_cnt - sc0);
            end
            wr_reg(8'h06, 8'h20);   wait_ticks(3);                      // CLEAR must not request a reset
            if (soft_cnt != sc0 + 2) begin
                errors = errors + 1;
                $display("ERROR: CLEAR of Reset produced a soft_reset pulse");
            end
            wr_reg(8'h04, 8'h2B);   wait_ticks(3);                      // 0Bh stored, Reset pulse
            rd_chk(0, 8'h04, 8'h0B);
            if ((xcvrselect !== 2'b11) || (termselect !== 1'b0) || (opmode !== 2'b01) || (suspendm !== 1'b0)) begin
                errors = errors + 1;
                $display("ERROR: Function Control outputs for 0Bh");
            end
            wr_reg(8'h04, 8'h45);   wait_ticks(2);
            rd_chk(0, 8'h04, 8'h45);

            // ---- read-only registers ignore writes ----
            for (a = 0; a <= 3; a = a + 1) wr_reg(a, 8'hFF);
            wr_reg(8'h13, 8'hFF); wr_reg(8'h14, 8'hFF); wr_reg(8'h15, 8'hFF);
            rd_chk(0, 8'h00, 8'h24); rd_chk(0, 8'h01, 8'h04); rd_chk(0, 8'h02, 8'h07); rd_chk(0, 8'h03, 8'h00);
            rd_chk(0, 8'h13, 8'h00); rd_chk(0, 8'h14, 8'h00); rd_chk(0, 8'h15, 8'h00);

            // ---- unmapped addresses and the extended set ----
            wr_reg(8'h20, 8'hFF); wr_reg(8'h2F, 8'hFF); wr_reg(8'h19, 8'hFF);
            rd_chk(0, 8'h20, 8'h00); rd_chk(0, 8'h2F, 8'h00); rd_chk(0, 8'h19, 8'h00);
            // vendor range: every address reaches the slave, imm and ext, no aliases
            sc0 = vnd_writes;
            for (a = 8'h30; a <= 8'h3F; a = a + 1) begin
                wr_reg(a, a ^ 8'hC3); rd_chk(0, a, vstub(a)); wr_ext(a, a); rd_chk(1, a, vstub(a));
            end
            wr_ext(8'h70, 8'h11); wr_ext(8'hB3, 8'h22); wr_reg(8'h2F, 8'h33);
            rd_chk(1, 8'h70, 8'h00); rd_chk(1, 8'hF3, 8'h00);
            if (vnd_writes - sc0 != 32) begin
                errors = errors + 1; $display("ERROR: %0d vendor writes, expected 32", vnd_writes - sc0);
            end
            // extended 00h-3Fh mirror the immediate set, 40h-FFh are empty
            wr_ext(8'h16, 8'hA5);  wr_ext(8'h40, 8'hFF);  wr_ext(8'hFF, 8'hFF);
            rd_chk(0, 8'h16, 8'hA5); rd_chk(1, 8'h16, 8'hA5);
            rd_chk(1, 8'h04, 8'h45); rd_chk(1, 8'h00, 8'h24); rd_chk(1, 8'h03, 8'h00);
            rd_chk(1, 8'h40, 8'h00); rd_chk(1, 8'hFF, 8'h00); rd_chk(1, 8'h2F, 8'h00);
            wr_reg(8'h16, 8'h3C);  rd_chk(1, 8'h16, 8'h3C);
            wr_ext(8'h18, 8'h0C);  rd_chk(0, 8'h16, 8'h30);             // ext CLR alias
            wr_reg(8'h16, 8'h00);  rd_chk(1, 8'h16, 8'h00);

            // ---- interrupt status, latch, clear on read ----
            wr_reg(8'h0D, 8'h02);                                       // rising VbusValid only
            wr_reg(8'h10, 8'h00);
            set_status(1'b0, 1'b1, 1'b0, 1'b0, 1'b0);  wait_ticks(5);
            rd_chk(0, 8'h13, 8'h02);                                    // live status
            rd_chk(0, 8'h14, 8'h02);                                    // latched
            rd_chk(0, 8'h14, 8'h00);                                    // cleared by the read
            set_status(1'b0, 1'b0, 1'b0, 1'b0, 1'b0);  wait_ticks(5);   // falling edge: not enabled
            rd_chk(0, 8'h13, 8'h00);
            rd_chk(0, 8'h14, 8'h00);
            wr_reg(8'h10, 8'h02);                                       // falling VbusValid too
            set_status(1'b0, 1'b1, 1'b0, 1'b0, 1'b0);  wait_ticks(5);
            set_status(1'b0, 1'b0, 1'b0, 1'b0, 1'b0);  wait_ticks(5);
            rd_chk(0, 8'h14, 8'h02);                                    // both events in the same bit
            rd_chk(0, 8'h14, 8'h00);
            wr_reg(8'h0D, 8'h1F);  wr_reg(8'h10, 8'h1F);
            set_status(1'b1, 1'b0, 1'b1, 1'b0, 1'b1);  wait_ticks(5);   // HostDisc, SessValid, IdGnd rise
            rd_chk(0, 8'h13, 8'h15);
            rd_chk(0, 8'h14, 8'h15);
            set_status(1'b0, 1'b0, 1'b0, 1'b1, 1'b0);  wait_ticks(5);   // fall of those, SessEnd rises
            rd_chk(0, 8'h14, 8'h1D);
            rd_chk(0, 8'h14, 8'h00);
            linestate = 2'b10;  wait_ticks(5);
            rd_chk(0, 8'h15, 8'h02);                                    // LineState snapshot
            linestate = 2'b00;  wait_ticks(5);
            set_status(1'b0, 1'b0, 1'b0, 1'b0, 1'b0);  wait_ticks(5);
            rd_chk(0, 8'h14, 8'h08);                                    // SessEnd fell (both enabled)
            rd_chk(0, 8'h14, 8'h00);
            wr_reg(8'h0D, 8'h1F);  wr_reg(8'h10, 8'h1F);
        end
    endtask

    // ---------------- random lockstep test ----------------
    task random_run(input integer nticks);
        integer k;
        reg [31:0] r, r2;
        begin
            for (k = 0; k < nticks; k = k + 1) begin
                @(negedge clk);
                r  = $random(seed);
                r2 = $random(seed);
                reg_wr  = 1'b0;
                reg_rd  = 1'b0;
                if (r[7:0] < 8'd90)       reg_wr = 1'b1;
                else if (r[7:0] < 8'd180) reg_rd = 1'b1;
                reg_ext   = (r[11:8] == 4'd0);
                reg_addr  = (r[15:12] == 4'd0) ? r2[7:0] : {3'b000, r2[4:0]} + (r2[5] ? 8'd0 : 8'd0);
                reg_wdata = r2[15:8];
                if (r[19:16] < 4'd5) begin
                    host_disc  = r2[16];
                    a_vbus_vld = r2[17];
                    sess_vld   = r2[18];
                    sess_end   = r2[19];
                    id_gnd     = r2[20];
                end
                if (r[23:20] < 4'd4) linestate = r2[22:21];
                if (r[31:24] < 8'd12) begin                    // keep the interesting registers in play
                    case (r2[26:24] % 4)
                        0: reg_addr = 8'h14;
                        1: reg_addr = 8'h13;
                        2: reg_addr = 8'h30 + r2[30:27];
                        default: reg_addr = 8'h04 + (r2[28:27] % 3);
                    endcase
                end
            end
            @(negedge clk);
            reg_wr = 1'b0;
            reg_rd = 1'b0;
        end
    endtask

    integer cm;

    initial begin
        $dumpfile("tb_usb_ulpi_reg_file.vcd");
        $dumpvars(0, tb_usb_ulpi_reg_file);

        rst_n = 1'b0;
        repeat (4) @(posedge clk);
        @(negedge clk) rst_n = 1'b1;
        repeat (4) @(posedge clk);

        $display("Directed tests, ce = 1");
        ce_mode = 0;
        directed;

        $display("Directed tests after a reset, ce = 1 tick in 8");
        @(negedge clk) rst_n = 1'b0;
        set_status(1'b0, 1'b0, 1'b0, 1'b0, 1'b0);
        linestate = 2'd0;
        repeat (3) @(posedge clk);
        @(negedge clk) rst_n = 1'b1;
        ce_mode = 1;
        repeat (20) @(posedge clk);
        directed;

        for (cm = 0; cm < 3; cm = cm + 1) begin
            $display("Random lockstep test, ce_mode = %0d", cm);
            ce_mode = cm;
            random_run(6000);
        end

        wait_ticks(4);
        $display("--------------------------------------------------");
        $display("Lockstep comparisons: %0d, vendor writes: %0d", lock_checks, vnd_writes);
        if (errors == 0) $display("TEST PASSED");
        else             $display("TEST FAILED: %0d error(s)", errors);
        $display("--------------------------------------------------");
        $finish;
    end

    initial begin
        #50_000_000;
        $display("TEST FAILED: timeout");
        $finish;
    end

endmodule
