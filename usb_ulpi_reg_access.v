//-----------------------------------------------------------------------------
// usb_ulpi_reg_access.v
//
// "Register Access FSM" of the ULPI Interface Controller (PHY side): ULPI register
// write / read, immediate (00h-3Fh) and extended (pointer 2Fh, 00h-FFh).
//
//   usb_ulpi_input_capture --> [THIS BLOCK] <--> ULPI Register File
//                                   |  \--> nxt_n     (NXT request, registered in usb_ulpi_bus_owner)
//                                   |  \--> rd burst  (register data toward the Link, through usb_ulpi_burst_mux)
//
// ULPI protocol as implemented (ticks = clock cycles with ce = 1; NXT = 1 in a tick
// consumes the byte that the Link drives in that tick; the Link holds every byte until
// it is consumed):
//   register write            : RegWrite cmd (10 AAAAAA) -> data byte -> STP in the tick
//                               after the data byte; the register is written at STP
//   extended register write   : cmd AFh -> address byte -> data byte -> STP
//   register read             : RegRead cmd (11 AAAAAA) -> the PHY takes the bus
//                               (turnaround), returns the register value with NXT = 0 as
//                               a burst of one byte, releases the bus
//   extended register read    : cmd EFh -> address byte -> read data as above
//
// Read timing (fixed, ULPI 1.1 Figures 22 / 30): NXT on the pin consumes the last byte
//   of the read (the command, or the extended address) in tick N; DIR rises in N+1
//   (turnaround), the data is on the bus in N+2 with NXT = 0, DIR falls in N+3.
//   * tick N:   rd_ack_q = 1 (this NXT was planned as the last NXT of a read) and NXT is
//               on the pin -> rd_turn: usb_ulpi_bus_owner takes the bus at the end of N.
//   * tick N+1: the captured byte (lnk_data) is that last byte, so the address is known:
//               reg_rd is pulsed, the Register File answers in the same tick, and the
//               value goes straight to the bus owner (rd_burst_*), which is in its
//               turnaround state and consumes it -> on the bus in N+2.
//   If the bus owner does not consume it in N+1 (should not happen), the value is kept
//   in rdata_q and sent as soon as the bus owner takes it (S_RRET).
//
// Latency handling (same as usb_tx_holding): the captured Link signals are one tick old,
//   so a byte is taken when nxt_seen = 1; the NXT acknowledges are planned against the
//   NXT that is already on the pin (nxt_pin).  The command is acknowledged with one NXT,
//   and one further NXT is issued per byte that the command still needs, in consecutive
//   ticks, but never for a plain register read.  NXT is withdrawn when STP is on the pin
//   (stp_raw).
//
// Register File interface (as in the register-file block diagram)
//   reg_wr   : one-tick pulse at STP, reg_addr / reg_wdata / reg_ext valid
//   reg_rd   : one-tick pulse, reg_addr / reg_ext valid; the Register File must answer
//              in the SAME tick (reg_rdata combinational from reg_addr, rd_valid =
//              reg_rd).  rd_valid is kept in the port list for the interface but not
//              needed here: the fixed ULPI read timing leaves no room for wait states.
//   reg_ext  : 1 = extended register set (reg_addr 8 bits), 0 = immediate (6 bits)
//
// Coordination with the TX path
//   * tx_busy (usb_tx_holding busy): a register command is not acknowledged while a TX
//     packet is in progress, so payload bytes that look like commands are never decoded.
//   * link_busy = 1 while the Link is still driving bytes of a register transfer; it
//     inhibits the TXCMD decode (the bytes of a register transfer can look like a
//     TXCMD) and keeps the bus owner from taking the bus.  It is low while the read
//     data is fetched and returned, so the bus owner can take the bus for the return.
//   * The read data goes out as its own one-byte burst (rd_burst_*, NXT = 0).
//   * rd_pend = 1 in tick N (read acknowledged, data not on its way yet) and while a
//     value waits in S_RRET: usb_ulpi_burst_mux holds PHY bursts back meanwhile, so the
//     read data is the first byte after the turnaround (ULPI 1.1 3.8.3.1) and never
//     comes after an RXCMD, which the Link could not tell apart from it (both NXT = 0).
//
// Clocking: one clock with tick enable ce (1 on clk60, ce60 on clk_bit).
//-----------------------------------------------------------------------------
`timescale 1ns/1ps

module usb_ulpi_reg_access (
    input  wire        clk,
    input  wire        rst_n,         // async assert, sync release
    input  wire        ce,

    // from usb_ulpi_input_capture
    input  wire        cmd_regw,
    input  wire        cmd_regr,
    input  wire        cmd_ext,
    input  wire [5:0]  cmd_addr,
    input  wire        lnk_valid,
    input  wire [7:0]  lnk_data,
    input  wire        lnk_stp,
    input  wire        nxt_seen,
    input  wire        nxt_pin,
    input  wire        stp_raw,

    input  wire        tx_busy,       // usb_tx_holding busy

    // NXT request toward usb_ulpi_bus_owner (reg_nxt_n)
    output wire        nxt_n,
    output wire        link_busy,

    // ULPI Register File
    output wire        reg_wr,
    output wire        reg_rd,
    output wire        reg_ext,
    output wire [7:0]  reg_addr,
    output wire [7:0]  reg_wdata,
    input  wire [7:0]  reg_rdata,
    input  wire        rd_valid,      // = reg_rd (same-tick answer), not used

    // register data burst toward the Link (through usb_ulpi_burst_mux; NXT = 0)
    output wire        rd_burst_valid,
    output wire [7:0]  rd_burst_data,
    input  wire        rd_burst_ready,
    output wire        rd_pend,       // read acknowledged, data not ready yet
    output wire        rd_turn,       // take the bus now: NXT on the pin ends a read

    output wire        busy
);

    localparam [2:0] S_IDLE  = 3'd0;
    localparam [2:0] S_AB    = 3'd1;   // waiting for the extended address byte
    localparam [2:0] S_WD    = 3'd2;   // waiting for the write data byte
    localparam [2:0] S_WSTP  = 3'd3;   // waiting for STP, then write the register
    localparam [2:0] S_RRET  = 3'd6;   // read data not consumed at once: waiting

    reg [2:0] st;
    reg [1:0] rem;                      // bytes still to be taken after the command
    reg       op_wr;
    reg       ext_q;
    reg [7:0] addr_q;
    reg [7:0] data_q;
    reg [7:0] rdata_q;
    reg       rd_ack_q;                 // the NXT on the pin ends a read (planned last tick)

    // ---------------- decode of the captured Link byte ----------------
    wire cmd_eff    = (cmd_regw || cmd_regr) && !tx_busy;
    wire take_cmd0  = (st == S_IDLE) && nxt_seen && cmd_eff;
    wire take_byte0 = ((st == S_AB) || (st == S_WD)) && nxt_seen && lnk_valid && !lnk_stp;
    wire take_cmd   = ce && take_cmd0;
    wire take_byte  = ce && take_byte0;
    wire stp_evt    = ce && (st == S_WSTP) && lnk_valid && lnk_stp;

    // the read itself (tick N+1): immediate read when its command is taken, extended
    // read when its address byte is taken
    wire rd_imm0 = take_cmd0 && cmd_regr && !cmd_ext;
    wire rd_ext0 = take_byte0 && (st == S_AB) && !op_wr;
    wire rd_now0 = rd_imm0 || rd_ext0;

    // ---------------- outputs ----------------
    assign link_busy = (st == S_AB) || (st == S_WD) || (st == S_WSTP);
    assign busy      = (st != S_IDLE);

    assign reg_wr    = stp_evt;
    assign reg_rd    = ce && rd_now0;
    assign reg_ext   = rd_now0 ? rd_ext0 : ext_q;
    assign reg_addr  = rd_ext0 ? lnk_data : (rd_imm0 ? {2'b00, cmd_addr} : addr_q);
    assign reg_wdata = data_q;

    assign rd_turn        = rd_ack_q && nxt_pin;
    assign rd_pend        = rd_ack_q || (st == S_RRET);
    assign rd_burst_valid = rd_now0 || (st == S_RRET);
    assign rd_burst_data  = (st == S_RRET) ? rdata_q : reg_rdata;

    // ---------------- next-state logic ----------------
    reg [2:0] st_n;
    reg [1:0] rem_n;
    reg       nxt_r;
    reg       last_rd;                  // nxt_r is the last NXT of a register read

    always @* begin
        st_n  = st;
        rem_n = rem;
        case (st)
            S_IDLE: begin
                if (take_cmd) begin
                    if (cmd_regw) begin
                        rem_n = cmd_ext ? 2'd2 : 2'd1;
                        st_n  = cmd_ext ? S_AB : S_WD;
                    end else begin
                        rem_n = cmd_ext ? 2'd1 : 2'd0;
                        st_n  = cmd_ext ? S_AB : (rd_burst_ready ? S_IDLE : S_RRET);
                    end
                end
            end
            S_AB: begin
                if (take_byte) begin
                    rem_n = rem - 2'd1;
                    st_n  = op_wr ? S_WD : (rd_burst_ready ? S_IDLE : S_RRET);
                end
            end
            S_WD: begin
                if (take_byte) begin
                    rem_n = rem - 2'd1;
                    st_n  = S_WSTP;
                end
            end
            S_WSTP: begin
                if (stp_evt)
                    st_n = S_IDLE;
            end
            S_RRET: begin
                if (rd_burst_ready)
                    st_n = S_IDLE;
            end
            default: st_n = S_IDLE;
        endcase

        // NXT for the next tick
        last_rd = 1'b0;
        if ((st_n == S_IDLE) && !rd_now0) begin
            // acknowledge a command held by the Link; a second NXT only if the command
            // still needs bytes (write data / extended address), never for a plain read.
            // (Not in the tick of a read: the captured byte is the command / address
            // that was just consumed.)
            nxt_r   = cmd_eff && (!nxt_pin || cmd_regw || cmd_ext);
            // the last NXT of a read: the only one of a plain read, the second one
            // (address byte) of an extended read
            last_rd = nxt_r && cmd_regr && (cmd_ext ? nxt_pin : !nxt_pin);
        end else if ((st_n == S_AB) || (st_n == S_WD)) begin
            nxt_r   = (({2'b00, rem_n} > {2'b00, nxt_pin}) && !stp_raw);
            last_rd = nxt_r && (st_n == S_AB) && !(take_cmd0 ? cmd_regw : op_wr);
        end else begin
            nxt_r   = 1'b0;
        end
    end

    assign nxt_n = nxt_r;

    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            st      <= S_IDLE;
            rem     <= 2'd0;
            op_wr   <= 1'b0;
            ext_q   <= 1'b0;
            addr_q  <= 8'd0;
            data_q  <= 8'd0;
            rdata_q <= 8'd0;
            rd_ack_q <= 1'b0;
        end else if (ce) begin
            st  <= st_n;
            rem <= rem_n;
            rd_ack_q <= last_rd;
            if (take_cmd) begin
                op_wr  <= cmd_regw;
                ext_q  <= cmd_ext;
                addr_q <= {2'b00, cmd_addr};
            end
            if (take_byte && (st == S_AB))
                addr_q <= lnk_data;
            if (take_byte && (st == S_WD))
                data_q <= lnk_data;
            if (rd_now0 && !rd_burst_ready)
                rdata_q <= reg_rdata;
        end
    end

endmodule
