/*
 * MODUL: mcu_rx
 * ---------------
 * Empfängt einen seriellen Byte-Strom:
 * - Audio: "AUD" gefolgt von 10 Bytes (CH0 - CH9)
 * - Frequenz: "FRQ" gefolgt von 40 Bytes (4 Bytes pro Kanal, MSB first)
 * - Gain: "GAN" gefolgt von 1 Byte (Kanal 0-9) und 2 Bytes (16-Bit Gain, MSB first)
 */
module mcu_rx (
    input wire clk,
    input wire rst,
    input wire [7:0] data_in,   // 8-Bit Bus von MCU
    input wire data_en,         // Strobe/Enable Puls von MCU
    
    // Parallele Ausgänge für die Modulatoren (Audio)
    output reg [7:0] ch0, ch1, ch2, ch3, ch4, ch5, ch6, ch7, ch8, ch9,
    
    // Parallele Ausgänge für die Modulatoren (Frequenzwörter, 32-Bit)
    output reg [31:0] f_ch0, f_ch1, f_ch2, f_ch3, f_ch4, 
    output reg [31:0] f_ch5, f_ch6, f_ch7, f_ch8, f_ch9,

    // Parallele Ausgänge für die Modulatoren (Gain, 16-Bit)
    output reg [15:0] g_ch0, g_ch1, g_ch2, g_ch3, g_ch4,
    output reg [15:0] g_ch5, g_ch6, g_ch7, g_ch8, g_ch9
);

    // Zustandsdefinitionen
    localparam S_IDLE   = 4'd0;
    localparam S_A_U    = 4'd1;
    localparam S_A_D    = 4'd2;
    localparam S_A_DATA = 4'd3;
    localparam S_F_R    = 4'd4;
    localparam S_F_Q    = 4'd5;
    localparam S_F_DATA = 4'd6;
    // ZUSTÄNDE FÜR GAIN
    localparam S_G_A    = 4'd7;
    localparam S_G_N    = 4'd8;
    localparam S_G_CH   = 4'd9;
    localparam S_G_DATA = 4'd10;
                
    reg [3:0] state;
    reg [5:0] byte_cnt;         // Zählt Bytes (bis 40 für Freq, bis 2 für Gain)
    reg [31:0] temp_freq;       // Schieberegister für Frequenz
    
    // Hilfsregister für Gain-Parsing
    reg [3:0] target_ch;        // Speichert den Zielkanal (0-9)
    reg [15:0] temp_gain;       // Schieberegister für das 16-Bit Gain-Wort

    reg de_prev;
    wire de_pulse = (data_en && !de_prev); // Flankenerkennung

    always @(posedge clk) begin
        if (rst) begin
            state <= S_IDLE; // Automat fängt in Zustand IDLE an
            de_prev <= 1'b0;
            byte_cnt <= 6'd0;
            temp_freq <= 32'd0;
            temp_gain <= 16'd0;
            target_ch <= 4'd0;
            
            // Initialisierung mit "Stille" (Offset-Binary Mitte)
            {ch0, ch1, ch2, ch3, ch4, ch5, ch6, ch7, ch8, ch9} <= 80'h80808080808080808080;
            
            // Initialisierung mit den Hardcode-Default-Frequenzen!
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
            de_prev <= data_en;
            
            if (de_pulse) begin
                case (state)
                    S_IDLE: begin
                        if (data_in == "A") state <= S_A_U;
                        else if (data_in == "F") state <= S_F_R;
                        else if (data_in == "G") state <= S_G_A; // Einstieg in Gain-Pfad
                    end
                    
                    // --- AUDIO PFAD ("A" bereits empfangen) ---
                    S_A_U: state <= (data_in == "U") ? S_A_D : S_IDLE;
                    S_A_D: begin
                        if (data_in == "D") begin 
                            state <= S_A_DATA; byte_cnt <= 6'd0; 
                        end else state <= S_IDLE;
                    end
                    S_A_DATA: begin
                        case (byte_cnt)
                            6'd0: ch0 <= data_in; 6'd1: ch1 <= data_in;
                            6'd2: ch2 <= data_in; 6'd3: ch3 <= data_in;
                            6'd4: ch4 <= data_in; 6'd5: ch5 <= data_in;
                            6'd6: ch6 <= data_in; 6'd7: ch7 <= data_in;
                            6'd8: ch8 <= data_in; 
                            6'd9: begin ch9 <= data_in; state <= S_IDLE; end
                            default: state <= S_IDLE;
                        endcase
                        byte_cnt <= byte_cnt + 6'd1;
                    end
                    
                    // --- FREQUENZ PFAD ("F" bereits empfangen) ---
                    S_F_R: state <= (data_in == "R") ? S_F_Q : S_IDLE;
                    S_F_Q: begin
                        if (data_in == "Q") begin 
                            state <= S_F_DATA; byte_cnt <= 6'd0; 
                        end else state <= S_IDLE;
                    end
                    S_F_DATA: begin
                        // Neues Byte in das 32-Bit Wort reinschieben (Big-Endian Aufbau)
                        temp_freq <= {temp_freq[23:0], data_in};
                        
                        // Jeweils beim 4. Byte weisen wir das fertige 32-Bit Wort dem Kanal zu
                        if (byte_cnt[1:0] == 2'd3) begin
                            case (byte_cnt[5:2])
                                4'd0: f_ch0 <= {temp_freq[23:0], data_in};
                                4'd1: f_ch1 <= {temp_freq[23:0], data_in};
                                4'd2: f_ch2 <= {temp_freq[23:0], data_in};
                                4'd3: f_ch3 <= {temp_freq[23:0], data_in};
                                4'd4: f_ch4 <= {temp_freq[23:0], data_in};
                                4'd5: f_ch5 <= {temp_freq[23:0], data_in};
                                4'd6: f_ch6 <= {temp_freq[23:0], data_in};
                                4'd7: f_ch7 <= {temp_freq[23:0], data_in};
                                4'd8: f_ch8 <= {temp_freq[23:0], data_in};
                                4'd9: begin f_ch9 <= {temp_freq[23:0], data_in}; state <= S_IDLE; end
                                default: ; 
                            endcase
                        end
                        byte_cnt <= byte_cnt + 6'd1;
                    end

                    // --- NEU: GAIN PFAD ("G" bereits empfangen) ---
                    S_G_A: state <= (data_in == "A") ? S_G_N : S_IDLE;
                    S_G_N: state <= (data_in == "N") ? S_G_CH : S_IDLE;
                    
                    S_G_CH: begin
                        // Erwartet Kanalnummer als Rohwert (0x00 - 0x09)
                        if (data_in <= 8'd9) begin
                            target_ch <= data_in[3:0];
                            state <= S_G_DATA;
                            byte_cnt <= 6'd0;
                        end else begin
                            state <= S_IDLE; // Abbruch bei ungültigem Kanal
                        end
                    end
                    
                    S_G_DATA: begin
                        // 16-Bit Wort zusammenbauen (Big-Endian)
                        temp_gain <= {temp_gain[7:0], data_in};
                        
                        if (byte_cnt == 6'd1) begin // Zweites Byte empfangen
                            case (target_ch)
                                4'd0: g_ch0 <= {temp_gain[7:0], data_in};
                                4'd1: g_ch1 <= {temp_gain[7:0], data_in};
                                4'd2: g_ch2 <= {temp_gain[7:0], data_in};
                                4'd3: g_ch3 <= {temp_gain[7:0], data_in};
                                4'd4: g_ch4 <= {temp_gain[7:0], data_in};
                                4'd5: g_ch5 <= {temp_gain[7:0], data_in};
                                4'd6: g_ch6 <= {temp_gain[7:0], data_in};
                                4'd7: g_ch7 <= {temp_gain[7:0], data_in};
                                4'd8: g_ch8 <= {temp_gain[7:0], data_in};
                                4'd9: g_ch9 <= {temp_gain[7:0], data_in};
                                default: ;
                            endcase
                            state <= S_IDLE; // Fertig, zurücksetzen
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
