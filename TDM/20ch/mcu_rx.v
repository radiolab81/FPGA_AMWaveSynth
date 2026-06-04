/*
 * MODUL: mcu_rx (TDM-Bus-Version - EMV-Version - 20 KANAL)
 * ---------------------------------------------------------------------
 * Empfängt und decodiert den Byte-Strom der MCU unter EMV-Bedingungen.
 * Schützt die FSM durch digitale Hysterese (Glitch-Filter) vor Störimpulsen.
 * Nutzt das Zustand-für-Zustand Prüfprinzip ("Türsteher"), um unempfindlich 
 * gegen asynchronen Datenmüll zu sein, hält aber die Bus-Pipeline synchron.
 * Hardware-Härtungen:
 * - 2-FF Synchronizer für den Datenbus (gegen Metastabilität)
 * - 3-FF Synchronizer + Glitch-Filter für Strobe/Enable
 * - FSM Watchdog-Timeout (verhindert Deadlocks bei abgerissenen Transfers)
 */
module mcu_rx #(
    // Parameter für die Hardware-Härtung
    // Bei z.B. 50 MHz Takt entspricht 50.000.000 -> 1 Sekunde Timeout
    parameter TIMEOUT_CYCLES = 32'd50_000_000, 
    parameter FILTER_TAPS    = 4'd4            // Länge des Glitch-Filters (Takte)
)(
    input wire clk,
    input wire rst,
    input wire [7:0] data_in,   // Asynchroner 8-Bit Bus von MCU
    input wire data_en,         // Asynchroner Strobe/Enable Puls von MCU
    
    // ERWEITERUNG: 5-Bit Bus für bis zu 32 Kanäle (wir nutzen 20)
    output reg [4:0]  w_ch,
    output reg        w_audio_en,
    output reg [7:0]  w_audio_data,
    output reg        w_frq_en,
    output reg [31:0] w_frq_data,
    output reg        w_gain_en,
    output reg [15:0] w_gain_data
);

    // =========================================================================
    // 1. EINGANGSSYNCHRONISATION & GLITCH-FILTERUNG (PIPELINED)
    // =========================================================================
    
    // Synchronisierungs-Register
    reg [7:0] data_in_meta, data_in_sync;
    reg [2:0] en_meta; // 3-stufiger Synchronizer für das kritische Strobe-Signal
    
    // Pipeline zur Laufzeitkompensation (6 Stufen), damit der Datenbus 
    // exakt synchron mit dem gefilterten Enable-Signal bei der FSM ankommt.
    reg [7:0] data_pipe [0:5];
    
    // Dieser Draht spiegelt das perfekt verzögerte Datenbyte für die FSM
    wire [7:0] data_in_sync2 = data_pipe[5];
    
    // Register für den digitalen Tiefpass (Hysterese)
    reg [FILTER_TAPS-1:0] en_filter;
    reg en_clean;
    reg en_clean_prev;
    
    // Edge-Detection auf dem SAUBEREN Signal
    wire de_pulse = (en_clean && !en_clean_prev);

    always @(posedge clk) begin
        if (rst) begin
            data_in_meta <= 8'd0;
            data_in_sync <= 8'd0;
            en_meta      <= 3'd0;
            en_filter    <= {FILTER_TAPS{1'b0}};
            en_clean     <= 1'b0;
            en_clean_prev<= 1'b0;
            
            data_pipe[0] <= 8'd0; data_pipe[1] <= 8'd0;
            data_pipe[2] <= 8'd0; data_pipe[3] <= 8'd0;
            data_pipe[4] <= 8'd0; data_pipe[5] <= 8'd0;
        end else begin
            // 2-FF Sync für Datenbus (Verhindert fehlerhaftes Routing durch Metastabilität)
            data_in_meta <= data_in;
            data_in_sync <= data_in_meta;
            
            // Daten-Pipeline schiebt das Byte parallel zur Filterlaufzeit nach hinten
            data_pipe[0]     <= data_in_sync;
            data_pipe[1]     <= data_pipe[0];
            data_pipe[2]     <= data_pipe[1];
            data_pipe[3]     <= data_pipe[2];
            data_pipe[4]     <= data_pipe[3];
            data_pipe[5]     <= data_pipe[4];
            
            // 3-FF Sync für Enable
            en_meta <= {en_meta[1:0], data_en};
            
            // Glitch Filter / Digitale Hysterese
            // Signal wird in ein Schieberegister getaktet
            en_filter <= {en_filter[FILTER_TAPS-2:0], en_meta[2]};
            
            // "Schmitt-Trigger" Logik:
            // Signal geht nur High, wenn alle Taps High sind (stabiles 1)
            // Signal geht nur Low, wenn alle Taps Low sind (stabiles 0)
            if (&en_filter) begin
                en_clean <= 1'b1;
            end else if (~|en_filter) begin
                en_clean <= 1'b0;
            end
            
            // Verzögerung für Flankenerkennung
            en_clean_prev <= en_clean;
        end
    end


    // =========================================================================
    // 2. PROTOKOLL FSM & WATCHDOG (FÜR TDM-BUS-AUSGABE)
    // =========================================================================

    // Zustandsdefinitionen
    localparam S_IDLE   = 4'd0;
    localparam S_A_U    = 4'd1;
    localparam S_A_D    = 4'd2;
    localparam S_A_DATA = 4'd3;
    localparam S_F_R    = 4'd4;
    localparam S_F_Q    = 4'd5;
    localparam S_F_DATA = 4'd6;
    localparam S_G_A    = 4'd7;
    localparam S_G_N    = 4'd8;
    localparam S_G_CH   = 4'd9;
    localparam S_G_DATA = 4'd10;
                
    reg [3:0]  state;
    // ERWEITERUNG: Zähler auf 7 Bit für 80 Bytes (Frequenz)
    reg [6:0]  byte_cnt;
    reg [31:0] temp_freq;
    reg [4:0]  target_ch; // 5-Bit Zielkanal
    reg [15:0] temp_gain;
    reg [31:0] watchdog_cnt;

    always @(posedge clk) begin
        if (rst) begin
            state        <= S_IDLE;
            byte_cnt     <= 7'd0;
            temp_freq    <= 32'd0;
            temp_gain    <= 16'd0;
            target_ch    <= 5'd0;
            watchdog_cnt <= 32'd0;
            
            w_ch         <= 5'd0;
            w_audio_en   <= 1'b0; w_audio_data <= 8'd0;
            w_frq_en     <= 1'b0; w_frq_data   <= 32'd0;
            w_gain_en    <= 1'b0; w_gain_data  <= 16'd0;
        end else begin
            // Strobes für den Bus standardmäßig für genau einen Takt auf 0 setzen
            w_audio_en <= 1'b0;
            w_frq_en   <= 1'b0;
            w_gain_en  <= 1'b0;

            // Watchdog Logic: Setzt die FSM zurück, wenn sie festhängt
            if (state != S_IDLE) begin
                if (de_pulse) begin
                    watchdog_cnt <= 32'd0; // Reset Watchdog bei Aktivität
                end else begin
                    watchdog_cnt <= watchdog_cnt + 1'b1;
                    if (watchdog_cnt >= TIMEOUT_CYCLES) begin
                        state        <= S_IDLE;
                        watchdog_cnt <= 32'd0;
                    end
                end
            end else begin
                watchdog_cnt <= 32'd0; // Im IDLE ruht der Watchdog
            end

            // Haupt FSM
            if (de_pulse) begin
                case (state)
                    
                    // --- HEADER-ERKENNUNG (Zeichen für Zeichen, absolut EMV-sicher) ---
                    S_IDLE: begin
                        if (data_in_sync2 == "A") state <= S_A_U;
                        else if (data_in_sync2 == "F") state <= S_F_R;
                        else if (data_in_sync2 == "G") state <= S_G_A;
                    end

                    // --- AUDIO PFAD ---
                    S_A_U: state <= (data_in_sync2 == "U") ? S_A_D : S_IDLE;
                    S_A_D: begin
                        if (data_in_sync2 == "D") begin
                            state <= S_A_DATA; byte_cnt <= 7'd0;
                        end else state <= S_IDLE;
                    end

                    // --- AUDIO DATENPFAD (Direktes Streaming auf den TDM-Bus) ---
                    S_A_DATA: begin
                        w_ch         <= byte_cnt[4:0];
                        w_audio_data <= data_in_sync2;
                        w_audio_en   <= 1'b1; // Trigger für den TDM-Kern des aktuellen Kanals
                        
                        // Stop bei Kanal 19 (20. Byte)
                        if (byte_cnt == 7'd19) state <= S_IDLE;
                        else byte_cnt <= byte_cnt + 7'd1;
                    end

                    // --- FREQUENZ PFAD ---
                    S_F_R: state <= (data_in_sync2 == "R") ? S_F_Q : S_IDLE;
                    S_F_Q: begin
                        if (data_in_sync2 == "Q") begin
                            state <= S_F_DATA; byte_cnt <= 7'd0;
                        end else state <= S_IDLE;
                    end
                    // --- FREQUENZ DATENPFAD (32-Bit zusammensetzen, dann feuern) ---
                    S_F_DATA: begin
                        temp_freq <= {temp_freq[23:0], data_in_sync2};
                        
                        // Jedes 4. Byte (Byte-Index 3, 7, 11...) ist das LSB -> Wort komplett
                        if (byte_cnt[1:0] == 2'b11) begin
                            w_ch       <= byte_cnt[6:2]; // Kanal berechnen
                            w_frq_data <= {temp_freq[23:0], data_in_sync2};
                            w_frq_en   <= 1'b1; 
                        end
                        
                        // Stop bei Byte 79 (20 x 4 Bytes)
                        if (byte_cnt == 7'd79) state <= S_IDLE;
                        else byte_cnt <= byte_cnt + 7'd1;
                    end
       
                    // --- GAIN PFAD ---
                    S_G_A: state <= (data_in_sync2 == "A") ? S_G_N : S_IDLE;
                    S_G_N: state <= (data_in_sync2 == "N") ? S_G_CH : S_IDLE;

                    S_G_CH: begin
                        // Gültigkeit prüfen: Darf max Kanal 19 sein
                        if (data_in_sync2 <= 8'd19) begin
                            target_ch <= data_in_sync2[4:0];
                            state <= S_G_DATA; byte_cnt <= 7'd0;
                        end else state <= S_IDLE;
                    end
                    
                    S_G_DATA: begin
                        temp_gain <= {temp_gain[7:0], data_in_sync2};
                        if (byte_cnt == 7'd1) begin
                            w_ch        <= target_ch;
                            w_gain_data <= {temp_gain[7:0], data_in_sync2};
                            w_gain_en   <= 1'b1; 
                            state       <= S_IDLE;
                        end else byte_cnt <= byte_cnt + 7'd1;
                    end
                    
                    default: state <= S_IDLE;
                endcase
            end
        end
    end
endmodule
