module probe_macros (
    rst_sync_n,
    clock,
    ui_in,
    uo_out,
    uio_out,
    uio_oe
);

    input rst_sync_n;
    input clock;
    input [7:0] ui_in;
    output [7:0] uo_out;
    output [7:0] uio_out;
    output [7:0] uio_oe;

    wire [7:0] _10;
    wire [7:0] _90;
    wire [15:0] _87;
    wire [9:0] _45;
    wire [15:0] _43;
    wire [15:0] _42;
    wire [9:0] _41;
    wire _38;
    wire _39;
    wire _24;
    wire _37;
    wire _40;
    wire [15:0] _49;
    wire [15:0] _3;
    reg [15:0] _88;
    wire [7:0] _89;
    wire [7:0] _85;
    wire [7:0] _84;
    wire [7:0] _83;
    wire [31:0] _80;
    wire [8:0] _67;
    wire gnd;
    wire [31:0] _66;
    wire [31:0] _65;
    wire [8:0] _64;
    wire _61;
    wire _62;
    wire _33;
    reg _34;
    wire _35;
    wire _25;
    reg _28;
    reg _31;
    wire _36;
    wire _15;
    reg _19;
    reg _22;
    wire [71:0] _14;
    wire _51;
    reg _54;
    reg _57;
    wire [70:0] _50;
    wire [71:0] _58;
    wire [71:0] _4;
    reg [71:0] _23;
    wire _59;
    wire _60;
    wire _63;
    wire [31:0] _71;
    wire [31:0] _5;
    reg [31:0] _81;
    wire [7:0] _82;
    wire [2:0] _77;
    wire vdd;
    wire _13;
    wire [2:0] _72;
    reg [2:0] _75;
    reg [2:0] _78;
    reg [7:0] _93;
    reg [7:0] _96;
    assign _10 = 8'b00000000;
    assign _90 = _88[15:8];
    assign _87 = 16'b0000000000000000;
    assign _45 = 10'b0000000000;
    assign _43 = 16'b1111111111111111;
    assign _42 = _23[68:53];
    assign _41 = _23[52:43];
    assign _38 = _23[70:70];
    assign _39 = _38 & _36;
    assign _24 = _23[69:69];
    assign _37 = _24 & _36;
    assign _40 = _37 | _39;
    RM_IHPSG13_1P_1024x16_c2_bm_bist
        u_data
        ( .A_CLK(clock),
          .A_MEN(_40),
          .A_WEN(_37),
          .A_REN(_39),
          .A_ADDR(_41),
          .A_DIN(_42),
          .A_DLY(vdd),
          .A_BM(_43),
          .A_BIST_CLK(gnd),
          .A_BIST_EN(gnd),
          .A_BIST_MEN(gnd),
          .A_BIST_WEN(gnd),
          .A_BIST_REN(gnd),
          .A_BIST_ADDR(_45),
          .A_BIST_DIN(_87),
          .A_BIST_BM(_87),
          .A_DOUT(_49[15:0]) );
    assign _3 = _49;
    always @(posedge clock) begin
        if (_13)
            _88 <= _87;
        else
            _88 <= _3;
    end
    assign _89 = _88[7:0];
    assign _85 = _81[31:24];
    assign _84 = _81[23:16];
    assign _83 = _81[15:8];
    assign _80 = 32'b00000000000000000000000000000000;
    assign _67 = 9'b000000000;
    assign gnd = 1'b0;
    assign _66 = 32'b11111111111111111111111111111111;
    assign _65 = _23[40:9];
    assign _64 = _23[8:0];
    assign _61 = _23[42:42];
    assign _62 = _61 & _36;
    assign _33 = 1'b0;
    always @(posedge clock) begin
        if (_13)
            _34 <= _33;
        else
            _34 <= _31;
    end
    assign _35 = ~ _34;
    assign _25 = ui_in[2:2];
    always @(posedge clock) begin
        if (_13)
            _28 <= _33;
        else
            _28 <= _25;
    end
    always @(posedge clock) begin
        if (_13)
            _31 <= _33;
        else
            _31 <= _28;
    end
    assign _36 = _31 & _35;
    assign _15 = ui_in[1:1];
    always @(posedge clock) begin
        if (_13)
            _19 <= _33;
        else
            _19 <= _15;
    end
    always @(posedge clock) begin
        if (_13)
            _22 <= _33;
        else
            _22 <= _19;
    end
    assign _14 = 72'b000000000000000000000000000000000000000000000000000000000000000000000000;
    assign _51 = ui_in[0:0];
    always @(posedge clock) begin
        if (_13)
            _54 <= _33;
        else
            _54 <= _51;
    end
    always @(posedge clock) begin
        if (_13)
            _57 <= _33;
        else
            _57 <= _54;
    end
    assign _50 = _23[70:0];
    assign _58 = { _50,
                   _57 };
    assign _4 = _58;
    always @(posedge clock) begin
        if (_13)
            _23 <= _14;
        else
            if (_22)
                _23 <= _4;
    end
    assign _59 = _23[41:41];
    assign _60 = _59 & _36;
    assign _63 = _60 | _62;
    RM_IHPSG13_1P_512x32_c2_bm_bist
        u_prog
        ( .A_CLK(clock),
          .A_MEN(_63),
          .A_WEN(_60),
          .A_REN(_62),
          .A_ADDR(_64),
          .A_DIN(_65),
          .A_DLY(vdd),
          .A_BM(_66),
          .A_BIST_CLK(gnd),
          .A_BIST_EN(gnd),
          .A_BIST_MEN(gnd),
          .A_BIST_WEN(gnd),
          .A_BIST_REN(gnd),
          .A_BIST_ADDR(_67),
          .A_BIST_DIN(_80),
          .A_BIST_BM(_80),
          .A_DOUT(_71[31:0]) );
    assign _5 = _71;
    always @(posedge clock) begin
        if (_13)
            _81 <= _80;
        else
            _81 <= _5;
    end
    assign _82 = _81[7:0];
    assign _77 = 3'b000;
    assign vdd = 1'b1;
    assign _13 = ~ rst_sync_n;
    assign _72 = ui_in[5:3];
    always @(posedge clock) begin
        if (_13)
            _75 <= _77;
        else
            _75 <= _72;
    end
    always @(posedge clock) begin
        if (_13)
            _78 <= _77;
        else
            _78 <= _75;
    end
    always @* begin
        case (_78)
        0:
            _93 <= _82;
        1:
            _93 <= _83;
        2:
            _93 <= _84;
        3:
            _93 <= _85;
        4:
            _93 <= _89;
        5:
            _93 <= _90;
        6:
            _93 <= _10;
        default:
            _93 <= _10;
        endcase
    end
    always @(posedge clock) begin
        if (_13)
            _96 <= _10;
        else
            _96 <= _93;
    end
    assign uo_out = _96;
    assign uio_out = _10;
    assign uio_oe = _10;

endmodule
