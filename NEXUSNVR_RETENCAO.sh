#!/usr/bin/env bash
# ============================================================
# Nexus NVR - Retencao Profissional de Gravacoes
# Versao: 2026-05-18-retencao-1.2-final-ui
# ============================================================

set -Eeuo pipefail

VERSION="2026-05-18-retencao-1.2-final-ui"

NVR_ROOT="${NVR_ROOT:-/home/nexus}"
SYSTEM_RECORDINGS_DIR="${SYSTEM_RECORDINGS_DIR:-/home/nexus/gravacoes}"
CONFIG_FILE="${CONFIG_FILE:-/home/nexus/retencao_nvr.conf}"
LOG_FILE="${LOG_FILE:-/var/log/nexus_nvr_retencao.log}"
LAST_RUN_FILE="${LAST_RUN_FILE:-/home/nexus/.retencao_nvr_last_run}"
CRON_MARKER="NEXUS_NVR_RETENCAO"
SCRIPT_PATH="$(readlink -f "$0" 2>/dev/null || echo "$0")"
CRON_SCRIPT_PATH="${RETENTION_CRON_SCRIPT:-/home/nexus/cron/retencao_nvr.sh}"
[[ -x "$CRON_SCRIPT_PATH" ]] || CRON_SCRIPT_PATH="$SCRIPT_PATH"

red='\033[0;31m'
green='\033[0;32m'
yellow='\033[1;33m'
blue='\033[0;34m'
reset='\033[0m'

ok(){ echo -e "${green}[OK]${reset} $*"; }
warn(){ echo -e "${yellow}[AVISO]${reset} $*"; }
err(){ echo -e "${red}[ERRO]${reset} $*"; }

title(){
  echo
  echo "============================================================"
  echo " $*"
  echo "============================================================"
}

section(){
  echo
  echo "$*"
  echo "------------------------------------------------------------"
}

kv(){
  printf "  %-31s: %s\n" "$1" "$2"
}

note(){
  printf "  - %s\n" "$1"
}

need_root(){
  if [[ "${EUID}" -ne 0 ]]; then
    err "Execute com sudo: sudo bash $0"
    exit 1
  fi
}

yes_no(){
  local prompt="$1"
  local default="${2:-N}"
  local ans hint="[s/N]"
  [[ "$default" == "S" ]] && hint="[S/n]"
  while true; do
    read -r -p "$prompt $hint: " ans || true
    ans="${ans:-$default}"
    case "$ans" in
      s|S|sim|SIM|Sim) return 0 ;;
      n|N|nao|NAO|não|NÃO|Nao|Não) return 1 ;;
      *) echo "Responda s ou n." ;;
    esac
  done
}

ask_number(){
  local prompt="$1" default="$2" min="$3" max="$4" ans
  while true; do
    read -r -p "$prompt [$default]: " ans || true
    ans="${ans:-$default}"
    if [[ ! "$ans" =~ ^[0-9]+([.][0-9]+)?$ ]]; then
      warn "Digite um numero valido."
      continue
    fi
    if python3 - "$ans" "$min" "$max" <<'PY' >/dev/null 2>&1
import sys
x=float(sys.argv[1]); mn=float(sys.argv[2]); mx=float(sys.argv[3])
raise SystemExit(0 if mn <= x <= mx else 1)
PY
    then
      echo "$ans"
      return 0
    fi
    warn "Valor fora do intervalo permitido: $min a $max."
  done
}

ask_int(){
  local prompt="$1" default="$2" min="$3" max="$4" ans
  while true; do
    read -r -p "$prompt [$default]: " ans || true
    ans="${ans:-$default}"
    if [[ "$ans" =~ ^[0-9]+$ ]] && [[ "$ans" -ge "$min" ]] && [[ "$ans" -le "$max" ]]; then
      echo "$ans"
      return 0
    fi
    warn "Digite um numero inteiro entre $min e $max."
  done
}

