//-----------------------------------------------------------------------------
// usb_rx_datapath.v
//
// RX datapath of the USB 2.0 PHY (HS / FS / LS), from the AFE receiver outputs
// to the RX Data Handler of the ULPI Interface Controller (usb_ulpi_rx_path):
//
//   HS:    CDR rxd/clk_rx -> usb_rx_hs_frontend -> usb_rx_decoder (HS, clk_rx)
//                         -> usb_rx_elastic_buffer (async, clk_rx -> clk_bit) --+
//   FS/LS: rxrcv/rxdp/rxdm -> usb_rx_fsls_frontend (DPLL) -> usb_rx_decoder      |
//                         (FS/LS, clk_bit) -> usb_rx_elastic_buffer (sync) -----+
//                                                                                 |
//          RX output stage (clk_bit, ce60) <--------------------------------------+
//            -> rx_start / rx_valid + rx_data / rx_end / rx_error
//
// usb_rx_decoder is: NRZI decoder -> SYNC detect -> bit unstuffer ->
// deserializer 1:8 -> EOP / RxError check.  The HS and the FS/LS chain are
// separate instances because they run on different clocks; only one of them is
// enabled at a time.
//
// Mode (speed = XcvrSelect, quasi-static): 00 HS chain; 01 FS, 10 LS, 11 FS
//   (FS/LS chain).  Changing the mode during a packet ends it with an error.
//
// Local transmitter: while tx_en is high and for HOLDOFF clk_bit cycles after
//   it falls, both chains are disabled (receiver inactive), so the PHY never
//   reports its own packets (the HS receiver and the FS/LS receivers see the
//   local transmitter on the line).  HOLDOFF covers the AFE and CDR latency of
//   the echo.  rx_en = 0 disables reception as well (e.g. low-power mode).
//
// Output (clk_bit domain, registered, updated on ce60 edges, so every pulse is
//   one tick long - the format of usb_ulpi_rx_handler):
//   rx_start           a packet starts (SYNC received)
//   rx_valid, rx_data  a byte of the packet (PID first; SYNC and EOP stripped)
//   rx_end             the packet is over; rx_error = 1 in the same tick if the
//                      packet had an error (bit-stuff violation, not ending on a
//                      byte boundary, signal lost before the EOP, buffer
//                      overflow)
//   At most one event per tick.  The output stage pops one event per tick from
//   the elastic buffer of the active chain; a packet that was started is always
//   ended, events outside a packet are dropped.
//
// Clocks / resets: clk_bit with ce60 (local PLL), clk_rx (HS recovered clock).
//   rst_n is asynchronous; its release is synchronized to clk_rx here (it is
//   assumed to be synchronous to clk_bit already).
//-----------------------------------------------------------------------------
`timescale 1ns/1ps

module usb_rx_datapath #(
    parameter FS_DIV  = 40,
    parameter LS_DIV  = 320,
    parameter DIV_W   = 9,
    parameter HS_ZMIN = 6,            // SYNC zeros needed, HS
    parameter FS_ZMIN = 4,            // SYNC zeros needed, FS / LS
    parameter HS_AW   = 4,            // HS elastic buffer: 16 events
    parameter FS_AW   = 2,            // FS/LS event buffer: 4 events
    parameter HOLDOFF = 64            // clk_bit cycles after tx_en
) (
    input  wire        clk_bit,
    input  wire        rst_n,
    input  wire        ce60,

    input  wire [1:0]  speed,         // XcvrSelect
    input  wire        rx_en,
    input  wire        tx_en,         // local transmitter active

    // HS receiver / CDR
    input  wire        clk_rx,
    input  wire        hs_rxd,
    input  wire        hs_squelch,
    input  wire        hs_cdr_lock,

    // FS / LS receivers
    input  wire        rxrcv,
    input  wire        rxdp,
    input  wire        rxdm,

    // to usb_ulpi_rx_path
    output reg         rx_start,
    output reg         rx_valid,
    output reg  [7:0]  rx_data,
    output reg         rx_end,
    output reg         rx_error,

    output wire        rx_busy        // a packet is open at the output
);

    localparam [1:0] EV_BYTE  = 2'b00;
    localparam [1:0] EV_START = 2'b01;
    localparam [1:0] EV_END   = 2'b10;

    // ---------------- mode, local transmitter hold-off ----------------
    localparam HW = (HOLDOFF < 2) ? 1 : $clog2(HOLDOFF + 1);

    reg [HW-1:0] hold;
    reg          hs_en_q, fs_en_q, ls_q;
    wire         block = tx_en || (hold != {HW{1'b0}});

    always @(posedge clk_bit or negedge rst_n) begin
        if (!rst_n) begin
            hold    <= {HW{1'b0}};
            hs_en_q <= 1'b0;
            fs_en_q <= 1'b0;
            ls_q    <= 1'b0;
        end else begin
            if (tx_en)                    hold <= HOLDOFF;
            else if (hold != {HW{1'b0}})  hold <= hold - 1'b1;
            hs_en_q <= rx_en && !block && (speed == 2'b00);
            fs_en_q <= rx_en && !block && (speed != 2'b00);
            ls_q    <= (speed == 2'b10);
        end
    end

    // ---------------- clk_rx reset synchronizer ----------------
    reg rr1, rst_rx_n;
    always @(posedge clk_rx or negedge rst_n) begin
        if (!rst_n) begin
            rr1      <= 1'b0;
            rst_rx_n <= 1'b0;
        end else begin
            rr1      <= 1'b1;
            rst_rx_n <= rr1;
        end
    end

    // ---------------- HS chain (clk_rx) ----------------
    wire       hb_en, hb_lvl, hb_se0, hb_act;
    wire       h_ev_wr, h_afull, h_full, h_wovf, h_busy, h_ovf;
    wire [9:0] h_ev;
    wire       h_valid;
    wire [9:0] h_rdata;
    wire       h_pop;

    usb_rx_hs_frontend u_hs_fe (
        .clk_rx   (clk_rx),
        .rst_n    (rst_rx_n),
        .rxd      (hs_rxd),
        .squelch  (hs_squelch),
        .cdr_lock (hs_cdr_lock),
        .enable   (hs_en_q),
        .b_en     (hb_en),
        .b_lvl    (hb_lvl),
        .b_se0    (hb_se0),
        .b_act    (hb_act)
    );

    usb_rx_decoder #(.HS(1), .ZMIN(HS_ZMIN)) u_hs_dec (
        .clk       (clk_rx),
        .rst_n     (rst_rx_n),
        .b_en      (hb_en),
        .b_lvl     (hb_lvl),
        .b_se0     (hb_se0),
        .b_act     (hb_act),
        .buf_afull (h_afull),
        .ev_wr     (h_ev_wr),
        .ev_data   (h_ev),
        .busy      (h_busy),
        .ovf       (h_ovf)
    );

    usb_rx_elastic_buffer #(.W(10), .AW(HS_AW), .ASYNC(1)) u_hs_eb (
        .wclk    (clk_rx),
        .wrst_n  (rst_rx_n),
        .w_en    (h_ev_wr),
        .w_data  (h_ev),
        .w_full  (h_full),
        .w_afull (h_afull),
        .w_ovf   (h_wovf),
        .rclk    (clk_bit),
        .rrst_n  (rst_n),
        .r_valid (h_valid),
        .r_data  (h_rdata),
        .r_pop   (h_pop)
    );

    // ---------------- FS / LS chain (clk_bit) ----------------
    wire       fb_en, fb_lvl, fb_se0, fb_act;
    wire       f_ev_wr, f_afull, f_full, f_wovf, f_busy, f_ovf;
    wire [9:0] f_ev;
    wire       f_valid;
    wire [9:0] f_rdata;
    wire       f_pop;

    usb_rx_fsls_frontend #(.FS_DIV(FS_DIV), .LS_DIV(LS_DIV), .DIV_W(DIV_W)) u_fs_fe (
        .clk    (clk_bit),
        .rst_n  (rst_n),
        .rxrcv  (rxrcv),
        .rxdp   (rxdp),
        .rxdm   (rxdm),
        .ls     (ls_q),
        .enable (fs_en_q),
        .b_en   (fb_en),
        .b_lvl  (fb_lvl),
        .b_se0  (fb_se0),
        .b_act  (fb_act)
    );

    usb_rx_decoder #(.HS(0), .ZMIN(FS_ZMIN)) u_fs_dec (
        .clk       (clk_bit),
        .rst_n     (rst_n),
        .b_en      (fb_en),
        .b_lvl     (fb_lvl),
        .b_se0     (fb_se0),
        .b_act     (fb_act),
        .buf_afull (f_afull),
        .ev_wr     (f_ev_wr),
        .ev_data   (f_ev),
        .busy      (f_busy),
        .ovf       (f_ovf)
    );

    usb_rx_elastic_buffer #(.W(10), .AW(FS_AW), .ASYNC(0)) u_fs_eb (
        .wclk    (clk_bit),
        .wrst_n  (rst_n),
        .w_en    (f_ev_wr),
        .w_data  (f_ev),
        .w_full  (f_full),
        .w_afull (f_afull),
        .w_ovf   (f_wovf),
        .rclk    (clk_bit),
        .rrst_n  (rst_n),
        .r_valid (f_valid),
        .r_data  (f_rdata),
        .r_pop   (f_pop)
    );

    // ---------------- output stage (clk_bit, one event per ce60 tick) ----------------
    reg        open;                  // a packet is open at the output
    reg        src;                   // 0 = HS chain, 1 = FS/LS chain (while open)

    wire       sel   = open ? src : !h_valid;          // idle: HS first
    wire       e_val = sel ? f_valid : h_valid;
    wire [9:0] e_dat = sel ? f_rdata : h_rdata;
    wire [1:0] e_typ = e_dat[9:8];

    // a START while a packet is open is not popped: the open packet is closed
    // with an error first (cannot happen with usb_rx_eop_check, which always
    // pairs START / END)
    wire       e_pop = ce60 && e_val && !(open && (e_typ == EV_START));
    assign h_pop = e_pop && !sel;
    assign f_pop = e_pop &&  sel;

    assign rx_busy = open;

    always @(posedge clk_bit or negedge rst_n) begin
        if (!rst_n) begin
            open     <= 1'b0;
            src      <= 1'b0;
            rx_start <= 1'b0;
            rx_valid <= 1'b0;
            rx_data  <= 8'd0;
            rx_end   <= 1'b0;
            rx_error <= 1'b0;
        end else if (ce60) begin
            rx_start <= 1'b0;
            rx_valid <= 1'b0;
            rx_end   <= 1'b0;
            rx_error <= 1'b0;
            if (e_val) begin
                if (!open) begin
                    if (e_typ == EV_START) begin
                        rx_start <= 1'b1;
                        open     <= 1'b1;
                        src      <= sel;
                    end                                     // else: orphan, dropped
                end else begin
                    case (e_typ)
                        EV_BYTE: begin
                            rx_valid <= 1'b1;
                            rx_data  <= e_dat[7:0];
                        end
                        EV_END: begin
                            rx_end   <= 1'b1;
                            rx_error <= e_dat[0];
                            open     <= 1'b0;
                        end
                        default: begin                      // START while open
                            rx_end   <= 1'b1;
                            rx_error <= 1'b1;
                            open     <= 1'b0;
                        end
                    endcase
                end
            end
        end
    end

endmodule
