//-----------------------------------------------------------------------------
// usb_ulpi_rx_path.v
//
// RX side of the ULPI Interface Controller: RX Data Handler + RXCMD Generator + Output
// Arbiter.  Its burst output (ext_*) feeds usb_ulpi_burst_mux / usb_ulpi_bus_owner.
//
//   RX datapath --> usb_ulpi_rx_handler --+--> usb_ulpi_out_arbiter --> ext_* burst
//   status      --> usb_ulpi_rxcmd_gen ---+          (RX data > RXCMD)
//
// RX datapath side (all synchronous to the tick clock, pulses are one tick long):
//   rx_start, rx_valid / rx_data, rx_error, rx_end - see usb_ulpi_rx_handler
//   rx_abort                                      - STP seen while the PHY owns the bus
//                                                   (usb_ulpi_input_capture.stp_abort)
// Status side: linestate, vbusstate, host_disc, id_gnd, alt_int and the USB Interrupt
//   Enable registers ie_rise / ie_fall (see usb_ulpi_rxcmd_gen).
//
// Clocking: one clock with tick enable ce (1 on clk60, ce60 on clk_bit).
//-----------------------------------------------------------------------------
`timescale 1ns/1ps

module usb_ulpi_rx_path #(
    parameter DEPTH = 8
) (
    input  wire        clk,
    input  wire        rst_n,
    input  wire        ce,

    // RX datapath
    input  wire        rx_start,
    input  wire        rx_valid,
    input  wire [7:0]  rx_data,
    input  wire        rx_end,
    input  wire        rx_error,
    input  wire        rx_abort,

    // status
    input  wire [1:0]  linestate,
    input  wire [1:0]  vbusstate,
    input  wire        host_disc,
    input  wire        id_gnd,
    input  wire        alt_int,
    input  wire [4:0]  ie_rise,
    input  wire [4:0]  ie_fall,

    // burst toward the bus owner (through usb_ulpi_burst_mux)
    output wire        ext_valid,
    output wire [7:0]  ext_data,
    output wire        ext_is_data,
    input  wire        ext_ready,

    output wire        rx_active,
    output wire        rx_err,
    output wire        overrun
);

    wire       rxd_valid, rxd_ready, rxcmd_req, cmd_taken;
    wire [7:0] rxd_data, cmd_now;
    wire [1:0] sent_rxev;

    usb_ulpi_rx_handler #(.DEPTH(DEPTH)) u_h (
        .clk       (clk),
        .rst_n     (rst_n),
        .ce        (ce),
        .rx_start  (rx_start),
        .rx_valid  (rx_valid),
        .rx_data   (rx_data),
        .rx_end    (rx_end),
        .rx_error  (rx_error),
        .rx_abort  (rx_abort),
        .sent_rxev (sent_rxev),
        .rxa       (rx_active),
        .rxe       (rx_err),
        .rxd_valid (rxd_valid),
        .rxd_data  (rxd_data),
        .rxd_ready (rxd_ready),
        .overrun   (overrun)
    );

    usb_ulpi_rxcmd_gen u_g (
        .clk       (clk),
        .rst_n     (rst_n),
        .ce        (ce),
        .linestate (linestate),
        .vbusstate (vbusstate),
        .host_disc (host_disc),
        .id_gnd    (id_gnd),
        .alt_int   (alt_int),
        .rxa       (rx_active),
        .rxe       (rx_err),
        .ie_rise   (ie_rise),
        .ie_fall   (ie_fall),
        .cmd_taken (cmd_taken),
        .cmd_now   (cmd_now),
        .rxcmd_req (rxcmd_req),
        .sent_rxev (sent_rxev)
    );

    usb_ulpi_out_arbiter u_a (
        .rxd_valid   (rxd_valid),
        .rxd_data    (rxd_data),
        .rxd_ready   (rxd_ready),
        .rxcmd_req   (rxcmd_req),
        .cmd_now     (cmd_now),
        .rx_active   (rx_active),
        .cmd_taken   (cmd_taken),
        .ext_valid   (ext_valid),
        .ext_data    (ext_data),
        .ext_is_data (ext_is_data),
        .ext_ready   (ext_ready)
    );

endmodule
