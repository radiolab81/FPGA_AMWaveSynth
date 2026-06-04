/*
 * MODUL: tdm_nco_core (Inklusive vollständiger Pro-Kanal-AGC & Noise-Gate)
 * ---------------------------------------------------------------------
 * Verarbeitet 5 Kanäle im Time-Division-Multiplexing-Verfahren.
 * Integriert die AGC-Zustände je Kanal und sichert einen absolut reinen
 * unmodulierten Träger bei Stille über ein pro Kanal wirkendes Noise-Gate.
 */

module tdm_nco_core (
    input wire clk,
    input wire rst,
    input wire [2:0] slot,          // Aktueller TDM-Slot (0..4)
    input wire [2:0] slot_stg1,     // Um 1 Takt verzögerter Slot für RAM-Writeback
    
    // MCU RAM-Schreibinterface
    input wire [2:0]  mcu_waddr,
    input wire        mcu_audio_we,
    input wire [7:0]  mcu_audio_data,
    input wire        mcu_frq_we,
    input wire [31:0] mcu_frq_data,
    input wire        mcu_gain_we,
    input wire [15:0] mcu_gain_data,
    
    // Interface zum externen Shared Sine ROM
    output wire [11:0]        sine_addr,
    input wire signed [15:0]  sine_val,
    
    // Modulierter RF-Ausgang dieses Kerns
    output reg signed [15:0]  rf_out
);

    // ----------------------------------------------------
    // M4K-RAM Definitionen (Inferred Dual-Port RAM)
    // ----------------------------------------------------
    (* ramstyle = "M4K" *) reg [7:0]  ram_audio [0:4];
    (* ramstyle = "M4K" *) reg [31:0] ram_frq   [0:4];
    (* ramstyle = "M4K" *) reg [15:0] ram_gain  [0:4];
    (* ramstyle = "M4K" *) reg [31:0] ram_phase [0:4];
    
    // Speicherstrukturen für den AGC-Status der 5 Kanäle
    (* ramstyle = "M4K" *) reg [6:0]  ram_peak  [0:4];
    (* ramstyle = "M4K" *) reg [15:0] ram_decay [0:4];

    // Speicher-Initialisierung
    integer i;
    initial begin
        for (i = 0; i < 5; i = i + 1) begin
            ram_audio[i] = 8'd128; ram_frq[i]   = 32'd0;
            ram_gain[i]  = 16'hFFFF;  ram_phase[i] = 32'd0;
            ram_peak[i]  = 7'd0;   ram_decay[i] = 16'd0;
        end
    end

    // Synchroner Schreibzugriff von der MCU (Port A)
    always @(posedge clk) begin
        if (mcu_audio_we) ram_audio[mcu_waddr] <= mcu_audio_data;
        if (mcu_frq_we)   ram_frq[mcu_waddr]   <= mcu_frq_data;
        if (mcu_gain_we)  ram_gain[mcu_waddr]  <= mcu_gain_data;
    end

    // ----------------------------------------------------
    // Pipeline-Stufe 1: RAM-Lesezugriff & Phasen-/AGC-Update
    // ----------------------------------------------------
    reg [7:0]  core_audio;
    reg [15:0] core_gain;
    reg [31:0] core_frq;
    reg [31:0] core_phase;
    reg [6:0]  core_peak;
    reg [15:0] core_decay;

    /*always @(posedge clk) begin
        core_audio <= ram_audio[slot];
        core_frq   <= ram_frq[slot];
        core_gain  <= ram_gain[slot];
        core_phase <= ram_phase[slot];
        core_peak  <= ram_peak[slot];    // AGC Peak-Wert für diesen Slot holen
        core_decay <= ram_decay[slot];   // AGC Decay-Zähler für diesen Slot holen
    end*/
    always @(posedge clk) begin
        // --- AUDIO FORWARDING ---
        // Wenn MCU schreibt UND die Adresse dem aktuellen Slot entspricht: Forwarding
        if (mcu_audio_we && (mcu_waddr == slot)) 
            core_audio <= mcu_audio_data;
        else 
            core_audio <= ram_audio[slot];

        // --- FREQUENZ FORWARDING ---
        if (mcu_frq_we && (mcu_waddr == slot)) 
            core_frq <= mcu_frq_data;
        else 
            core_frq <= ram_frq[slot];

        // --- GAIN FORWARDING ---
        if (mcu_gain_we && (mcu_waddr == slot)) 
            core_gain <= mcu_gain_data;
        else 
            core_gain <= ram_gain[slot];

        // --- STANDARD READ (Kein MCU-Schreibzugriff für diese RAMs) ---
        core_phase <= ram_phase[slot];
        core_peak  <= ram_peak[slot];
        core_decay <= ram_decay[slot];
    end

    // Ausgabe der Phasenadresse an das externe ROM
    assign sine_addr = core_phase[31:20];

    // ----------------------------------------------------
    // Pipeline-Stufe 2: AGC Peak-Tracker & Gain LUT-Generierung
    // ----------------------------------------------------
    // Audio zentrieren: 0..255 -> -128..+127
    wire signed [8:0] w_audio_centered = $signed({1'b0, core_audio}) - 9'sd128;
    wire [6:0] w_audio_abs = w_audio_centered[8] ? -w_audio_centered[6:0] : w_audio_centered[6:0];

    // Kombinatorische Berechnung des nächsten AGC-Status für den aktuellen Kanal
    reg [6:0]  next_peak;
    reg [15:0] next_decay;
    always @(*) begin
        if (w_audio_abs > core_peak) begin
            next_peak  = w_audio_abs;     // Instanter Attack
            next_decay = 16'd0;
        end else begin
            if (core_decay == 16'd50000) begin // 5 ms bei 10 MHz Slot-Frequenz
                next_peak  = (core_peak > 7'd0) ? core_peak - 7'd1 : 7'd0;
                next_decay = 16'd0;
            end else begin
                next_peak  = core_peak;
                next_decay = core_decay + 16'd1;
            end
        end
    end

    // Phasen- und AGC-Zustände synchron im Folgetakt (Stufe 2) zurückschreiben
    wire [31:0] next_phase = core_phase + core_frq;
    always @(posedge clk) begin
        ram_phase[slot_stg1] <= next_phase;
        ram_peak[slot_stg1]  <= next_peak;
        ram_decay[slot_stg1] <= next_decay;
    end

    // AGC Inversions-LUT (angewendet auf den gelesenen core_peak)
    reg [7:0] w_agc_gain;
    always @(*) begin
        if      (core_peak < 7'd10) w_agc_gain = 8'h00; // NOISE GATE: Träger wird absolut rein!
        else if (core_peak >= 112)  w_agc_gain = 8'h0D; // ~80% AM Regler
        else if (core_peak >= 96)   w_agc_gain = 8'h10;
        else if (core_peak >= 80)   w_agc_gain = 8'h13;
        else if (core_peak >= 64)   w_agc_gain = 8'h16;
        else if (core_peak >= 48)   w_agc_gain = 8'h1D;
        else if (core_peak >= 32)   w_agc_gain = 8'h29;
        else                        w_agc_gain = 8'h3F; // Max Boost
    end

    // Pipeline-Register von Stufe 2 zu Stufe 3
    reg signed [8:0] audio_centered_stg2;
    reg [7:0]        agc_gain_stg2;
    reg [15:0]       gain_stg2;

    always @(posedge clk) begin
        audio_centered_stg2 <= w_audio_centered;
        agc_gain_stg2       <= w_agc_gain;
        gain_stg2           <= core_gain;
    end

    // ----------------------------------------------------
    // Pipeline-Stufe 3: AGC Gain anwenden & Audio skalieren
    // ----------------------------------------------------
    wire signed [11:0] w_agc_mult = (audio_centered_stg2 * $signed({1'b0, agc_gain_stg2})) >>> 4;
    
    // Sättigungslogik
    wire signed [8:0] w_audio_gained = (w_agc_mult > 127)  ? 9'sd127 :
                                       (w_agc_mult < -128) ? -9'sd128 :
                                       w_agc_mult[8:0];

    // Pipeline-Register von Stufe 3 zu Stufe 4 (Ausrichtung auf ROM-Output)
    reg signed [17:0] audio_scaled_stg3;
    reg [15:0]        gain_stg3;

    always @(posedge clk) begin
        audio_scaled_stg3 <= $signed(w_audio_gained) <<< 7; // Skalierung passend zu CARRIER_BASE
        gain_stg3         <= gain_stg2;
    end

    // ----------------------------------------------------
    // Pipeline-Stufe 4: Hüllkurve & AM-Modulation des Kanals
    // ----------------------------------------------------
    localparam signed [17:0] CARRIER_BASE = 18'sd16384;

    // Wenn das Noise Gate in Stufe 2 greift, ist audio_scaled_stg3 exakt 0.
    // w_env_pre ist dann exakt CARRIER_BASE -> Absolut unmodulierter Träger!
    wire signed [17:0] w_env_pre   = $signed({1'b0, CARRIER_BASE}) + audio_scaled_stg3;
    wire signed [34:0] w_env_mult  = w_env_pre * $signed({2'b0, gain_stg3});
    wire signed [15:0] w_env_final = w_env_mult[31:16]; // Normierung des externen Kanalgains
    
    // Endgültige Multiplikation der reinen Hüllkurve mit dem Sinus aus dem Shared ROM
    wire signed [31:0] w_rf_mult   = w_env_final * sine_val;

    always @(posedge clk) begin
        if (rst) begin
            rf_out <= 16'd0;
        end else begin
            rf_out <= w_rf_mult[30:15]; // Bereinigter HF-Ausgang (skaliert)
        end
    end
endmodule
