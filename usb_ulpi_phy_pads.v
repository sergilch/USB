//-----------------------------------------------------------------------------
// usb_ulpi_phy_pads.v
//
// Pad wrapper of the digital ULPI PHY: usb_ulpi_phy_top with its ULPI pins and the
// external reset taken through X-FAB xh018 digital I/O cells BBSUD8F (bidirectional,
// 8 mA, Schmitt-trigger input, gated pull-up / pull-down).  Every other port of
// usb_ulpi_phy_top (RX datapath, comparators, line state, transmitter, configuration)
// is on-chip and passes straight through.
//
//   chip pins            BBSUD8F cells               core side
//   PAD_ULPI_CLK   <---- out  A = clk60               clk60 from the PLL (CLKOUT)
//   PAD_ULPI_DATA  <---> bidir A = data_out,          usb_ulpi_phy_top ulpi_data_*
//                        EN = !data_oe, Y = data_in
//   PAD_ULPI_DIR   <---- out                          ulpi_dir
//   PAD_ULPI_NXT   <---- out                          ulpi_nxt
//   PAD_ULPI_STP   ----> in   Y = stp                 ulpi_stp
//   PAD_RESETB     ----> in   Y -> reset synchronizer rst_n of the core (core_rst_n)
//
// BBSUD8F pin use (behaviour as in the library model, X-FAB/BBSUD8F.v)
//   EN is active low: EN = 0 drives PAD with A.  Input-only cells have EN = 1, A = 0;
//   output-only cells have EN = 0 and Y unused.
//   Pulls: PUEN = 0 pull-up; PUEN = 1, PDEN = 0 pull-down; PUEN = PDEN = 1 none.
//
// ULPI interface protection (ULPI 1.1 section 3.12, Interface Control bit 7 "Interface
// Protect Disable", reset 0 = protection on)
//   * STP has a weak pull-up while the protection is on, so a Link that tri-states its
//     outputs is seen as STP = 1.
//   * DATA[7:0] have weak pull-downs while the protection is on and the PHY is not
//     driving the bus (ulpi_data_oe = 0), so a floating bus reads 00h.
//   Writing Interface Control bit 7 = 1 switches both off.  DIR, NXT, CLK and RESETB
//   have no pulls.  The holding state that goes with the STP pull-up (ignore DATA and
//   keep DIR low while STP is unexpectedly high) is in usb_ulpi_core.
//   Compared with the USB3320 (datasheet DS00001792, Digital IO table and section on
//   the Link start-up): its STP pull-up is switched the same way; its DATA pull-downs
//   are on in ULPI synchronous mode regardless of the protect bit.  Here they follow
//   the protect bit and are off while the PHY drives DATA, which ULPI 1.1 also allows
//   (the pull-downs are optional, and the protect bit may switch them off) and saves
//   current.  RESETB has no pull, like the USB3320 (the Link must drive it).
//   Open: the BBSUD8F pull polarity is taken from the simulation model only (work
//   plan D8), and the USB3320 tri-states its ULPI outputs while RESETB is low, whereas
//   here DIR / NXT / CLK stay driven during reset (work plan D9).
//
// Reset
//   PAD_RESETB is active low.  It resets the core asynchronously and is released
//   synchronously to clk_bit through two flip-flops; core_rst_n is exported for the
//   blocks that will sit next to usb_ulpi_phy_top (RX datapath, clock / power control).
//   ifc_ctrl is reset with the core, so the protection pulls are on during reset.
//
// NAND tree (DFT): the PI / PO pins of all 13 cells form one chain, PI of the first
//   cell tied to 1, in the order STP, RESETB, DATA0..DATA7, DIR, NXT, CLK; the end of
//   the chain is nand_tree_out.  Putting the output cells into input mode for the test
//   belongs to the DFT controller (work plan Phase 7) and is not done here.
//
// Supplies: the cells' VDDI / VDDOI / VDDRI and GNDI / GNDOI / GNDRI / PSUB pins are
//   tied to supply1 / supply0 nets; in the layout they come from the pad ring.
//
// Register file: there is exactly one, usb_ulpi_reg_file inside usb_ulpi_phy_top
//   (u_core.u_rf); this wrapper adds no register storage of its own.
//
// Clocking: as usb_ulpi_phy_top, everything on clk_bit with the tick enable ce60.
//   clk60 (the 60 MHz PLL output that goes to CLKOUT) is only passed to the CLK pad;
//   ce60 must be high in the clk_bit cycle that ends at a rising edge of clk60.
//-----------------------------------------------------------------------------
`timescale 1ns/1ps

module usb_ulpi_phy_pads #(
    parameter FS_DIV   = 40,
    parameter LS_DIV   = 320,
    parameter DIV_W    = 9,
    parameter RX_DEPTH = 8
) (
    // ---------------- chip pins (through BBSUD8F) ----------------
    inout  wire        PAD_ULPI_CLK,
    inout  wire [7:0]  PAD_ULPI_DATA,
    inout  wire        PAD_ULPI_DIR,
    inout  wire        PAD_ULPI_NXT,
    inout  wire        PAD_ULPI_STP,
    inout  wire        PAD_RESETB,

    // ---------------- on-chip side ----------------
    input  wire        clk_bit,
    input  wire        ce60,
    input  wire        clk60,
    output wire        core_rst_n,

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
    output wire        rx_overrun,

    // DFT
    output wire        nand_tree_out
);

    // ---------------- supplies of the I/O cells ----------------
    supply1 vdd;
    supply0 gnd;

    // ---------------- core <-> pad nets ----------------
    wire [7:0] ulpi_data_in, ulpi_data_out;
    wire       ulpi_data_oe, ulpi_dir, ulpi_nxt, ulpi_stp;
    wire       resetb_y;

    wire       protect_en = ~ifc_ctrl[7];                 // Interface Protect Disable = 0
    wire       stp_puen   = ~protect_en;                  // 0 = pull-up on
    wire       data_pden  = ~(protect_en & ~ulpi_data_oe); // 0 = pull-down on (PUEN = 1)

    // NAND-tree chain: nt[0] = 1, nt[k+1] = PO of cell k
    wire [13:0] nt;
    assign nt[0]         = 1'b1;
    assign nand_tree_out = nt[13];

    // ---------------- inputs ----------------
    BBSUD8F u_pad_stp (
        .A(1'b0), .EN(1'b1), .PUEN(stp_puen), .PDEN(1'b1),
        .PAD(PAD_ULPI_STP), .Y(ulpi_stp), .PI(nt[0]), .PO(nt[1]),
        .VDDI(vdd), .VDDOI(vdd), .VDDRI(vdd), .GNDI(gnd), .GNDOI(gnd), .GNDRI(gnd), .PSUB(gnd)
    );

    BBSUD8F u_pad_resetb (
        .A(1'b0), .EN(1'b1), .PUEN(1'b1), .PDEN(1'b1),
        .PAD(PAD_RESETB), .Y(resetb_y), .PI(nt[1]), .PO(nt[2]),
        .VDDI(vdd), .VDDOI(vdd), .VDDRI(vdd), .GNDI(gnd), .GNDOI(gnd), .GNDRI(gnd), .PSUB(gnd)
    );

    // ---------------- bidirectional data ----------------
    genvar i;
    generate
        for (i = 0; i < 8; i = i + 1) begin : g_data
            BBSUD8F u_pad_data (
                .A(ulpi_data_out[i]), .EN(~ulpi_data_oe), .PUEN(1'b1), .PDEN(data_pden),
                .PAD(PAD_ULPI_DATA[i]), .Y(ulpi_data_in[i]), .PI(nt[2+i]), .PO(nt[3+i]),
                .VDDI(vdd), .VDDOI(vdd), .VDDRI(vdd), .GNDI(gnd), .GNDOI(gnd), .GNDRI(gnd), .PSUB(gnd)
            );
        end
    endgenerate

    // ---------------- outputs ----------------
    wire dir_y, nxt_y, clk_y;                              // read-back, unused

    BBSUD8F u_pad_dir (
        .A(ulpi_dir), .EN(1'b0), .PUEN(1'b1), .PDEN(1'b1),
        .PAD(PAD_ULPI_DIR), .Y(dir_y), .PI(nt[10]), .PO(nt[11]),
        .VDDI(vdd), .VDDOI(vdd), .VDDRI(vdd), .GNDI(gnd), .GNDOI(gnd), .GNDRI(gnd), .PSUB(gnd)
    );

    BBSUD8F u_pad_nxt (
        .A(ulpi_nxt), .EN(1'b0), .PUEN(1'b1), .PDEN(1'b1),
        .PAD(PAD_ULPI_NXT), .Y(nxt_y), .PI(nt[11]), .PO(nt[12]),
        .VDDI(vdd), .VDDOI(vdd), .VDDRI(vdd), .GNDI(gnd), .GNDOI(gnd), .GNDRI(gnd), .PSUB(gnd)
    );

    BBSUD8F u_pad_clk (
        .A(clk60), .EN(1'b0), .PUEN(1'b1), .PDEN(1'b1),
        .PAD(PAD_ULPI_CLK), .Y(clk_y), .PI(nt[12]), .PO(nt[13]),
        .VDDI(vdd), .VDDOI(vdd), .VDDRI(vdd), .GNDI(gnd), .GNDOI(gnd), .GNDRI(gnd), .PSUB(gnd)
    );

    // ---------------- reset synchronizer (async assert, sync release) ----------------
    reg [1:0] rst_sync;
    always @(posedge clk_bit or negedge resetb_y) begin
        if (!resetb_y) rst_sync <= 2'b00;
        else           rst_sync <= {rst_sync[0], 1'b1};
    end
    assign core_rst_n = rst_sync[1];

    // ---------------- PHY core (with the one and only register file) ----------------
    usb_ulpi_phy_top #(
        .FS_DIV   (FS_DIV),
        .LS_DIV   (LS_DIV),
        .DIV_W    (DIV_W),
        .RX_DEPTH (RX_DEPTH)
    ) u_core (
        .clk_bit       (clk_bit),
        .rst_n         (core_rst_n),
        .ce60          (ce60),
        .ulpi_data_in  (ulpi_data_in),
        .ulpi_stp      (ulpi_stp),
        .ulpi_dir      (ulpi_dir),
        .ulpi_nxt      (ulpi_nxt),
        .ulpi_data_out (ulpi_data_out),
        .ulpi_data_oe  (ulpi_data_oe),
        .rx_start      (rx_start),
        .rx_valid      (rx_valid),
        .rx_data       (rx_data),
        .rx_end        (rx_end),
        .rx_error      (rx_error),
        .linestate     (linestate),
        .host_disc     (host_disc),
        .a_vbus_vld    (a_vbus_vld),
        .sess_vld      (sess_vld),
        .sess_end      (sess_end),
        .id_gnd        (id_gnd),
        .alt_int       (alt_int),
        .dir_hold      (dir_hold),
        .xcvrselect    (xcvrselect),
        .termselect    (termselect),
        .opmode        (opmode),
        .suspendm      (suspendm),
        .soft_reset    (soft_reset),
        .ifc_ctrl      (ifc_ctrl),
        .otg_ctrl      (otg_ctrl),
        .cfg_speed     (cfg_speed),
        .cfg_bypass    (cfg_bypass),
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

endmodule
