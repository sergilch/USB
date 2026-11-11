//-----------------------------------------------------------------------------
// usb_afe_tx_if.v - TX data boundary to the analog front end (HS TX + FS/LS)
//
// WORK_PLAN 6.1, AFE_INTEGRATION_PLAN.md 3.1 / phase A2, pin list and timing in
// DOC/afe_interface_spec.md 3.1, 3.4 and 4.1.  Position:
//
//   usb_tx_path (txd, tx_en, tx_se0, tx_speed) -> [THIS BLOCK] -> HS TX  (TX_IN_P/N, TX_EN)
//                                                              -> FS/LS transceiver (new)
//
// Function
//   * Retiming: every output is a flip-flop on clk_bit with nothing behind it,
//     so all pins change on the same clock edge.  hs_tx_p and hs_tx_n come from
//     two separate flops (next value and its complement), not from one flop and
//     an inverter, so the P/N skew is only the flop and routing mismatch.
//   * Input register: the serializer outputs and the clamp inputs are registered
//     first, so every 480 MHz path in here starts at a local flop (the delay
//     line entry has a fan-out of 2^LEAD_W).
//   * Driver select from tx_speed (XcvrSelect, constant within a packet):
//     00 -> HS current driver, 01 / 11 -> FS driver, 10 -> LS driver.  The
//     unused driver stays idle.  The select is registered at the input, not
//     carried through the delay line: tx_speed must not change within
//     2^LEAD_W + 3 cycles after a packet (it cannot: XcvrSelect changes only
//     after a ULPI register write).  Chirp (OpMode 10 at HS) is ordinary HS data
//     here.
//   * TX_EN lead / lag (HS only).  The HS current source needs time to settle,
//     so hs_tx_en rises tx_lead bit times before the first SYNC bit: the data
//     (all speeds) is delayed by tx_lead extra clk_bit cycles, hs_tx_en is not.
//     After the last EOP bit hs_tx_en stays high tx_lag more bit times.  During
//     the lead hs_tx_p / hs_tx_n show J (the idle level), or with lead_first = 1
//     the level of the first data bit (OpMode 10, usb_mode_term_ctrl tx_bypass:
//     a chirp K must not start with a J, which the driver would put on the line
//     for the last tx_lead x 2.08 ns - T_EN of the lead); during the lag they
//     hold the EOP level, so the lag lengthens the HS EOP by tx_lag bits (USB
//     receivers treat any bit-stuff error as EOP; SOF EOPs are 40 bits long).
//     FS/LS have no lead / lag: fs_oe is the delayed tx_en.
//   * Idle clamp: drv_dis (OpMode 01 / 11 non-driving, future) or iso_en (power
//     sequencer, future), registered once, puts every output to its idle value
//     on the following edge (2 edges after the input), flushes the delay line and
//     drops the rest of the current packet: input is ignored until tx_en from
//     the serializer has gone low with the clamp off, so a packet never resumes
//     in the middle.  Real isolation cells, if the power concept needs them,
//     belong to the AFE side (spec 1); this clamp keeps the digital outputs safe.
//
// Latency (clk_bit cycles, from the serializer outputs to the pins)
//   data (hs_tx_p/n, fs_*) : tx_lead + 3
//   hs_tx_en rise          : 3              (so it leads the data by tx_lead)
//   hs_tx_en fall          : tx_lead + 3 + tx_lag after the serializer's tx_en falls
//   tx_active              : 1 (rise) ... until the last driver enable falls
//
// tx_lead / tx_lag: static configuration (vendor register, WORK_PLAN 6.4).  They
//   are taken over only after 2^QW - 1 cycles without tx_en, when the delay line
//   is empty (QW below), so a change during a packet affects the next one.  After
//   reset the block starts with lead 0 / lag 0 and loads the ports once that idle
//   time has passed.
//
// Requirement on the user: tx_lead + tx_lag + 3 bit times must be shorter than
//   the gap between two HS packets (USB 2.0: >= 88 bit times at the device);
//   otherwise hs_tx_en stays high across the gap and the line shows the held EOP
//   level instead of idle.  The ranges of DOC/afe_interface_spec.md 4.1
//   (lead <= 31, lag <= 7) always satisfy this.
//
// Pin values (spec 3.1 / 3.4)            reset / clamp   idle, not clamped
//   hs_tx_p  TX_IN_P  1 = J (DP high)          1                1
//   hs_tx_n  TX_IN_N  complement               0                0
//   hs_tx_en TX_EN    HS driver on             0                0
//   fs_oe    FS_OE_A  FS/LS driver on          0                0
//   fs_dat   FS_DAT_A 1 = J at the selected    1                1
//                     speed (the driver maps J to DP for FS, to DM for fs_ls = 1)
//   fs_se0   FS_SE0_A drive SE0                0                0
//   fs_ls    FS_LS_A  LS slew rate             0                holds the last
//                                                               packet's value
//
// tx_active: a driver is on, or will be within the latency above (for the local
//   TX hold-off of the receiver, usb_rx_datapath tx_en).
//
// Clocking: clk_bit only; every output is updated on every clk_bit edge (no
//   ce60), active-low asynchronous reset rst_n.
//-----------------------------------------------------------------------------
`timescale 1ns/1ps

module usb_afe_tx_if #(
    parameter LEAD_W = 5,                    // tx_lead width: 0 .. 2^LEAD_W - 1
    parameter LAG_W  = 3                     // tx_lag width:  0 .. 2^LAG_W - 1
) (
    input  wire              clk_bit,
    input  wire              rst_n,

    // from usb_tx_path / usb_tx_serializer
    input  wire              txd,            // J = 1 / K = 0
    input  wire              tx_en,
    input  wire              tx_se0,
    input  wire [1:0]        tx_speed,       // 00 HS, 01 FS, 10 LS, 11 FS

    // configuration / control
    input  wire [LEAD_W-1:0] tx_lead,        // HS TX_EN lead, bit times
    input  wire [LAG_W-1:0]  tx_lag,         // HS TX_EN lag, bit times
    input  wire              drv_dis,        // drivers off (non-driving OpMode)
    input  wire              iso_en,         // isolation: outputs to idle
    input  wire              lead_first,     // HS lead at the first bit's level, not J (static)

    // HS transmitter
    output reg               hs_tx_p,
    output reg               hs_tx_n,
    output reg               hs_tx_en,

    // FS / LS transceiver
    output reg               fs_oe,
    output reg               fs_dat,
    output reg               fs_se0,
    output reg               fs_ls,

    output wire              tx_active
);

    localparam DEPTH = 1 << LEAD_W;                               // delay-line stages
    localparam QW    = ((LEAD_W > LAG_W) ? LEAD_W : LAG_W) + 2;   // quiet counter

    // ---------------- input register ----------------
    reg  clamp;                          // drv_dis | iso_en, registered
    reg  kill;                           // rest of a clamped packet is dropped
    reg  i_en, i_d, i_se0, i_hs, i_ls;   // qualified serializer outputs

    // ---------------- configuration take-over ----------------
    reg [DEPTH-1:0] sel;                 // one-hot: entry stage = lead
    reg [LAG_W-1:0] lag_q;
    reg [QW-1:0]    quiet;               // cycles without tx_en, saturating
    reg             q_full;              // quiet == all ones (registered compare)
    reg             cfg_ld;              // take tx_lead / tx_lag over (registered)

    // ---------------- delay line ----------------
    // Stage `lead` loads the input register, every stage below it shifts down,
    // stage 0 feeds the output flops.  Stages above the entry only ever see idle
    // from the top.  One mux per stage, select static.  Only p_en is cleared by
    // the clamp; p_d / p_se0 are don't care while p_en is 0.
    // The driver select is not delayed: spd_hs / spd_ls are taken from the input
    // register with every valid bit and apply to the bits leaving the line (see
    // the header for why that is safe).
    reg [DEPTH-1:0] p_en, p_d, p_se0;
    reg             spd_hs, spd_ls;

    // ---------------- output stage ----------------
    reg              e_hs_q;             // HS bit in the input register, delayed (TX_EN lead)
    reg [LAG_W-1:0]  lag_cnt;
    reg              lag_on;
    reg              d_first;            // first HS bit of the packet (lead level)

    wire o_hs   = p_en[0] & spd_hs;      // HS bit at the end of the delay line
    wire o_fs   = p_en[0] & ~spd_hs;     // FS/LS bit
    wire hs_on  = e_hs_q | o_hs | lag_on;
    // lead start (hs_tx_en still low): J, or the first bit with lead_first
    wire hs_p_n = clamp ? 1'b1 : o_hs ? p_d[0] :
                  hs_on ? (hs_tx_en ? hs_tx_p : (lead_first ? d_first : 1'b1)) : 1'b1;

    always @(posedge clk_bit or negedge rst_n) begin
        if (!rst_n) begin
            clamp    <= 1'b0;
            kill     <= 1'b0;
            i_en     <= 1'b0;
            i_d      <= 1'b1;
            i_se0    <= 1'b0;
            i_hs     <= 1'b0;
            i_ls     <= 1'b0;
            sel      <= {{(DEPTH-1){1'b0}}, 1'b1};
            lag_q    <= {LAG_W{1'b0}};
            quiet    <= {QW{1'b0}};
            q_full   <= 1'b0;
            cfg_ld   <= 1'b0;
            p_en     <= {DEPTH{1'b0}};
            p_d      <= {DEPTH{1'b1}};
            p_se0    <= {DEPTH{1'b0}};
            spd_hs   <= 1'b0;
            spd_ls   <= 1'b0;
            e_hs_q   <= 1'b0;
            lag_cnt  <= {LAG_W{1'b0}};
            lag_on   <= 1'b0;
            d_first  <= 1'b1;
            hs_tx_p  <= 1'b1;
            hs_tx_n  <= 1'b0;
            hs_tx_en <= 1'b0;
            fs_oe    <= 1'b0;
            fs_dat   <= 1'b1;
            fs_se0   <= 1'b0;
            fs_ls    <= 1'b0;
        end else begin
            // input register
            clamp <= drv_dis | iso_en;
            kill  <= clamp | (kill & tx_en);
            i_en  <= tx_en & ~clamp & ~kill;
            i_d   <= txd;
            i_se0 <= tx_se0;
            i_hs  <= (tx_speed == 2'b00);
            i_ls  <= (tx_speed == 2'b10);

            // configuration, only while the delay line is empty
            quiet  <= tx_en ? {QW{1'b0}} : q_full ? quiet : quiet + 1'b1;
            q_full <= ~tx_en & (q_full | (quiet == {{(QW-1){1'b1}}, 1'b0}));
            // one cycle later: a bit that arrives meanwhile is still in the input
            // register and enters the delay line after sel has changed
            cfg_ld <= q_full & ~tx_en;
            if (cfg_ld) begin
                sel   <= {{(DEPTH-1){1'b0}}, 1'b1} << tx_lead;
                lag_q <= tx_lag;
            end

            // delay line
            p_en  <= clamp ? {DEPTH{1'b0}}
                           : (sel & {DEPTH{i_en}}) | (~sel & {1'b0, p_en[DEPTH-1:1]});
            p_d   <= (sel & {DEPTH{i_d}})   | (~sel & {1'b1, p_d[DEPTH-1:1]});
            p_se0 <= (sel & {DEPTH{i_se0}}) | (~sel & {1'b0, p_se0[DEPTH-1:1]});
            if (i_en) begin
                spd_hs <= i_hs;
                spd_ls <= i_ls;
            end

            e_hs_q <= ~clamp & i_en & i_hs;
            if (i_en && i_hs && !e_hs_q) d_first <= i_d;

            // TX_EN lag after the last HS bit
            if (clamp) begin
                lag_cnt <= {LAG_W{1'b0}};
                lag_on  <= 1'b0;
            end else if (o_hs) begin
                lag_cnt <= lag_q;
                lag_on  <= (lag_q != {LAG_W{1'b0}});
            end else if (lag_on) begin
                lag_cnt <= lag_cnt - 1'b1;
                lag_on  <= (lag_cnt != {{(LAG_W-1){1'b0}}, 1'b1});
            end

            // HS pins
            hs_tx_en <= ~clamp & hs_on;
            hs_tx_p  <= hs_p_n;
            hs_tx_n  <= ~hs_p_n;

            // FS / LS pins
            fs_oe  <= ~clamp & o_fs;
            fs_dat <= clamp | ~o_fs | p_d[0];
            fs_se0 <= ~clamp & o_fs & p_se0[0];
            fs_ls  <= clamp ? 1'b0 : o_fs ? spd_ls : fs_ls;
        end
    end

    assign tx_active = i_en | hs_tx_en | fs_oe;

endmodule
