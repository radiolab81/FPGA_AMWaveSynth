/*
 * MODUL: audio_rx
 * ---------------
 * Empfängt einen seriellen Byte-Strom mit dem Header "AUD"
 * und verteilt die folgenden 10 Bytes auf parallele Register.
 * // ERWEITERUNG: Auf 10 Kanäle (CH0 bis CH9) ausgebaut.
 */
module audio_rx (
    input wire clk,
    input wire rst,
    input wire [7:0] data_in,   // 8-Bit Bus von MCU
    input wire data_en,         // Strobe/Enable Puls von MCU
    
    // Parallele Ausgänge für die Modulatoren
    output reg [7:0] ch0,
    output reg [7:0] ch1,
    output reg [7:0] ch2,
    output reg [7:0] ch3,
    output reg [7:0] ch4,
    output reg [7:0] ch5,
    output reg [7:0] ch6,
    output reg [7:0] ch7,
    output reg [7:0] ch8,
    output reg [7:0] ch9
);

    // Zustandsdefinitionen
    localparam S_IDLE = 4'd0, S_U = 4'd1, S_D = 4'd2, 
               S_CH0  = 4'd3, S_CH1 = 4'd4, S_CH2 = 4'd5, S_CH3 = 4'd6,
               S_CH4  = 4'd7, S_CH5 = 4'd8, S_CH6 = 4'd9, S_CH7 = 4'd10,
               S_CH8  = 4'd11, S_CH9 = 4'd12;
               
    reg [3:0] state; // ERWEITERUNG: Breite auf 4 Bit erhöht für 13 Zustände
    reg de_prev;
    wire de_pulse = (data_en && !de_prev); // Flankenerkennung

    always @(posedge clk) begin
        if (rst) begin
            state <= S_IDLE; // Automat fängt in Zustand IDLE an
            de_prev <= 1'b0;
            // ERWEITERUNG: Alle 10 Kanäle mit "Stille" (128) initialisieren
            {ch0, ch1, ch2, ch3, ch4, ch5, ch6, ch7, ch8, ch9} <= 80'h80808080808080808080;
        end else begin
            de_prev <= data_en;
            
            if (de_pulse) begin
                case (state)
                    S_IDLE: if (data_in == "A") state <= S_U;
                    S_U:    if (data_in == "U") state <= S_D;    else state <= S_IDLE;
                    S_D:    if (data_in == "D") state <= S_CH0;  else state <= S_IDLE;
                    S_CH0:  begin ch0 <= data_in; state <= S_CH1; end
                    S_CH1:  begin ch1 <= data_in; state <= S_CH2; end
                    S_CH2:  begin ch2 <= data_in; state <= S_CH3; end
                    S_CH3:  begin ch3 <= data_in; state <= S_CH4; end
                    S_CH4:  begin ch4 <= data_in; state <= S_CH5; end
                    S_CH5:  begin ch5 <= data_in; state <= S_CH6; end
                    S_CH6:  begin ch6 <= data_in; state <= S_CH7; end
                    S_CH7:  begin ch7 <= data_in; state <= S_CH8; end
                    S_CH8:  begin ch8 <= data_in; state <= S_CH9; end
                    S_CH9:  begin ch9 <= data_in; state <= S_IDLE; end
                    default: state <= S_IDLE;
                endcase
            end
        end
    end
endmodule
