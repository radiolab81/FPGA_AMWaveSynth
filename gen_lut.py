import numpy as np

# Parameter für den ersten Quadranten (0 bis 90 Grad)
depth = 1024  
max_val = 32767 # Maximalwert für 16-Bit Signed (2^15 - 1)

with open("sin_quarter.hex", "w") as f:
    for i in range(depth):
        # Wir berechnen den Sinus von 0 bis fast 90 Grad.
        # Da wir im FPGA die Spiegelung nutzen, entspricht 
        # der Index 1023 dem Wert kurz vor 90 Grad.
        sin_val = np.sin((np.pi / 2) * i / depth)
        
        int_val = int(round(sin_val * max_val))
        
        # Sicherstellen, dass keine Werte außerhalb des Bereichs liegen
        int_val = max(0, min(max_val, int_val))
        
        # Formatierung als 4-stelliger Hex-Wert
        # Da im ersten Quadranten alles positiv ist, reicht :04x
        f.write(f"{int_val:04x}\n")

print(f"Datei 'sin_quarter.hex' mit {depth} Einträgen erfolgreich erstellt.")