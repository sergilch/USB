//-----------------------------------------------------------------------------
// usb_ulpi_tx_top.v
//
// ULPI TX front end of the USB 2.0 PHY: ULPI pins in, line signals out.
//
//   ULPI pins --> usb_ulpi_input_capture --> usb_tx_datapath (holding, SYNC/PID mux,
//                       ^                      stuffer, NRZI, serializer) --> txd/tx_en/tx_se0
//                       |                          |  nxt_n, hold_busy
//                       +---- dir/nxt ---- usb_ulpi_bus_owner <-- PHY bursts (arb_*)
//                                                 |
//                                  ULPI pins DIR, NXT, DATA out + OE
//
// Everything runs on clk_bit with the tick enable ce60 (one cycle in eight, aligned
// with clk60).  The pad cells are outside: ulpi_data_in / ulpi_stp come from the
// input pads, ulpi_dir / ulpi_nxt / ulpi_data_out / ulpi_data_oe drive the output
// pads (DATA is bidirectional, the pad cell uses ulpi_data_oe).
//
// Open ends for the blocks still to be written
//   * arb_valid / arb_data / arb_is_data / arb_ready : byte bursts of the PHY toward
//     the Link (Output Arbiter: RX data, RXCMD, register read data)
//   * reg_nxt_n : NXT request of the Register Access FSM (tie to 0 until it exists)
//   * cmd_regw / cmd_regr / cmd_ext / cmd_addr / lnk_* / nxt_seen : captured and
//     decoded Link signals for the Register Access FSM
//   * dir_hold : keep DIR high (low-power mode)
//-----------------------------------------------------------------------------
`timescale 1ns/1ps

module usb_ulpi_tx_top #(
    parameter FS_DIV = 40,
    parameter LS_DIV = 320,
    parameter DIV_W  = 9
) (
    input  wire        clk_bit,
    input  wire        rst_n,
    input  wire        ce60,

    // ULPI pins
    input  wire [7:0]  ulpi_data_in,
    input  wire        ulpi_stp,
    output wire        ulpi_dir,
    output wire        ulpi_nxt,
    output wire [7:0]  ulpi_data_out,
    output wire        ulpi_data_oe,

    // static configuration
    input  wire [1:0]  speed,
    input  wire        bypass_en,
    input  wire        sync_dis,

    // PHY byte bursts toward the Link
    input  wire        arb_valid,
    input  wire [7:0]  arb_data,
    input  wire        arb_is_data,
    output wire        arb_ready,
    input  wire        dir_hold,

    // Register Access FSM hookup
    input  wire        reg_nxt_n,
    output wire        lnk_valid,
    output wire [7:0]  lnk_data,
    output wire        lnk_stp,
    output wire        nxt_seen,
    output wire        cmd_regw,
    output wire        cmd_regr,
    output wire        cmd_ext,
    output wire [5:0]  cmd_addr,

    // transmitter side
    output wire        txd,
    output wire        tx_en,
    output wire        tx_se0,
    output wire [1:0]  tx_speed,

    output wire        busy,
    output wire        tx_done,
    output wire        tx_underrun
);

    wire       dir_q, nxt_q, oe_q;
    wire [7:0] data_q;

    wire       stp_raw, cmd_noop, cmd_tx;
    wire [3:0] cmd_pid;
    wire       tx_nxt_n, hold_busy;

    usb_ulpi_input_capture u_cap (
        .clk       (clk_bit),
        .rst_n     (rst_n),
        .ce        (ce60),
        .data_in   (ulpi_data_in),
        .stp_in    (ulpi_stp),
        .dir_q     (dir_q),
        .nxt_q     (nxt_q),
        .lnk_valid (lnk_valid),
        .lnk_data  (lnk_data),
        .lnk_stp   (lnk_stp),
        .nxt_seen  (nxt_seen),
        .stp_raw   (stp_raw),
        .cmd_noop  (cmd_noop),
        .cmd_tx    (cmd_tx),
        .cmd_pid   (cmd_pid),
        .cmd_regw  (cmd_regw),
        .cmd_regr  (cmd_regr),
        .cmd_ext   (cmd_ext),
        .cmd_addr  (cmd_addr)
    );

    usb_tx_datapath #(
        .FS_DIV (FS_DIV),
        .LS_DIV (LS_DIV),
        .DIV_W  (DIV_W)
    ) u_dp (
        .clk_bit     (clk_bit),
        .rst_n       (rst_n),
        .ce60        (ce60),
        .speed       (speed),
        .bypass_en   (bypass_en),
        .sync_dis    (sync_dis),
        .cmd_tx      (cmd_tx),
        .cmd_pid     (cmd_pid),
        .lnk_valid   (lnk_valid),
        .lnk_data    (lnk_data),
        .lnk_stp     (lnk_stp),
        .nxt_seen    (nxt_seen),
        .nxt_pin     (nxt_q),
        .stp_raw     (stp_raw),
        .nxt_n       (tx_nxt_n),
        .hold_busy   (hold_busy),
        .txd         (txd),
        .tx_en       (tx_en),
        .tx_se0      (tx_se0),
        .tx_speed    (tx_speed),
        .busy        (busy),
        .tx_done     (tx_done),
        .tx_underrun (tx_underrun)
    );

    usb_ulpi_bus_owner u_bus (
        .clk         (clk_bit),
        .rst_n       (rst_n),
        .ce          (ce60),
        .tx_nxt_n    (tx_nxt_n),
        .reg_nxt_n   (reg_nxt_n),
        .tx_busy     (hold_busy),
        .arb_valid   (arb_valid),
        .arb_data    (arb_data),
        .arb_is_data (arb_is_data),
        .arb_ready   (arb_ready),
        .dir_hold    (dir_hold),
        .dir_q       (dir_q),
        .nxt_q       (nxt_q),
        .data_q      (data_q),
        .oe_q        (oe_q)
    );

    assign ulpi_dir      = dir_q;
    assign ulpi_nxt      = nxt_q;
    assign ulpi_data_out = data_q;
    assign ulpi_data_oe  = oe_q;

endmodule
