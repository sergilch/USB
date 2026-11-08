//-----------------------------------------------------------------------------
// usb_ulpi_burst_mux.v
//
// Minimal arbitration between the byte bursts that the PHY sends to the Link:
//   * register read data (usb_ulpi_reg_access, NXT = 0, always a burst of ONE byte)
//   * everything else (rd_*): the Output Arbiter / RX Data Handler / RXCMD Generator
//     of the PHY (ext_*), whose bursts last as long as ext_valid stays high
// toward the ready/valid burst input of usb_ulpi_bus_owner (out_*).
//
// Rules
//   * Register data has priority, but a PHY burst that has already started (a byte
//     consumed and ext_valid still high) is never interrupted: ext_mid.
//   * The register byte is followed by one tick with out_valid = 0, so it always forms
//     a burst of its own (DIR falls after it) and is never merged with a PHY burst.
//   * out_ready is the arb_ready of the bus owner; it is routed to the source that is
//     currently selected.
//
// This block is a stand-in for the priority logic of the Output Arbiter and is meant
// to be replaced / absorbed by it later.
//
// Clocking: one clock with tick enable ce (1 on clk60, ce60 on clk_bit).
//-----------------------------------------------------------------------------
`timescale 1ns/1ps

module usb_ulpi_burst_mux (
    input  wire        clk,
    input  wire        rst_n,
    input  wire        ce,

    // register read data burst
    input  wire        rd_valid,
    input  wire [7:0]  rd_data,
    output wire        rd_ready,

    // PHY burst source
    input  wire        ext_valid,
    input  wire [7:0]  ext_data,
    input  wire        ext_is_data,
    output wire        ext_ready,

    // toward usb_ulpi_bus_owner
    output wire        out_valid,
    output wire [7:0]  out_data,
    output wire        out_is_data,
    input  wire        out_ready
);

    reg ext_mid;                           // a PHY burst is in progress
    reg gap;                               // one empty tick after the register byte

    wire use_reg = rd_valid && !ext_mid;

    assign out_valid   = !gap && (use_reg ? rd_valid : ext_valid);
    assign out_data    = use_reg ? rd_data : ext_data;
    assign out_is_data = use_reg ? 1'b0 : ext_is_data;

    assign rd_ready    = out_ready && use_reg && !gap;
    assign ext_ready   = out_ready && !use_reg;

    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            ext_mid <= 1'b0;
            gap     <= 1'b0;
        end else if (ce) begin
            gap <= rd_ready;
            if (ext_ready)
                ext_mid <= 1'b1;
            else if (!ext_valid)
                ext_mid <= 1'b0;
        end
    end

endmodule
