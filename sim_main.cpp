#include <iostream>
#include "verilated.h"
#include "verilated_vcd_c.h" // 1. Header für VCD Export
#include "Vam_modulator_top.h"

#include <fstream> // für csv (FFT des DAC out)

// Audio Stream
#include <sys/socket.h>
#include <netinet/in.h>
//#include <fcntl.h> // Für non-blocking Sockets


// Hilfsfunktion zum Senden eines Bytes an den Modulator
void send_to_fpga(Vam_modulator_top* top, uint8_t val, uint64_t &time_counter, VerilatedVcdC* tfp) {
    top->data_in = val;
    top->data_en = 1;
    
    // 2 Takte für den FPGA Zeit geben (50MHz Domäne)
    // Das entspricht einer steigenden Flanke, damit die audio_rx Logik das Byte sieht
    for(int i=0; i<2; i++) {
        top->clk = !top->clk;
        top->eval();
        if (tfp) tfp->dump(time_counter++);
    }
    top->data_en = 0; // Enable wieder runter
    top->clk = !top->clk; 
    top->eval(); 
    if (tfp) tfp->dump(time_counter++);
}


int main(int argc, char** argv) {
    Verilated::commandArgs(argc, argv);

    // Audio Empfänger bereitstellen:
    uint8_t packet_buffer[4]; // Platz für 4 Audio-Kanäle
    uint64_t sim_time = 0;

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

    top->clk = 0;
    top->rst = 1;

    std::cout << "Starte Simulation mit VCD-Export..." << std::endl;

    // Hauptschleife der Simulation
    for (int i = 0; i < 1000000; i++) {
        // Reset nach 40 Ticks lösen
        if (i == 40) top->rst = 0;

        // 1. Schauen, ob Audio-Daten da sind   
        // ffmpeg -re -i deine_musik.mp3 \
    // -af "pan=4c|c0=c0|c1=c1|c2=c0|c3=c1,aresample=44100" \
    // -f u8 -acodec pcm_u8 udp://127.0.0.1:4444
        struct sockaddr_in cliaddr;
        socklen_t len = sizeof(cliaddr);
        
        // MSG_DONTWAIT sorgt dafür, dass wir nicht blockieren, wenn kein Paket da ist
        int n = recvfrom(sockfd, packet_buffer, 4, MSG_DONTWAIT, (struct sockaddr *)&cliaddr, &len);
        
        if (n == 4) { // Wir haben ein Sample-Set für alle(!) 4 Kanäle!
            static int p_count = 0;
            if (p_count++ % 1000 == 0) printf("Audio-Paket erhalten! (Gesamt: %d)\n", p_count);

            // Sende das Protokoll-Paket: Header "AUD" + 4 Byte Daten
            send_to_fpga(top, 'A', sim_time, tfp);
            send_to_fpga(top, 'U', sim_time, tfp);
            send_to_fpga(top, 'D', sim_time, tfp);
            send_to_fpga(top, packet_buffer[0], sim_time, tfp);
            send_to_fpga(top, packet_buffer[1], sim_time, tfp);
            send_to_fpga(top, packet_buffer[2], sim_time, tfp);
            send_to_fpga(top, packet_buffer[3], sim_time, tfp);
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