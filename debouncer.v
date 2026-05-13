/*
 * MODUL: debouncer
 * ----------------
 * Unterdrückt mechanisches Prellen.
 * Signal muss für 'WAIT_CYCLES' stabil sein, bevor der Ausgang umschaltet.
 */
module debouncer #(
    parameter WAIT_CYCLES = 1_000_000 // 20ms bei 50MHz
)(
    input  wire clk,
    input  wire signal_in,
    output reg  signal_out
);
    reg [21:0] count; // Genügend Bits für WAIT_CYCLES
    reg last_state;

    always @(posedge clk) begin
        if (signal_in != last_state) begin
            // Signal hat gewackelt -> Zähler zurücksetzen
            count <= 0;
            last_state <= signal_in;
        end else if (count < WAIT_CYCLES) begin
            // Signal ist stabil -> Zähler läuft
            count <= count + 1;
        end else begin
            // Zähler erreicht -> Signal übernehmen
            signal_out <= last_state;
        end
    end
endmodule