detect_recordings_dir(){
  local real=""
  if [[ -L "$SYSTEM_RECORDINGS_DIR" ]]; then
    real="$(readlink -f "$SYSTEM_RECORDINGS_DIR" 2>/dev/null || true)"
  elif [[ -d "$SYSTEM_RECORDINGS_DIR" ]]; then
    real="$(readlink -f "$SYSTEM_RECORDINGS_DIR" 2>/dev/null || echo "$SYSTEM_RECORDINGS_DIR")"
  fi

  if [[ -z "$real" ]]; then
    for p in /dados/nexus/gravacoes /data/nexus/gravacoes /srv/nexus/gravacoes /mnt/*/nexus/gravacoes /media/*/nexus/gravacoes; do
      if [[ -d "$p" ]]; then
        real="$(readlink -f "$p" 2>/dev/null || echo "$p")"
        break
      fi
    done
  fi

  echo "$real"
}

is_safe_recordings_dir(){
  local p="$1"
  [[ -n "$p" ]] || return 1

  case "$p" in
    "/"|"/home"|"/root"|"/etc"|"/usr"|"/var"|"/opt"|"/tmp"|"/srv"|"/mnt"|"/media"|"/dados"|"/data")
      return 1
      ;;
  esac

  case "$p" in
    "$NVR_ROOT/gravacoes"|"$NVR_ROOT/gravacoes/"*) return 0 ;;
    */nexus/gravacoes|*/nexus/gravacoes/*) return 0 ;;
    *) return 1 ;;
  esac
}

load_config(){
  if [[ -f "$CONFIG_FILE" ]]; then
    # shellcheck source=/dev/null
    source "$CONFIG_FILE"
  fi

  RET_MODE="${RET_MODE:-disabled}"
  GB_LIMIT="${GB_LIMIT:-50}"
  GB_ACTION="${GB_ACTION:-gb}"
  GB_DELETE="${GB_DELETE:-5}"
  GB_DELETE_DAYS="${GB_DELETE_DAYS:-2}"
  KEEP_DAYS="${KEEP_DAYS:-15}"
  DELETE_DAYS="${DELETE_DAYS:-3}"
  PROTECT_MINUTES="${PROTECT_MINUTES:-30}"
  AUTO_INTERVAL_MINUTES="${AUTO_INTERVAL_MINUTES:-30}"
  VIDEO_EXTENSIONS="${VIDEO_EXTENSIONS:-mkv,mp4,ts,avi,mov,m4v}"
}

save_config(){
  mkdir -p "$(dirname "$CONFIG_FILE")"
  cat > "$CONFIG_FILE" <<EOF
# Nexus NVR - Configuracao de retencao
RET_MODE="$RET_MODE"
GB_LIMIT="$GB_LIMIT"
GB_ACTION="$GB_ACTION"
GB_DELETE="$GB_DELETE"
GB_DELETE_DAYS="$GB_DELETE_DAYS"
KEEP_DAYS="$KEEP_DAYS"
DELETE_DAYS="$DELETE_DAYS"
PROTECT_MINUTES="$PROTECT_MINUTES"
AUTO_INTERVAL_MINUTES="$AUTO_INTERVAL_MINUTES"
VIDEO_EXTENSIONS="$VIDEO_EXTENSIONS"
EOF
  chmod 600 "$CONFIG_FILE" 2>/dev/null || true
  ok "Configuracao salva em: $CONFIG_FILE"
}

write_log(){
  mkdir -p "$(dirname "$LOG_FILE")" 2>/dev/null || true
  printf '%s %s\n' "$(date '+%Y-%m-%d %H:%M:%S')" "$*" >> "$LOG_FILE" 2>/dev/null || true
}

retention_python(){
  local action="$1"
  load_config

  local real
  real="$(detect_recordings_dir)"

  if [[ -z "$real" || ! -d "$real" ]]; then
    err "Pasta real de gravacoes nao encontrada."
    return 1
  fi

  if ! is_safe_recordings_dir "$real"; then
    err "Bloqueado por seguranca. Pasta detectada:"
    err "$real"
    return 1
  fi

  export NVR_RET_ACTION="$action"
  export NVR_RET_ROOT="$real"
  export NVR_RET_LOG="$LOG_FILE"
  export NVR_RET_MODE="$RET_MODE"
  export NVR_RET_GB_LIMIT="$GB_LIMIT"
  export NVR_RET_GB_ACTION="$GB_ACTION"
  export NVR_RET_GB_DELETE="$GB_DELETE"
  export NVR_RET_GB_DELETE_DAYS="$GB_DELETE_DAYS"
  export NVR_RET_KEEP_DAYS="$KEEP_DAYS"
  export NVR_RET_DELETE_DAYS="$DELETE_DAYS"
  export NVR_RET_PROTECT_MINUTES="$PROTECT_MINUTES"
  export NVR_RET_VIDEO_EXTENSIONS="$VIDEO_EXTENSIONS"

python3 - <<'PY'
import os
import re
from pathlib import Path
from datetime import datetime, timedelta

ACTION = os.environ.get("NVR_RET_ACTION", "status")
ROOT = Path(os.environ["NVR_RET_ROOT"]).resolve()
MODE = os.environ.get("NVR_RET_MODE", "disabled")
LOG_FILE = Path(os.environ.get("NVR_RET_LOG", "/var/log/nexus_nvr_retencao.log"))

GB_LIMIT = float(os.environ.get("NVR_RET_GB_LIMIT", "50"))
GB_ACTION = os.environ.get("NVR_RET_GB_ACTION", "gb")
GB_DELETE = float(os.environ.get("NVR_RET_GB_DELETE", "5"))
GB_DELETE_DAYS = int(os.environ.get("NVR_RET_GB_DELETE_DAYS", "2"))
KEEP_DAYS = int(os.environ.get("NVR_RET_KEEP_DAYS", "15"))
DELETE_DAYS = int(os.environ.get("NVR_RET_DELETE_DAYS", "3"))
PROTECT_MINUTES = int(os.environ.get("NVR_RET_PROTECT_MINUTES", "30"))
EXTS = {("." + x.strip().lower().lstrip(".")) for x in os.environ.get("NVR_RET_VIDEO_EXTENSIONS", "mkv,mp4,ts,avi,mov,m4v").split(",") if x.strip()}

DATE_RE = re.compile(r"^\d{2}-\d{2}-\d{4}$")
NOW = datetime.now()
PROTECT_AFTER = NOW - timedelta(minutes=PROTECT_MINUTES)
GB = 1024 ** 3

def log(msg):
    try:
        LOG_FILE.parent.mkdir(parents=True, exist_ok=True)
        with LOG_FILE.open("a", encoding="utf-8") as f:
            f.write(f"{datetime.now():%Y-%m-%d %H:%M:%S} {msg}\n")
    except Exception:
        pass

def fmt_bytes(n):
    n = float(n)
    units = ["B", "KB", "MB", "GB", "TB"]
    i = 0
    while n >= 1024 and i < len(units) - 1:
        n /= 1024
        i += 1
    return f"{n:.2f} {units[i]}"

def disk_usage():
    st = os.statvfs(str(ROOT))
    total = st.f_blocks * st.f_frsize
    free = st.f_bavail * st.f_frsize
    used = total - free
    return total, used, free

def mount_for_root():
    root = str(ROOT)
    best = ""
    try:
        with open("/proc/mounts", "r", encoding="utf-8", errors="ignore") as f:
            for line in f:
                parts = line.split()
                if len(parts) < 2:
                    continue
                mp = parts[1].replace("\\040", " ")
                if root == mp or root.startswith(mp.rstrip("/") + "/"):
                    if len(mp) > len(best):
                        best = mp
    except Exception:
        pass
    return best or "desconhecida"

def bar(percent, width=24):
    filled = max(0, min(width, int(width * percent / 100)))
    return "[" + ("#" * filled) + ("-" * (width - filled)) + f"] {percent:.1f}%"

def line(label, value):
    print(f"{label:<31}: {value}")

def is_video(p):
    return p.is_file() and p.suffix.lower() in EXTS

def iter_video_files():
    try:
        for p in ROOT.rglob("*"):
            if is_video(p):
                yield p
    except FileNotFoundError:
        return

def file_info(p):
    try:
        st = p.stat()
        return {"path": p, "size": st.st_size, "mtime": datetime.fromtimestamp(st.st_mtime)}
    except FileNotFoundError:
        return None

def safe_video_files():
    eligible, protected = [], []
    for p in iter_video_files():
        info = file_info(p)
        if not info:
            continue
        if info["mtime"] > PROTECT_AFTER:
            protected.append(info)
        else:
            eligible.append(info)
    eligible.sort(key=lambda x: (x["mtime"], str(x["path"])))
    protected.sort(key=lambda x: (x["mtime"], str(x["path"])))
    return eligible, protected

def total_video_size():
    total = 0
    count = 0
    for p in iter_video_files():
        try:
            total += p.stat().st_size
            count += 1
        except FileNotFoundError:
            pass
    return total, count

def discover_day_dirs():
    days = {}
    if not ROOT.exists():
        return days
    for cam_dir in ROOT.iterdir():
        if not cam_dir.is_dir():
            continue
        for day_dir in cam_dir.iterdir():
            if not day_dir.is_dir() or not DATE_RE.match(day_dir.name):
                continue
            try:
                d = datetime.strptime(day_dir.name, "%d-%m-%Y").date()
            except Exception:
                continue
            days.setdefault(d, []).append(day_dir)
    return dict(sorted(days.items(), key=lambda kv: kv[0]))

def day_video_infos(day_dir):
    infos = []
    try:
        for p in day_dir.rglob("*"):
            if is_video(p):
                info = file_info(p)
                if info:
                    infos.append(info)
    except FileNotFoundError:
        pass
    return infos

def remove_empty_day_dirs(execute):
    removed = []
    for _, dirs in discover_day_dirs().items():
        for d in dirs:
            try:
                if not any(d.iterdir()):
                    removed.append(d)
                    if execute:
                        d.rmdir()
            except (FileNotFoundError, OSError):
                pass
    return removed

def delete_files(files, execute):
    deleted = []
    freed = 0
    for info in files:
        p = info["path"]
        size = info["size"]
        if execute:
            try:
                p.unlink()
                deleted.append(p)
                freed += size
                log(f"DELETE_FILE size={size} path={p}")
            except FileNotFoundError:
                pass
            except Exception as e:
                print(f"[AVISO] Falha ao apagar {p}: {e}")
        else:
            deleted.append(p)
            freed += size
    return deleted, freed

def selected_days_oldest(n):
    days = discover_day_dirs()
    selected = []
    for d in sorted(days.keys()):
        if len(selected) >= n:
            break
        selected.append((d, days[d]))
    return selected

def selected_days_older_than_keep(keep_days, n):
    cutoff = NOW.date() - timedelta(days=keep_days)
    return [(d, dirs) for d, dirs in discover_day_dirs().items() if d < cutoff][:n]

def delete_day_groups(groups, execute):
    files, protected = [], []
    for _, dirs in groups:
        for day_dir in dirs:
            for info in day_video_infos(day_dir):
                if info["mtime"] > PROTECT_AFTER:
                    protected.append(info)
                else:
                    files.append(info)
    files.sort(key=lambda x: (x["mtime"], str(x["path"])))
    deleted, freed = delete_files(files, execute)
    emptied = remove_empty_day_dirs(execute)
    return deleted, freed, protected, emptied

def print_status():
    total, count = total_video_size()
    eligible, protected = safe_video_files()
    days = discover_day_dirs()
    disk_total, disk_used, disk_free = disk_usage()
    disk_pct = (disk_used / disk_total * 100) if disk_total else 0

    print("============================================================")
    print(" STATUS DAS GRAVACOES - NEXUS NVR")
    print("============================================================\n")

    print("ARMAZENAMENTO")
    print("------------------------------------------------------------")
    line("Pasta real dos videos", ROOT)
    line("Montagem/disco", mount_for_root())
    line("Disco total", fmt_bytes(disk_total))
    line("Disco usado", f"{fmt_bytes(disk_used)}  {bar(disk_pct)}")
    line("Disco livre", fmt_bytes(disk_free))

    print("\nRETENCAO CONFIGURADA")
    print("------------------------------------------------------------")
    if MODE == "disabled":
        line("Modo", "desativado")
    elif MODE == "gb":
        line("Modo", "por limite de GB")
        line("Limite maximo", f"{GB_LIMIT} GB")
        if GB_ACTION == "gb":
            line("Ao atingir o limite", f"apagar {GB_DELETE} GB antigos")
        else:
            line("Ao atingir o limite", f"apagar {GB_DELETE_DAYS} dia(s) antigo(s)")
    elif MODE == "days":
        line("Modo", "por dias")
        line("Manter gravacoes por", f"{KEEP_DAYS} dia(s)")
        line("Ao passar do limite", f"apagar {DELETE_DAYS} dia(s) antigo(s)")
    else:
        line("Modo", MODE)
    line("Protecao arquivos novos", f"{PROTECT_MINUTES} minuto(s)")
    line("Extensoes de video", ", ".join(sorted(EXTS)))

    print("\nRESUMO DOS VIDEOS")
    print("------------------------------------------------------------")
    line("Total de videos", count)
    line("Espaco usado por videos", fmt_bytes(total))
    line("Arquivos protegidos", f"{len(protected)} arquivo(s) recentes/em gravacao")
    line("Pastas de dias detectadas", len(days))
    if days:
        line("Dia mais antigo", min(days.keys()).strftime("%d-%m-%Y"))
        line("Dia mais novo", max(days.keys()).strftime("%d-%m-%Y"))
    else:
        line("Dias encontrados", "nenhum")

    print("\nVIDEOS MAIS ANTIGOS E ELEGIVEIS PARA LIMPEZA")
    print("------------------------------------------------------------")
    if not eligible:
        print("Nenhum video elegivel no momento.")
        print(f"Obs.: arquivos modificados nos ultimos {PROTECT_MINUTES} minuto(s) ficam protegidos.")
    else:
        print(f"{'Data/hora':<18} {'Tamanho':>12}  Caminho")
        print("-" * 80)
        for info in eligible[:10]:
            print(f"{info['mtime']:%Y-%m-%d %H:%M} {fmt_bytes(info['size']):>12}  {info['path']}")
        if len(eligible) > 10:
            print(f"... mais {len(eligible) - 10} arquivo(s) elegivel(is).")
    print("\n============================================================")

def run_retention(execute):
    if MODE == "disabled":
        print("[AVISO] Retencao desativada. Configure um modo primeiro.")
        return 0

    total_before, count_before = total_video_size()

    print("============================================================")
    print(" EXECUCAO DA RETENCAO")
    print("============================================================")
    line("Modo", MODE)
    line("Acao", "APAGAR DE VERDADE" if execute else "SIMULACAO")
    line("Pasta real", ROOT)
    line("Uso atual por videos", f"{fmt_bytes(total_before)} em {count_before} arquivo(s)")
    line("Protecao", f"arquivos dos ultimos {PROTECT_MINUTES} minuto(s) nao serao apagados")

    deleted, freed, protected, empty_dirs = [], 0, [], []

    if MODE == "gb":
        limit = int(GB_LIMIT * GB)
        print()
        line("Limite GB", f"{GB_LIMIT} GB")

        if total_before <= limit:
            print("\n[OK] Uso atual abaixo do limite. Nada a apagar.")
            return 0

        if GB_ACTION == "gb":
            target_free = int(GB_DELETE * GB)
            line("Folga", f"apagar ate liberar {GB_DELETE} GB")
            candidates, protected = safe_video_files()
            selected, accum = [], 0
            for info in candidates:
                if accum >= target_free:
                    break
                selected.append(info)
                accum += info["size"]
            deleted, freed = delete_files(selected, execute)
            empty_dirs = remove_empty_day_dirs(execute)
        else:
            line("Folga", f"apagar {GB_DELETE_DAYS} dia(s) mais antigo(s)")
            deleted, freed, protected, empty_dirs = delete_day_groups(selected_days_oldest(GB_DELETE_DAYS), execute)

    elif MODE == "days":
        print()
        line("Manter dias", KEEP_DAYS)
        line("Lote", f"apagar {DELETE_DAYS} dia(s) antigo(s)")
        groups = selected_days_older_than_keep(KEEP_DAYS, DELETE_DAYS)
        if not groups:
            print("\n[OK] Nao ha dias mais antigos que o limite configurado. Nada a apagar.")
            return 0

        print("\nDias selecionados:")
        for d, dirs in groups:
            print(f"  {d.strftime('%d-%m-%Y')} ({len(dirs)} pasta(s))")
        deleted, freed, protected, empty_dirs = delete_day_groups(groups, execute)

    else:
        print(f"[ERRO] Modo desconhecido: {MODE}")
        return 1

    print("\nRESULTADO")
    print("------------------------------------------------------------")
    line("Arquivos afetados", len(deleted))
    line("Espaco liberado", fmt_bytes(freed))
    line("Arquivos protegidos", len(protected))
    line("Pastas vazias afetadas", len(empty_dirs))

    if deleted:
        print("\nPrimeiros arquivos afetados:")
        for p in deleted[:20]:
            print(f"  {p}")
        if len(deleted) > 20:
            print(f"  ... mais {len(deleted) - 20} arquivo(s)")

    if empty_dirs:
        print("\nPastas vazias afetadas:")
        for p in empty_dirs[:20]:
            print(f"  {p}")
        if len(empty_dirs) > 20:
            print(f"  ... mais {len(empty_dirs) - 20} pasta(s)")

    if execute:
        total_after, count_after = total_video_size()
        print()
        line("Uso final por videos", f"{fmt_bytes(total_after)} em {count_after} arquivo(s)")
        log(f"CLEAN mode={MODE} deleted={len(deleted)} freed={freed} root={ROOT}")
    else:
        print("\n[INFO] Simulacao: nada foi apagado.")
    return 0

if ACTION == "status":
    print_status()
elif ACTION == "simulate":
    raise SystemExit(run_retention(False))
elif ACTION == "clean":
    raise SystemExit(run_retention(True))
else:
    print(f"[ERRO] Acao desconhecida: {ACTION}")
    raise SystemExit(1)
PY
}

show_status(){
  retention_python status
}

show_config(){
  load_config
  local real
  real="$(detect_recordings_dir)"

  title "Nexus NVR - Configuracao de Retencao"

  section "CONFIGURACAO"
  kv "Arquivo" "$CONFIG_FILE"
  [[ -f "$CONFIG_FILE" ]] || kv "Status" "nenhuma configuracao salva ainda"

  case "$RET_MODE" in
    gb)
      kv "Modo" "por limite de GB"
      kv "Limite maximo" "${GB_LIMIT} GB"
      if [[ "$GB_ACTION" == "gb" ]]; then
        kv "Ao atingir limite" "apagar ${GB_DELETE} GB antigos"
      else
        kv "Ao atingir limite" "apagar ${GB_DELETE_DAYS} dia(s) antigo(s)"
      fi
      ;;
    days)
      kv "Modo" "por dias"
      kv "Manter gravacoes" "${KEEP_DAYS} dia(s)"
      kv "Ao passar limite" "apagar ${DELETE_DAYS} dia(s) antigo(s)"
      ;;
    disabled)
      kv "Modo" "desativado"
      ;;
    *)
      kv "Modo" "$RET_MODE"
      ;;
  esac

  kv "Protecao arquivos novos" "${PROTECT_MINUTES} minuto(s)"
  kv "Intervalo automatico" "${AUTO_INTERVAL_MINUTES} minuto(s)"
  kv "Extensoes de video" "$VIDEO_EXTENSIONS"

  section "ARMAZENAMENTO"
  kv "Caminho do sistema" "$SYSTEM_RECORDINGS_DIR"
  kv "Pasta real detectada" "${real:-nenhuma}"
  if [[ -n "$real" ]]; then
    is_safe_recordings_dir "$real" && kv "Seguranca da pasta" "OK" || kv "Seguranca da pasta" "BLOQUEADA"
    df -hT "$real" 2>/dev/null | awk 'NR==1 || NR==2 {print "  " $0}'
  fi

  section "OBSERVACAO"
  note "A limpeza automatica so apaga quando o limite configurado for atingido."
  note "Arquivos recentes ficam protegidos para evitar apagar video ainda em gravacao."
}

configure_gb(){
  title "Configurar Retencao por GB"
  load_config

  section "COMO FUNCIONA"
  note "Voce define um limite maximo de uso da pasta de gravacoes."
  note "Quando passar do limite, o script cria uma folga apagando videos antigos."
  note "Se estiver abaixo do limite, nada sera apagado."

  section "LIMITE"
  RET_MODE="gb"
  GB_LIMIT="$(ask_number "Limite maximo da pasta de gravacoes em GB" "${GB_LIMIT:-50}" "0.1" "100000")"

  section "FOLGA AO ATINGIR O LIMITE"
  echo "  1) Apagar X GB dos videos mais antigos"
  echo "  2) Apagar X dias mais antigos"
  echo

  local op=""
  while true; do
    read -r -p "Escolha [1/2]: " op || true
    case "$op" in
      1)
        GB_ACTION="gb"
        GB_DELETE="$(ask_number "Quantos GB apagar por lote" "${GB_DELETE:-5}" "0.1" "100000")"
        break
        ;;
      2)
        GB_ACTION="days"
        GB_DELETE_DAYS="$(ask_int "Quantos dias antigos apagar por lote" "${GB_DELETE_DAYS:-2}" "1" "3650")"
        break
        ;;
      *)
        warn "Opcao invalida."
        ;;
    esac
  done

  section "PROTECAO"
  note "Arquivos modificados recentemente podem estar em gravacao."
  PROTECT_MINUTES="$(ask_int "Proteger arquivos modificados nos ultimos X minutos" "${PROTECT_MINUTES:-30}" "1" "1440")"

  save_config
  show_config
}

configure_days(){
  title "Configurar Retencao por Dias"
  load_config

  section "COMO FUNCIONA"
  note "Voce define quantos dias deseja manter."
  note "Quando existirem gravacoes mais antigas que isso, o script apaga dias antigos por lote."
  note "Pastas de dias vazias sao removidas automaticamente."

  section "DIAS"
  RET_MODE="days"
  KEEP_DAYS="$(ask_int "Manter gravacoes por quantos dias" "${KEEP_DAYS:-15}" "1" "3650")"
  DELETE_DAYS="$(ask_int "Quando passar do limite, apagar quantos dias antigos por lote" "${DELETE_DAYS:-3}" "1" "3650")"

  section "PROTECAO"
  note "Arquivos modificados recentemente podem estar em gravacao."
  PROTECT_MINUTES="$(ask_int "Proteger arquivos modificados nos ultimos X minutos" "${PROTECT_MINUTES:-30}" "1" "1440")"

  save_config
  show_config
}

run_simulation(){
  title "Simulacao de Limpeza"
  section "O QUE A SIMULACAO FAZ"
  note "Mostra o que seria apagado."
  note "Nao remove nenhum arquivo."
  note "Use sempre antes da limpeza real."
  retention_python simulate
}

run_clean(){
  title "Limpeza Real"

  section "ATENCAO"
  warn "Esta acao pode apagar videos antigos conforme a configuracao atual."
  warn "Somente arquivos de video dentro da pasta segura de gravacoes serao apagados."
  warn "Pastas de dias vazias podem ser removidas."

  echo
  if yes_no "Deseja ver a simulacao antes de apagar?" "S"; then
    retention_python simulate
    echo
  fi

  section "CONFIRMACAO"
  warn "Para apagar de verdade, digite exatamente: APAGAR VIDEOS"
  read -r -p "Confirmacao: " ans || true
  if [[ "$ans" != "APAGAR VIDEOS" ]]; then
    warn "Limpeza real cancelada."
    return 0
  fi
  retention_python clean
}

configure_auto_interval(){
  title "Configurar Intervalo Automatico"
  load_config

  section "INTERVALO"
  note "Esse e o tempo entre verificacoes automaticas."
  note "Exemplo: 30 minutos = verifica a cada 30 minutos se precisa limpar."

  while true; do
    AUTO_INTERVAL_MINUTES="$(ask_int "Verificar automaticamente a cada quantos minutos (10 a 120, multiplos de 10)" "${AUTO_INTERVAL_MINUTES:-30}" "10" "120")"
    if (( AUTO_INTERVAL_MINUTES % 10 == 0 )); then
      break
    fi
    warn "Use apenas multiplos de 10: 10, 20, 30, 40 ... 120."
  done

  save_config

  section "RESULTADO"
  kv "Intervalo automatico" "${AUTO_INTERVAL_MINUTES} minuto(s)"
  if crontab -l 2>/dev/null | grep -q "$CRON_MARKER"; then
    kv "Automatico" "ativo; usara o novo intervalo"
  else
    kv "Automatico" "nao ativo; use a opcao 7 para ativar"
  fi
}

enable_auto(){
  title "Ativar Limpeza Automatica"
  load_config

  if [[ "$RET_MODE" == "disabled" ]]; then
    warn "Configure primeiro um modo de retencao por GB ou por dias."
    return 1
  fi

  section "COMO FUNCIONA"
  note "O cron acorda o script periodicamente."
  note "O script so apaga algo se o limite configurado for atingido."
  note "Se estiver abaixo do limite, ele nao faz nada."

  configure_auto_interval

  chmod +x "$CRON_SCRIPT_PATH" 2>/dev/null || true

  local tmp
  tmp="$(mktemp)"
  crontab -l 2>/dev/null | grep -v "$CRON_MARKER" > "$tmp" || true
  echo "*/10 * * * * $CRON_SCRIPT_PATH --auto # $CRON_MARKER" >> "$tmp"
  crontab "$tmp"
  rm -f "$tmp"

  section "ATIVADO"
  kv "Intervalo escolhido" "a cada ${AUTO_INTERVAL_MINUTES} minuto(s)"
  kv "Cron tecnico" "*/10 * * * * $CRON_SCRIPT_PATH --auto"
  note "O cron acorda a cada 10 minutos, mas o script respeita o intervalo escolhido."
}

