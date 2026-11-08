//-----------------------------------------------------------------------------
// usb_ulpi_input_capture.v
//
// "Input Capture" + "TXCMD Decoder / Input Qualifier" of the ULPI Interface
// Controller (PHY side).
//
//   ULPI pins DATA[7:0] / STP --> [THIS BLOCK] --> usb_tx_holding (TX path)
//                                      |       \-> Register Access FSM (later)
//   dir_q, nxt_q  <-- usb_ulpi_bus_owner (what the PHY itself drives on DIR / NXT)
//
// Timing (ticks = clock cycles with ce = 1; ce = 1 on clk60, ce60 on clk_bit):
//   * DATA and STP are registered, so all captured signals describe the pin values
//     of the PREVIOUS tick.
//   * lnk_valid says that the captured byte was driven by the Link: DIR was low in
//     that tick and in the tick before it (the first tick after DIR falls is the
//     turnaround tick, in which nobody drives the bus).
//   * nxt_seen is the NXT value that was on the pin in the tick of the captured
//     byte (nxt_q delayed by one tick).  A byte is consumed by the PHY when
//     nxt_seen = 1; usb_tx_holding and the Register Access FSM use it to qualify
//     the captured byte.
//   * stp_abort is the captured STP seen while the PHY owned the bus (DIR high in that
//     tick and in the tick before it): the Link aborts a receive with it.
//   * stp_raw is the unregistered STP of the CURRENT tick, qualified with the same
//     bus-ownership rule.  It lets the TX path withdraw NXT in the tick right after
//     STP, which the registered path would be a tick too late for.
//
// Command decode of the captured byte (only while lnk_valid = 1):
//   00h              NOOP / idle
//   01 00 PPPP       transmit TXCMD  (cmd_tx, cmd_pid = PPPP, 0 = NOPID)
//   10 AAAAAA        register write  (cmd_regw, cmd_addr)   AAAAAA = 2Fh: extended
//   11 AAAAAA        register read   (cmd_regr, cmd_addr)   AAAAAA = 2Fh: extended
//   Other codes are not decoded (all cmd_* low).
//   The decode is level based: a command stays decoded for as long as the Link holds
//   it on the bus (until NXT), and the consumers qualify it with nxt_seen.
//-----------------------------------------------------------------------------
`timescale 1ns/1ps

module usb_ulpi_input_capture (
    input  wire        clk,
    input  wire        rst_n,        // async assert, sync release
    input  wire        ce,

    // ULPI pins (inputs from the pad cells)
    input  wire [7:0]  data_in,
    input  wire        stp_in,

    // what the PHY drives on DIR / NXT (from usb_ulpi_bus_owner)
    input  wire        dir_q,
    input  wire        nxt_q,

    // captured, aligned signals
    output wire        lnk_valid,
    output wire [7:0]  lnk_data,
    output wire        lnk_stp,      // captured STP, qualified with lnk_valid
    output wire        nxt_seen,
    output wire        stp_raw,
    output wire        stp_abort,    // STP while the PHY owns the bus (Link abort of a receive)

    // command decode of the captured byte
    output wire        cmd_noop,
    output wire        cmd_tx,
    output wire [3:0]  cmd_pid,
    output wire        cmd_regw,
    output wire        cmd_regr,
    output wire        cmd_ext,      // extended register access (address field 2Fh)
    output wire [5:0]  cmd_addr
);

    reg        dir_prev;
    reg [7:0]  data_r;
    reg        stp_r;
    reg        val_r;
    reg        phy_r;
    reg        nxt_d;

    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            dir_prev <= 1'b0;
            data_r   <= 8'd0;
            stp_r    <= 1'b0;
            val_r    <= 1'b0;
            phy_r    <= 1'b0;
            nxt_d    <= 1'b0;
        end else if (ce) begin
            dir_prev <= dir_q;
            data_r   <= data_in;
            stp_r    <= stp_in;
            val_r    <= !dir_q && !dir_prev;      // Link owned the bus in this tick
            phy_r    <= dir_q && dir_prev;        // PHY owned the bus in this tick
            nxt_d    <= nxt_q;
        end
    end

    assign lnk_valid = val_r;
    assign lnk_data  = data_r;
    assign lnk_stp   = val_r && stp_r;
    assign nxt_seen  = nxt_d;
    assign stp_raw   = stp_in && !dir_q && !dir_prev;
    assign stp_abort = phy_r && stp_r;

    assign cmd_noop  = val_r && (data_r == 8'h00);
    assign cmd_tx    = val_r && (data_r[7:4] == 4'b0100);
    assign cmd_pid   = data_r[3:0];
    assign cmd_regw  = val_r && (data_r[7:6] == 2'b10);
    assign cmd_regr  = val_r && (data_r[7:6] == 2'b11);
    assign cmd_ext   = (cmd_regw || cmd_regr) && (data_r[5:0] == 6'h2F);
    assign cmd_addr  = data_r[5:0];

endmodule
