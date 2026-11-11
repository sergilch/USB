//-----------------------------------------------------------------------------
// tb_usb_ulpi_phy_pads.v - register read / write testbench for usb_ulpi_phy_pads
// (usb_ulpi_phy_top behind the BBSUD8F digital pads)
//
// Run (Icarus Verilog), with the pull-up / pull-down model of the pads (recommended):
//   iverilog -g2005 -DDISPLAY_PD_PU_EN -o sim_pads X-FAB/VLG_PRIMITIVES.v X-FAB/BBSUD8F.v \
//            usb_ulpi_input_capture.v usb_ulpi_bus_owner.v usb_ulpi_reg_access.v \
//            usb_ulpi_burst_mux.v usb_tx_holding.v usb_tx_sync_mux.v usb_bit_stuffer.v \
//            usb_nrzi_encoder.v usb_tx_serializer.v usb_tx_path.v usb_tx_datapath.v \
//            usb_ulpi_core.v usb_ulpi_rx_handler.v usb_ulpi_rxcmd_gen.v \
//            usb_ulpi_out_arbiter.v usb_ulpi_rx_path.v usb_ulpi_phy_if.v \
//            usb_ulpi_reg_file.v usb_mode_term_ctrl.v usb_ulpi_phy_top.v usb_ulpi_phy_pads.v \
//            tb_usb_ulpi_phy_pads.v
//   vvp sim_pads
// Without -DDISPLAY_PD_PU_EN the pads do not model their pulls: the test runs the same,
// the bus floats (X) in turnaround cycles and the pull checks are skipped.
//
// Clocks: clk_bit 480 MHz, ce60 one cycle in eight, clk60 (to the CLK pad) rises half a
// clk_bit cycle before the clk_bit edge on which the core samples (ce60 = 1).  So the
// core launches its outputs ~1 ns after the CLK pin edge, like a PHY clock-to-out, and
// the Link model, clocked by the CLK pin, drives its outputs 2 ns after that edge
// (hold time > the 1 ns sampling offset of the core).
//
// The ULPI Link model works only on the chip pins (PAD_*): it samples DIR / NXT / DATA
// on the rising edge of PAD_ULPI_CLK, releases DATA combinationally while DIR = 1, holds
// every byte until NXT, retries a command that loses against DIR, and flags protocol
// errors (DIR inside a transfer, NXT with nothing on the bus, RX data bytes, missing
// read data).  It runs the register commands
//   RegWrite (80h | a) data STP,  extended write AFh addr data STP,
//   RegRead  (C0h | a) -> turnaround -> data,  extended read EFh addr -> data,
// and holds the PHY to the read timing of ULPI 1.1 Fig. 22 / 30: the NXT that consumes
// the last byte (command or address) in cycle N, turnaround in N+1, the data in N+2,
// DIR low in N+3.
// Checked
//   * every read returns what a shadow model of the register map predicts (reset values,
//     write / SET / CLR aliases, reserved bits, RO registers, unmapped and extended
//     addresses, the extended mirror of 00h-3Fh, status / latch / debug from the status
//     inputs); data and addresses are often bytes that look like commands;
//   * the configuration outputs follow the shadow model; soft_reset pulses once per
//     write of Function Control with Reset = 1; the ULPI writes land in the one register
//     file of the design (u_core.u_rf);
//   * ALT_INT toggles in the background of the random phase, so RXCMDs collide with
//     Link commands (the Link must retry, at least once);
//   * every RXCMD seen at the pins carries the current LineState / VbusState / ID /
//     ALT_INT / HostDisconnect once the status inputs are stable;
//   * pads: DIR / NXT / CLK / DATA pins equal the core outputs, DATA / STP inputs reach
//     the core, the NAND-tree output equals the NAND chain of the pin levels, the Link and
//     the PHY never drive DATA at the same time, and (with DISPLAY_PD_PU_EN) STP is pulled
//     up and DATA down while Interface Protect Disable = 0, and both float when it is 1;
//   * ULPI holding state (ULPI 1.1 section 3.12): with STP high while the Link idles
//     (driven high with command-like bytes on DATA, held high after a register write,
//     or pulled up while the Link is tri-stated) no command is taken and DIR / NXT stay
//     low; status changes meanwhile produce exactly one RXCMD when STP falls;
//   * RESETB: asynchronous reset of the core, release two clk_bit edges after the pin,
//     all registers back at their reset values.
//-----------------------------------------------------------------------------
`timescale 1ns/1ps

module tb_usb_ulpi_phy_pads;

    parameter real    HALF = 1.042;          // ~480 MHz
    parameter real    TCO  = 2.0;            // Link clock-to-out after the CLK pin edge
    parameter integer NRAND = 600;           // random register operations

    // ---------------- clocks ----------------
    reg clk_bit = 1'b0;
    always #(HALF) clk_bit = ~clk_bit;

    reg [2:0] ce_cnt = 3'd0;                 // free running (PLL side, not reset)
    always @(posedge clk_bit) ce_cnt <= ce_cnt + 3'd1;
    wire ce60 = (ce_cnt == 3'd7);

    reg clk60 = 1'b0;
    always @(negedge clk_bit) begin
        if (ce_cnt == 3'd7)      clk60 <= 1'b1;
        else if (ce_cnt == 3'd3) clk60 <= 1'b0;
    end

    // ---------------- pins ----------------
    wire       PAD_ULPI_CLK, PAD_ULPI_DIR, PAD_ULPI_NXT, PAD_ULPI_STP, PAD_RESETB;
    wire [7:0] PAD_ULPI_DATA;

    reg        resetb     = 1'b0;
    reg  [7:0] lk_data    = 8'h00;
    reg        lk_stp     = 1'b0;
    reg        lk_drv     = 1'b1;           // Link drives DATA (while DIR = 0)
    reg        lk_stp_drv = 1'b1;           // Link drives STP
    wire       lk_drv_eff = lk_drv && (PAD_ULPI_DIR === 1'b0);

    assign PAD_RESETB    = resetb;
    assign PAD_ULPI_DATA = lk_drv_eff ? lk_data : 8'hzz;
    assign PAD_ULPI_STP  = lk_stp_drv ? lk_stp : 1'bz;

    // ---------------- on-chip side ----------------
    reg  [1:0] linestate = 2'b00;
    reg        host_disc = 1'b0, a_vbus_vld = 1'b0, sess_vld = 1'b0, sess_end = 1'b1;
    reg        id_gnd = 1'b0, alt_int = 1'b0;

    wire       core_rst_n;
    wire [1:0] xcvrselect, opmode, cfg_speed, tx_speed;
    wire       termselect, suspendm, soft_reset, cfg_bypass;
    wire [7:0] ifc_ctrl, otg_ctrl;
    wire       txd, tx_en, tx_se0, busy, tx_done, tx_underrun, rx_active, rx_err, rx_overrun;
    wire       nand_tree_out;

    usb_ulpi_phy_pads dut (
        .PAD_ULPI_CLK  (PAD_ULPI_CLK),
        .PAD_ULPI_DATA (PAD_ULPI_DATA),
        .PAD_ULPI_DIR  (PAD_ULPI_DIR),
        .PAD_ULPI_NXT  (PAD_ULPI_NXT),
        .PAD_ULPI_STP  (PAD_ULPI_STP),
        .PAD_RESETB    (PAD_RESETB),
        .clk_bit       (clk_bit),
        .ce60          (ce60),
        .clk60         (clk60),
        .core_rst_n    (core_rst_n),
        .rx_start      (1'b0),
        .rx_valid      (1'b0),
        .rx_data       (8'h00),
        .rx_end        (1'b0),
        .rx_error      (1'b0),
        .linestate     (linestate),
        .host_disc     (host_disc),
        .a_vbus_vld    (a_vbus_vld),
        .sess_vld      (sess_vld),
        .sess_end      (sess_end),
        .id_gnd        (id_gnd),
        .alt_int       (alt_int),
        .dir_hold      (1'b0),
        .xcvrselect    (xcvrselect),
        .termselect    (termselect),
        .opmode        (opmode),
        .suspendm      (suspendm),
        .soft_reset    (soft_reset),
        .ifc_ctrl      (ifc_ctrl),
        .otg_ctrl      (otg_ctrl),
        .cfg_speed     (cfg_speed),
        .cfg_bypass    (cfg_bypass),
        .txd           (txd),
        .tx_en         (tx_en),
        .tx_se0        (tx_se0),
        .tx_speed      (tx_speed),
        .busy          (busy),
        .tx_done       (tx_done),
        .tx_underrun   (tx_underrun),
        .rx_active     (rx_active),
        .rx_err        (rx_err),
        .rx_overrun    (rx_overrun),
        .nand_tree_out (nand_tree_out)
    );

    integer errors = 0;
    integer seed   = 32'h0BAD_F00D;

    // ---------------- shadow model of the register map ----------------
    reg [7:0] sh_fc, sh_ic, sh_otg, sh_ier, sh_ief, sh_scr;
    reg [4:0] sh_latch;
    integer   exp_soft_reset = 0;

    task sh_reset;
        begin
            sh_fc = 8'h45; sh_ic = 8'h00; sh_otg = 8'h06;
            sh_ier = 8'h1F; sh_ief = 8'h1F; sh_scr = 8'h00;
            // the status synchronizer starts from 0 after reset: every status input that
            // is 1 makes a rising edge, and all rising edges are enabled at reset
            sh_latch = {id_gnd, sess_end, sess_vld, a_vbus_vld, host_disc};
        end
    endtask

    function [4:0] stat_now;
        input dummy;
        stat_now = {id_gnd, sess_end, sess_vld, a_vbus_vld, host_disc};
    endfunction

    // effective immediate address of an access, -1 = not in the immediate set
    function integer imm_addr;
        input ext;
        input [7:0] a;
        imm_addr = (!ext || (a[7:6] == 2'b00)) ? a : -1;
    endfunction

    function [7:0] sh_read;
        input ext;
        input [7:0] a;
        integer m;
        begin
            m = imm_addr(ext, a);
            sh_read = 8'h00;
            if (m >= 0) begin
                case (m)
                    8'h00: sh_read = 8'h24;
                    8'h01: sh_read = 8'h04;
                    8'h02: sh_read = 8'h07;
                    8'h03: sh_read = 8'h00;
                    8'h04, 8'h05, 8'h06: sh_read = sh_fc;
                    8'h07, 8'h08, 8'h09: sh_read = sh_ic;
                    8'h0A, 8'h0B, 8'h0C: sh_read = sh_otg;
                    8'h0D, 8'h0E, 8'h0F: sh_read = sh_ier;
                    8'h10, 8'h11, 8'h12: sh_read = sh_ief;
                    8'h13: sh_read = {3'b000, stat_now(0)};
                    8'h14: sh_read = {3'b000, sh_latch};
                    8'h15: sh_read = {6'b000000, linestate};
                    8'h16, 8'h17, 8'h18: sh_read = sh_scr;
                    default: sh_read = 8'h00;
                endcase
            end
        end
    endfunction

    function [7:0] upd;
        input [7:0] q, w, mask;
        input integer op;                    // 0 write, 1 set, 2 clear
        case (op)
            0:       upd = w & mask;
            1:       upd = (q | w) & mask;
            default: upd = q & ~w;
        endcase
    endfunction

    task sh_write(input ext, input [7:0] a, input [7:0] d);
        integer m;
        begin
            m = imm_addr(ext, a);
            if (m >= 8'h04 && m <= 8'h06) begin
                sh_fc = upd(sh_fc, d, 8'h5F, m - 8'h04);
                if ((m != 8'h06) && d[5]) exp_soft_reset = exp_soft_reset + 1;
            end
            if (m >= 8'h07 && m <= 8'h09) sh_ic  = upd(sh_ic,  d, 8'hFF, m - 8'h07);
            if (m >= 8'h0A && m <= 8'h0C) sh_otg = upd(sh_otg, d, 8'hFF, m - 8'h0A);
            if (m >= 8'h0D && m <= 8'h0F) sh_ier = upd(sh_ier, d, 8'h1F, m - 8'h0D);
            if (m >= 8'h10 && m <= 8'h12) sh_ief = upd(sh_ief, d, 8'h1F, m - 8'h10);
            if (m >= 8'h16 && m <= 8'h18) sh_scr = upd(sh_scr, d, 8'hFF, m - 8'h16);
        end
    endtask

    // ---------------- ULPI Link model (pins only) ----------------
    localparam L_IDLE = 0, L_CMD = 1, L_ADDR = 2, L_DATA = 3, L_STP = 4, L_WRD = 5;
    localparam OP_WR = 0, OP_WX = 1, OP_RD = 2, OP_RX = 3;

    integer   lk_state  = L_IDLE;
    integer   op_type   = 0;
    reg [7:0] op_addr   = 8'h00;
    reg [7:0] op_wdata  = 8'h00;
    reg [7:0] op_rdata  = 8'h00;
    integer   op_issued = 0;
    integer   op_done   = 0;
    integer   rd_phase  = 0;                 // 0 wait for DIR, 1 turnaround seen, 2 data taken
    integer   rd_wait   = 0;
    integer   rd_t      = 0;                 // CLK periods since the NXT that ended a read
    integer   retries   = 0;
    integer   rxcmds    = 0;
    integer   rxcmds_chk = 0;
    integer   stat_age  = 0;                 // CLK periods since the last status change
    reg       s_dir, s_nxt, p_dir = 1'b0;

    // ULPI holding state (ULPI 1.1 section 3.12): hold_mode makes the Link drive STP high
    // (and command-like bytes on DATA) while idle; a released STP (pull-up) also counts
    reg       hold_mode = 1'b0;
    integer   hold_k    = 0;
    integer   hold_cnt  = 0;                 // CLK periods with STP high while the Link idles
    integer   hold_cyc  = 0;                 // total, for the report
    integer   hold_viol = 0;
    reg [7:0] s_data;
    reg [7:0] exp_rxcmd;

    // bytes that the PHY must not interpret while STP is high
    function [7:0] hold_pat;
        input integer k;
        case (k % 7)
            0: hold_pat = 8'h96;  1: hold_pat = 8'hFF;  2: hold_pat = 8'hD6;  3: hold_pat = 8'h41;
            4: hold_pat = 8'hAF;  5: hold_pat = 8'h16;  default: hold_pat = 8'hEF;
        endcase
    endfunction

    function [7:0] cmd_of;
        input integer t;
        input [7:0] a;
        case (t)
            OP_WR:   cmd_of = {2'b10, a[5:0]};
            OP_WX:   cmd_of = 8'hAF;
            OP_RD:   cmd_of = {2'b11, a[5:0]};
            default: cmd_of = 8'hEF;
        endcase
    endfunction

    always @(posedge PAD_ULPI_CLK) begin
        s_dir  = PAD_ULPI_DIR;
        s_nxt  = PAD_ULPI_NXT;
        s_data = PAD_ULPI_DATA;
        stat_age = stat_age + 1;

        // strict read timing (ULPI 1.1 Fig. 22 / 30): NXT for the last byte in cycle N,
        // turnaround in N+1, the data in N+2, DIR low in N+3
        if (resetb && core_rst_n && (lk_state == L_WRD)) begin
            rd_t = rd_t + 1;
            if ((rd_t == 1) && !((s_dir === 1'b1) && !p_dir)) begin
                errors = errors + 1;
                $display("ERROR @%0t: DIR = %b in the cycle after the read NXT, expected the turnaround", $time, s_dir);
            end
            if ((rd_t == 2) && !((s_dir === 1'b1) && p_dir)) begin
                errors = errors + 1;
                $display("ERROR @%0t: no read data in the second cycle after the read NXT", $time);
            end
            if ((rd_t == 3) && (s_dir !== 1'b0)) begin
                errors = errors + 1;
                $display("ERROR @%0t: DIR still high in the third cycle after the read NXT", $time);
            end
        end

        // holding state: no DIR, no NXT once STP has been high for two cycles
        if (resetb && core_rst_n && (lk_state == L_IDLE) && (PAD_ULPI_STP === 1'b1) &&
            (hold_mode || !lk_stp_drv)) begin
            hold_cnt = hold_cnt + 1;
            hold_cyc = hold_cyc + 1;
            if ((hold_cnt > 2) && ((s_dir !== 1'b0) || (s_nxt !== 1'b0) || (tx_en !== 1'b0))) begin
                errors = errors + 1;
                hold_viol = hold_viol + 1;
                $display("ERROR @%0t: holding state (STP high): DIR %b NXT %b tx_en %b", $time, s_dir, s_nxt, tx_en);
            end
        end else begin
            hold_cnt = 0;
        end

        if (!resetb || !core_rst_n) begin
            lk_state = L_IDLE;
            lk_data <= #(TCO) 8'h00;
            lk_stp  <= #(TCO) 1'b0;
        end else if (s_dir === 1'b1) begin
            // ---- the PHY owns the bus ----
            if (p_dir) begin                                       // a byte driven by the PHY
                if ((lk_state == L_WRD) && (rd_phase == 1)) begin
                    if (s_nxt !== 1'b0) begin
                        errors = errors + 1;
                        $display("ERROR @%0t: NXT = %b with the register read data", $time, s_nxt);
                    end
                    op_rdata = s_data;
                    rd_phase = 2;
                end else begin
                    rxcmds = rxcmds + 1;
                    if (s_nxt !== 1'b0) begin
                        errors = errors + 1;
                        $display("ERROR @%0t: RX data byte %02h at the pins, no packet was received", $time, s_data);
                    end
                    if (stat_age > 3) begin
                        exp_rxcmd = {alt_int, id_gnd, (host_disc ? 2'b10 : 2'b00),
                                     (a_vbus_vld ? 2'b11 : sess_vld ? 2'b10 : sess_end ? 2'b00 : 2'b01),
                                     linestate};
                        rxcmds_chk = rxcmds_chk + 1;
                        if (s_data !== exp_rxcmd) begin
                            errors = errors + 1;
                            $display("ERROR @%0t: RXCMD %02h, expected %02h", $time, s_data, exp_rxcmd);
                        end
                    end
                end
            end else if ((lk_state == L_WRD) && (rd_phase == 0)) begin
                rd_phase = 1;                                      // turnaround of the read
            end
            case (lk_state)
                L_CMD: begin                                       // PHY won: retry later
                    lk_state = L_IDLE;
                    retries  = retries + 1;
                end
                L_ADDR, L_DATA, L_STP: begin
                    errors = errors + 1;
                    $display("ERROR @%0t: DIR rose inside a register transfer (state %0d)", $time, lk_state);
                    lk_state = L_IDLE;
                end
                default: ;
            endcase
            lk_data <= #(TCO) 8'h00;
            lk_stp  <= #(TCO) 1'b0;
        end else begin
            // ---- the Link owns the bus ----
            if (s_dir !== 1'b0) begin
                errors = errors + 1;
                $display("ERROR @%0t: DIR = %b", $time, s_dir);
            end
            if ((s_nxt === 1'b1) && !p_dir && ((lk_state == L_IDLE) || (lk_state == L_WRD))) begin
                errors = errors + 1;
                $display("ERROR @%0t: NXT high while the Link has nothing on the bus", $time);
            end
            if (s_nxt !== 1'b0 && s_nxt !== 1'b1) begin
                errors = errors + 1;
                $display("ERROR @%0t: NXT = %b", $time, s_nxt);
            end
            case (lk_state)
                L_IDLE: begin
                    lk_data <= #(TCO) 8'h00;
                    lk_stp  <= #(TCO) 1'b0;
                    if (op_issued != op_done) begin
                        lk_data <= #(TCO) cmd_of(op_type, op_addr);
                        lk_state = L_CMD;
                    end else if (hold_mode) begin
                        lk_stp  <= #(TCO) 1'b1;
                        lk_data <= #(TCO) hold_pat(hold_k);
                        hold_k  = hold_k + 1;
                    end
                end
                L_CMD: if (s_nxt === 1'b1) begin
                    case (op_type)
                        OP_WR:   begin lk_data <= #(TCO) op_wdata; lk_state = L_DATA; end
                        OP_RD:   begin lk_data <= #(TCO) 8'h00;    lk_state = L_WRD;
                                       rd_phase = 0; rd_wait = 0; rd_t = 0; end
                        default: begin lk_data <= #(TCO) op_addr;  lk_state = L_ADDR; end
                    endcase
                end
                L_ADDR: if (s_nxt === 1'b1) begin
                    if (op_type == OP_WX) begin
                        lk_data <= #(TCO) op_wdata;
                        lk_state = L_DATA;
                    end else begin
                        lk_data <= #(TCO) 8'h00;
                        lk_state = L_WRD;
                        rd_phase = 0;
                        rd_wait  = 0;
                        rd_t     = 0;
                    end
                end
                L_DATA: if (s_nxt === 1'b1) begin
                    lk_data <= #(TCO) 8'h00;
                    lk_stp  <= #(TCO) 1'b1;
                    lk_state = L_STP;
                end
                L_STP: begin
                    lk_stp  <= #(TCO) hold_mode;   // hold_mode: STP stays high (Fig. 55)
                    lk_state = L_IDLE;
                    op_done  = op_done + 1;
                end
                L_WRD: begin
                    if (rd_phase == 2) begin                       // DIR fell after the data
                        lk_state = L_IDLE;
                        op_done  = op_done + 1;
                    end else if (rd_phase == 1) begin
                        errors = errors + 1;
                        $display("ERROR @%0t: DIR fell without register read data", $time);
                        lk_state = L_IDLE;
                        op_done  = op_done + 1;
                    end else begin
                        rd_wait = rd_wait + 1;
                        if (rd_wait > 40) begin
                            errors = errors + 1;
                            $display("ERROR @%0t: no answer to a register read", $time);
                            lk_state = L_IDLE;
                            op_done  = op_done + 1;
                        end
                    end
                end
                default: lk_state = L_IDLE;
            endcase
        end
        p_dir = (s_dir === 1'b1);
    end

    // ---------------- pad checks (continuous) ----------------
    function [0:0] nand_chain;
        input dummy;
        reg [12:0] p;
        reg        v;
        integer    k;
        begin
            p = {PAD_ULPI_CLK, PAD_ULPI_NXT, PAD_ULPI_DIR, PAD_ULPI_DATA, PAD_RESETB, PAD_ULPI_STP};
            v = 1'b1;
            for (k = 0; k < 13; k = k + 1) v = ~(p[k] & v);
            nand_chain = v;
        end
    endfunction

    integer nand_checks = 0;
    integer pad_checks  = 0;
    always @(negedge clk_bit) begin
        if (resetb && core_rst_n) begin
            pad_checks = pad_checks + 1;
            if ((PAD_ULPI_DIR !== dut.ulpi_dir) || (PAD_ULPI_NXT !== dut.ulpi_nxt) || (PAD_ULPI_CLK !== clk60)) begin
                errors = errors + 1;
                $display("ERROR @%0t: output pads DIR/NXT/CLK = %b%b%b, core %b%b%b", $time,
                         PAD_ULPI_DIR, PAD_ULPI_NXT, PAD_ULPI_CLK, dut.ulpi_dir, dut.ulpi_nxt, clk60);
            end
            if (dut.ulpi_data_oe && lk_drv_eff) begin
                errors = errors + 1;
                $display("ERROR @%0t: PHY and Link drive DATA at the same time", $time);
            end
            if (dut.ulpi_data_oe && (PAD_ULPI_DATA !== dut.ulpi_data_out)) begin
                errors = errors + 1;
                $display("ERROR @%0t: DATA pins %02h, core drives %02h", $time, PAD_ULPI_DATA, dut.ulpi_data_out);
            end
            if (lk_drv_eff && (dut.ulpi_data_in !== lk_data)) begin
                errors = errors + 1;
                $display("ERROR @%0t: core sees DATA %02h, Link drives %02h", $time, dut.ulpi_data_in, lk_data);
            end
            if (lk_stp_drv && (dut.ulpi_stp !== lk_stp)) begin
                errors = errors + 1;
                $display("ERROR @%0t: core sees STP %b, Link drives %b", $time, dut.ulpi_stp, lk_stp);
            end
            if (^{PAD_ULPI_CLK, PAD_ULPI_NXT, PAD_ULPI_DIR, PAD_ULPI_DATA, PAD_RESETB, PAD_ULPI_STP} !== 1'bx) begin
                nand_checks = nand_checks + 1;
                if (nand_tree_out !== nand_chain(0)) begin
                    errors = errors + 1;
                    $display("ERROR @%0t: nand_tree_out = %b, expected %b", $time, nand_tree_out, nand_chain(0));
                end
            end
        end
    end

    // background RXCMD source: ALT_INT toggles (always reported in an RXCMD, in no
    // register), so RXCMDs collide with the Link commands and force retries
    reg     noise_en = 1'b0;
    integer seed_n   = 32'h0000_51DE;
    always @(negedge PAD_ULPI_CLK) begin
        if (noise_en && (({$random(seed_n)} % 23) == 0)) begin
            alt_int  = ~alt_int;
            stat_age = 0;
        end
    end

    // soft_reset pulses (one tick each)
    integer soft_reset_cnt = 0;
    always @(posedge clk_bit) if (core_rst_n && ce60 && soft_reset) soft_reset_cnt = soft_reset_cnt + 1;

    // ---------------- helpers ----------------
    task wait_clk(input integer n);
        integer k;
        begin
            for (k = 0; k < n; k = k + 1) @(posedge PAD_ULPI_CLK);
            #(4.0);
        end
    endtask

    task do_op(input integer t, input [7:0] a, input [7:0] d);
        begin
            if ((t == OP_WR || t == OP_RD) && (a[5:0] == 6'h2F)) begin
                $display("TB BUG: immediate access to 2Fh"); $finish;
            end
            op_type  = t;
            op_addr  = a;
            op_wdata = d;
            op_issued = op_issued + 1;
            wait (op_done == op_issued);
            #(0.1);
        end
    endtask

    task wr(input [5:0] a, input [7:0] d);
        begin do_op(OP_WR, {2'b00, a}, d); sh_write(1'b0, {2'b00, a}, d); end
    endtask

    task wx(input [7:0] a, input [7:0] d);
        begin do_op(OP_WX, a, d); sh_write(1'b1, a, d); end
    endtask

    integer reads = 0;
    task rd_chk_x(input ext, input [7:0] a);
        reg [7:0] e;
        begin
            e = sh_read(ext, a);
            if (imm_addr(ext, a) == 8'h14) sh_latch = 5'd0;       // clear on read
            do_op(ext ? OP_RX : OP_RD, a, 8'h00);
            reads = reads + 1;
            if (op_rdata !== e) begin
                errors = errors + 1;
                $display("ERROR @%0t: read %s%02h = %02h, expected %02h", $time,
                         ext ? "ext " : "", a, op_rdata, e);
            end
        end
    endtask

    task rd(input [5:0] a);   rd_chk_x(1'b0, {2'b00, a}); endtask
    task rx(input [7:0] a);   rd_chk_x(1'b1, a);          endtask

    task check_cfg;
        begin
            wait_clk(2);
            if ((xcvrselect !== sh_fc[1:0]) || (termselect !== sh_fc[2]) || (opmode !== sh_fc[4:3]) ||
                (suspendm !== sh_fc[6]) || (ifc_ctrl !== sh_ic) || (otg_ctrl !== sh_otg) ||
                (cfg_speed !== sh_fc[1:0]) || (cfg_bypass !== (sh_fc[4:3] == 2'b10)) ||
                (dut.u_core.ie_rise !== sh_ier[4:0]) || (dut.u_core.ie_fall !== sh_ief[4:0])) begin
                errors = errors + 1;
                $display("ERROR @%0t: configuration outputs xcvr %b term %b opmode %b suspendm %b ifc %02h otg %02h ie %02h/%02h, expected FC %02h IC %02h OTG %02h IE %02h/%02h",
                         $time, xcvrselect, termselect, opmode, suspendm, ifc_ctrl, otg_ctrl,
                         dut.u_core.ie_rise, dut.u_core.ie_fall, sh_fc, sh_ic, sh_otg, sh_ier, sh_ief);
            end
            // the ULPI register file the Link talks to is the one inside usb_ulpi_phy_top
            if ((dut.u_core.u_rf.fc_q !== sh_fc) || (dut.u_core.u_rf.ic_q !== sh_ic) ||
                (dut.u_core.u_rf.otg_q !== sh_otg) || (dut.u_core.u_rf.scr_q !== sh_scr) ||
                (dut.u_core.u_rf.ier_q !== sh_ier) || (dut.u_core.u_rf.ief_q !== sh_ief)) begin
                errors = errors + 1;
                $display("ERROR @%0t: u_core.u_rf contents differ from the shadow model", $time);
            end
        end
    endtask

    // status change; the latch model applies the enabled edges
    task set_status(input hd, input vv, input sv, input se, input idg);
        reg [4:0] o, n;
        begin
            o = stat_now(0);
            n = {idg, se, sv, vv, hd};
            sh_latch = sh_latch | ((n & ~o) & sh_ier[4:0]) | ((~n & o) & sh_ief[4:0]);
            host_disc = hd; a_vbus_vld = vv; sess_vld = sv; sess_end = se; id_gnd = idg;
            stat_age = 0;
            wait_clk(8);
        end
    endtask

    task set_ls(input [1:0] ls);
        begin linestate = ls; stat_age = 0; wait_clk(8); end
    endtask

    task read_all;
        integer a;
        begin
            for (a = 0; a < 8'h40; a = a + 1)
                if (a != 8'h2F) rd(a);
            rx(8'h04); rx(8'h16); rx(8'h2F); rx(8'h40); rx(8'h80); rx(8'hFF);
        end
    endtask

    // bytes that look like ULPI commands
    function [7:0] cmd_like;
        input [3:0] k;
        case (k % 10)
            0: cmd_like = 8'h40;  1: cmd_like = 8'h4F;  2: cmd_like = 8'h80;  3: cmd_like = 8'hAF;
            4: cmd_like = 8'hC0;  5: cmd_like = 8'hEF;  6: cmd_like = 8'h2F;  7: cmd_like = 8'hFF;
            8: cmd_like = 8'h43;  default: cmd_like = 8'hC4;
        endcase
    endfunction

    // ---------------- pull checks ----------------
    task pull_check(input expect_pulls);
        begin
`ifdef DISPLAY_PD_PU_EN
            // the Link stops driving STP and DATA while DIR = 0.  With the protection on
            // it stays off for a few ticks (the core then sees STP = 1, DATA = 00h);
            // with the protection off the pins would float into the core, so they are
            // released only between two core sampling edges (ce60).
            wait (PAD_ULPI_DIR === 1'b0);
            @(posedge clk_bit);
            while (!ce60) @(posedge clk_bit);
            #(1.0);
            lk_drv = 1'b0; lk_stp_drv = 1'b0;
            if (expect_pulls) wait_clk(3);
            else              #(6.0);
            if (expect_pulls) begin
                if ((PAD_ULPI_STP !== 1'b1) || (dut.ulpi_stp !== 1'b1)) begin
                    errors = errors + 1;
                    $display("ERROR @%0t: STP pin %b (core %b), expected the pull-up", $time, PAD_ULPI_STP, dut.ulpi_stp);
                end
                if (((PAD_ULPI_DIR === 1'b0) && (PAD_ULPI_DATA !== 8'h00)) || (dut.ulpi_data_in !== 8'h00)) begin
                    errors = errors + 1;
                    $display("ERROR @%0t: DATA pins %b (core %b), expected the pull-downs", $time, PAD_ULPI_DATA, dut.ulpi_data_in);
                end
            end else begin
                if (PAD_ULPI_STP !== 1'bz) begin
                    errors = errors + 1;
                    $display("ERROR @%0t: STP pin %b, expected floating (protection disabled)", $time, PAD_ULPI_STP);
                end
                if (PAD_ULPI_DATA !== 8'hzz) begin
                    errors = errors + 1;
                    $display("ERROR @%0t: DATA pins %b, expected floating (protection disabled)", $time, PAD_ULPI_DATA);
                end
            end
            lk_data = 8'h00; lk_stp = 1'b0;
            lk_drv = 1'b1; lk_stp_drv = 1'b1;
            wait_clk(3);
`else
            // without the pull model a released pin would be X in the core: skip
            wait_clk(1);
`endif
        end
    endtask

    // ---------------- RESETB ----------------
    task pin_reset;
        begin
            wait (op_done == op_issued);
            @(negedge clk_bit);
            resetb = 1'b0;
            #(0.1);
            if (core_rst_n !== 1'b0) begin
                errors = errors + 1;
                $display("ERROR @%0t: core_rst_n not asserted asynchronously by RESETB", $time);
            end
            wait_clk(10);
            @(negedge clk_bit);
            resetb = 1'b1;
            @(posedge clk_bit); #(0.1);
            if (core_rst_n !== 1'b0) begin
                errors = errors + 1;
                $display("ERROR @%0t: core_rst_n released after one clk_bit edge", $time);
            end
            @(posedge clk_bit); #(0.1);
            if (core_rst_n !== 1'b1) begin
                errors = errors + 1;
                $display("ERROR @%0t: core_rst_n not released two clk_bit edges after RESETB", $time);
            end
            sh_reset;
            wait_clk(10);
        end
    endtask

    // ---------------- holding-state test ----------------
    // mode 0: STP driven high while idle, command-like bytes on DATA
    // mode 1: a register write whose STP stays high (Link about to stop driving)
    // mode 2: the Link stops driving STP and DATA (the pad pull-up holds STP high)
    // While STP is high: no command is taken, DIR / NXT stay low (monitor above), RXCMD
    // changes are not sent; when STP falls exactly one RXCMD with the current values.
    task hold_test(input integer mode);
        integer r0;
        reg [7:0] scr;
        begin
            wait_clk(5);
            scr = sh_scr;
            r0  = rxcmds;
            if (mode == 1) begin
                hold_mode = 1'b1;
                scr = 8'h5A ^ hold_k[7:0];
                wr(6'h16, scr);                          // STP of the write stays high
            end else if (mode == 2) begin
                wait (PAD_ULPI_DIR === 1'b0);
                @(posedge clk_bit);
                while (!ce60) @(posedge clk_bit);
                #(1.0);
                lk_drv = 1'b0; lk_stp_drv = 1'b0;
            end else begin
                hold_mode = 1'b1;
            end
            wait_clk(4);
            set_ls(2'b01);                               // RXCMD triggers while holding
            set_ls(2'b10);
            alt_int = 1'b1; stat_age = 0; wait_clk(6);
            set_ls(2'b11);
            wait_clk(10);
            if (rxcmds != r0) begin
                errors = errors + 1;
                $display("ERROR @%0t: %0d RXCMD(s) sent in the holding state (mode %0d)", $time, rxcmds - r0, mode);
            end
            // leave the holding state
            if (mode == 2) begin
                lk_data = 8'h00; lk_stp = 1'b0;
                lk_drv = 1'b1; lk_stp_drv = 1'b1;
            end
            hold_mode = 1'b0;
            wait_clk(12);
            if (rxcmds != r0 + 1) begin
                errors = errors + 1;
                $display("ERROR @%0t: %0d RXCMD(s) after the holding state (mode %0d), expected exactly 1", $time, rxcmds - r0, mode);
            end
            rd(6'h16);                                   // nothing was written meanwhile
            if (sh_scr !== scr) begin
                errors = errors + 1;
                $display("ERROR: TB scratch bookkeeping");
            end
            alt_int = 1'b0; stat_age = 0;
            set_ls(2'b00);
        end
    endtask

    // ---------------- main sequence ----------------
    integer i, k, t;
    reg [31:0] r, r2;
    reg [7:0]  a8, d8;

    initial begin
        $dumpfile("tb_usb_ulpi_phy_pads.vcd");
        $dumpvars(0, tb_usb_ulpi_phy_pads);
`ifndef DISPLAY_PD_PU_EN
        $display("NOTE: DISPLAY_PD_PU_EN not defined - pad pulls not modelled, pull checks skipped");
`endif
        sh_reset;
        resetb = 1'b0;
        #(100);
        @(negedge clk_bit);
        resetb = 1'b1;
        wait_clk(10);

        // ---- 1. reset values of the whole map ----
        $display("[1] reset values");
        read_all;
        check_cfg;

        // ---- 2. write / SET / CLR of every RW register, command-like data ----
        $display("[2] write / set / clear aliases");
        for (k = 0; k < 10; k = k + 1) begin
            d8 = cmd_like(k);
            wr(6'h16, d8);  rd(6'h16);  rd(6'h17);  rd(6'h18);
            wr(6'h17, 8'h0F); rd(6'h16);
            wr(6'h18, 8'h3C); rd(6'h16);
            wr(6'h0A, d8);  rd(6'h0A);  wr(6'h0B, 8'h81); wr(6'h0C, 8'h18); rd(6'h0C);
            wr(6'h0D, d8);  rd(6'h0D);  wr(6'h0E, 8'hEF); rd(6'h0E);  wr(6'h0F, 8'h05); rd(6'h0F);
            wr(6'h10, d8);  rd(6'h10);  wr(6'h11, 8'h80); rd(6'h11);  wr(6'h12, 8'h1A); rd(6'h12);
            wr(6'h07, d8 & 8'h7F); rd(6'h07);  wr(6'h08, 8'h2F); rd(6'h08);  wr(6'h09, 8'hFF); rd(6'h09);
            wr(6'h04, d8 & 8'hDF); rd(6'h04);  check_cfg;
            wr(6'h05, 8'h40); rd(6'h05);  wr(6'h06, 8'h1B); rd(6'h06);  check_cfg;
        end
        wr(6'h04, 8'h45); wr(6'h0D, 8'h1F); wr(6'h10, 8'h1F); wr(6'h07, 8'h00);
        check_cfg;

        // ---- 3. Function Control Reset bit -> soft_reset ----
        $display("[3] Function Control Reset bit");
        wr(6'h04, 8'h65); rd(6'h04);          // write with Reset = 1
        wr(6'h05, 8'h20); rd(6'h05);          // SET alias with Reset = 1
        wr(6'h06, 8'h20); rd(6'h06);          // CLR alias: no pulse
        wr(6'h04, 8'h45);
        check_cfg;

        // ---- 4. RO registers, unmapped addresses ----
        $display("[4] read-only and unmapped registers");
        for (k = 0; k < 4; k = k + 1) wr(k, 8'hFF);
        wr(6'h13, 8'hFF); wr(6'h14, 8'hFF); wr(6'h15, 8'hFF);
        wr(6'h19, 8'hAF); wr(6'h20, 8'hEF); wr(6'h3F, 8'hC0); wr(6'h30, 8'h80);
        for (k = 0; k < 6; k = k + 1) rd(k);
        rd(6'h13); rd(6'h14); rd(6'h15); rd(6'h19); rd(6'h20); rd(6'h3F); rd(6'h30);

        // ---- 5. extended register set ----
        $display("[5] extended set: mirror of 00h-3Fh, empty 40h-FFh");
        wx(8'h16, 8'hEF); rd(6'h16); rx(8'h16); rx(8'h17);
        wx(8'h0B, 8'h2F); rd(6'h0A); rx(8'h0A);
        wx(8'h0C, 8'hFF); rx(8'h0B);
        wx(8'h04, 8'h41); rx(8'h04); rd(6'h04); check_cfg;
        wr(6'h04, 8'h45);
        for (k = 0; k < 8; k = k + 1) begin
            a8 = 8'h40 + k * 8'h19;
            wx(a8, cmd_like(k)); rx(a8);
        end
        wx(8'h2F, 8'hAF); rx(8'h2F); rx(8'h00); rx(8'h01); rx(8'h02); rx(8'h03);
        rx(8'h3F); rx(8'hC0); rx(8'hEF);
        check_cfg;

        // ---- 6. interrupt status / latch / debug through the status inputs ----
        $display("[6] interrupt status, latch, debug");
        wr(6'h0D, 8'h02); wr(6'h10, 8'h00);              // rising VbusValid only
        set_status(0, 1, 0, 1, 0);  rd(6'h13); rd(6'h14); rd(6'h14);
        set_status(0, 0, 0, 1, 0);  rd(6'h13); rd(6'h14);
        wr(6'h10, 8'h02);
        set_status(0, 1, 0, 1, 0);  set_status(0, 0, 0, 1, 0);  rd(6'h14); rd(6'h14);
        wr(6'h0D, 8'h1F); wr(6'h10, 8'h1F);
        set_status(1, 0, 1, 0, 1);  rd(6'h13); rx(8'h14); rd(6'h14);
        set_status(0, 0, 0, 1, 0);  rx(8'h13); rd(6'h14); rd(6'h14);
        set_status(0, 1, 1, 0, 0);  rd(6'h13); rd(6'h14);
        set_status(0, 0, 1, 0, 0);  rd(6'h13); rd(6'h14);
        for (k = 0; k < 4; k = k + 1) begin
            set_ls(k);  rd(6'h15); rx(8'h15);
        end
        alt_int = 1'b1; stat_age = 0; wait_clk(8); rd(6'h15);
        alt_int = 1'b0; stat_age = 0; wait_clk(8);
        set_ls(2'b00);

        // ---- 7. ULPI interface protection pulls ----
        $display("[7] interface protection pulls");
        pull_check(1'b1);                                // Interface Protect Disable = 0
        wr(6'h08, 8'h80); rd(6'h07); check_cfg;          // disable the protection
        pull_check(1'b0);
        wr(6'h09, 8'h80); rd(6'h07); check_cfg;          // enable it again
        pull_check(1'b1);
        rd(6'h16); rd(6'h04);

        // ---- 8. random register traffic with status / line-state activity ----
        $display("[8] %0d random register operations", NRAND);
        noise_en = 1'b1;
        for (i = 0; i < NRAND; i = i + 1) begin
            r  = $random(seed);
            r2 = $random(seed);
            d8 = r2[3] ? cmd_like(r2[7:4]) : r2[15:8];
            case (r[2:0])
                0, 1: a8 = 8'h04 + (r[12:8] % 21);       // the mapped RW / RO area
                2:    a8 = r[13:8];                      // any immediate address
                default: a8 = 8'h16 + (r[9:8] % 3);
            endcase
            if (a8[5:0] == 6'h2F) a8 = 8'h16;
            // keep the bus usable: never disable the protection here
            if ((a8 >= 8'h07) && (a8 <= 8'h08)) d8 = d8 & 8'h7F;
            // Function Control: keep OpMode / XcvrSelect arbitrary, SuspendM too
            t = r[18:16];
            case (t)
                0, 1: wr(a8[5:0], d8);
                2:    wx(a8, d8);
                3:    wx({r2[23], 1'b1, r2[21:16]}, d8);   // empty part of the extended set
                4, 5: rd(a8[5:0]);
                6:    rx(a8);
                default: rx({r2[23], 1'b1, r2[21:16]});
            endcase
            if (r[27:24] == 4'd0) set_ls(r2[25:24]);
            if (r[31:28] == 4'd0) begin
                set_status(r2[26], r2[27], r2[28], r2[29], r2[30]);
            end
            if (r[22:20] == 3'd0) wait_clk(r2[31:29]);
            if ((i % 50) == 49) check_cfg;
        end
        noise_en = 1'b0;
        alt_int  = 1'b0;
        stat_age = 0;
        wait_clk(10);
        if (retries == 0) begin
            errors = errors + 1;
            $display("ERROR: no Link command lost against an RXCMD - the retry path was not exercised");
        end
        for (k = 0; k <= 8'h18; k = k + 1) rd(k);
        check_cfg;

        // ---- 9. ULPI holding state ----
        $display("[9] ULPI holding state");
        hold_test(0);                                    // STP driven high, command-like DATA
        hold_test(1);                                    // STP stays high after a register write
`ifdef DISPLAY_PD_PU_EN
        hold_test(2);                                    // Link tri-stated, STP pull-up
`endif
        rd(6'h16); rd(6'h04); rd(6'h07);

        // ---- 10. RESETB pin ----
        $display("[10] RESETB");
        wr(6'h16, 8'h5A); wr(6'h0A, 8'hAF); wr(6'h04, 8'h41);
        pin_reset;
        read_all;
        check_cfg;
        wr(6'h16, 8'hC0); rd(6'h16); rx(8'h16);
        check_cfg;

        wait_clk(20);
        if (soft_reset_cnt != exp_soft_reset) begin
            errors = errors + 1;
            $display("ERROR: %0d soft_reset pulses, expected %0d", soft_reset_cnt, exp_soft_reset);
        end
        if (tx_en !== 1'b0 || rx_active !== 1'b0) begin
            errors = errors + 1;
            $display("ERROR: tx_en = %b, rx_active = %b at the end (no USB traffic was started)", tx_en, rx_active);
        end
        if (rxcmds_chk == 0) begin
            errors = errors + 1;
            $display("ERROR: no RXCMD was checked");
        end

        $display("--------------------------------------------------");
        $display("register operations: %0d (%0d reads), Link retries: %0d", op_done, reads, retries);
        $display("RXCMDs at the pins: %0d (%0d checked), soft_reset pulses: %0d", rxcmds, rxcmds_chk, soft_reset_cnt);
        $display("pad checks: %0d, NAND-tree checks: %0d, holding-state cycles: %0d", pad_checks, nand_checks, hold_cyc);
        if (errors == 0) $display("TEST PASSED");
        else             $display("TEST FAILED: %0d error(s)", errors);
        $display("--------------------------------------------------");
        $finish;
    end

    // ---------------- watchdog ----------------
    initial begin
        #(20_000_000);
        $display("TEST FAILED: timeout");
        $finish;
    end

endmodule
