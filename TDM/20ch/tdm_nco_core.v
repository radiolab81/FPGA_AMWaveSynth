/*
 * MODUL: tdm_nco_core (Stateless ALU Pipeline)
 * ---------------------------------------------------------------------
 * Reine Rechen-Pipeline für NCO, AM-Modulation und AGC.
 * Bezieht ihre Daten aus einem externen Speichermodul und schreibt 
 * den neuen Status im selben Takt zyklisch zurück.
 */

module tdm_nco_core (
    input wire clk,
    input wire rst,
    
    // Daten aus dem externen Speichermodul (Pipeline Stufe 1)
    input wire [7:0]  core_audio,
    input wire [31:0] core_frq,
    input wire [15:0] core_gain,
    input wire [31:0] core_phase,
    input wire [6:0]  core_peak,
    input wire [15:0] core_decay,
    
    // Write-Back an das externe Speichermodul (Stufe 2)
    output wire [31:0] next_phase,
    output wire [6:0]  next_peak,
    output wire [15:0] next_decay,
    
    // Interface zum externen Shared Sine ROM
    output wire [11:0]        sine_addr,
    input wire signed [15:0]  sine_val,
    
    // Modulierter RF-Ausgang dieses Kerns
    output reg signed [15:0]  rf_out
);

    assign sine_addr = core_phase[31:20];

    // ----------------------------------------------------
    // Pipeline-Stufe 2: AGC Peak-Tracker & Gain LUT-Generierung
    // ----------------------------------------------------
    // Audio zentrieren: 0..255 -> -128..+127
    wire signed [8:0] w_audio_centered = $signed({1'b0, core_audio}) - 9'sd128;
    wire [6:0] w_audio_abs = w_audio_centered[8] ? -w_audio_centered[6:0] : w_audio_centered[6:0];

    // Kombinatorisches Write-Back generieren
    assign next_phase = core_phase + core_frq;

    reg [6:0]  r_next_peak;
    reg [15:0] r_next_decay;
    always @(*) begin
        if (w_audio_abs > core_peak) begin
            r_next_peak  = w_audio_abs;  // Instanter Attack
            r_next_decay = 16'd0;
        end else begin
            if (core_decay == 16'd50000) begin // 5 ms bei 10 MHz Slot-Frequenz
                r_next_peak  = (core_peak > 7'd0) ? core_peak - 7'd1 : 7'd0;
                r_next_decay = 16'd0;
            end else begin
                r_next_peak  = core_peak;
                r_next_decay = core_decay + 16'd1;
            end
        end
    end
    
    assign next_peak  = r_next_peak;
    assign next_decay = r_next_decay;

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
    // Pipeline-Stufe 4: Hüllkurve & AM-Modulation
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
