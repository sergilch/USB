//-----------------------------------------------------------------------------
// usb_ulpi_core.v
//
// ULPI Interface Controller core of the USB 2.0 PHY: ULPI pins on one side, the
// transmitter line signals, the ULPI Register File and the PHY byte-burst source on
// the other.
//
//   pins --> usb_ulpi_input_capture --+--> usb_tx_datapath (holding, SYNC/PID mux,
//              ^                      |        stuffer, NRZI, serializer) --> txd/tx_en/tx_se0
//              |                      +--> usb_ulpi_reg_access <--> ULPI Register File
//              |                                   |  (read data burst)
//              |        PHY bursts (arb_*) --> usb_ulpi_burst_mux
//              |                                   |
//              +------ dir/nxt ------ usb_ulpi_bus_owner --> pins DIR, NXT, DATA out + OE
//
// Everything runs on clk_bit with the tick enable ce60 (one cycle in eight, aligned with
// clk60).  The pad cells are outside (usb_ulpi_phy_pads): ulpi_data_in / ulpi_stp come
// from the input pads, ulpi_dir / ulpi_nxt / ulpi_data_out / ulpi_data_oe drive the
// output pads.
//
// How the two Link-driven transfer types are kept apart
//   * a register command is not acknowledged while a TX packet is in progress
//     (usb_tx_holding busy), and TXCMD decoding is inhibited while the Link is still
//     driving bytes of a register transfer (reg_link_busy), because payload / address /
//     data bytes can look like commands;
//   * the bus owner never takes the bus while either of them is active;
//   * between the acknowledge of a register read and its data (rd_pend) the burst mux
//     starts no PHY burst, so the read data is the first byte after the turnaround and
//     a pending RXCMD goes out after it; the read itself is fixed-latency (rd_turn, see
//     usb_ulpi_reg_access): turnaround in the cycle after the last NXT, then the data.
//
// ULPI holding state (ULPI 1.1 section 3.12)
//   STP high while the Link owns the bus and neither a TX packet nor a register
//   transfer is in progress (so nothing expects an STP) means the Link cannot drive the
//   interface (reset, power-up, tri-stated outputs held by the STP pull-up of the pads):
//   * the captured byte of such a cycle is not a command (cmd_ok = 0): no TXCMD, no
//     register command is decoded or acknowledged;
//   * the PHY does not take the bus (DIR stays low), checked against the captured STP
//     and against the STP on the pin, so DIR cannot rise in the cycle after STP rose.
//     RXCMD changes meanwhile are not sent; the RXCMD Generator compares against what
//     the Link was told last, so a single RXCMD with the current values goes out when
//     the holding state ends.
//   The holding state ends with the first cycle in which STP is low: its data is
//   processed normally ("the PHY begins processing its data inputs in the cycle when
//   dir and stp are both low").  An STP that ends a transfer is expected, so it does not
//   enter the holding state; an STP that is held longer than that (ULPI Fig. 55: the
//   Link drives STP high before it stops driving) does.
//
// Still open: the Output Arbiter / RX Data Handler / RXCMD Generator (they drive
// arb_*), the low-power controller (dir_hold) and the Register File itself.
//-----------------------------------------------------------------------------
`timescale 1ns/1ps

module usb_ulpi_core #(
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
    input  wire        eop_dis,

    // PHY byte bursts toward the Link
    input  wire        arb_valid,
    input  wire [7:0]  arb_data,
    input  wire        arb_is_data,
    output wire        arb_ready,
    input  wire        dir_hold,

    // ULPI Register File
    output wire        reg_wr,
    output wire        reg_rd,
    output wire        reg_ext,
    output wire [7:0]  reg_addr,
    output wire [7:0]  reg_wdata,
    input  wire [7:0]  reg_rdata,
    input  wire        rd_valid,

    // Link abort of a receive (STP while the PHY owns the bus), for usb_ulpi_rx_path
    output wire        stp_abort,

    // transmitter side
    output wire        txd,
    output wire        tx_en,
    output wire        tx_se0,
    output wire [1:0]  tx_speed,

    output wire        busy,
    output wire        tx_done,
    output wire        tx_underrun
);

    // pins as driven by the bus owner
    wire       dir_q, nxt_q, oe_q;
    wire [7:0] data_q;

    // input capture
    wire       lnk_valid, lnk_stp, nxt_seen, stp_raw;
    wire [7:0] lnk_data;
    wire       cmd_noop, cmd_tx, cmd_regw, cmd_regr, cmd_ext;
    wire [3:0] cmd_pid;
    wire [5:0] cmd_addr;

    // TX datapath
    wire       tx_nxt_n, hold_busy, dp_busy;
    // register access
    wire       reg_nxt_n, reg_link_busy, reg_busy;
    wire       xfer_busy, holding, cmd_ok;
    wire       rg_burst_valid, rg_burst_ready, rg_rd_pend, rg_rd_turn;
    wire [7:0] rg_burst_data;
    // burst mux -> bus owner
    wire       m_valid, m_is_data, m_ready;
    wire [7:0] m_data;

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
        .stp_abort (stp_abort),
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
        .eop_dis     (eop_dis),
        .cmd_tx      (cmd_tx && !reg_link_busy && cmd_ok),  // not while a register transfer runs
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
        .busy        (dp_busy),
        .tx_done     (tx_done),
        .tx_underrun (tx_underrun)
    );

    usb_ulpi_reg_access u_reg (
        .clk            (clk_bit),
        .rst_n          (rst_n),
        .ce             (ce60),
        .cmd_regw       (cmd_regw && cmd_ok),
        .cmd_regr       (cmd_regr && cmd_ok),
        .cmd_ext        (cmd_ext),
        .cmd_addr       (cmd_addr),
        .lnk_valid      (lnk_valid),
        .lnk_data       (lnk_data),
        .lnk_stp        (lnk_stp),
        .nxt_seen       (nxt_seen),
        .nxt_pin        (nxt_q),
        .stp_raw        (stp_raw),
        .tx_busy        (hold_busy),
        .nxt_n          (reg_nxt_n),
        .link_busy      (reg_link_busy),
        .reg_wr         (reg_wr),
        .reg_rd         (reg_rd),
        .reg_ext        (reg_ext),
        .reg_addr       (reg_addr),
        .reg_wdata      (reg_wdata),
        .reg_rdata      (reg_rdata),
        .rd_valid       (rd_valid),
        .rd_burst_valid (rg_burst_valid),
        .rd_burst_data  (rg_burst_data),
        .rd_burst_ready (rg_burst_ready),
        .rd_pend        (rg_rd_pend),
        .rd_turn        (rg_rd_turn),
        .busy           (reg_busy)
    );

    usb_ulpi_burst_mux u_mux (
        .clk         (clk_bit),
        .rst_n       (rst_n),
        .ce          (ce60),
        .rd_valid    (rg_burst_valid),
        .rd_data     (rg_burst_data),
        .rd_ready    (rg_burst_ready),
        .rd_pend     (rg_rd_pend),
        .ext_valid   (arb_valid),
        .ext_data    (arb_data),
        .ext_is_data (arb_is_data),
        .ext_ready   (arb_ready),
        .out_valid   (m_valid),
        .out_data    (m_data),
        .out_is_data (m_is_data),
        .out_ready   (m_ready)
    );

    usb_ulpi_bus_owner u_bus (
        .clk         (clk_bit),
        .rst_n       (rst_n),
        .ce          (ce60),
        .tx_nxt_n    (tx_nxt_n),
        .reg_nxt_n   (reg_nxt_n),
        .tx_busy     (hold_busy | reg_link_busy | holding),
        .rd_turn     (rg_rd_turn),
        .arb_valid   (m_valid),
        .arb_data    (m_data),
        .arb_is_data (m_is_data),
        .arb_ready   (m_ready),
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
    assign busy          = dp_busy | reg_busy;

    // ---------------- ULPI holding state ----------------
    assign xfer_busy = hold_busy | reg_busy;              // a transfer that may end with STP
    assign cmd_ok    = !(lnk_stp && !xfer_busy);          // captured cycle had STP unexpectedly high
    assign holding   = (lnk_stp || stp_raw) && !xfer_busy;

endmodule