disable_auto(){
  title "Desativar Limpeza Automatica"
  local tmp
  tmp="$(mktemp)"
  crontab -l 2>/dev/null | grep -v "$CRON_MARKER" > "$tmp" || true
  crontab "$tmp"
  rm -f "$tmp"
  rm -f "$LAST_RUN_FILE" 2>/dev/null || true
  ok "Limpeza automatica desativada."
}

show_auto(){
  title "Agendamento Automatico"

  section "CRON"
  local line
  line="$(crontab -l 2>/dev/null | grep "$CRON_MARKER" || true)"
  if [[ -n "$line" ]]; then
    kv "Status" "ativo"
    kv "Entrada cron" "$line"
  else
    kv "Status" "desativado"
  fi

  load_config
  kv "Intervalo configurado" "${AUTO_INTERVAL_MINUTES} minuto(s)"
}

show_log(){
  title "Log da Retencao"
  if [[ -f "$LOG_FILE" ]]; then
    kv "Arquivo" "$LOG_FILE"
    section "ULTIMAS LINHAS"
    tail -80 "$LOG_FILE"
  else
    warn "Log ainda nao existe: $LOG_FILE"
  fi
}

disable_retention(){
  title "Desativar Retencao"
  load_config
  RET_MODE="disabled"
  save_config
  disable_auto
  ok "Retencao desativada."
}

