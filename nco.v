/*
 * MODUL: nco
 * ----------
 * Implementiert einen AM-modulierten Oszillator 
 *
 */

module nco (
    input wire clk,                // Globaler 50 MHz Takt
    input wire rst,                // Synchroner Reset
    input wire en,                 // Enable-Puls (Taktfreigabe für 10 MHz)
    input wire [31:0] phase_inc,   // Frequenzsteuerung (Phase Increment)
    input wire [7:0]  audio_in,    // 8-Bit PCM Audio (0-255) für die AM Modulation
    input wire [15:0] ext_gain,    // Att. des modulierten Trägers d65535 = 1.0 / jedes Bit -6dB (-96dB gesammt)
    input wire signed [15:0] sine_val_in, // <--- Kommt vom Shared ROM
    output wire [11:0] phase_out,         // <--- Geht zum Shared ROM
    output reg signed [15:0] rf_out       // Modulierter RF-Ausgang (16-Bit)
);

    // Konstante für den 100% Trägeranteil (Offset für AM)
    localparam signed [17:0] CARRIER_BASE = 18'sd16384;
 
    reg [31:0] phase_acc;                // Phasenakkumulator
    reg signed [17:0] envelope_reg;      // Register für berechnete Hüllkurve
    reg signed [35:0] mod_full;          // Ergebnis der Multiplikation, fertig modulierter Träger

    // --- NEU: State-Variablen für die AGC ---
    reg [6:0] peak_reg;                  // Speichert den aktuellen Spitzenwert (0-128)
    reg [15:0] decay_cnt;                // Zähler für die Abklingzeit (Release)
    
    // Wir geben die Adresse nach außen
    assign phase_out = phase_acc[31:20];

    reg signed [17:0] env_stage1; // Neu: Erste Stufe der Hüllkurve
    reg signed [17:0] env_stage2; // Neu: Zweite Stufe (synchron zum ROM-Output)

    // ====================================================================
    // HÜLLKURVEN-MATHEMATIK & AGC (Kombinatorisch)
    // ====================================================================
    // 1. Audio zentrieren: 0..255 wird zu -128..+127
    wire signed [8:0] audio_centered = $signed({1'b0, audio_in}) - 9'sd128;
    
    // --- NEU: AGC Absolutwert-Bildung ---
    wire [6:0] audio_abs = audio_centered[8] ? -audio_centered[6:0] : audio_centered[6:0];

    // --- NEU: AGC Inversions-LUT für exakt ~80% Modulationsgrad ---
    // Q4.4 Format. Beinhaltet ein Noise-Gate bei Stille, um den Träger absolut rein zu halten.
    reg [7:0] agc_gain;
    always @(*) begin
        if      (peak_reg < 7'd10) agc_gain = 8'h00; // Noise Gate: Bei Stille komplett stumm -> Träger 100% sauber!
        else if (peak_reg >= 112)  agc_gain = 8'h0D; // Regelt Vollaussteuerung auf exakt ~80% AM runter (Faktor 0.81)
        else if (peak_reg >= 96)   agc_gain = 8'h10; // Faktor 1.0
        else if (peak_reg >= 80)   agc_gain = 8'h13; // Faktor 1.2
        else if (peak_reg >= 64)   agc_gain = 8'h16; // Faktor 1.4
        else if (peak_reg >= 48)   agc_gain = 8'h1D; // Faktor 1.8
        else if (peak_reg >= 32)   agc_gain = 8'h29; // Faktor 2.5
        else                       agc_gain = 8'h3F; // Maximaler Boost für leise Signale (Faktor 3.9)
    end

    // --- NEU: AGC Gain anwenden & Skalierung auf Träger-Niveau ---
    wire signed [11:0] agc_mult = (audio_centered * $signed({1'b0, agc_gain})) >>> 4;
    wire signed [8:0] audio_gained = (agc_mult > 127)  ? 9'sd127 :
                                     (agc_mult < -128) ? -9'sd128 :
                                     agc_mult[8:0];

    // Skalierung um 7 Bit (x128), damit das Audio im Verhältnis zu CARRIER_BASE (16384) exakt ~80% erreicht
    wire signed [17:0] audio_scaled = $signed(audio_gained) <<< 7;

    always @(posedge clk) begin
        if (rst) begin
            phase_acc  <= 32'd0;
            env_stage1 <= 18'sd0;
            env_stage2 <= 18'sd0;
            mod_full   <= 36'sd0;
            rf_out     <= 16'd0;
            
            // AGC Reset
            peak_reg   <= 7'd128;
            decay_cnt  <= 16'd0;
        end else if (en) begin
            // Phasen-Update (Adresse geht zum ROM)
            // Frequenz erzeugen & Hüllkurve vorbereiten
            // Wir erhöhen die Phase für den nächsten Lesevorgang.
            phase_acc <= phase_acc + phase_inc;
            
            // --- NEU: AGC Peak-Tracker ---
            if (audio_abs > peak_reg) begin
                peak_reg <= audio_abs; // Instantaner Attack
                decay_cnt <= 16'd0;
            end else begin
                decay_cnt <= decay_cnt + 1;
                if (decay_cnt == 16'd50000) begin // 5 ms pro Decay-Schritt bei 10 MHz
                    if (peak_reg > 7'd0) peak_reg <= peak_reg - 1;
                    decay_cnt <= 16'd0;
                end
            end

            // Parallel dazu berechnen wir die Hüllkurve für diesen Zeitschritt.
            env_stage1 <= 18'($signed( 34'($signed({1'b0, CARRIER_BASE}) + audio_scaled) * $signed({2'b0, ext_gain}) ) >>> 16);
            
            // Verzögerung (Stufe 2), damit Audio zeitgleich mit sine_val_in ankommt
            env_stage2 <= env_stage1;
            
            // Multiplikation Träger * Hüllkurve
            mod_full <= env_stage2 * sine_val_in;
            
            // Runden und Normieren
            // Wir addieren 0.5 (2^14), bevor wir um 15 Bit shiften.
            // Das 16'(...) Casting ist für Verilator, um WIDTH-Warnings zu vermeiden.
            rf_out <= (mod_full + 36'sh4000) >>> 15;
        end
    end
endmodule
