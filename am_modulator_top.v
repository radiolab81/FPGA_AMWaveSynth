/*
 * PROJEKT: Multi-Kanal AM-Modulator
 * ----------------------------------------------------
 * Dieses Modul führt 10 AM-Sender zusammen. 
 * Nutzt Shared-Dual-Port-ROMs für die NCOs.
 * TAKTKONZEPT:
 * - clk: 50 MHz (Physischer FPGA-Takt)
 * - sample_en: 10 MHz (Logischer Takt / Enable-Puls alle 5 Zyklen)
 * - DAC-Rate: 10 MSPS (Jedes Sample steht für 100ns stabil am R2R-Ausgang)
 */

module am_modulator_top #(
    parameter OUT_BITS = 12  // Breite des DAC oder R2R-Netzwerks
)(
    input wire clk,          // Globaler 50 MHz Takt vom Quarz
    input wire rst,          // Reset-Eingang
    output wire sample_en_out, // <---  Hier legen wir den Debug-"Enable"- Puls nach außen
    
    // Audio Interface von MCU
    input wire [7:0] data_in,   // 8-Bit Bus von MCU
    input wire data_en,         // Strobe/Enable Puls von MCU

    // DAC/R2R-DAC Ausgangspins
    output reg signed [OUT_BITS-1:0] dac_out
);
    // für den Fall, dass RST auf dem Board invertiert ist 
    wire sys_rst = !rst; // sys_rst ist jetzt 1, wenn der Taster GEDRÜCKT wird

    // ----------------------------------------------------
    // 1. TAKT-GENERATOR (ENABLE-PULS)
    // ----------------------------------------------------
    // Wir teilen 50 MHz durch 5, um auf 10 MHz zu kommen.
    reg [2:0] clk_div; // clk Zwischenzähler
    wire sample_en = (clk_div == 4); //  kontinuierliche Zuweisung ("Draht",im Gegensatz zu reg) :setzt sample_en auf 1, wenn clk_div gleich 4 ist (also alle 5 Takte, da Zähler von 0 bis 4).
    assign sample_en_out = sample_en; //  Den internen Puls zuweisen  <- sample_en nach draußen debuggen

    always @(posedge clk) begin
        if (sys_rst) clk_div <= 0; 
        else clk_div <= (sample_en) ? 3'd0 : clk_div + 3'd1; // sample_en HIGH, dann clk_div auf 0, sonst clk_div inkrementieren [ 1x Arbeitstakt, 4 Leertakte  = 5 Takte ]
    end

    // ----------------------------------------------------
    // 2. AUDIO-EMPFÄNGER (PROTOKOLL-DECODER)
    // ----------------------------------------------------
    // Dieses Modul empfängt das [A][U][D][CH1][CH2][CH3][CH4] Protokoll
    // ERWEITERUNG: Nimmt jetzt auch CH5 bis CH10 entgegen

    wire [7:0] w_aud0, w_aud1, w_aud2, w_aud3, w_aud4, w_aud5, w_aud6, w_aud7, w_aud8, w_aud9;

    audio_rx rx_inst (
        .clk(clk), .rst(sys_rst), .data_in(data_in), .data_en(data_en),
        .ch0(w_aud0), .ch1(w_aud1), .ch2(w_aud2), .ch3(w_aud3),
        .ch4(w_aud4), .ch5(w_aud5), .ch6(w_aud6), .ch7(w_aud7), 
        .ch8(w_aud8), .ch9(w_aud9)
    );

    // ----------------------------------------------------
    // 3. ZENTRALE SPEICHER-RESSOURCEN (Shared ROMs)
    // ----------------------------------------------------
    // Wir nutzen 5 Dual-Port ROMs für 10 NCOs. 
    // Jedes ROM hat 2048 Einträge.
    wire [11:0] addr0, addr1, addr2, addr3, addr4, addr5, addr6, addr7, addr8, addr9;
    wire signed [15:0] sine_val0, sine_val1, sine_val2, sine_val3, sine_val4, sine_val5, sine_val6, sine_val7, sine_val8, sine_val9;

    // Erstes Shared ROM für Kanal 0 und 1
    shared_sine_rom rom_inst_A (
        .clk(clk),
        .addr_a(addr0), .q_a(sine_val0),
        .addr_b(addr1), .q_b(sine_val1)
    );

    // Zweites Shared ROM für Kanal 2 und 3
    shared_sine_rom rom_inst_B (
        .clk(clk),
        .addr_a(addr2), .q_a(sine_val2),
        .addr_b(addr3), .q_b(sine_val3)
    );

    // Drittes Shared ROM für Kanal 4 und 5
    shared_sine_rom rom_inst_C (
        .clk(clk),
        .addr_a(addr4), .q_a(sine_val4),
        .addr_b(addr5), .q_b(sine_val5)
    );

    // Viertes Shared ROM für Kanal 6 und 7
    shared_sine_rom rom_inst_D (
        .clk(clk),
        .addr_a(addr6), .q_a(sine_val6),
        .addr_b(addr7), .q_b(sine_val7)
    );

    // Fünftes Shared ROM für Kanal 8 und 9
    shared_sine_rom rom_inst_E (
        .clk(clk),
        .addr_a(addr8), .q_a(sine_val8),
        .addr_b(addr9), .q_b(sine_val9)
    );


    // ----------------------------------------------------
    // 4. KANAL-INSTANZEN (NCOs),  getaktet durch sample_en, also 1/5-tel des Haupttaktes von 50 MHz
    // ----------------------------------------------------
    // Die phase_inc Werte sind auf 10 MHz Referenztakt berechnet!
    // Formel: phase_inc = (f_ziel * 2^32) / 10.000.000
    wire signed [15:0] s0, s1, s2, s3, s4, s5, s6, s7, s8, s9;

    // Kanal 0: 603 kHz
    nco nco0 (.clk(clk), .rst(sys_rst), .en(sample_en), .rf_out(s0), 
              .audio_in(w_aud0), .phase_inc(32'h0F70_0020), .ext_gain(16'd256),
              .phase_out(addr0), .sine_val_in(sine_val0));

    // Kanal 1: 756 kHz
    nco nco1 (.clk(clk), .rst(sys_rst), .en(sample_en), .rf_out(s1), 
              .audio_in(w_aud1), .phase_inc(32'h1359_196B), .ext_gain(16'd256),
              .phase_out(addr1), .sine_val_in(sine_val1));

    // Kanal 2: 999 kHz
    nco nco2 (.clk(clk), .rst(sys_rst), .en(sample_en), .rf_out(s2), 
              .audio_in(w_aud2), .phase_inc(32'h1993_4566), .ext_gain(16'd256),
              .phase_out(addr2), .sine_val_in(sine_val2));

    // Kanal 3: 1440 kHz
    nco nco3 (.clk(clk), .rst(sys_rst), .en(sample_en), .rf_out(s3), 
              .audio_in(w_aud3), .phase_inc(32'h24DD_2F1B), .ext_gain(16'd256),
              .phase_out(addr3), .sine_val_in(sine_val3));

    // Kanal 4: 531 kHz
    nco nco4 (.clk(clk), .rst(sys_rst), .en(sample_en), .rf_out(s4), 
              .audio_in(w_aud4), .phase_inc(32'h0D98_B22B), .ext_gain(16'd256),
              .phase_out(addr4), .sine_val_in(sine_val4));

    // Kanal 5: 810 kHz
    nco nco5 (.clk(clk), .rst(sys_rst), .en(sample_en), .rf_out(s5), 
              .audio_in(w_aud5), .phase_inc(32'h14BC_A17F), .ext_gain(16'd256),
              .phase_out(addr5), .sine_val_in(sine_val5));

    // Kanal 6: 900 kHz
    nco nco6 (.clk(clk), .rst(sys_rst), .en(sample_en), .rf_out(s6), 
              .audio_in(w_aud6), .phase_inc(32'h170A_7C70), .ext_gain(16'd256),
              .phase_out(addr6), .sine_val_in(sine_val6));

    // Kanal 7: 1080 kHz
    nco nco7 (.clk(clk), .rst(sys_rst), .en(sample_en), .rf_out(s7), 
              .audio_in(w_aud7), .phase_inc(32'h1BA5_E353), .ext_gain(16'd256),
              .phase_out(addr7), .sine_val_in(sine_val7));

    // Kanal 8: 1215 kHz
    nco nco8 (.clk(clk), .rst(sys_rst), .en(sample_en), .rf_out(s8), 
              .audio_in(w_aud8), .phase_inc(32'h1F1A_82BE), .ext_gain(16'd256),
              .phase_out(addr8), .sine_val_in(sine_val8));

    // Kanal 9: 1530 kHz
    nco nco9 (.clk(clk), .rst(sys_rst), .en(sample_en), .rf_out(s9), 
              .audio_in(w_aud9), .phase_inc(32'h272B_4B0C), .ext_gain(16'd256),
              .phase_out(addr9), .sine_val_in(sine_val9));


    // ----------------------------------------------------
    // 5. PIPELINED ADDER TREE (Summierung)
    // ----------------------------------------------------
    // Die Summierung erfolgt synchron zum sample_en.
    reg signed [16:0] sum_stage1_a, sum_stage1_b, sum_stage1_c, sum_stage1_d, sum_stage1_e;  // 17 Bit, da Summe von 16 Bit


    /* verilator lint_off UNUSEDSIGNAL */
    // ERWEITERUNG: Bitbreite wurde von 18 Bit auf 20 Bit erhöht, um Overflow bei 10 NCOs zu verhindern!
    reg signed [19:0] sum_stage2;  // VORHER 18 Bit, JETZT 20 Bit, da Summe aus 10 Signalen
    /* verilator lint_on UNUSEDSIGNAL */

    always @(posedge clk) begin
        if (sys_rst) begin
            sum_stage1_a <= 0; sum_stage1_b <= 0; sum_stage1_c <= 0; sum_stage1_d <= 0; sum_stage1_e <= 0;
            sum_stage2   <= 0; dac_out      <= 0;
        end else if (sample_en) begin 
            // bei jedem 5. Takt , also 10 MHz bei 50 MHz Master-CLK
            // bei jeder ADD ein Bit mehr um Überlauf zu verhindern
            // Ebene 1: Addiere Paare (17 Bit)
            sum_stage1_a <= $signed(s0) + $signed(s1);
            sum_stage1_b <= $signed(s2) + $signed(s3);
            sum_stage1_c <= $signed(s4) + $signed(s5);
            sum_stage1_d <= $signed(s6) + $signed(s7);
            sum_stage1_e <= $signed(s8) + $signed(s9);

            // Ebene 2: Gesamtsumme (VORHER 18 Bit, JETZT 20 Bit)
            // ERWEITERUNG: Hier werden nun alle 5 Paare summiert
            sum_stage2   <= $signed(sum_stage1_a) + $signed(sum_stage1_b) + 
                            $signed(sum_stage1_c) + $signed(sum_stage1_d) + 
                            $signed(sum_stage1_e);
            
            // DAC-Mapping (Offset-Binary Wandlung)
            // Wir nehmen die obersten 12 Bit der Gesamtsumme.
            // Das höchste Bit ist das Vorzeichen. 
            // Durch Invertieren des Vorzeichenbits verschieben wir 
            // den Wertebereich vom negativen in den reinen positiven Bereich.
            // ERWEITERUNG: Indizes von 17 auf 19 und 16 auf 18 verschoben (wegen 20-Bit Erweiterung).
            dac_out <= { ~sum_stage2[19], sum_stage2[18:19-(OUT_BITS-1)] };
        end
        // WICHTIG: dac_out behält seinen Wert automatisch für die 
        // restlichen 4 Takte, in denen 'sample_en' Low ist (Hold).
    end

endmodule
