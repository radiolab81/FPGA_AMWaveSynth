% analyze_am.m
fs = 10e6; 
data = load('dac_output.csv');
L = length(data);

% FFT berechnen
% Statt: Y = fft(data);
Y = fft(data .* hamming(length(data)));
P2 = abs(Y/L);          % Zweiseitiges Spektrum
P1 = P2(1:L/2+1);       % Einseitiges Spektrum
P1(2:end-1) = 2*P1(2:end-1);

% Frequenzachse definieren
f = fs*(0:(L/2))/L;

% Plotten
figure;
plot(f/1e3, 20*log10(P1 + 1e-6)); % dB-Skala
title('Leistungsspektrum des AM-Modulators');
xlabel('Frequenz (kHz)');
ylabel('Amplitude (dB)');
grid on;
axis([0 2000 -40 80]); % Zoom auf 0-2 MHz (AM-Bereich)