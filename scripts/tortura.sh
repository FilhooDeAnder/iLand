#!/bin/zsh
# Bateria de tortura do iLand. Uso:
#   scripts/tortura.sh macaco [semente] [segundos]   mouse ao acaso no notch + vigia de travamento + custo
#   scripts/tortura.sh custo [minutos]                custo do iLand instalado parado (CPU, acordadas, memória, disco)
#   scripts/tortura.sh extremo                        testes de entrada absurda (sem abrir o app)
# O macaco fecha o iLand instalado durante o teste e abre de novo no fim (os serviços continuam ligados).
# Ele mexe o mouse de verdade: não use o Mac enquanto ele roda. Sai com 1 se algum teto passou.
set -u
cd "${0:A:h}/.."
modo=${1:-macaco}

case $modo in
custo)
  python3 scripts/orcamento.py --min ${2:-10}
  ;;
extremo)
  zsh scripts/test_unit.sh extremo
  ;;
macaco)
  semente=${2:-$RANDOM}; segundos=${3:-60}
  out=$(mktemp -d)
  zsh scripts/build.sh >/dev/null || { echo "build falhou"; exit 1; }
  osascript -e 'quit app "iLand"' 2>/dev/null; sleep 2
  ILAND_MONKEY=$semente,$segundos ILAND_SHOTS=$out ./iLand.app/Contents/MacOS/iLand >/dev/null 2>&1 &
  pid=$!
  # Se o teste travar ou você der Ctrl-C, o iLand de teste morre e o instalado volta.
  ( sleep $((segundos + 60)); kill -9 $pid 2>/dev/null ) & vigia=$!
  trap 'kill -9 $pid $vigia 2>/dev/null; open /Applications/iLand.app; exit 1' INT TERM
  sleep 3
  custo=$(python3 scripts/orcamento.py --pid $pid --min $(( segundos > 10 ? (segundos - 5) / 60.0 : 0.1 )) --json 2>&1)
  wait $pid
  kill $vigia 2>/dev/null; trap - INT TERM
  open /Applications/iLand.app
  python3 - "$out/monkey.json" "$custo" <<'EOF'
import json, sys
TETO = {"stalls250": 0, "stallMaxMs": 500, "cresce_mb": 50, "parado_cpu": 3.0}
try:
    m = json.load(open(sys.argv[1]))
except OSError:
    print("REPROVADO: o iLand fechou antes do fim (sem monkey.json)"); sys.exit(1)
try:
    c = json.loads(sys.argv[2])
except ValueError:
    c = {"cpu_pct": None, "falhas": [sys.argv[2][-200:]]}
cresce = round(m["memEndMB"] - m["memStartMB"], 1)
print("semente %s, %s s, %s eventos, %s movimentos, mouse de verdade: %s" % (m["seed"], m["seconds"], m["events"], m["moves"], "sim" if m["realMouse"] else "NÃO (sem Acessibilidade)"))
print("travadas > 250 ms: %s   pior travada: %s ms   memória: %s → %s MB (pico %s)" % (m["stalls250"], m["stallMaxMs"], round(m["memStartMB"], 1), round(m["memEndMB"], 1), round(m["memPeakMB"], 1)))
print("CPU média com o macaco: %s%%   CPU parado depois: %s%%" % (c.get("cpu_pct"), m["restCpuPct"]))
falhas = []
if m["stalls250"] > TETO["stalls250"]: falhas.append("%s travadas acima de 250 ms" % m["stalls250"])
if m["stallMaxMs"] > TETO["stallMaxMs"]: falhas.append("pior travada %s ms" % m["stallMaxMs"])
if cresce > TETO["cresce_mb"]: falhas.append("memória cresceu %s MB" % cresce)
if m["restCpuPct"] > TETO["parado_cpu"]: falhas.append("CPU parado depois do macaco %s%%" % m["restCpuPct"])
if not m["realMouse"]: falhas.append("sem Acessibilidade: o mouse não mexeu")
print("REPROVADO: " + "; ".join(falhas) if falhas else "ok (repetir: scripts/tortura.sh macaco %s %s)" % (m["seed"], m["seconds"]))
sys.exit(1 if falhas else 0)
EOF
  ;;
*) echo "uso: $0 macaco|custo|extremo"; exit 2 ;;
esac
