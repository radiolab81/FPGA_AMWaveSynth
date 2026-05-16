/*
 * MODUL: mcu_rx (EMV-Version)
 * ---------------
 * Empfängt einen seriellen Byte-Strom:
 * - Audio: "AUD" gefolgt von 10 Bytes (CH0 - CH9)
 * - Frequenz: "FRQ" gefolgt von 40 Bytes (4 Bytes pro Kanal, MSB first)
 * - Gain: "GAN" gefolgt von 1 Byte (Kanal 0-9) und 2 Bytes (16-Bit Gain, MSB first)
 * 
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
    
    // Parallele Ausgänge für die Modulatoren (Audio)
    output reg [7:0] ch0, ch1, ch2, ch3, ch4, ch5, ch6, ch7, ch8, ch9,
    
    // Parallele Ausgänge für die Modulatoren (Frequenzwörter, 32-Bit)
    output reg [31:0] f_ch0, f_ch1, f_ch2, f_ch3, f_ch4, 
    output reg [31:0] f_ch5, f_ch6, f_ch7, f_ch8, f_ch9,

    // Parallele Ausgänge für die Modulatoren (Gain, 16-Bit)
    output reg [15:0] g_ch0, g_ch1, g_ch2, g_ch3, g_ch4,
    output reg [15:0] g_ch5, g_ch6, g_ch7, g_ch8, g_ch9
);

    // =========================================================================
    // 1. EINGANGSSYNCHRONISATION & GLITCH-FILTERUNG
    // =========================================================================
    
    // Synchronisierungs-Register
    reg [7:0] data_in_meta, data_in_sync;
    reg [2:0] en_meta; // 3-stufiger Synchronizer für das kritische Strobe-Signal
    
    // Glitch-Filter Register (Schieberegister)
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
        end else begin
            // 2-FF Sync für Datenbus (Verhindert fehlerhaftes Routing durch Metastabilität)
            data_in_meta <= data_in;
            data_in_sync <= data_in_meta;
            
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
    // 2. PROTOKOLL FSM & WATCHDOG
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
    reg [5:0]  byte_cnt;         // Zählt Bytes (bis 40 für Freq, bis 2 für Gain)
    reg [31:0] temp_freq;        // Schieberegister für Frequenz
    reg [3:0]  target_ch;        // Speichert den Zielkanal (0-9)
    reg [15:0] temp_gain;        // Schieberegister für das 16-Bit Gain-Wort
    
    reg [31:0] watchdog_cnt;     // Timeout-Zähler

    always @(posedge clk) begin
        if (rst) begin
            state        <= S_IDLE;
            byte_cnt     <= 6'd0;
            temp_freq    <= 32'd0;
            temp_gain    <= 16'd0;
            target_ch    <= 4'd0;
            watchdog_cnt <= 32'd0;
            
            // Initialisierung mit "Stille" (Offset-Binary Mitte)
            {ch0, ch1, ch2, ch3, ch4, ch5, ch6, ch7, ch8, ch9} <= 80'h80808080808080808080;
            
            // Initialisierung Frequenzen
            f_ch0 <= 32'h0F70_0020; f_ch1 <= 32'h1359_196B;
            f_ch2 <= 32'h1993_4566; f_ch3 <= 32'h24DD_2F1B;
            f_ch4 <= 32'h0D98_B22B; f_ch5 <= 32'h14BC_A17F;
            f_ch6 <= 32'h170A_7C70; f_ch7 <= 32'h1BA5_E353;
            f_ch8 <= 32'h1F1A_82BE; f_ch9 <= 32'h272B_4B0C;
                
            // Initialisierung Gain (Voller Pegel = 65535)
            g_ch0 <= 16'd65535; g_ch1 <= 16'd65535; g_ch2 <= 16'd65535; 
            g_ch3 <= 16'd65535; g_ch4 <= 16'd65535; g_ch5 <= 16'd65535; 
            g_ch6 <= 16'd65535; g_ch7 <= 16'd65535; g_ch8 <= 16'd65535; 
            g_ch9 <= 16'd65535;
            
        end else begin
            
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
                // WICHTIG: Wir nutzen jetzt data_in_sync anstelle von data_in!
                case (state)
                    S_IDLE: begin
                        if (data_in_sync == "A") state <= S_A_U;
                        else if (data_in_sync == "F") state <= S_F_R;
                        else if (data_in_sync == "G") state <= S_G_A;
                    end
                    
                    // --- AUDIO PFAD ---
                    S_A_U: state <= (data_in_sync == "U") ? S_A_D : S_IDLE;
                    S_A_D: begin
                        if (data_in_sync == "D") begin 
                            state <= S_A_DATA; byte_cnt <= 6'd0; 
                        end else state <= S_IDLE;
                    end
                    S_A_DATA: begin
                        case (byte_cnt)
                            6'd0: ch0 <= data_in_sync; 6'd1: ch1 <= data_in_sync;
                            6'd2: ch2 <= data_in_sync; 6'd3: ch3 <= data_in_sync;
                            6'd4: ch4 <= data_in_sync; 6'd5: ch5 <= data_in_sync;
                            6'd6: ch6 <= data_in_sync; 6'd7: ch7 <= data_in_sync;
                            6'd8: ch8 <= data_in_sync; 
                            6'd9: begin ch9 <= data_in_sync; state <= S_IDLE; end
                            default: state <= S_IDLE;
                        endcase
                        byte_cnt <= byte_cnt + 6'd1;
                    end
                    
                    // --- FREQUENZ PFAD ---
                    S_F_R: state <= (data_in_sync == "R") ? S_F_Q : S_IDLE;
                    S_F_Q: begin
                        if (data_in_sync == "Q") begin 
                            state <= S_F_DATA; byte_cnt <= 6'd0; 
                        end else state <= S_IDLE;
                    end
                    S_F_DATA: begin
                        temp_freq <= {temp_freq[23:0], data_in_sync};
                        
                        if (byte_cnt[1:0] == 2'd3) begin
                            case (byte_cnt[5:2])
                                4'd0: f_ch0 <= {temp_freq[23:0], data_in_sync};
                                4'd1: f_ch1 <= {temp_freq[23:0], data_in_sync};
                                4'd2: f_ch2 <= {temp_freq[23:0], data_in_sync};
                                4'd3: f_ch3 <= {temp_freq[23:0], data_in_sync};
                                4'd4: f_ch4 <= {temp_freq[23:0], data_in_sync};
                                4'd5: f_ch5 <= {temp_freq[23:0], data_in_sync};
                                4'd6: f_ch6 <= {temp_freq[23:0], data_in_sync};
                                4'd7: f_ch7 <= {temp_freq[23:0], data_in_sync};
                                4'd8: f_ch8 <= {temp_freq[23:0], data_in_sync};
                                4'd9: begin f_ch9 <= {temp_freq[23:0], data_in_sync}; state <= S_IDLE; end
                                default: ; 
                            endcase
                        end
                        byte_cnt <= byte_cnt + 6'd1;
                    end

                    // --- GAIN PFAD ---
                    S_G_A: state <= (data_in_sync == "A") ? S_G_N : S_IDLE;
                    S_G_N: state <= (data_in_sync == "N") ? S_G_CH : S_IDLE;
                    
                    S_G_CH: begin
                        if (data_in_sync <= 8'd9) begin
                            target_ch <= data_in_sync[3:0];
                            state <= S_G_DATA;
                            byte_cnt <= 6'd0;
                        end else begin
                            state <= S_IDLE; 
                        end
                    end
                    
                    S_G_DATA: begin
                        temp_gain <= {temp_gain[7:0], data_in_sync};
                        
                        if (byte_cnt == 6'd1) begin 
                            case (target_ch)
                                4'd0: g_ch0 <= {temp_gain[7:0], data_in_sync};
                                4'd1: g_ch1 <= {temp_gain[7:0], data_in_sync};
                                4'd2: g_ch2 <= {temp_gain[7:0], data_in_sync};
                                4'd3: g_ch3 <= {temp_gain[7:0], data_in_sync};
                                4'd4: g_ch4 <= {temp_gain[7:0], data_in_sync};
                                4'd5: g_ch5 <= {temp_gain[7:0], data_in_sync};
                                4'd6: g_ch6 <= {temp_gain[7:0], data_in_sync};
                                4'd7: g_ch7 <= {temp_gain[7:0], data_in_sync};
                                4'd8: g_ch8 <= {temp_gain[7:0], data_in_sync};
                                4'd9: g_ch9 <= {temp_gain[7:0], data_in_sync};
                                default: ;
                            endcase
                            state <= S_IDLE;
                        end else begin
                            byte_cnt <= byte_cnt + 6'd1;
                        end
                    end
                    
                    default: state <= S_IDLE;
                endcase
            end
        end
    end
endmodule
