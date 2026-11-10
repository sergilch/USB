//-----------------------------------------------------------------------------
// usb_afe_rx_if.v - HS receive boundary to the analog front end (HS RX + CDR)
//
// WORK_PLAN 6.2, AFE_INTEGRATION_PLAN.md 3.2 / 5.2 / phase A3, pin list and
// timing in DOC/afe_interface_spec.md 3.2 and 4.2.  Position:
//
//   AFE: HS RX -> CDR --clk_rx, hs_rxd_a--> [THIS BLOCK] --clk_rx, hs_rxd-----> usb_rx_datapath
//        squelch det. --squelch_a-------->              --hs_squelch, hs_cdr_lock->
//                     <--rx_en_hs, cdr_en--
//
// Function
//   * Enables (clk_bit, registered): rx_en_hs (RX_EN: HS receiver + squelch
//     detector) and cdr_en (CDR_EN) are on in HS mode (speed = 00) while rx_en
//     is set and iso_en is not.  In FS / LS mode, in low-power mode and while
//     isolated both are off; the CDR then stops clk_rx (the HS chain of
//     usb_rx_datapath is disabled in those modes anyway, and its clk_rx reset
//     synchronizer releases once the clock runs again).
//   * Isolation: iso_en forces the inputs to their isolated values
//     (squelch_a -> 1, hs_rxd_a -> 1, spec 3.2) before anything samples them.
//   * Squelch synchronizer (2 FF on clk_rx) and lock: hs_cdr_lock rises
//     lock_dly bit times after the synchronized squelch falls and drops with
//     it (the CDR has no lock detector, spec 4.2).  Both outputs are registered
//     together, so they change on the same clk_rx edge.
//   * Squelch latency compensation: the data is delayed by 3 + sq_comp bit
//     times, the squelch / lock outputs by 3 (synchronizer + output register).
//     usb_rx_hs_frontend aligns its data with its own squelch synchronizer, so
//     sq_comp extra bits of data before the squelch detector released are
//     received as well: sq_comp ~ squelch response time / bit time gives those
//     bits back to the SYNC budget.  At the end of a packet the squelch rises
//     sq_comp bits earlier relative to the data, so the squelch hold time after
//     the line goes idle must stay above sq_comp bits plus the CDR latency.
//     Bits taken in front of the real signal are idle-line noise.
//
// Settings (measured in tb_usb_afe_rx_if, 12-bit SYNC; DOC/afe_interface_spec.md 4.2)
//   * Squelch release and CDR lock overlap in time, so the squelch costs SYNC
//     bits only where it is slower than the CDR.  Recommended: lock_dly = 2
//     with HS_ZMIN = 4 in usb_rx_datapath: the CDR may then deliver up to 6
//     wrong bits after the first line bit (HS_ZMIN = 6, lock_dly = 0: 4), and
//     a squelch release up to 12 ns is tolerated.  lock_dly hides wrong
//     pre-lock bits from the SYNC detector, which otherwise can take them for
//     a SYNC end.
//   * sq_comp = 0 unless the squelch detector releases later than about 12 ns:
//     at 16 ns, sq_comp = 2 recovers the loss.  With faster squelch it only adds
//     idle-line noise in front of SYNC (false SYNCs with HS_ZMIN = 4) and costs
//     EOP margin (sq_comp = 3 fails with a 6 ns squelch hold time).
//
// Configuration (lock_dly, sq_comp): static, from the clk_bit domain (vendor
//   register, WORK_PLAN 6.4); used on clk_rx without synchronization, so change
//   them only while HS reception is off (rx_en_hs = 0).  speed, rx_en, iso_en
//   are clk_bit-domain inputs; iso_en also gates the asynchronous AFE inputs.
//
// Outputs to usb_rx_datapath (all registered on clk_rx):
//   hs_rxd      CDR data, 1 = J, delayed 3 + sq_comp clk_rx cycles
//   hs_squelch  1 = no signal (synchronized, delayed 3 cycles)
//   hs_cdr_lock 1 = data valid (lock_dly cycles after hs_squelch fell)
//
// Clocks / resets: clk_bit (enables), clk_rx (data).  rst_n asynchronous; its
//   release is synchronized to clk_rx here.
//-----------------------------------------------------------------------------
`timescale 1ns/1ps

module usb_afe_rx_if #(
    parameter DLY_W  = 3,                    // lock_dly width
    parameter COMP_W = 3                     // sq_comp width
) (
    input  wire              clk_bit,
    input  wire              rst_n,

    // mode / control (clk_bit domain)
    input  wire [1:0]        speed,          // XcvrSelect: 00 HS
    input  wire              rx_en,          // reception allowed (not low power)
    input  wire              iso_en,
    input  wire [DLY_W-1:0]  lock_dly,       // bit times, static
    input  wire [COMP_W-1:0] sq_comp,        // bit times, static

    // AFE
    output reg               rx_en_hs,       // RX_EN
    output reg               cdr_en,         // CDR_EN
    input  wire              clk_rx,         // CDR recovered clock
    input  wire              hs_rxd_a,       // CDR retimed data, 1 = J
    input  wire              squelch_a,      // SQUELCH_A, 1 = no signal

    // to usb_rx_datapath (clk_rx domain)
    output wire              hs_rxd,
    output reg               hs_squelch,
    output reg               hs_cdr_lock
);

    localparam NST = (1 << COMP_W) + 2;      // data stages: delay 3 .. 3 + 2^COMP_W - 1

    // ---------------- enables (clk_bit) ----------------
    always @(posedge clk_bit or negedge rst_n) begin
        if (!rst_n) begin
            rx_en_hs <= 1'b0;
            cdr_en   <= 1'b0;
        end else begin
            rx_en_hs <= rx_en & ~iso_en & (speed == 2'b00);
            cdr_en   <= rx_en & ~iso_en & (speed == 2'b00);
        end
    end

    // ---------------- clk_rx reset synchronizer ----------------
    reg rr1, rst_rx_n;
    always @(posedge clk_rx or negedge rst_n) begin
        if (!rst_n) begin
            rr1      <= 1'b0;
            rst_rx_n <= 1'b0;
        end else begin
            rr1      <= 1'b1;
            rst_rx_n <= rr1;
        end
    end

    // ---------------- squelch, lock (clk_rx) ----------------
    wire             sq_in = squelch_a | iso_en;   // isolated value 1
    reg              sq1, sq2;
    reg [DLY_W-1:0]  lk_cnt;                       // cycles since sq2 fell, saturating

    always @(posedge clk_rx or negedge rst_rx_n) begin
        if (!rst_rx_n) begin
            sq1         <= 1'b1;
            sq2         <= 1'b1;
            lk_cnt      <= {DLY_W{1'b0}};
            hs_squelch  <= 1'b1;
            hs_cdr_lock <= 1'b0;
        end else begin
            sq1 <= sq_in;
            sq2 <= sq1;
            if (sq2)
                lk_cnt <= {DLY_W{1'b0}};
            else if (lk_cnt != {DLY_W{1'b1}})
                lk_cnt <= lk_cnt + 1'b1;
            hs_squelch  <= sq2;
            hs_cdr_lock <= ~sq2 & (lk_cnt >= lock_dly);
        end
    end

    // ---------------- data delay line (clk_rx) ----------------
    // Stage 2 + sq_comp loads the input (one-hot select, static), every stage
    // below shifts down, stage 0 is the output: delay = 3 + sq_comp cycles.
    // One mux per stage between flops.
    wire           d_in = hs_rxd_a | iso_en;     // isolated value 1 (J)
    wire [COMP_W:0] ent = {1'b0, sq_comp} + 2'd2;   // entry stage
    reg  [NST-1:0] sel;
    reg  [NST-1:0] dl;

    always @(posedge clk_rx or negedge rst_rx_n) begin
        if (!rst_rx_n) begin
            sel <= {NST{1'b0}};
            dl  <= {NST{1'b1}};
        end else begin
            sel <= {{(NST-1){1'b0}}, 1'b1} << ent;
            dl  <= (sel & {NST{d_in}}) | (~sel & {1'b1, dl[NST-1:1]});
        end
    end

    assign hs_rxd = dl[0];

endmodule
