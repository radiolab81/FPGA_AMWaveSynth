/*
 * MODUL: audio_rx
 * ---------------
 * Empfängt einen seriellen Byte-Strom:
 * - Audio: "AUD" gefolgt von 10 Bytes (CH0 - CH9)
 * - Frequenz: "FRQ" gefolgt von 40 Bytes (4 Bytes pro Kanal, MSB first)
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
    output reg [31:0] f_ch5, f_ch6, f_ch7, f_ch8, f_ch9
);

    // Zustandsdefinitionen
    localparam S_IDLE   = 3'd0;
    localparam S_A_U    = 3'd1;
    localparam S_A_D    = 3'd2;
    localparam S_A_DATA = 3'd3;
    localparam S_F_R    = 3'd4;
    localparam S_F_Q    = 3'd5;
    localparam S_F_DATA = 3'd6;
               
    reg [2:0] state;
    reg [5:0] byte_cnt;         // Zählt bis 40 für Frequenzdaten
    reg [31:0] temp_freq;       // Schieberegister für den 32-Bit Zusammenbau

    reg de_prev;
    wire de_pulse = (data_en && !de_prev); // Flankenerkennung

    always @(posedge clk) begin
        if (rst) begin
            state <= S_IDLE; // Automat fängt in Zustand IDLE an
            de_prev <= 1'b0;
            byte_cnt <= 6'd0;
            temp_freq <= 32'd0;
            
            // Initialisierung mit "Stille" (Offset-Binary Mitte)
            {ch0, ch1, ch2, ch3, ch4, ch5, ch6, ch7, ch8, ch9} <= 80'h80808080808080808080;
            
            // Initialisierung mit den Hardcode-Default-Frequenzen!
            f_ch0 <= 32'h0F70_0020; f_ch1 <= 32'h1359_196B;
            f_ch2 <= 32'h1993_4566; f_ch3 <= 32'h24DD_2F1B;
            f_ch4 <= 32'h0D98_B22B; f_ch5 <= 32'h14BC_A17F;
            f_ch6 <= 32'h170A_7C70; f_ch7 <= 32'h1BA5_E353;
            f_ch8 <= 32'h1F1A_82BE; f_ch9 <= 32'h272B_4B0C;
            
        end else begin
            de_prev <= data_en;
            
            if (de_pulse) begin
                case (state)
                    S_IDLE: begin
                        if (data_in == "A") state <= S_A_U;
                        else if (data_in == "F") state <= S_F_R;
                    end
                    
                    // --- AUDIO PFAD ("A" bereits empfangen) ---
                    S_A_U: state <= (data_in == "U") ? S_A_D : S_IDLE;
                    S_A_D: begin
                        if (data_in == "D") begin 
                            state <= S_A_DATA; 
                            byte_cnt <= 6'd0; 
                        end else state <= S_IDLE;
                    end
                    S_A_DATA: begin
                        case (byte_cnt)
                            6'd0: ch0 <= data_in;
                            6'd1: ch1 <= data_in;
                            6'd2: ch2 <= data_in;
                            6'd3: ch3 <= data_in;
                            6'd4: ch4 <= data_in;
                            6'd5: ch5 <= data_in;
                            6'd6: ch6 <= data_in;
                            6'd7: ch7 <= data_in;
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
                            state <= S_F_DATA; 
                            byte_cnt <= 6'd0; 
                        end else state <= S_IDLE;
                    end
                    S_F_DATA: begin
                        // Neues Byte in das 32-Bit Wort reinschieben (Big-Endian Aufbau)
                        temp_freq <= {temp_freq[23:0], data_in};
                        
                        // Jeweils beim 4. Byte weisen wir das fertige 32-Bit Wort dem Kanal zu
                        if (byte_cnt[1:0] == 2'd3) begin
                            // byte_cnt[5:2] teilt durch 4, ergibt direkt den Kanalindex (0 bis 9)
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
                            endcase
                        end
                        byte_cnt <= byte_cnt + 6'd1;
                    end
                    
                    default: state <= S_IDLE;
                endcase
            end
        end
    end
endmodule
