//-----------------------------------------------------------------------------
// usb_ulpi_phy_top.v
//
// Digital ULPI side of the USB 2.0 PHY: usb_ulpi_phy_if (pins, TX path, register access,
// RX path) connected to the ULPI Register File.
//
//   ULPI pins <--> usb_ulpi_phy_if <--reg_*--> usb_ulpi_reg_file --> configuration outputs
//                        ^    ^                        ^
//   RX datapath ---------+    +--- ie_rise/ie_fall ----+--- status inputs (comparators)
//
// Mappings done here
//   * VbusState (RXCMD) from the comparators:  VbusValid -> 11, SessValid -> 10,
//     SessEnd (VBUS below the session-end threshold) -> 00, otherwise 01.
//   * speed (TX bit rate)  = XcvrSelect of Function Control: 00 HS, 01 FS, 10 LS,
//     11 (LS via FS preamble) is sent at the FS rate by the serializer.
//   * bypass (no bit stuffing, no NRZI) = OpMode 10.  OpMode 01 (non-driving) and 11, the
//     Reset bit (soft_reset) and SuspendM / low-power handling are exported as they are:
//     reacting to them (disabling the driver, resetting the PHY core, entering low power
//     and holding DIR) belongs to the blocks that are still to be written.
//
// Clocking: everything on clk_bit with the tick enable ce60.
//-----------------------------------------------------------------------------
`timescale 1ns/1ps

module usb_ulpi_phy_top #(
    parameter FS_DIV   = 40,
    parameter LS_DIV   = 320,
    parameter DIV_W    = 9,
    parameter RX_DEPTH = 8
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

    // RX datapath
    input  wire        rx_start,
    input  wire        rx_valid,
    input  wire [7:0]  rx_data,
    input  wire        rx_end,
    input  wire        rx_error,

    // line / VBUS / ID status
    input  wire [1:0]  linestate,
    input  wire        host_disc,
    input  wire        a_vbus_vld,
    input  wire        sess_vld,
    input  wire        sess_end,
    input  wire        id_gnd,
    input  wire        alt_int,

    input  wire        dir_hold,

    // configuration (from the Register File)
    output wire [1:0]  xcvrselect,
    output wire        termselect,
    output wire [1:0]  opmode,
    output wire        suspendm,
    output wire        soft_reset,
    output wire [7:0]  ifc_ctrl,
    output wire [7:0]  otg_ctrl,
    output wire [1:0]  cfg_speed,
    output wire        cfg_bypass,

    // transmitter side
    output wire        txd,
    output wire        tx_en,
    output wire        tx_se0,
    output wire [1:0]  tx_speed,

    output wire        busy,
    output wire        tx_done,
    output wire        tx_underrun,
    output wire        rx_active,
    output wire        rx_err,
    output wire        rx_overrun
);

    wire        reg_wr, reg_rd, reg_ext, rd_valid;
    wire [7:0]  reg_addr, reg_wdata, reg_rdata;
    wire [4:0]  ie_rise, ie_fall;

    wire [1:0]  vbusstate = a_vbus_vld ? 2'b11 :
                            sess_vld   ? 2'b10 :
                            sess_end   ? 2'b00 : 2'b01;

    assign cfg_speed  = xcvrselect;
    assign cfg_bypass = (opmode == 2'b10);

    usb_ulpi_phy_if #(
        .FS_DIV   (FS_DIV),
        .LS_DIV   (LS_DIV),
        .DIV_W    (DIV_W),
        .RX_DEPTH (RX_DEPTH)
    ) u_phy (
        .clk_bit       (clk_bit),
        .rst_n         (rst_n),
        .ce60          (ce60),
        .ulpi_data_in  (ulpi_data_in),
        .ulpi_stp      (ulpi_stp),
        .ulpi_dir      (ulpi_dir),
        .ulpi_nxt      (ulpi_nxt),
        .ulpi_data_out (ulpi_data_out),
        .ulpi_data_oe  (ulpi_data_oe),
        .speed         (cfg_speed),
        .bypass_en     (cfg_bypass),
        .sync_dis      (1'b0),
        .dir_hold      (dir_hold),
        .rx_start      (rx_start),
        .rx_valid      (rx_valid),
        .rx_data       (rx_data),
        .rx_end        (rx_end),
        .rx_error      (rx_error),
        .linestate     (linestate),
        .vbusstate     (vbusstate),
        .host_disc     (host_disc),
        .id_gnd        (id_gnd),
        .alt_int       (alt_int),
        .ie_rise       (ie_rise),
        .ie_fall       (ie_fall),
        .reg_wr        (reg_wr),
        .reg_rd        (reg_rd),
        .reg_ext       (reg_ext),
        .reg_addr      (reg_addr),
        .reg_wdata     (reg_wdata),
        .reg_rdata     (reg_rdata),
        .rd_valid      (rd_valid),
        .txd           (txd),
        .tx_en         (tx_en),
        .tx_se0        (tx_se0),
        .tx_speed      (tx_speed),
        .busy          (busy),
        .tx_done       (tx_done),
        .tx_underrun   (tx_underrun),
        .rx_active     (rx_active),
        .rx_err        (rx_err),
        .rx_overrun    (rx_overrun)
    );

    usb_ulpi_reg_file u_rf (
        .clk        (clk_bit),
        .rst_n      (rst_n),
        .ce         (ce60),
        .reg_wr     (reg_wr),
        .reg_rd     (reg_rd),
        .reg_ext    (reg_ext),
        .reg_addr   (reg_addr),
        .reg_wdata  (reg_wdata),
        .reg_rdata  (reg_rdata),
        .rd_valid   (rd_valid),
        .host_disc  (host_disc),
        .a_vbus_vld (a_vbus_vld),
        .sess_vld   (sess_vld),
        .sess_end   (sess_end),
        .id_gnd     (id_gnd),
        .linestate  (linestate),
        .xcvrselect (xcvrselect),
        .termselect (termselect),
        .opmode     (opmode),
        .suspendm   (suspendm),
        .soft_reset (soft_reset),
        .ifc_ctrl   (ifc_ctrl),
        .otg_ctrl   (otg_ctrl),
        .ie_rise    (ie_rise),
        .ie_fall    (ie_fall)
    );

endmodule
