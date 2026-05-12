#include <iostream>
#include "verilated.h"
#include "verilated_vcd_c.h" // 1. Header für VCD Export
#include "Vam_modulator_top.h"

#include <fstream> // für csv (FFT des DAC out)

// Audio Stream
#include <sys/socket.h>
#include <netinet/in.h>
//#include <fcntl.h> // Für non-blocking Sockets

// Hilfsfunktion zum Senden eines Bytes
void send_to_fpga(Vam_modulator_top* top, uint8_t val, uint64_t &time_counter, VerilatedVcdC* tfp) {
    // 1. Daten anlegen, aber clk ist noch 0. 
    // Wir stellen sicher, dass data_en 0 ist, damit de_prev im FPGA sicher 0 wird.
    top->data_in = val;
    top->data_en = 0; 
    top->clk = 0;
    top->eval();
    if (tfp) tfp->dump(time_counter++);

    // 2. Steigende Flanke 1: Das FPGA-Register 'de_prev' übernimmt die 0 von oben.
    // data_en ist immer noch 0.
    top->clk = 1;
    top->eval();
    if (tfp) tfp->dump(time_counter++);

    // 3. Fallende Flanke: clk geht auf 0. Jetzt setzen wir data_en auf 1.
    // Das bereitet die Flankenerkennung für den NÄCHSTEN Takt vor.
    top->clk = 0;
    top->data_en = 1;
    top->eval();
    if (tfp) tfp->dump(time_counter++);

    // 4. Steigende Flanke 2: JETZT passiert die Magie!
    // data_en ist 1, de_prev ist noch 0 -> de_pulse ist für diesen EINEN Takt 1.
    top->clk = 1;
    top->eval();
    if (tfp) tfp->dump(time_counter++);

    // 5. Abfallende Flanke & Aufräumen: data_en wieder weg.
    top->clk = 0;
    top->data_en = 0;
    top->eval();
    if (tfp) tfp->dump(time_counter++);
}

// NEU: Hilfsfunktion um alle 10 Frequenzen zu setzen
void send_frequency_update(Vam_modulator_top* top, const uint32_t freqs[10], uint64_t &time_counter, VerilatedVcdC* tfp) {
    std::cout << "Sende Frequenz-Update an alle Kanäle..." << std::endl;
    send_to_fpga(top, 'F', time_counter, tfp);
    send_to_fpga(top, 'R', time_counter, tfp);
    send_to_fpga(top, 'Q', time_counter, tfp);

    for(int i = 0; i < 10; i++) {
        // Zerlege 32-Bit in 4 Bytes (Big-Endian: MSB zuerst)
        send_to_fpga(top, (freqs[i] >> 24) & 0xFF, time_counter, tfp);
        send_to_fpga(top, (freqs[i] >> 16) & 0xFF, time_counter, tfp);
        send_to_fpga(top, (freqs[i] >> 8)  & 0xFF, time_counter, tfp);
        send_to_fpga(top, (freqs[i] >> 0)  & 0xFF, time_counter, tfp);
    }
}

int main(int argc, char** argv) {
    Verilated::commandArgs(argc, argv);

    // Audio Empfänger bereitstellen:
    uint8_t packet_buffer[10]; // Platz für 10 Audio-Kanäle
    uint64_t sim_time = 0;

    // UDP Setup
    int sockfd = socket(AF_INET, SOCK_DGRAM, 0);
    struct sockaddr_in servaddr;
    servaddr.sin_family = AF_INET;
    servaddr.sin_addr.s_addr = INADDR_ANY;
    servaddr.sin_port = htons(4444); // Port muss zum Sender (ffmpeg/MCU) passen
    bind(sockfd, (const struct sockaddr *)&servaddr, sizeof(servaddr));

    // Socket auf non-blocking setzen, damit die Simulation nicht stehen bleibt
    //fcntl(sockfd, F_SETFL, O_NONBLOCK);
    
    // Instanz erstellen
    Vam_modulator_top* top = new Vam_modulator_top;


    // 2. Tracing vorbereiten
    Verilated::traceEverOn(true);
    VerilatedVcdC* tfp = new VerilatedVcdC;
    top->trace(tfp, 99);        // Hierarchie-Tiefe
    tfp->open("waveform.vcd");  // Dateiname

    std::ofstream dac_file("dac_output.csv"); // DAC Ausgangssignal für FFT in GNU Octave

    // Initialisierung
    top->clk = 0;
    //top->rst = 1;
    top->rst = 0; // unser Dev-Board nutzt einen inv. Reset.

    // Beispiel-Frequenzen (könnten auch live berechnet werden)
    // Die Formel für den NCO (DDS) bei einem Referenztakt (fclk​) von 10 MHz und einem 32-Bit Phasenakkumulator lautet: fout​=232phase_inc⋅fclk​​


    // Neue Frequenzen: LW (153, 171, 225) und diverse MW Sender
    uint32_t my_freqs[10] = {
        0x03E978D5, // CH0: 153 kHz
        0x046452D1, // CH1: 171 kHz
        0x05C8500D, // CH2: 225 kHz
        0x2467C924, // CH3: 1422 kHz
        0x24DD2F1B, // CH4: 1440 kHz
        0x0FE5890C, // CH5: 621 kHz
        0x19934566, // CH6: 999 kHz
        0x1999999A, // CH7: 1000 kHz
        0x1FC7A163, // CH8: 1242 kHz
        0x2889A027  // CH9: 1584 kHz
    };

    bool freqs_initialized = false;

    for (int i = 0; i < 1000000; i++) {
        if (i == 40) top->rst = 1; // Reset lösen

        // Sobald Reset gelöst ist, schicken wir einmal die Frequenzen raus
        if (i > 100 && !freqs_initialized) {
            send_frequency_update(top, my_freqs, sim_time, tfp);
            freqs_initialized = true;
        }

        // Audio-Empfang
        struct sockaddr_in cliaddr;
        socklen_t len = sizeof(cliaddr);
        
        // MSG_DONTWAIT sorgt dafür, dass wir nicht blockieren, wenn kein Paket da ist
        int n = recvfrom(sockfd, packet_buffer, 10, MSG_DONTWAIT, (struct sockaddr *)&cliaddr, &len);
        
        if (n == 10) {
            send_to_fpga(top, 'A', sim_time, tfp);
            send_to_fpga(top, 'U', sim_time, tfp);
            send_to_fpga(top, 'D', sim_time, tfp);
            for(int k=0; k<10; k++) send_to_fpga(top, packet_buffer[k], sim_time, tfp);
        }

        // --- Normaler Systemtakt (50 MHz Domäne) ---
        // 1. Takt toggeln
        top->clk = !top->clk;

        // 2. Logik berechnen
        top->eval();


        // Wir speichern zusätzlich nur bei der steigenden Flanke das DAC Signal für eine FFT zum Beispiel in GNU Octave
        if (top->clk && top->sample_en_out) { // NUR loggen, wenn Taktflanke UND Enable aktiv sind! 50 -> 10 MHz/MSPS
          dac_file << (int32_t)top->dac_out << "\n";
        }

        // 3. Den Zustand GENAU JETZT in die Waveform-Datei schreiben
        tfp->dump(sim_time); 
        sim_time++;
        
        // Verilator-Check ob Simulation beendet werden soll (z.B. Strg+C)
        if (Verilated::gotFinish()) break;
    }

    dac_file.close();
    std::cout << "Simulation beendet. Datei 'waveform.vcd' wurde erstellt." << std::endl;

    tfp->close(); // Wichtig: Datei sauber schließen!
    delete top;
    delete tfp;
    return 0;
}
