//-----------------------------------------------------------------------------
// tb_usb_rx_eop_check.v - self-checking testbench for usb_rx_eop_check
//
// Run (Icarus Verilog):
//   iverilog -g2005 -o sim_rxeop usb_rx_eop_check.v tb_usb_rx_eop_check.v
//   vvp sim_rxeop
//
// Two instances, HS = 1 and HS = 0 (FS/LS), get the same stream of bit-level
// events (SYNC, bytes, bit-stuff violation with a residual count, SE0 with a
// residual count, receiver inactive, idle bits, strobe gaps).  The stream is
// built from scenarios whose expected event list is written down per instance:
//
//   scenario                         HS instance          FS/LS instance
//   sync, n bytes, serr (nres = 7)   START n*BYTE END 0   START n*BYTE END 1
//   sync, n bytes, serr (nres != 7)  ... END 1            ... END 1
//   sync, n bytes, se0 (nres = 0),
//     then inactive                  ... END 1 (inactive) ... END 0 (se0)
//   sync, n bytes, se0 (nres != 0),
//     then inactive                  ... END 1            ... END 1
//   sync, n bytes, inactive          ... END 1            ... END 1
//   sync, k bytes, serr, m bytes,
//     se0, inactive                  START k*BYTE END 1   START k*BYTE END 1
//   bytes / serr / se0 without SYNC  -                    -
//   buffer almost full at SYNC       - (ovf pulse)        - (ovf pulse)
//   almost full at byte j            byte j dropped, END 1 (ovf pulse)
//
// Checked: the event words of each instance in order, ev_wr only in the cycle
// after a strobe, the ovf pulse count, busy low between scenarios.
//-----------------------------------------------------------------------------
`timescale 1ns/1ps

module tb_usb_rx_eop_check;

    reg clk = 1'b0;
    always #5 clk = ~clk;
    reg rst_n;

    reg       i_en = 1'b0, i_byte_en = 1'b0, i_serr = 1'b0, i_se0 = 1'b0, i_act = 1'b1, i_sync = 1'b0;
    reg [7:0] i_byte = 8'd0;
    reg [2:0] i_nres = 3'd0;
    reg       afull = 1'b0;

    wire       h_wr, h_busy, h_ovf, f_wr, f_busy, f_ovf;
    wire [9:0] h_ev, f_ev;

    usb_rx_eop_check #(.HS(1)) dut_hs (
        .clk (clk), .rst_n (rst_n),
        .i_en (i_en), .i_byte_en (i_byte_en), .i_byte (i_byte), .i_nres (i_nres),
        .i_serr (i_serr), .i_se0 (i_se0), .i_act (i_act), .i_sync (i_sync),
        .buf_afull (afull),
        .ev_wr (h_wr), .ev_data (h_ev), .busy (h_busy), .ovf (h_ovf)
    );

    usb_rx_eop_check #(.HS(0)) dut_fs (
        .clk (clk), .rst_n (rst_n),
        .i_en (i_en), .i_byte_en (i_byte_en), .i_byte (i_byte), .i_nres (i_nres),
        .i_serr (i_serr), .i_se0 (i_se0), .i_act (i_act), .i_sync (i_sync),
        .buf_afull (afull),
        .ev_wr (f_wr), .ev_data (f_ev), .busy (f_busy), .ovf (f_ovf)
    );

    integer errors = 0;
    integer seed   = 32'h7531_ECA8;

    localparam [9:0] START = {2'b01, 8'h00};
    localparam [9:0] END0  = {2'b10, 8'h00};
    localparam [9:0] END1  = {2'b10, 8'h01};

    // expected event lists
    reg [9:0] xh [0:65535];  integer xh_w = 0, xh_r = 0;
    reg [9:0] xf [0:65535];  integer xf_w = 0, xf_r = 0;
    integer   x_ovf = 0, n_hovf = 0, n_fovf = 0;

    task exp_both(input [9:0] e);
        begin
            xh[xh_w] = e; xh_w = xh_w + 1;
            xf[xf_w] = e; xf_w = xf_w + 1;
        end
    endtask
    task exp_h(input [9:0] e); begin xh[xh_w] = e; xh_w = xh_w + 1; end endtask
    task exp_f(input [9:0] e); begin xf[xf_w] = e; xf_w = xf_w + 1; end endtask

    reg en_q = 1'b0;
    always @(posedge clk) begin
        if (rst_n) begin
            if ((h_wr || f_wr) && !en_q) begin
                errors = errors + 1;
                $display("ERROR @%0t: ev_wr not after a strobe", $time);
            end
            if (h_wr) begin
                if (xh_r >= xh_w || h_ev !== xh[xh_r]) begin
                    errors = errors + 1;
                    $display("ERROR @%0t: HS event %03h, expected %03h", $time, h_ev, (xh_r < xh_w) ? xh[xh_r] : 10'h3FF);
                end
                xh_r = xh_r + 1;
            end
            if (f_wr) begin
                if (xf_r >= xf_w || f_ev !== xf[xf_r]) begin
                    errors = errors + 1;
                    $display("ERROR @%0t: FS event %03h, expected %03h", $time, f_ev, (xf_r < xf_w) ? xf[xf_r] : 10'h3FF);
                end
                xf_r = xf_r + 1;
            end
            if (h_ovf) n_hovf = n_hovf + 1;
            if (f_ovf) n_fovf = n_fovf + 1;
        end
        en_q <= i_en;
    end

    // one strobe; kind: 0 idle, 1 sync, 2 byte, 3 serr, 4 se0, 5 inactive
    task strobe(input integer kind, input [7:0] v, input [2:0] nres);
        begin
            while ({$random(seed)} % 3 == 0) begin
                @(negedge clk);
                i_en = 1'b0;
                i_sync = $random(seed); i_byte_en = $random(seed); i_serr = $random(seed);   // ignored
                @(posedge clk);
            end
            @(negedge clk);
            i_en      = 1'b1;
            i_sync    = (kind == 1);
            i_byte_en = (kind == 2);
            i_byte    = v;
            i_serr    = (kind == 3);
            i_se0     = (kind == 4);
            i_act     = (kind != 5);
            i_nres    = nres;
            @(posedge clk);
            @(negedge clk);
            i_en = 1'b0; i_sync = 1'b0; i_byte_en = 1'b0; i_serr = 1'b0; i_se0 = 1'b0; i_act = 1'b1;
        end
    endtask

    task idle(input integer n);
        integer i;
        begin
            for (i = 0; i < n; i = i + 1) strobe(0, 8'h00, $random(seed));
        end
    endtask

    // sync + n bytes (both instances expect START + bytes); drop_at: afull at byte drop_at
    reg dropped;
    task head(input integer n, input integer drop_at);
        integer i;
        reg [7:0] v;
        begin
            dropped = 1'b0;
            exp_both(START);
            strobe(1, 8'h00, 3'd0);
            for (i = 0; i < n; i = i + 1) begin
                v = $random(seed);
                if (i == drop_at) begin
                    afull = 1'b1;
                    strobe(2, v, 3'd0);
                    afull = 1'b0;
                    dropped = 1'b1;
                    x_ovf = x_ovf + 1;
                end else begin
                    exp_both({2'b00, v});
                    strobe(2, v, $random(seed));
                end
                if ({$random(seed)} % 4 == 0) idle(1);
            end
        end
    endtask

    task scenario(input integer kind, input integer n);
        integer drop_at, k, i;
        reg [2:0] r;
        begin
            drop_at = ((n > 0) && ({$random(seed)} % 5 == 0)) ? {$random(seed)} % n : -1;
            case (kind)
                0: begin                                   // HS EOP
                       head(n, drop_at);
                       exp_h(dropped ? END1 : END0);
                       exp_f(END1);
                       strobe(3, 8'h00, 3'd7);
                   end
                1: begin                                   // HS EOP, wrong residual
                       head(n, drop_at);
                       r = {$random(seed)} % 7;
                       exp_both(END1);
                       strobe(3, 8'h00, r);
                   end
                2: begin                                   // FS/LS EOP
                       head(n, drop_at);
                       exp_h(END1);
                       exp_f(dropped ? END1 : END0);
                       strobe(4, 8'h00, 3'd0);
                       strobe(5, 8'h00, 3'd0);
                   end
                3: begin                                   // FS/LS EOP, wrong residual
                       head(n, drop_at);
                       r = 1 + {$random(seed)} % 7;
                       exp_both(END1);
                       strobe(4, 8'h00, r);
                       strobe(5, 8'h00, 3'd0);
                   end
                4: begin                                   // signal lost
                       head(n, drop_at);
                       exp_both(END1);
                       strobe(5, 8'h00, 3'd0);
                   end
                5: begin                                   // violation inside, rest ignored
                       head(n, drop_at);
                       exp_both(END1);
                       strobe(3, 8'h00, 3'd2);
                       for (i = 0; i < 3; i = i + 1) strobe(2, $random(seed), 3'd0);
                       strobe(4, 8'h00, 3'd0);
                       strobe(5, 8'h00, 3'd0);
                   end
                6: begin                                   // garbage without SYNC
                       for (i = 0; i < 4; i = i + 1) strobe(2, $random(seed), 3'd0);
                       strobe(3, 8'h00, 3'd7);
                       strobe(4, 8'h00, 3'd0);
                       strobe(5, 8'h00, 3'd0);
                   end
                default: begin                             // no room at SYNC: packet skipped
                       afull = 1'b1;
                       strobe(1, 8'h00, 3'd0);
                       afull = 1'b0;
                       x_ovf = x_ovf + 1;
                       for (i = 0; i < n; i = i + 1) strobe(2, $random(seed), 3'd0);
                       strobe(5, 8'h00, 3'd0);                 // ends the skipped packet in both
                   end
            endcase
            idle(1 + {$random(seed)} % 3);
            if (h_busy || f_busy) begin
                errors = errors + 1;
                $display("ERROR @%0t: busy after scenario %0d", $time, kind);
            end
        end
    endtask

    integer p;

    initial begin
        $dumpfile("tb_usb_rx_eop_check.vcd");
        $dumpvars(0, tb_usb_rx_eop_check);
        rst_n = 1'b0;
        repeat (3) @(posedge clk);
        @(negedge clk) rst_n = 1'b1;

        $display("Each scenario once, then random");
        for (p = 0; p < 8; p = p + 1) scenario(p, 3);
        for (p = 0; p < 800; p = p + 1) scenario({$random(seed)} % 8, {$random(seed)} % 12);

        repeat (5) @(posedge clk);
        if (xh_r != xh_w || xf_r != xf_w) begin
            errors = errors + 1;
            $display("ERROR: events HS %0d of %0d, FS %0d of %0d", xh_r, xh_w, xf_r, xf_w);
        end
        if (n_hovf != x_ovf || n_fovf != x_ovf) begin
            errors = errors + 1;
            $display("ERROR: ovf pulses HS %0d FS %0d, expected %0d", n_hovf, n_fovf, x_ovf);
        end
        $display("%0d HS events, %0d FS events, %0d drops", xh_r, xf_r, x_ovf);
        if (errors == 0) $display("TEST PASSED");
        else             $display("TEST FAILED: %0d error(s)", errors);
        $finish;
    end

    initial begin
        #20_000_000;
        $display("TEST FAILED: timeout");
        $finish;
    end

endmodule
