//-----------------------------------------------------------------------------
// usb_ulpi_out_arbiter.v
//
// "Output Arbiter / Byte Mux" of the ULPI Interface Controller (PHY side): chooses the
// byte that the PHY sends to the Link in the next tick.  It is purely combinational and
// feeds the burst input of usb_ulpi_burst_mux (and from there usb_ulpi_bus_owner).
//
// Priority
//   1. RX data byte      (NXT = 1)   - from usb_ulpi_rx_handler, only released after the
//                                      RXCMD with RxActive = 1 has been sent
//   2. RXCMD byte        (NXT = 0)   - when usb_ulpi_rxcmd_gen requests it, and as a
//                                      filler while an RX packet is active and there is no
//                                      data (ULPI has no "idle" byte: with DIR high and
//                                      NXT low the bus carries an RXCMD, repeating the same
//                                      RXCMD is allowed), which keeps DIR high for the whole
//                                      packet without toggling the bus
//   3. nothing           - the burst ends (one tick without ext_valid), DIR falls
// Register read data is arbitrated further downstream in usb_ulpi_burst_mux.
//
// The RXCMD sent is always the current one (cmd_now); rxd_ready / cmd_taken tell the
// RX Data Handler and the RXCMD Generator which source was consumed (ext_ready already
// contains ce).
//-----------------------------------------------------------------------------
`timescale 1ns/1ps

module usb_ulpi_out_arbiter (
    // RX Data Handler
    input  wire        rxd_valid,
    input  wire [7:0]  rxd_data,
    output wire        rxd_ready,

    // RXCMD Generator
    input  wire        rxcmd_req,
    input  wire [7:0]  cmd_now,
    input  wire        rx_active,
    output wire        cmd_taken,

    // burst toward usb_ulpi_burst_mux
    output wire        ext_valid,
    output wire [7:0]  ext_data,
    output wire        ext_is_data,
    input  wire        ext_ready
);

    wire want_cmd = rxcmd_req || rx_active;

    assign ext_valid   = rxd_valid || want_cmd;
    assign ext_data    = rxd_valid ? rxd_data : cmd_now;
    assign ext_is_data = rxd_valid;

    assign rxd_ready   = ext_ready && rxd_valid;
    assign cmd_taken   = ext_ready && !rxd_valid && want_cmd;

endmodule
