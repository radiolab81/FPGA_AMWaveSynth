/*
 * MODUL: audio_rx
 * ---------------
 * Empfängt einen seriellen Byte-Strom mit dem Header "AUD"
 * und verteilt die folgenden 4 Bytes auf parallele Register.
 */
module audio_rx (
    input wire clk,
    input wire rst,
    input wire [7:0] data_in,   // 8-Bit Bus vom ESP32
    input wire data_en,         // Strobe/Enable Puls vom ESP32
    
    // Parallele Ausgänge für die Modulatoren
    output reg [7:0] ch0,
    output reg [7:0] ch1,
    output reg [7:0] ch2,
    output reg [7:0] ch3
);

    // Zustandsdefinitionen
    localparam S_IDLE = 3'd0, S_U = 3'd1, S_D = 3'd2, 
               S_CH0  = 3'd3, S_CH1 = 3'd4, S_CH2 = 3'd5, S_CH3 = 3'd6;
               
    reg [2:0] state;
    reg de_prev;
    wire de_pulse = (data_en && !de_prev); // Flankenerkennung

    always @(posedge clk) begin
        if (rst) begin
            state <= S_IDLE; // Automat fängt in Zustand IDLE an
            de_prev <= 1'b0;
            {ch0, ch1, ch2, ch3} <= 32'h80808080; // Start mit "Stille" (128)
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
                    S_CH3:  begin ch3 <= data_in; state <= S_IDLE; end
                    default: state <= S_IDLE;
                endcase
            end
        end
    end
endmodule
