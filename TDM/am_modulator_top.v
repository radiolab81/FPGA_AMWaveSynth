/*
 * MODUL: am_modulator_top (Semi-Parallel TDM)
 * ---------------------------------------------------------------------
 * Hauptmodul des AM-Modulators. Instanziiert die Unterkomponenten und
 * führt die Akkumulation der TDM-Datenströme für den DAC durch.
 */

module am_modulator_top #( 
    parameter OUT_BITS = 12,  // Breite des DAC oder R2R-Netzwerks
    parameter TIMEOUT_CYCLES = 32'd50_000_000 
)( 
    input wire clk,                        // Globaler 50 MHz Takt vom Quarz
    input wire rst,                        // Asynchroner Hardware-Reset 
    output wire sample_en_out,             // DAC Sample-Trigger (10 MHz) 

    // MCU Interface 
    input wire [7:0] data_in,  // 8-Bit Bus von MCU
    input wire data_en,        // Strobe/Enable Puls von MCU
 
     // DAC/R2R-DAC Ausgangspins
    output reg signed [OUT_BITS-1:0] dac_out
);
    // ----------------------------------------------------
    // 0. RESET-ENTPRELLUNG (DEBOUNCER)
    // ----------------------------------------------------
    wire sys_rst; // Dieser Draht wird nun vom Debouncer getrieben

    // Instanziierung des Entprell-Moduls
    debouncer #(
        .WAIT_CYCLES(1)
    ) rst_filter (
        .clk(clk),
        .signal_in(!rst),      // (!)für den Fall, dass RST auf dem Board invertiert ist 
        .signal_out(sys_rst)   // Stabiles Ausgangssignal
    );
    // für den Fall, dass RST auf dem Board invertiert ist 
    //wire sys_rst = !rst; // sys_rst ist jetzt 1, wenn der Taster GEDRÜCKT wird

    // ---------------------------------------------------- 
    // Instanziierung: MCU-Empfänger / Protokoll-Parser 
    // ---------------------------------------------------- 
    wire [3:0]  mcu_w_ch; 
    wire        mcu_audio_en, mcu_frq_en, mcu_gain_en; 
    wire [7:0]  mcu_audio_data; 
    wire [31:0] mcu_frq_data; 
    wire [15:0] mcu_gain_data; 
 
    mcu_rx #(.TIMEOUT_CYCLES(TIMEOUT_CYCLES)) u_mcu_rx ( 
        .clk(clk), 
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
 
    // Adress-Dekodierung und Signalaufteilung für die beiden Kerne 
    // Core 0: Kanäle 0..4  |  Core 1: Kanäle 5..9 
    //wire [2:0] core_waddr = (mcu_w_ch >= 4'd5) ? (mcu_w_ch - 4'd5) : mcu_w_ch[2:0]; 
	 // KORREKTUR: Explizites Abschneiden auf 3 Bit am Ende der Berechnung
    // 1. Das mathematische 4-Bit-Ergebnis in einem Hilfs-Wire parken
    wire [3:0] mcu_w_ch_sub = mcu_w_ch - 4'd5;
    // 2. Jetzt sauber den Ternär-Operator mit echtem Bit-Select füttern
    wire [2:0] core_waddr = (mcu_w_ch >= 4'd5) ? mcu_w_ch_sub[2:0] : mcu_w_ch[2:0];
     
    wire core0_audio_we = mcu_audio_en && (mcu_w_ch < 4'd5); 
    wire core1_audio_we = mcu_audio_en && (mcu_w_ch >= 4'd5); 
     
    wire core0_frq_we   = mcu_frq_en   && (mcu_w_ch < 4'd5); 
    wire core1_frq_we   = mcu_frq_en   && (mcu_w_ch >= 4'd5); 
     
    wire core0_gain_we  = mcu_gain_en  && (mcu_w_ch < 4'd5); 
    wire core1_gain_we  = mcu_gain_en  && (mcu_w_ch >= 4'd5); 
 
    // ---------------------------------------------------- 
    // TDM-Slot-Steuerung (Zentraler Modulo-5-Zähler) 
    // ---------------------------------------------------- 
    reg [2:0] slot = 3'd0; 
    reg [2:0] slot_stg1 = 3'd0; 
 
    always @(posedge clk) begin 
        if (sys_rst) begin 
            slot <= 3'd0; 
        end else begin 
            if (slot == 3'd4) slot <= 3'd0; 
            else              slot <= slot + 3'd1; 
        end 
    end 
 
    always @(posedge clk) begin 
        slot_stg1 <= slot; 
    end 
 
    // ---------------------------------------------------- 
    // Instanziierung: Gemeinsames Dual-Port Sinus-ROM 
    // ---------------------------------------------------- 
    wire [11:0]        sine_addr_a, sine_addr_b; 
    wire signed [15:0] sine_q_a, sine_q_b; 
 
    shared_sine_rom u_shared_sine_rom ( 
        .clk(clk), 
        .addr_a(sine_addr_a), 
        .addr_b(sine_addr_b), 
        .q_a(sine_q_a), 
        .q_b(sine_q_b) 
    ); 
 
    // ---------------------------------------------------- 
    // Instanziierung: Die zwei parallelen TDM-Kerne 
    // ---------------------------------------------------- 
    wire signed [15:0] core0_rf_out; 
    wire signed [15:0] core1_rf_out; 
 
    // Core 0 verarbeitet CH 0, 1, 2, 3, 4 
    tdm_nco_core u_tdm_nco_core0 ( 
        .clk(clk), 
        .rst(sys_rst), 
        .slot(slot), 
        .slot_stg1(slot_stg1), 
        .mcu_waddr(core_waddr), 
        .mcu_audio_we(core0_audio_we), 
        .mcu_audio_data(mcu_audio_data), 
        .mcu_frq_we(core0_frq_we), 
        .mcu_frq_data(mcu_frq_data), 
        .mcu_gain_we(core0_gain_we), 
        .mcu_gain_data(mcu_gain_data), 
        .sine_addr(sine_addr_a), 
        .sine_val(sine_q_a), 
        .rf_out(core0_rf_out) 
    ); 
 
    // Core 1 verarbeitet CH 5, 6, 7, 8, 9 
    tdm_nco_core u_tdm_nco_core1 ( 
        .clk(clk), 
        .rst(sys_rst), 
        .slot(slot), 
        .slot_stg1(slot_stg1), 
        .mcu_waddr(core_waddr), 
        .mcu_audio_we(core1_audio_we), 
        .mcu_audio_data(mcu_audio_data), 
        .mcu_frq_we(core1_frq_we), 
        .mcu_frq_data(mcu_frq_data), 
        .mcu_gain_we(core1_gain_we), 
        .mcu_gain_data(mcu_gain_data), 
        .sine_addr(sine_addr_b), 
        .sine_val(sine_q_b), 
        .rf_out(core1_rf_out) 
    ); 
 
    // ---------------------------------------------------- 
    // Synchroner Akkumulator & DAC-Ausgabe 
    // ---------------------------------------------------- 
    reg signed [19:0] accumulator = 20'd0; 
    wire signed [16:0] current_pair_sum = $signed(core0_rf_out) + $signed(core1_rf_out); 
 
    always @(posedge clk) begin 
        if (sys_rst) begin 
            accumulator <= 20'd0; 
            dac_out     <= 12'd0; 
        end else begin 
            if (slot == 3'd4) begin 
                // 1. Die akkumulierte Summe aller 10 Kanäle an den DAC übergeben 
                // Konvertierung von Signed 2's Complement zu Offset-Binary 
                dac_out <= {~accumulator[19], accumulator[18:19-(OUT_BITS-1)]}; 
                 
                // 2. Akkumulator direkt mit dem ersten frischen Paar neu laden 
                accumulator <= $signed(current_pair_sum); 
            end else begin 
                // Kontinuierliche Aufsummierung über die Slots 
                accumulator <= accumulator + $signed(current_pair_sum); 
            end 
        end 
    end 
 
    // DAC Update-Puls (Aktiv bei jedem fertigen Berechnungszyklus) 
    assign sample_en_out = (slot == 3'd4); 
 
endmodule