menu(){
  while true; do
    title "Nexus NVR - Retencao de Gravacoes"

    echo "STATUS"
    echo "  1) Ver status das gravacoes"
    echo

    echo "CONFIGURACAO"
    echo "  2) Configurar modo por GB"
    echo "  3) Configurar modo por dias"
    echo "  4) Ver configuracao atual"
    echo

    echo "EXECUCAO"
    echo "  5) Rodar simulacao"
    echo "  6) Rodar limpeza agora"
    echo

    echo "AUTOMATICO"
    echo "  7) Ativar limpeza automatica"
    echo "  8) Configurar intervalo automatico"
    echo "  9) Ver agendamento automatico"
    echo " 10) Desativar limpeza automatica"
    echo

    echo "OUTROS"
    echo " 11) Ver log"
    echo " 12) Desativar retencao"
    echo " 13) Sair"
    echo

    read -r -p "Escolha uma opcao: " opt || true

    case "${opt:-}" in
      1) show_status ;;
      2) configure_gb ;;
      3) configure_days ;;
      4) show_config ;;
      5) run_simulation ;;
      6) run_clean ;;
      7) enable_auto ;;
      8) configure_auto_interval ;;
      9) show_auto ;;
      10) disable_auto ;;
      11) show_log ;;
      12) disable_retention ;;
      13) exit 0 ;;
      *) warn "Opcao invalida." ;;
    esac

    echo
    read -r -p "Pressione Enter para voltar ao menu..." _ || true
  done
}

auto_run(){
  need_root
  load_config

  local now last elapsed need
  now="$(date +%s)"
  need=$(( AUTO_INTERVAL_MINUTES * 60 ))

  if [[ -f "$LAST_RUN_FILE" ]]; then
    last="$(cat "$LAST_RUN_FILE" 2>/dev/null || echo 0)"
  else
    last=0
  fi

  if [[ "$last" =~ ^[0-9]+$ ]]; then
    elapsed=$(( now - last ))
  else
    elapsed=$need
  fi

  if (( elapsed < need )); then
    write_log "AUTO_SKIP elapsed=${elapsed}s need=${need}s interval=${AUTO_INTERVAL_MINUTES}min"
    exit 0
  fi

  echo "$now" > "$LAST_RUN_FILE" 2>/dev/null || true
  retention_python clean
}

main(){
  case "${1:-}" in
    --auto)
      auto_run
      ;;
    --status)
      need_root
      show_status
      ;;
    --simulate)
      need_root
      run_simulation
      ;;
    --clean)
      need_root
      retention_python clean
      ;;
    *)
      need_root
      menu
      ;;
  esac
}

main "$@"
