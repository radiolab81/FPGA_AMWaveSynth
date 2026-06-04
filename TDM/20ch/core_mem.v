/*
 * MODUL: core_mem
 * ---------------------------------------------------------------------
 * Kapselt die Speicherelemente für 5 Kanäle eines TDM-Kerns.
 * Nutzt hybride Synthese (Logic für kleine RAMs, M4K für große RAMs),
 * um das M4K-Block-Limit auf kleinen FPGAs nicht zu sprengen.
 */
module core_mem (
    input wire clk,

    // TDM Slot Steuerung
    input wire [2:0] slot,      // Aktueller TDM-Slot (0..4)
    input wire [2:0] slot_stg1, // Um 1 Takt verzögerter Slot für RAM-Writeback
    
    // MCU RAM-Schreibinterface
    input wire [2:0]  mcu_waddr,
    input wire        mcu_audio_we,
    input wire [7:0]  mcu_audio_data,
    input wire        mcu_frq_we,
    input wire [31:0] mcu_frq_data,
    input wire        mcu_gain_we,
    input wire [15:0] mcu_gain_data,
    
    // Output zum Rechenkern (Pipeline Stufe 1)
    output reg [7:0]  core_audio,
    output reg [31:0] core_frq,
    output reg [15:0] core_gain,
    output reg [31:0] core_phase,
    output reg [6:0]  core_peak,
    output reg [15:0] core_decay,
    
    // Write-Back vom Rechenkern (Pipeline Stufe 2)
    input wire [31:0] next_phase,
    input wire [6:0]  next_peak,
    input wire [15:0] next_decay
);

    // ----------------------------------------------------
    // Hybride RAM Definitionen
    // ----------------------------------------------------
    // Kleine RAMs zwingen wir in die Logik-Zellen (LUTs/FlipFlops)
    (* ramstyle = "logic" *) reg [7:0]  ram_audio [0:4];
    (* ramstyle = "logic" *) reg [15:0] ram_gain  [0:4];
    (* ramstyle = "logic" *) reg [6:0]  ram_peak  [0:4];
    (* ramstyle = "logic" *) reg [15:0] ram_decay [0:4];

    // Große 32-Bit RAMs belassen wir in den physikalischen M4K Blöcken
    (* ramstyle = "M4K" *)   reg [31:0] ram_frq   [0:4];
    (* ramstyle = "M4K" *)   reg [31:0] ram_phase [0:4];

    // Speicher-Initialisierung
    integer i;
    initial begin
        for (i = 0; i < 5; i = i + 1) begin
            ram_audio[i] = 8'd128; ram_frq[i]   = 32'd0;
            ram_gain[i]  = 16'hFFFF;  ram_phase[i] = 32'd0;
            ram_peak[i]  = 7'd0;   ram_decay[i] = 16'd0;
        end
    end

    // Synchroner Schreibzugriff von der MCU
    always @(posedge clk) begin
        if (mcu_audio_we) ram_audio[mcu_waddr] <= mcu_audio_data;
        if (mcu_frq_we)   ram_frq[mcu_waddr]   <= mcu_frq_data;
        if (mcu_gain_we)  ram_gain[mcu_waddr]  <= mcu_gain_data;
    end

    // TDM Lesezugriff (mit Forwarding)
    always @(posedge clk) begin
        // --- AUDIO FORWARDING ---
        // Wenn MCU schreibt UND die Adresse dem aktuellen Slot entspricht: Forwarding
        if (mcu_audio_we && (mcu_waddr == slot)) 
            core_audio <= mcu_audio_data;
        else 
            core_audio <= ram_audio[slot];

        // --- FREQUENZ FORWARDING ---
        if (mcu_frq_we && (mcu_waddr == slot)) 
            core_frq <= mcu_frq_data;
        else 
            core_frq <= ram_frq[slot];

        // --- GAIN FORWARDING ---
        if (mcu_gain_we && (mcu_waddr == slot)) 
            core_gain <= mcu_gain_data;
        else 
            core_gain <= ram_gain[slot];

        // --- STANDARD READ (Kein MCU-Schreibzugriff für diese RAMs) ---
        core_phase <= ram_phase[slot];
        core_peak  <= ram_peak[slot];
        core_decay <= ram_decay[slot];
    end

    // TDM Write-Back (Phasen & AGC Status zurückschreiben)
    always @(posedge clk) begin
        ram_phase[slot_stg1] <= next_phase;
        ram_peak[slot_stg1]  <= next_peak;
        ram_decay[slot_stg1] <= next_decay;
    end

endmodule
