/*
 * MODUL: am_modulator_top (Semi-Parallel TDM - 4x10 KANAL VERSION)
 * ---------------------------------------------------------------------
 * Hauptmodul. Verbindet 4 separierte Speicherblöcke mit 4 ALU-Kernen.
 * [ÄNDERUNG: Auf 100 MHz Takt und 40 Kanäle skaliert]
 */

module am_modulator_top #( 
    parameter OUT_BITS = 12,  // Breite des DAC oder R2R-Netzwerks
    // [ÄNDERUNG: Timeout an 100 MHz Systemtakt angepasst (1 Sekunde)]
    parameter TIMEOUT_CYCLES = 32'd100_000_000 
)( 
    input wire clk,                        // Hardwire 50 MHz Takt vom Quarz
    input wire rst,                        // Asynchroner Hardware-Reset
    output wire sample_en_out,             // DAC Sample-Trigger (10 MHz) 

    // MCU Interface 
    input wire [7:0] data_in,  // 8-Bit Bus von MCU
    input wire data_en,        // Strobe/Enable Puls von MCU
 
    // DAC/R2R-DAC Ausgangspins
    output reg signed [OUT_BITS-1:0] dac_out
);
    // ----------------------------------------------------
    // Hardware-PLL Instanziierung (50 MHz -> 100 MHz)
    // ----------------------------------------------------
    wire clk_100mhz;
    wire pll_locked;

    // Wir füttern die PLL direkt mit deinem vorhandenen 'clk' (Pin 17)
    my_pll pll_inst (
        .inclk0 ( clk ),         // 50 MHz vom Quarz rein
        .c0     ( clk_100mhz ),  // 100 MHz Systemtakt raus
        .locked ( pll_locked )   // High, sobald der Takt stabil steht
    );

    // ----------------------------------------------------
    // Globaler, stabiler System-Reset
    // ----------------------------------------------------
    wire sys_rst_raw = rst || !pll_locked;
    wire sys_rst;
    // ----------------------------------------------------
    // 0. RESET-ENTPRELLUNG (DEBOUNCER)
    // ----------------------------------------------------

    // Instanziierung des Entprell-Moduls
    debouncer #(
        .WAIT_CYCLES(1)
    ) rst_filter (
        .clk(clk_100mhz),
        .signal_in(!sys_rst_raw),      // (!)für den Fall, dass RST auf dem Board invertiert ist 
        .signal_out(sys_rst)   // Stabiles Ausgangssignal
    );
    // für den Fall, dass RST auf dem Board invertiert ist 
    //wire sys_rst = !rst; // sys_rst ist jetzt 1, wenn der Taster GEDRÜCKT wird

    // ---------------------------------------------------- 
    // Instanziierung: MCU-Empfänger / Protokoll-Parser 
    // ---------------------------------------------------- 
    // [ÄNDERUNG: Adressbus auf 6 Bit (0..39) erweitert für 40 Kanäle]
    wire [5:0]  mcu_w_ch;
    wire        mcu_audio_en, mcu_frq_en, mcu_gain_en; 
    wire [7:0]  mcu_audio_data; 
    wire [31:0] mcu_frq_data;
    wire [15:0] mcu_gain_data; 
 
    mcu_rx #(.TIMEOUT_CYCLES(TIMEOUT_CYCLES)) u_mcu_rx ( 
        .clk(clk_100mhz), 
        .rst(sys_rst), 
        .data_in(data_in), 
        .data_en(data_en), 
        .w_ch(mcu_w_ch), 
        .w_audio_en(mcu_audio_en), 
        .w_audio_data(mcu_audio_data), 
        .w_frq_en(mcu_frq_en), 
        .w_frq_data(mcu_frq_data), 
        .w_gain_en(mcu_gain_en), 
        .w_gain_data(mcu_gain_data) 
    );
    
    // ---------------------------------------------------- 
    // Adress-Dekodierung für 4 parallele Kerne (Je 10 Kanäle)
    // ---------------------------------------------------- 
    // [ÄNDERUNG: Subtraktions-Offsets auf 10er Blöcke angepasst und auf 6-Bit verbreitert]
    wire [5:0] mcu_w_ch_sub_1 = mcu_w_ch - 6'd10;
    wire [5:0] mcu_w_ch_sub_2 = mcu_w_ch - 6'd20;
    wire [5:0] mcu_w_ch_sub_3 = mcu_w_ch - 6'd30;

    // [ÄNDERUNG: Multiplexer für die lokale Kern-Adresse (0..9) benötigt nun 4 Bit]
    wire [3:0] core_waddr = (mcu_w_ch < 10) ? mcu_w_ch[3:0]       :
                            (mcu_w_ch < 20) ? mcu_w_ch_sub_1[3:0] :
                            (mcu_w_ch < 30) ? mcu_w_ch_sub_2[3:0] :
                                              mcu_w_ch_sub_3[3:0];

    // [ÄNDERUNG: Zuweisung der Write-Enables an die neuen 10er Grenzen angepasst]
    wire core0_we = (mcu_w_ch < 10);
    wire core1_we = (mcu_w_ch >= 10 && mcu_w_ch < 20);
    wire core2_we = (mcu_w_ch >= 20 && mcu_w_ch < 30);
    wire core3_we = (mcu_w_ch >= 30);

    // ---------------------------------------------------- 
    // TDM-Slot-Steuerung (Zentraler Modulo-10-Zähler) 
    // ---------------------------------------------------- 
    // [ÄNDERUNG: Zähler auf 4 Bit erweitert und Endwert auf 9 gesetzt]
    reg [3:0] slot = 4'd0;
    reg [3:0] slot_stg1 = 4'd0; 
 
    always @(posedge clk_100mhz) begin 
        if (sys_rst) begin 
            slot <= 4'd0;
        end else begin 
            if (slot == 4'd9) slot <= 4'd0; // [ÄNDERUNG] Modulo 10
            else              slot <= slot + 4'd1;
        end 
    end 
 
    always @(posedge clk_100mhz) begin 
        slot_stg1 <= slot;
    end 
 
    // ---------------------------------------------------- 
    // Zwei ROMs für 4 Kerne (umgeht Dual-Port-Limit)
    // ---------------------------------------------------- 
    wire [11:0]        sine_addr_0, sine_addr_1, sine_addr_2, sine_addr_3;
    wire signed [15:0] sine_q_0, sine_q_1, sine_q_2, sine_q_3; 
 
    // ROM A (versorgt Core 0 und 1)
    shared_sine_rom u_sine_rom_01 ( 
        .clk(clk_100mhz), 
        .addr_a(sine_addr_0), .addr_b(sine_addr_1), 
        .q_a(sine_q_0),       .q_b(sine_q_1) 
    );

    // ROM B (versorgt Core 2 und 3)
    shared_sine_rom u_sine_rom_23 ( 
        .clk(clk_100mhz), 
        .addr_a(sine_addr_2), .addr_b(sine_addr_3), 
        .q_a(sine_q_2),       .q_b(sine_q_3) 
    );

    // ---------------------------------------------------- 
    // Instanziierung: Die vier parallelen TDM-Kerne 
    // ---------------------------------------------------- 

    // --- Core 0 Interconnect & Instances ---
    wire [7:0]  c0_audio;  wire [31:0] c0_frq;  wire [15:0] c0_gain; wire [31:0] c0_phase; wire [6:0] c0_peak; wire [15:0] c0_decay;
    wire [31:0] c0_n_phase; wire [6:0] c0_n_peak; wire [15:0] c0_n_decay; wire signed [15:0] c0_rf;
    
    core_mem u_mem0 (
        .clk(clk_100mhz), .slot(slot), .slot_stg1(slot_stg1), .mcu_waddr(core_waddr),
        .mcu_audio_we(mcu_audio_en && core0_we), .mcu_audio_data(mcu_audio_data), .mcu_frq_we(mcu_frq_en && core0_we), .mcu_frq_data(mcu_frq_data), .mcu_gain_we(mcu_gain_en && core0_we), .mcu_gain_data(mcu_gain_data),
        .core_audio(c0_audio), .core_frq(c0_frq), .core_gain(c0_gain), .core_phase(c0_phase), .core_peak(c0_peak), .core_decay(c0_decay),
        .next_phase(c0_n_phase), .next_peak(c0_n_peak), .next_decay(c0_n_decay)
    );
    tdm_nco_core u_core0 (
        .clk(clk_100mhz), .rst(sys_rst),
        .core_audio(c0_audio), .core_frq(c0_frq), .core_gain(c0_gain), .core_phase(c0_phase), .core_peak(c0_peak), .core_decay(c0_decay),
        .next_phase(c0_n_phase), .next_peak(c0_n_peak), .next_decay(c0_n_decay),
        .sine_addr(sine_addr_0), .sine_val(sine_q_0), .rf_out(c0_rf)
    );

    // --- Core 1 Interconnect & Instances ---
    wire [7:0]  c1_audio;  wire [31:0] c1_frq; wire [15:0] c1_gain; wire [31:0] c1_phase; wire [6:0] c1_peak; wire [15:0] c1_decay;
    wire [31:0] c1_n_phase; wire [6:0] c1_n_peak; wire [15:0] c1_n_decay; wire signed [15:0] c1_rf;
    core_mem u_mem1 (
        .clk(clk_100mhz), .slot(slot), .slot_stg1(slot_stg1), .mcu_waddr(core_waddr),
        .mcu_audio_we(mcu_audio_en && core1_we), .mcu_audio_data(mcu_audio_data), .mcu_frq_we(mcu_frq_en && core1_we), .mcu_frq_data(mcu_frq_data), .mcu_gain_we(mcu_gain_en && core1_we), .mcu_gain_data(mcu_gain_data),
        .core_audio(c1_audio), .core_frq(c1_frq), .core_gain(c1_gain), .core_phase(c1_phase), .core_peak(c1_peak), .core_decay(c1_decay),
        .next_phase(c1_n_phase), .next_peak(c1_n_peak), .next_decay(c1_n_decay)
    );
    tdm_nco_core u_core1 (
        .clk(clk_100mhz), .rst(sys_rst),
        .core_audio(c1_audio), .core_frq(c1_frq), .core_gain(c1_gain), .core_phase(c1_phase), .core_peak(c1_peak), .core_decay(c1_decay),
        .next_phase(c1_n_phase), .next_peak(c1_n_peak), .next_decay(c1_n_decay),
        .sine_addr(sine_addr_1), .sine_val(sine_q_1), .rf_out(c1_rf)
    );

    // --- Core 2 Interconnect & Instances ---
    wire [7:0]  c2_audio;  wire [31:0] c2_frq; wire [15:0] c2_gain; wire [31:0] c2_phase; wire [6:0] c2_peak; wire [15:0] c2_decay;
    wire [31:0] c2_n_phase; wire [6:0] c2_n_peak; wire [15:0] c2_n_decay; wire signed [15:0] c2_rf;
    core_mem u_mem2 (
        .clk(clk_100mhz), .slot(slot), .slot_stg1(slot_stg1), .mcu_waddr(core_waddr),
        .mcu_audio_we(mcu_audio_en && core2_we), .mcu_audio_data(mcu_audio_data), .mcu_frq_we(mcu_frq_en && core2_we), .mcu_frq_data(mcu_frq_data), .mcu_gain_we(mcu_gain_en && core2_we), .mcu_gain_data(mcu_gain_data),
        .core_audio(c2_audio), .core_frq(c2_frq), .core_gain(c2_gain), .core_phase(c2_phase), .core_peak(c2_peak), .core_decay(c2_decay),
        .next_phase(c2_n_phase), .next_peak(c2_n_peak), .next_decay(c2_n_decay)
    );
    tdm_nco_core u_core2 (
        .clk(clk_100mhz), .rst(sys_rst),
        .core_audio(c2_audio), .core_frq(c2_frq), .core_gain(c2_gain), .core_phase(c2_phase), .core_peak(c2_peak), .core_decay(c2_decay),
        .next_phase(c2_n_phase), .next_peak(c2_n_peak), .next_decay(c2_n_decay),
        .sine_addr(sine_addr_2), .sine_val(sine_q_2), .rf_out(c2_rf)
    );

    // --- Core 3 Interconnect & Instances ---
    wire [7:0]  c3_audio;  wire [31:0] c3_frq; wire [15:0] c3_gain; wire [31:0] c3_phase; wire [6:0] c3_peak; wire [15:0] c3_decay;
    wire [31:0] c3_n_phase; wire [6:0] c3_n_peak; wire [15:0] c3_n_decay; wire signed [15:0] c3_rf;
    core_mem u_mem3 (
        .clk(clk_100mhz), .slot(slot), .slot_stg1(slot_stg1), .mcu_waddr(core_waddr),
        .mcu_audio_we(mcu_audio_en && core3_we), .mcu_audio_data(mcu_audio_data), .mcu_frq_we(mcu_frq_en && core3_we), .mcu_frq_data(mcu_frq_data), .mcu_gain_we(mcu_gain_en && core3_we), .mcu_gain_data(mcu_gain_data),
        .core_audio(c3_audio), .core_frq(c3_frq), .core_gain(c3_gain), .core_phase(c3_phase), .core_peak(c3_peak), .core_decay(c3_decay),
        .next_phase(c3_n_phase), .next_peak(c3_n_peak), .next_decay(c3_n_decay)
    );
    tdm_nco_core u_core3 (
        .clk(clk_100mhz), .rst(sys_rst),
        .core_audio(c3_audio), .core_frq(c3_frq), .core_gain(c3_gain), .core_phase(c3_phase), .core_peak(c3_peak), .core_decay(c3_decay),
        .next_phase(c3_n_phase), .next_peak(c3_n_peak), .next_decay(c3_n_decay),
        .sine_addr(sine_addr_3), .sine_val(sine_q_3), .rf_out(c3_rf)
    );

    // ---------------------------------------------------- 
    // Synchroner Akkumulator & DAC-Ausgabe 
    // ---------------------------------------------------- 
    // [ÄNDERUNG: Akkumulator auf 22 Bit erweitert für 40 Kanäle (max. +- 1310720)]
    reg signed [21:0] accumulator = 22'd0;
    
    // 4-Wege Addierer-Baum für diesen Takt
    wire signed [17:0] current_quad_sum = $signed(c0_rf) + $signed(c1_rf) + $signed(c2_rf) + $signed(c3_rf);
    
    always @(posedge clk_100mhz) begin 
        if (sys_rst) begin 
            accumulator <= 22'd0;
            dac_out     <= 12'd0; 
        end else begin 
            if (slot == 4'd9) begin // [ÄNDERUNG: Trigger bei Slot 9]
                // 1. DAC Output aktualisieren (Mit 22-Bit MSB Logik)
                // [ÄNDERUNG: Indizierung an 22-Bit Akkumulator angepasst]
                // dac_out <= {~accumulator[21], accumulator[20:21-(OUT_BITS-1)]};
                dac_out <= {~accumulator[21], accumulator[20:22-OUT_BITS]};
                // 2. Akkumulator direkt mit dem ersten frischen Quad-Paar neu laden 
                accumulator <= $signed(current_quad_sum);
            end else begin 
                // Kontinuierliche Aufsummierung
                accumulator <= accumulator + $signed(current_quad_sum);
            end 
        end 
    end 
 
    assign sample_en_out = (slot == 4'd9); // [ÄNDERUNG: DAC Enalbe bei Slot 9]
endmodule
