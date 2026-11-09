//-----------------------------------------------------------------------------
// usb_rx_decoder.v
//
// RX bit chain of the USB 2.0 PHY: from received line bits to packet events.
//
//   b_* (front end) -> usb_rx_nrzi_decoder -> usb_rx_sync_detect
//                   -> usb_rx_bit_unstuffer -> usb_rx_deserializer
//                   -> usb_rx_eop_check -> ev_wr / ev_data (to the elastic buffer)
//
// Every stage is one register deep and passes the bit strobe (en) with its
// sideband, so the chain has a fixed latency of 5 clocks and no stalls: one
// bit can enter in every clock (HS: every recovered clock).  The only feedback
// is the elastic buffer's almost-full flag into the EOP check.
//
// Two instances are used in usb_rx_datapath: HS = 1 on the recovered HS clock,
// HS = 0 on clk_bit for FS / LS.  The event format and the end / error rules
// are described in usb_rx_eop_check.
//
// Clocking: one clock `clk`, active-low asynchronous reset rst_n.
//-----------------------------------------------------------------------------
`timescale 1ns/1ps

module usb_rx_decoder #(
    parameter HS   = 1,
    parameter ZMIN = 6
) (
    input  wire       clk,
    input  wire       rst_n,

    input  wire       b_en,
    input  wire       b_lvl,
    input  wire       b_se0,
    input  wire       b_act,

    input  wire       buf_afull,
    output wire       ev_wr,
    output wire [9:0] ev_data,
    output wire       busy,
    output wire       ovf
);

    wire n_en, n_bit, n_se0, n_act;
    wire s_en, s_bit, s_se0, s_act, s_sync, s_pkt;
    wire u_en, u_dat, u_bit, u_serr, u_se0, u_act, u_sync, u_pkt;
    wire d_en, d_byte_en, d_serr, d_se0, d_act, d_sync;
    wire [7:0] d_byte;
    wire [2:0] d_nres;

    usb_rx_nrzi_decoder u_nrzi (
        .clk   (clk),   .rst_n (rst_n),
        .i_en  (b_en),  .i_lvl (b_lvl), .i_se0 (b_se0), .i_act (b_act),
        .o_en  (n_en),  .o_bit (n_bit), .o_se0 (n_se0), .o_act (n_act)
    );

    usb_rx_sync_detect #(.ZMIN(ZMIN)) u_syncdet (
        .clk    (clk),    .rst_n (rst_n),
        .i_en   (n_en),   .i_bit (n_bit), .i_se0 (n_se0), .i_act (n_act),
        .o_en   (s_en),   .o_bit (s_bit), .o_se0 (s_se0), .o_act (s_act),
        .o_sync (s_sync), .o_pkt (s_pkt)
    );

    usb_rx_bit_unstuffer u_unstuff (
        .clk    (clk),    .rst_n  (rst_n),
        .i_en   (s_en),   .i_bit  (s_bit), .i_se0 (s_se0), .i_act (s_act),
        .i_sync (s_sync), .i_pkt  (s_pkt),
        .o_en   (u_en),   .o_dat  (u_dat), .o_bit (u_bit), .o_serr (u_serr),
        .o_se0  (u_se0),  .o_act  (u_act), .o_sync (u_sync), .o_pkt (u_pkt)
    );

    usb_rx_deserializer u_deser (
        .clk       (clk),       .rst_n  (rst_n),
        .i_en      (u_en),      .i_dat  (u_dat),  .i_bit (u_bit), .i_serr (u_serr),
        .i_se0     (u_se0),     .i_act  (u_act),  .i_sync (u_sync),
        .o_en      (d_en),      .o_byte_en (d_byte_en), .o_byte (d_byte), .o_nres (d_nres),
        .o_serr    (d_serr),    .o_se0  (d_se0),  .o_act (d_act), .o_sync (d_sync)
    );

    usb_rx_eop_check #(.HS(HS)) u_eop (
        .clk       (clk),       .rst_n   (rst_n),
        .i_en      (d_en),      .i_byte_en (d_byte_en), .i_byte (d_byte), .i_nres (d_nres),
        .i_serr    (d_serr),    .i_se0   (d_se0),  .i_act (d_act), .i_sync (d_sync),
        .buf_afull (buf_afull),
        .ev_wr     (ev_wr),     .ev_data (ev_data), .busy (busy), .ovf (ovf)
    );

endmodule
