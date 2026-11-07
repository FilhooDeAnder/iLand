#!/usr/bin/env python3
"""Mede o custo do iLand no Mac durante N minutos e compara com o teto (orçamento).

Uso: python3 scripts/orcamento.py [--min 10] [--pid PID] [--json]
Sem --pid, mede o iLand que está rodando. Sai com 1 se um teto passou.

O que mede, por proc_pid_rusage (o mesmo que o Monitor de Atividade usa):
- CPU do iLand e dos filhos que ele já terminou (du, ps, lsof): a conta inclui o custo que ele terceiriza.
- Acordadas por segundo (timers e interrupções): o que gasta bateria mesmo com CPU baixa.
- Memória (phys_footprint): pico e crescimento por hora (reta dos mínimos quadrados).
- Escrita em disco.
- Os 5 outros processos que mais gastaram CPU no período. O iLand pode acordar um daemon do
  sistema (o caso do disco acordou o photolibraryd). Esta lista não reprova: ela mostra para comparar.
"""
import argparse, ctypes, json, os, subprocess, sys, time

TETO = {                       # por minuto de uso parado, com a vista fechada
    "cpu_pct": 2.0,            # % de 1 núcleo, média, iLand + filhos
    "acordadas_s": 30.0,       # acordadas por segundo, média
    "memoria_mb": 350.0,       # pico do phys_footprint
    "cresce_mb_h": 60.0,       # crescimento da memória por hora (só vale com 10 min ou mais)
    "escrita_mb_h": 50.0,      # escrita em disco por hora
}

lib = ctypes.CDLL("/usr/lib/libproc.dylib")
U64 = ctypes.c_uint64


class RU(ctypes.Structure):   # rusage_info_v4 (só os campos até a escrita em disco importam)
    _fields_ = [("uuid", ctypes.c_uint8 * 16)] + [(n, U64) for n in (
        "user", "system", "idle_wk", "int_wk", "pageins", "wired", "resident", "footprint",
        "start", "exit", "c_user", "c_system", "c_idle_wk", "c_int_wk", "c_pageins", "c_elapsed",
        "io_read", "io_written")] + [("rest", U64 * 40)]


class TB(ctypes.Structure):
    _fields_ = [("numer", ctypes.c_uint32), ("denom", ctypes.c_uint32)]


tb = TB(); ctypes.CDLL("/usr/lib/libSystem.dylib").mach_timebase_info(ctypes.byref(tb))
NS = tb.numer / tb.denom      # tempo do rusage vem em ticks da máquina; no Apple Silicon 1 tick ≠ 1 ns


def ru(pid):
    r = RU()
    if lib.proc_pid_rusage(int(pid), 4, ctypes.byref(r)) != 0:
        return None
    return r


def cpu_s(r):
    return (r.user + r.system + r.c_user + r.c_system) * NS / 1e9


def iland_pid():
    out = subprocess.run(["pgrep", "-x", "iLand"], capture_output=True, text=True).stdout.split()
    return int(out[0]) if out else None


def vivos(pid):
    """Filhos vivos do pid (o nowplaying.pl fica ligado o tempo todo; o rusage só soma filho que já terminou)."""
    out = subprocess.run(["ps", "-A", "-o", "pid=,ppid="], capture_output=True, text=True).stdout
    pais = {}
    for linha in out.split("\n"):
        f = linha.split()
        if len(f) == 2:
            pais.setdefault(int(f[1]), []).append(int(f[0]))
    res, fila = set(), [pid]
    while fila:
        for c in pais.get(fila.pop(), []):
            if c not in res:
                res.add(c); fila.append(c)
    return res


def cpu_vivos(pids):
    return {p: (r.user + r.system) * NS / 1e9 for p in pids if (r := ru(p))}


