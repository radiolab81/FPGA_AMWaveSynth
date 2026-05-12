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

    
    // Wir geben die Adresse nach außen
    assign phase_out = phase_acc[31:20];

    reg signed [17:0] env_stage1; // Neu: Erste Stufe der Hüllkurve
    reg signed [17:0] env_stage2; // Neu: Zweite Stufe (synchron zum ROM-Output)

    always @(posedge clk) begin
        if (rst) begin
            phase_acc  <= 32'd0;
            env_stage1 <= 18'sd0;
            env_stage2 <= 18'sd0;
            mod_full   <= 36'sd0;
            rf_out     <= 16'd0;
        end else if (en) begin
            // Phasen-Update (Adresse geht zum ROM)
            // Frequenz erzeugen & Hüllkurve vorbereiten
            // Wir erhöhen die Phase für den nächsten Lesevorgang.
            phase_acc <= phase_acc + phase_inc;
            

            // Parallel dazu berechnen wir die Hüllkurve für diesen Zeitschritt.
            // Audio wird zentriert (-128) und mit Gain multipliziert.
            // {9'd0, audio_in}  => aufblasen auf 17 Bits / Vorzeichen
            // - 18'sd128 : Verschiebt den audio_in-Wert um -128, um einen Bereich um 0 zu schaffen, z.B. bei einer 8-Bit-Range (0..255) wird 128 als Mittelwert genutzt.
            // $signed({2'b0, ext_gain}): => ext_gain ist 16 Bits, hier werden 2 Nullen vorangestellt, um es auf 18 Bits zu erweitern, dann signed interpretiert.
            env_stage1 <= 18'($signed( 34'($signed({1'b0, CARRIER_BASE}) + ($signed({9'd0, audio_in}) - 18'sd128)) * $signed({2'b0, ext_gain}) ) >>> 16);
            
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
