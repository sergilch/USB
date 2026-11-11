//-----------------------------------------------------------------------------
// usb_rx_status_sync.v
//
// "Receiver status sync + glitch filter" of the AFE interface (WORK_PLAN 3.1 /
// 4.1, AFE_INTEGRATION_PLAN.md phase A5).  Single synchronization point for
// the static and slow analog status outputs.  Position:
//
//   AFE: FS/LS receivers (RXDP_A, RXDM_A, RXRCV_A), squelch / disconnect
//        (SQUELCH_A, DISC_A), VBUS / ID comparators
//     --> [THIS BLOCK] --> usb_line_state (LineState, HostDisconnect)
//                      --> usb_rx_datapath FS/LS inputs (rxdp / rxdm / rxrcv)
//                      --> VbusState / IdGnd of usb_ulpi_phy_top
//
// All inputs are asynchronous (analog comparators).  Three groups:
//
//   1. rxdp, rxdm, rxrcv -> rxdp_s, rxdm_s, rxrcv_s: 2-FF synchronizers only,
//      no filter.  The FS/LS DPLL (usb_rx_fsls_frontend) and the LineState
//      filter (usb_line_state) need every edge; SE0 / SE1 glitches at D+ / D-
//      crossovers are removed there, per mode.  usb_rx_fsls_frontend has its
//      own 2-FF stage; fed from here it only adds 2 cycles of delay.
//   2. squelch, disc -> squelch_s, disc_s: 2-FF synchronizer + glitch filter
//      on clk_bit.  The output takes a new value once the synchronized input has
//      held it for flt + 1 consecutive cycles (flt = sq_flt for squelch,
//      disc_flt for disconnect; 0 = no filtering, 1 cycle after the second
//      flop).  Shorter pulses are dropped; latency 2 + flt + 1 cycles.
//      The squelch detector already filters (spec 4.2: 4 ns release / 12 ns
//      hold); this filter is the digital safety margin against comparator
//      chatter, so keep sq_flt small (default 2 = 6.25 ns total): it delays the
//      HS LineState only, not the HS data path (usb_afe_rx_if has its own
//      squelch synchronizer on clk_rx).
//   3. a_vbus_vld, sess_vld, sess_end, id_gnd -> *_s: 2-FF synchronizer, then
//      a debounce counted in ce60 ticks: a new value is taken after it held for
//      vb_flt + 1 consecutive ticks (VB_W bits: up to 2^16 ticks = 1.09 ms with
//      the default VB_W = 16, the ms-range debounce of WORK_PLAN 4.1).  These
//      outputs change on ce60 only, so they are ULPI-domain signals (8-cycle
//      multicycle paths into usb_ulpi_phy_top).
//
// Reset values are the isolated values of DOC/afe_interface_spec.md 3.2 /
// 3.4 / 3.5: rxdp = rxdm = 0, rxrcv = 1, squelch = 1, disc = 0,
// a_vbus_vld = sess_vld = 0, sess_end = 1, id_gnd = 0.  The filters start in
// that state, so a status that is already different at reset release shows up
// after the normal filter delay (and produces the RXCMD it should).
//
// Filter lengths are ports until the trim / config registers exist (WORK_PLAN
// 6.4); they are quasi-static.
//
// Clocking: clk_bit, ce60 enable for group 3; active-low asynchronous reset.
//-----------------------------------------------------------------------------
`timescale 1ns/1ps

module usb_rx_status_sync #(
    parameter SQ_W = 4,               // squelch / disconnect filter counter width
    parameter VB_W = 16               // VBUS / ID debounce counter width (ce60 ticks)
) (
    input  wire            clk_bit,
    input  wire            rst_n,
    input  wire            ce60,

    // asynchronous AFE outputs
    input  wire            rxdp,
    input  wire            rxdm,
    input  wire            rxrcv,
    input  wire            squelch,
    input  wire            disc,
    input  wire            a_vbus_vld,
    input  wire            sess_vld,
    input  wire            sess_end,
    input  wire            id_gnd,

    // filter lengths (quasi-static)
    input  wire [SQ_W-1:0] sq_flt,    // squelch: extra clk_bit cycles
    input  wire [SQ_W-1:0] disc_flt,  // disconnect: extra clk_bit cycles
    input  wire [VB_W-1:0] vb_flt,    // VBUS / ID: extra ce60 ticks

    // synchronized (clk_bit domain)
    output wire            rxdp_s,
    output wire            rxdm_s,
    output wire            rxrcv_s,
    output wire            squelch_s,
    output wire            disc_s,
    // synchronized + debounced, change on ce60 only
    output wire            a_vbus_vld_s,
    output wire            sess_vld_s,
    output wire            sess_end_s,
    output wire            id_gnd_s
);

    // ---------------- 2-FF synchronizers ----------------
    // reset value = isolated value of each input (bit order as din)
    localparam [8:0] RST_V = {1'b0, 1'b1, 1'b0, 1'b0, 1'b0, 1'b1, 1'b1, 1'b0, 1'b0};

    wire [8:0] din = {id_gnd, sess_end, sess_vld, a_vbus_vld, disc, squelch,
                      rxrcv, rxdm, rxdp};
    reg  [8:0] s1, s2;

    always @(posedge clk_bit or negedge rst_n) begin
        if (!rst_n) begin
            s1 <= RST_V;
            s2 <= RST_V;
        end else begin
            s1 <= din;
            s2 <= s1;
        end
    end

    assign rxdp_s  = s2[0];
    assign rxdm_s  = s2[1];
    assign rxrcv_s = s2[2];

    // ---------------- squelch / disconnect filters (clk_bit) ----------------
    usb_rx_status_flt #(.W(SQ_W), .RST_V(1'b1)) u_sq (
        .clk(clk_bit), .rst_n(rst_n), .en(1'b1), .din(s2[3]), .len(sq_flt),
        .dout(squelch_s));
    usb_rx_status_flt #(.W(SQ_W), .RST_V(1'b0)) u_disc (
        .clk(clk_bit), .rst_n(rst_n), .en(1'b1), .din(s2[4]), .len(disc_flt),
        .dout(disc_s));

    // ---------------- VBUS / ID debounce (ce60 ticks) ----------------
    usb_rx_status_flt #(.W(VB_W), .RST_V(1'b0)) u_avv (
        .clk(clk_bit), .rst_n(rst_n), .en(ce60), .din(s2[5]), .len(vb_flt),
        .dout(a_vbus_vld_s));
    usb_rx_status_flt #(.W(VB_W), .RST_V(1'b0)) u_sv (
        .clk(clk_bit), .rst_n(rst_n), .en(ce60), .din(s2[6]), .len(vb_flt),
        .dout(sess_vld_s));
    usb_rx_status_flt #(.W(VB_W), .RST_V(1'b1)) u_se (
        .clk(clk_bit), .rst_n(rst_n), .en(ce60), .din(s2[7]), .len(vb_flt),
        .dout(sess_end_s));
    usb_rx_status_flt #(.W(VB_W), .RST_V(1'b0)) u_id (
        .clk(clk_bit), .rst_n(rst_n), .en(ce60), .din(s2[8]), .len(vb_flt),
        .dout(id_gnd_s));

endmodule
