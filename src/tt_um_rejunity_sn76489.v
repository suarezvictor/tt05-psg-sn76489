/* verilator lint_off WIDTH */
`default_nettype none

module tt_um_rejunity_sn76489 #( // parameter CHANNEL_OUTPUT_BITS = 8,
                                 // parameter MASTER_OUTPUT_BITS = 7
                                 // parameter CHANNEL_OUTPUT_BITS = 6,
                                 parameter CHANNEL_OUTPUT_BITS = 15,
                                 parameter MASTER_OUTPUT_BITS = 8
) (
    input  wire [7:0] ui_in,    // Dedicated inputs - connected to the input switches
    output wire [7:0] uo_out,   // Dedicated outputs - connected to the 7 segment display
    input  wire [7:0] uio_in,   // IOs: Bidirectional Input path
    output wire [7:0] uio_out,  // IOs: Bidirectional Output path
    output wire [7:0] uio_oe,   // IOs: Bidirectional Enable path (active high: 0=input, 1=output)
    input  wire       ena,      // will go high when the design is enabled
    input  wire       clk,      // clock
    input  wire       rst_n     // reset_n - low to reset
);
    localparam NUM_TONES = 3;
    localparam NUM_NOISES = 1;
    localparam ATTENUATION_CONTROL_BITS = 4;
    localparam FREQUENCY_COUNTER_BITS = 10;
    localparam NOISE_CONTROL_BITS = 3;

    assign uio_oe[7:0] = 8'b1111_1000; // Bidirectional path set to output, except the first /WE pin
    assign uio_out[7:0] = {8{1'b0}};
    wire reset = ! rst_n;

    wire we = ! uio_in[0];
    wire [1:0] master_clock_control = uio_in[2:1];
    wire [7:0] data;
    assign data = ui_in;

    reg [$clog2(128)-1:0] clk_counter;
    reg clk_master_strobe;
    always @(*) begin
        case(master_clock_control[1:0])
            2'b01:  clk_master_strobe = clk;                                // no div, for old SN94624/SN76494 at 250Khz
                                                                            // also useful to speedup record.py
            2'b10:  clk_master_strobe = clk_counter[$clog2(128)-1:0] == 0;  // div 128, for TinyTapeout5 running 32..50Mhz
            default:
                    clk_master_strobe = clk_counter[$clog2(16)-1:0] == 0;   // div  16, for standard SN76489 
                                                                            // running 4Mhz or NTCS/PAL frequencies
        endcase
    end

    // The SN76489 has 8 control "registers":
    // - 4 x 4 bit volume registers (attenuation)
    // - 3 x 10 bit tone registers  (frequency)
    // - 1 x 3 bit noise register
    localparam NUM_CHANNELS = NUM_TONES + NUM_NOISES;    
    reg [ATTENUATION_CONTROL_BITS-1:0]  control_attn[NUM_CHANNELS-1:0];
    reg [FREQUENCY_COUNTER_BITS-1:0]    control_tone_freq[NUM_TONES-1:0];
    reg [NOISE_CONTROL_BITS-1:0]        control_noise[NUM_NOISES-1:0];
    reg [2:0] latch_control_reg;
    reg restart_noise;

    always @(posedge clk) begin
        if (reset) begin
            clk_counter <= 0;

            control_attn[0] <= 4'b1111;
            control_attn[1] <= 4'b1111;
            control_attn[2] <= 4'b1111;
            control_attn[3] <= 4'b1111;
            control_tone_freq[0] <= 1;
            control_tone_freq[1] <= 1;
            control_tone_freq[2] <= 1;
            control_noise[0] <= 3'b100;

            latch_control_reg <= 0;
            restart_noise <= 0;
        end else begin
            clk_counter <= clk_counter + 1;                                 // provides clk_master_strobe for tone & noise generators
            restart_noise <= 0;
            if (we) begin
                if (data[7] == 1'b1) begin
                    case(data[6:4])
                        3'b000 : control_tone_freq[0][3:0] <= data[3:0];
                        3'b010 : control_tone_freq[1][3:0] <= data[3:0];
                        3'b100 : control_tone_freq[2][3:0] <= data[3:0];
                        3'b110 : 
                            begin 
                                control_noise[0] <= data[2:0];
                                restart_noise <= 1;
                            end
                        3'b001 : control_attn[0] <= data[3:0];
                        3'b011 : control_attn[1] <= data[3:0];
                        3'b101 : control_attn[2] <= data[3:0];
                        3'b111 : control_attn[3] <= data[3:0];
                        default : begin end
                    endcase
                    latch_control_reg <= data[6:4];
                end else begin
                    case(latch_control_reg)
                        3'b000 : control_tone_freq[0][9:4] <= data[5:0];
                        3'b010 : control_tone_freq[1][9:4] <= data[5:0];
                        3'b100 : control_tone_freq[2][9:4] <= data[5:0];
                        3'b001 : control_attn[0] <= data[3:0];
                        3'b011 : control_attn[1] <= data[3:0];
                        3'b101 : control_attn[2] <= data[3:0];
                        3'b111 : control_attn[3] <= data[3:0];
                        default : begin end
                    endcase
                end
            end
        end
    end

    wire                           channels [NUM_CHANNELS-1:0];
    wire [CHANNEL_OUTPUT_BITS-1:0] volumes  [NUM_CHANNELS-1:0];

    genvar i;
    generate
        for (i = 0; i < NUM_TONES; i = i + 1) begin : tone
            tone #(.COUNTER_BITS(FREQUENCY_COUNTER_BITS)) gen (
                .clk(clk),
                .enable(clk_master_strobe),
                .reset(reset),
                .compare(control_tone_freq[i]),
                .out(channels[i])
                );
        end

        for (i = 0; i < NUM_NOISES; i = i + 1) begin : noise
            noise #(.COUNTER_BITS(FREQUENCY_COUNTER_BITS)) gen (
                .clk(clk),
                .enable(clk_master_strobe),
                .reset(reset),
                .restart_noise(restart_noise),
                .control(control_noise[i]),
                .driven_by_tone(channels[NUM_TONES-1]), // can be driven by the last tone,
                                                        // when control_noise[1:0] == 2'b11
                .out(channels[NUM_TONES+i])
                );
        end

        for (i = 0; i < NUM_CHANNELS; i = i + 1) begin : chan
            attenuation #(.VOLUME_BITS(CHANNEL_OUTPUT_BITS)) attenuation (
                .in(channels[i]),
                .control(control_attn[i]),
                .out(volumes[i])
                );
        end
    endgenerate

    // assign uo_out[7:0] = (volumes[0] + volumes[1] + volumes[2] + volumes[3]);

    // sum up all the channels, clamp to the highest value when overflown
    // localparam OVERFLOW_BITS = $clog2(NUM_CHANNELS);
    // localparam ACCUMULATOR_BITS = CHANNEL_fOUTPUT_BITS + OVERFLOW_BITS;
    // wire [ACCUMULATOR_BITS-1:0] master;
    // assign master = (volumes[0] + volumes[1]) + volumes[2] + volumes[3]);

    // wire [1:0] master_overflow;
    // wire [CHANNEL_OUTPUT_BITS-1:0] master;
    // assign { master_overflow, master } = volumes[0] + volumes[1];// + volumes[2] + volumes[3];
    // assign uo_out[7:0] = (master_overflow == 0) ? master[CHANNEL_OUTPUT_BITS-1 -: MASTER_OUTPUT_BITS] : {MASTER_OUTPUT_BITS{1'b1}};


    wire master_overflow;
    wire [CHANNEL_OUTPUT_BITS-1+2:0] master;
    assign { master_overflow, master } = volumes[0] + volumes[1] + volumes[2] + volumes[3];
    assign uo_out[7:0] = (master_overflow == 0) ? master[CHANNEL_OUTPUT_BITS-1+2 -: MASTER_OUTPUT_BITS] : {MASTER_OUTPUT_BITS{1'b1}};

    // assign master = (volumes[0]);
    // assign uo_out[7:1] = (master[ACCUMULATOR_BITS-1 -: OVERFLOW_BITS] == 0) ? master[CHANNEL_OUTPUT_BITS-1 -: MASTER_OUTPUT_BITS] : {MASTER_OUTPUT_BITS{1'b1}};
    // assign uo_out[7:0] = (master[ACCUMULATOR_BITS-1 -: OVERFLOW_BITS] == 0) ? master[CHANNEL_OUTPUT_BITS-1 -: MASTER_OUTPUT_BITS] : {MASTER_OUTPUT_BITS{1'b1}};

    // pwm #(.VALUE_BITS(MASTER_OUTPUT_BITS)) pwm (
    //     .clk(clk),
    //     .reset(reset),
    //     .value(uo_out[7:1]),
    //     .out(uo_out[0])
    //     );
    
endmodule
