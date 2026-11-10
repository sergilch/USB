//-----------------------------------------------------------------------------
// usb_ulpi_bus_owner.v
//
// "Bus-Owner FSM (DIR / Turnaround)" plus the output registers (DIR, NXT, DATA,
// OE) of the ULPI Interface Controller (PHY side).
//
//   TX / register NXT requests --> [THIS BLOCK] --> ULPI pins DIR, NXT, DATA[7:0] (+ OE)
//   PHY byte bursts (RX data, RXCMD, register read data) --> arb_*
//
// Bus ownership
//   LINK   DIR = 0, bus driven by the Link                      (idle state)
//   TURN_P DIR = 1, nobody drives the bus (turnaround, Link -> PHY)
//   PHY    DIR = 1, the PHY drives one byte per tick (oe = 1)
//   TURN_L DIR = 0, nobody drives the bus (turnaround, PHY -> Link), then LINK
//   DIR is a state-decoded output, so it changes right after a ce edge like any
//   other registered pin; the first tick with DIR = 1 and the first tick with
//   DIR = 0 after a burst are the turnaround ticks.
//
// PHY bursts (arbiter side, ready/valid)
//   The arbiter presents bytes with arb_valid / arb_data / arb_is_data.  arb_is_data
//   is the value of NXT with that byte (1 = RX data byte, 0 = RXCMD / register data).
//   A byte is consumed in the tick arb_ready is high and appears on the pins in the
//   next tick.  The burst lasts as long as arb_valid stays high; the first tick with
//   arb_valid = 0 ends it (DIR falls one tick after the last byte).  Back-to-back
//   bursts without a gap merge into one DIR assertion.  The arbiter must hold
//   arb_valid / arb_data until arb_ready.
//
// Taking the bus (arbitration against the Link)
//   The PHY only takes the bus when the TX path is completely quiet: tx_busy = 0 and
//   no NXT on the pin in this and the previous tick (a byte may still be in flight)
//   and none requested for the next tick (tx_nxt_n / reg_nxt_n).  So the PHY never
//   steals the bus in the middle of a transmit or register access, and an NXT
//   acknowledge that has already been issued is never overtaken by DIR.  If the Link
//   is just presenting a TXCMD that was not acknowledged yet, the PHY wins the
//   collision: DIR rises, the Link withdraws the TXCMD and repeats it after DIR falls.
//
// Register read (rd_turn, from usb_ulpi_reg_access)
//   rd_turn = 1 in the tick the NXT on the pin consumes the last byte of a register
//   read.  The bus owner then goes to TURN_P at the end of that tick, although NXT is
//   high (the usual tx_ok rule would wait): ULPI 1.1 Figures 22 / 30 require DIR in the
//   cycle right after that NXT.  The read data is handed over (arb_*) in the TURN_P tick
//   and is on the bus in the next one.
//
// NXT
//   In the LINK state NXT = tx_nxt_n | reg_nxt_n (registered here).  It is forced
//   low in the tick the PHY takes the bus and in the first LINK tick after a
//   turnaround, and carries arb_is_data while the PHY drives bytes.
//
// dir_hold keeps DIR high (low-power mode: DIR held high, no bytes driven, oe = 0).
//
// Clocking: one clock with tick enable ce (1 on clk60, ce60 on clk_bit); the
//   registered outputs change only on ce ticks.
//-----------------------------------------------------------------------------
`timescale 1ns/1ps

module usb_ulpi_bus_owner (
    input  wire        clk,
    input  wire        rst_n,        // async assert, sync release
    input  wire        ce,

    // NXT requests of the Link-owned side (next-state values)
    input  wire        tx_nxt_n,     // usb_tx_holding
    input  wire        reg_nxt_n,    // Register Access FSM (tie to 0 until it exists)
    input  wire        tx_busy,      // usb_tx_holding busy
    input  wire        rd_turn,      // register read: take the bus now (see above)

    // PHY byte bursts
    input  wire        arb_valid,
    input  wire [7:0]  arb_data,
    input  wire        arb_is_data,
    output wire        arb_ready,

    input  wire        dir_hold,

    // pins (registered)
    output wire        dir_q,
    output wire        nxt_q,
    output wire [7:0]  data_q,
    output wire        oe_q
);

    localparam [1:0] S_LINK   = 2'd0;
    localparam [1:0] S_TURN_P = 2'd1;
    localparam [1:0] S_PHY    = 2'd2;
    localparam [1:0] S_TURN_L = 2'd3;

    reg [1:0] st;
    reg [7:0] data_r;
    reg       nxt_r;
    reg       nxt_d;                 // NXT of the previous tick
    reg       vld_r;                 // data_r holds a byte for the current tick

    assign dir_q  = (st == S_TURN_P) || (st == S_PHY);
    assign oe_q   = (st == S_PHY) && vld_r;
    assign nxt_q  = nxt_r;
    assign data_q = data_r;

    wire tx_ok = !tx_busy && !nxt_r && !nxt_d && !tx_nxt_n && !reg_nxt_n;
    wire want  = arb_valid || dir_hold;

    reg [1:0] st_n;
    reg       rdy;
    reg       nxt_n;

    always @* begin
        st_n = st;
        rdy  = 1'b0;
        case (st)
            S_LINK: begin
                if (rd_turn || (want && tx_ok))
                    st_n = S_TURN_P;
            end
            S_TURN_P: begin
                if (arb_valid) begin
                    rdy  = 1'b1;
                    st_n = S_PHY;
                end else if (dir_hold) begin
                    st_n = S_PHY;
                end else begin
                    st_n = S_TURN_L;
                end
            end
            S_PHY: begin
                if (arb_valid)
                    rdy = 1'b1;
                else if (!dir_hold)
                    st_n = S_TURN_L;
            end
            default: st_n = S_LINK;       // S_TURN_L
        endcase

        if ((st == S_LINK) && (st_n == S_LINK))
            nxt_n = tx_nxt_n | reg_nxt_n;
        else if (st_n == S_PHY)
            nxt_n = rdy ? arb_is_data : 1'b0;
        else
            nxt_n = 1'b0;
    end

    assign arb_ready = ce && rdy;

    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            st     <= S_LINK;
            data_r <= 8'd0;
            nxt_r  <= 1'b0;
            nxt_d  <= 1'b0;
            vld_r  <= 1'b0;
        end else if (ce) begin
            st     <= st_n;
            nxt_r  <= nxt_n;
            nxt_d  <= nxt_r;
            vld_r  <= rdy;
            if (rdy)
                data_r <= arb_data;
        end
    end

endmodule
