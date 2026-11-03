#!/bin/bash
# Gera os prints do README em assets/readme com dados inventados (ILAND_DEMO): nada do seu Mac aparece.
# Precisa de Mac com notch e da permissão de Gravação de Tela para o terminal. Fecha o iLand aberto e abre de novo no fim.
set -euo pipefail
root="$(cd "$(dirname "$0")/.." && pwd)"
cd "$root"
out="$root/assets/readme"
tmp="$(mktemp -d "${TMPDIR:-/private/tmp}/iland-shots.XXXXXXXX")"
trap 'rm -rf "$tmp"' EXIT
mkdir -p "$out"

[ -x iLand.app/Contents/MacOS/iLand ] || ./scripts/build.sh
swiftc -O scripts/readme_shots.swift -o "$tmp/helper"
was_running=$(pgrep -x iLand >/dev/null && echo 1 || echo 0)
pkill -x iLand || true

# Ajustes inventados só para esta execução (argumentos valem por cima dos Ajustes salvos, sem gravar nada).
fake=(-hiddenPages "" -pageOrder "" -earsSource claude)
machines=(-machines "web-1,db-principal,api-2")   # só no print de Máquinas (sem ele, nada consulta SSH)

# shot <arquivo> <sinal> [VAR=valor ...] (ILAND_MACHINES_DEMO=1 liga as máquinas inventadas)
shot() {
    local name="$1" sig="$2"; shift 2
    local extra=()
    [[ " $* " == *" ILAND_MACHINES_DEMO=1 "* ]] && extra=("${machines[@]}")
    env ILAND_DEMO=1 ILAND_PIN=1 "$@" iLand.app/Contents/MacOS/iLand "${fake[@]}" "${extra[@]+"${extra[@]}"}" >/dev/null 2>&1 &
    local pid=$!
    sleep 6
    kill -"$sig" "$pid"; sleep 1.5
    screencapture -x -o -l"$("$tmp/helper" window "$pid")" "$tmp/$name.png"
    kill "$pid"; wait "$pid" 2>/dev/null || true
    "$tmp/helper" frame "$tmp/$name.png" "$tmp/$name-framed.png"
    sips -Z 1400 "$tmp/$name-framed.png" --out "$out/$name.png" >/dev/null   # 2x do tamanho exibido no GitHub, arquivo menor
    echo "ok $name"
}

shot ears ALRM
shot quick USR2
shot tools USR2 ILAND_PAGE=tools
shot machines USR2 ILAND_PAGE=machines ILAND_MACHINES_DEMO=1
shot tunnels USR2 ILAND_PAGE=tunnels
shot overview USR1 ILAND_TAB=processes
shot charts USR1 ILAND_TAB=charts

[ "$was_running" = 1 ] && open iLand.app
