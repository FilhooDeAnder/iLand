#!/usr/bin/env python3
import rumps
import subprocess
import re
import os
import sys
from threading import Thread
import time

class TempMonitorApp(rumps.App):
    def __init__(self):
        super(TempMonitorApp, self).__init__("🌡️", quit_button=None)
        self.temperature = None
        
        # Detecta se está rodando como app bundle ou script
        if getattr(sys, 'frozen', False):
            # Rodando como app bundle (py2app)
            bundle_dir = os.environ.get('RESOURCEPATH', os.path.dirname(sys.executable))
            self.sensor_path = os.path.join(bundle_dir, 'sensors')
        else:
            # Rodando como script normal
            self.sensor_path = os.path.join(os.path.dirname(__file__), 'sensors')
        
        # Menu items
        self.menu = [
            rumps.MenuItem("Temperatura: --°C"),
            rumps.separator,
            rumps.MenuItem("Atualizar", callback=self.update_temp_now),
            rumps.MenuItem("Sair", callback=self.quit_app)
        ]
        
        # Inicia thread de monitoramento
        self.update_thread = Thread(target=self.update_loop, daemon=True)
        self.update_thread.start()
    
    def get_cpu_temperature(self):
        """Lê a temperatura da CPU"""
        try:
            if not os.path.exists(self.sensor_path):
                # Debug: mostra o caminho que está tentando
                self.menu["Temperatura: --°C"].title = f"Sensor não encontrado: {self.sensor_path[:50]}..."
                return None
            
            proc = subprocess.Popen([self.sensor_path], stdout=subprocess.PIPE, stderr=subprocess.PIPE, text=True)
            
            try:
                output, error = proc.communicate(timeout=0.5)
            except subprocess.TimeoutExpired:
                proc.kill()
                output, error = proc.communicate()
            
            if error:
                # Debug: mostra erro se houver
                self.menu["Temperatura: --°C"].title = f"Erro: {error[:50]}..."
                return None
            
            lines = output.strip().split('\n')
            
            if len(lines) < 2:
                return None
            
            sensor_names = lines[0].split(', ')
            temperatures = []
            pattern = re.compile(r"PMU tdie\d+$")
            
            for line in lines[1:]:
                if not line.strip():
                    continue
                    
                values = line.split(', ')
                
                for i, name in enumerate(sensor_names):
                    if i < len(values) and pattern.match(name.strip()):
                        try:
                            temp = float(values[i])
                            temperatures.append(temp)
                        except (ValueError, IndexError):
                            continue
            
            if temperatures:
                return sum(temperatures) / len(temperatures)
            
            return None
            
        except Exception as e:
            # Debug: mostra exceção
            self.menu["Temperatura: --°C"].title = f"Exceção: {str(e)[:50]}..."
            return None
    
    def update_loop(self):
        """Loop de atualização em background"""
        while True:
            self.temperature = self.get_cpu_temperature()
            self.update_display()
            time.sleep(3)  # Atualiza a cada 3 segundos
    
    def update_display(self):
        """Atualiza o display na barra de menu"""
        if self.temperature is not None:
            temp = self.temperature
            
            # Escolhe emoji baseado na temperatura
            if temp < 70:
                emoji = "🟢"
            elif temp < 90:
                emoji = "🟡"
            else:
                emoji = "🔴"
            
            # Atualiza título da barra
            self.title = f"{temp:.0f}°C"
            
            # Atualiza menu
            self.menu["Temperatura: --°C"].title = f"Temperatura: {temp:.1f}°C {emoji}"
        else:
            self.title = "🌡️"
            self.menu["Temperatura: --°C"].title = "Temperatura: Indisponível"
    
    def update_temp_now(self, _):
        """Callback para atualizar manualmente"""
        self.temperature = self.get_cpu_temperature()
        self.update_display()
    
    def quit_app(self, _):
        """Sair do app"""
        rumps.quit_application()

if __name__ == "__main__":
    app = TempMonitorApp()
    app.run()
