//-----------------------------------------------------------------------------
// usb_tx_datapath.v   (revision 2: latency-aware Link interface)
//
// TX datapath of the USB 2.0 PHY as drawn in the block diagram
// (usb_phy_ulpi_digital), from the captured ULPI Link signals to the transmitter
// line signals:
//
//   usb_ulpi_input_capture -> usb_tx_holding  (TX Holding Reg / Ctrl, NXT pacing)
//                          -> usb_tx_sync_mux (SYNC + PID/Data Mux)
//                          -> usb_tx_path     (Bit Stuffer -> NRZI -> Serializer + EOP)
//                          -> txd / tx_en / tx_se0 (to the AFE interface / transmitter)
//
// Clocking: everything runs on clk_bit (480 MHz); the 60 MHz ULPI domain is the
// tick enable ce60 (one clk_bit cycle in eight, aligned with clk60).
//
// Link-side hookup (all from usb_ulpi_input_capture / usb_ulpi_bus_owner):
//   cmd_tx, cmd_pid, lnk_valid, lnk_data, lnk_stp : captured and decoded Link signals
//   nxt_seen : NXT of the tick of the captured byte;  nxt_pin : NXT on the pin now
//   stp_raw  : unregistered STP on the pin now
//   nxt_n    : NXT request for the next tick -> tx_nxt_n of usb_ulpi_bus_owner
//   hold_busy: TX holding block busy        -> tx_busy   of usb_ulpi_bus_owner
//
// Static configuration (stable from TXCMD to tx_done)
//   speed     : XcvrSelect, 00 HS, 01 FS, 10 LS
//   bypass_en : no bit stuffing and no NRZI (OpMode "disable bit stuffing and NRZI")
//   sync_dis  : do not insert SYNC
//   eop_dis   : no EOP at the end of the packet (OpMode 10 chirp / K signalling)
//-----------------------------------------------------------------------------
`timescale 1ns/1ps

module usb_tx_datapath #(
    parameter FS_DIV = 40,
    parameter LS_DIV = 320,
    parameter DIV_W  = 9
) (
    input  wire        clk_bit,
    input  wire        rst_n,
    input  wire        ce60,

    input  wire [1:0]  speed,
    input  wire        bypass_en,
    input  wire        sync_dis,
    input  wire        eop_dis,

    // captured ULPI Link side
    input  wire        cmd_tx,
    input  wire [3:0]  cmd_pid,
    input  wire        lnk_valid,
    input  wire [7:0]  lnk_data,
    input  wire        lnk_stp,
    input  wire        nxt_seen,
    input  wire        nxt_pin,
    input  wire        stp_raw,
    output wire        nxt_n,
    output wire        hold_busy,

    // transmitter side
    output wire        txd,
    output wire        tx_en,
    output wire        tx_se0,
    output wire [1:0]  tx_speed,

    output wire        busy,
    output wire        tx_done,
    output wire        tx_underrun
);

    // holding -> mux
    wire        hdr_valid, hdr_ready, hdr_nopid, hdr_empty;
    wire [3:0]  hdr_pid;
    wire        d_valid, d_ready, d_last;
    wire [7:0]  d_data;

    // mux -> TX path (stuffer)
    wire        m_valid, m_ready, m_last;
    wire [7:0]  m_data;
    wire        mux_busy, path_busy;

    usb_tx_holding u_hold (
        .clk       (clk_bit),
        .rst_n     (rst_n),
        .ce        (ce60),
        .cmd_tx    (cmd_tx),
        .cmd_pid   (cmd_pid),
        .lnk_valid (lnk_valid),
        .lnk_data  (lnk_data),
        .lnk_stp   (lnk_stp),
        .nxt_seen  (nxt_seen),
        .nxt_pin   (nxt_pin),
        .stp_raw   (stp_raw),
        .nxt_n     (nxt_n),
        .hdr_valid (hdr_valid),
        .hdr_ready (hdr_ready),
        .hdr_pid   (hdr_pid),
        .hdr_nopid (hdr_nopid),
        .hdr_empty (hdr_empty),
        .d_valid   (d_valid),
        .d_ready   (d_ready),
        .d_data    (d_data),
        .d_last    (d_last),
        .busy      (hold_busy)
    );

    usb_tx_sync_mux u_mux (
        .clk       (clk_bit),
        .rst_n     (rst_n),
        .ce        (ce60),
        .speed     (speed),
        .sync_dis  (sync_dis),
        .hdr_valid (hdr_valid),
        .hdr_ready (hdr_ready),
        .hdr_pid   (hdr_pid),
        .hdr_nopid (hdr_nopid),
        .hdr_empty (hdr_empty),
        .d_valid   (d_valid),
        .d_ready   (d_ready),
        .d_data    (d_data),
        .d_last    (d_last),
        .out_valid (m_valid),
        .out_ready (m_ready),
        .out_data  (m_data),
        .out_last  (m_last),
        .busy      (mux_busy)
    );

    usb_tx_path #(
        .FS_DIV (FS_DIV),
        .LS_DIV (LS_DIV),
        .DIV_W  (DIV_W)
    ) u_path (
        .clk_bit     (clk_bit),
        .rst_n       (rst_n),
        .ce60        (ce60),
        .speed       (speed),
        .bypass_en   (bypass_en),
        .eop_dis     (eop_dis),
        .in_valid    (m_valid),
        .in_ready    (m_ready),
        .in_data     (m_data),
        .in_last     (m_last),
        .txd         (txd),
        .tx_en       (tx_en),
        .tx_se0      (tx_se0),
        .tx_speed    (tx_speed),
        .busy        (path_busy),
        .tx_done     (tx_done),
        .tx_underrun (tx_underrun)
    );

    assign busy = hold_busy | mux_busy | path_busy;

endmodule