def todos():
    """CPU acumulada de cada processo do usuário e do sistema que dá para ler: {pid: (nome, segundos)}."""
    out = subprocess.run(["ps", "-A", "-o", "pid=,comm="], capture_output=True, text=True).stdout
    res = {}
    for linha in out.splitlines():
        p, _, nome = linha.strip().partition(" ")
        r = ru(p) if p.isdigit() else None
        if r:
            res[int(p)] = (os.path.basename(nome.strip()), (r.user + r.system) * NS / 1e9)
    return res


def reta(xs, ys):
    n = len(xs)
    if n < 3:
        return 0.0
    mx, my = sum(xs) / n, sum(ys) / n
    d = sum((x - mx) ** 2 for x in xs)
    return sum((x - mx) * (y - my) for x, y in zip(xs, ys)) / d if d else 0.0


def medir(pid, minutos, passo=5):
    a, t0, sist0 = ru(pid), time.time(), todos()
    v0 = cpu_vivos(vivos(pid))
    if not a:
        sys.exit("não consegui ler o pid %d" % pid)
    ts, mem = [0.0], [a.footprint / 2**20]
    fim = t0 + minutos * 60
    while time.time() < fim:
        r = ru(pid)
        if not r:
            sys.exit("o iLand fechou durante a medida (pid %d)" % pid)
        ts.append(time.time() - t0); mem.append(r.footprint / 2**20)
        time.sleep(min(passo, max(0.1, fim - time.time())))
    b, dt, sist1 = ru(pid), time.time() - t0, todos()
    v1 = cpu_vivos(vivos(pid))
    vivos_s = sum(v1[p] - v0.get(p, 0) for p in v1)     # filho novo conta desde o início dele
    # Filho vivo no início que terminou no meio: o rusage soma a vida inteira dele em c_user/c_system; tira o que era de antes.
    vivos_s -= sum(v0[p] for p in v0 if p not in v1)
    outros = sorted(((s1 - sist0[p][1], n) for p, (n, s1) in sist1.items() if p in sist0 and p != pid and p not in v1),
                    reverse=True)[:5]
    return {
        "minutos": round(dt / 60, 1),
        "cpu_pct": round((cpu_s(b) - cpu_s(a) + vivos_s) / dt * 100, 2),
        "filhos_cpu_s": round((b.c_user + b.c_system - a.c_user - a.c_system) * NS / 1e9 + vivos_s, 2),
        "acordadas_s": round((b.idle_wk + b.int_wk - a.idle_wk - a.int_wk) / dt, 1),
        "memoria_mb": round(max(mem), 1),
        "cresce_mb_h": round(reta(ts, mem) * 3600, 1),
        "escrita_mb_h": round((b.io_written - a.io_written) / 2**20 / dt * 3600, 1),
        "outros": [{"nome": n, "cpu_pct": round(s / dt * 100, 1)} for s, n in outros],
    }


def julgar(m):
    falhas = []
    for k, teto in TETO.items():
        if k == "cresce_mb_h" and m["minutos"] < 10:
            continue
        if m[k] > teto:
            falhas.append("%s = %s (teto %s)" % (k, m[k], teto))
    return falhas


if __name__ == "__main__":
    ap = argparse.ArgumentParser()
    ap.add_argument("--min", type=float, default=10)
    ap.add_argument("--pid", type=int)
    ap.add_argument("--json", action="store_true")
    a = ap.parse_args()
    pid = a.pid or iland_pid()
    if not pid:
        sys.exit("o iLand não está rodando")
    m = medir(pid, a.min)
    falhas = julgar(m)
    if a.json:
        print(json.dumps({**m, "falhas": falhas}, ensure_ascii=False))
    else:
        for k in TETO:
            print("%-13s %8s   teto %s" % (k, m[k], TETO[k]))
        print("filhos_cpu_s  %8s" % m["filhos_cpu_s"])
        print("outros (CPU no período): " + ", ".join("%s %s%%" % (o["nome"], o["cpu_pct"]) for o in m["outros"]))
        print("REPROVADO: " + "; ".join(falhas) if falhas else "ok")
    sys.exit(1 if falhas else 0)
