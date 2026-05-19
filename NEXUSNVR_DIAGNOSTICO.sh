#!/usr/bin/env bash
# ============================================================
# Nexus NVR - Diagnostico do Servidor
# ============================================================

set -u

VERSION="2026-05-19-diagnostico-1.0"
NVR_ROOT="${NVR_ROOT:-/home/nexus}"
STATE_FILE="${STATE_FILE:-$NVR_ROOT/nvr_auto_state.env}"
API_CONFIG="${API_CONFIG:-$NVR_ROOT/api/nvr_config.json}"
GO2RTC_CONFIG="${GO2RTC_CONFIG:-$NVR_ROOT/go2rtc/go2rtc.yaml}"
RECORDINGS_DIR="${RECORDINGS_DIR:-$NVR_ROOT/gravacoes}"
RETENTION_CONFIG="${RETENTION_CONFIG:-$NVR_ROOT/retencao_nvr.conf}"
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
RETENTION_SCRIPT="${RETENTION_SCRIPT:-$SCRIPT_DIR/NEXUSNVR_RETENCAO.sh}"
LOG_FILE="/tmp/nexus_nvr_diagnostico_$(date +%Y%m%d_%H%M%S).log"

OK=0
WARN=0
FAIL=0

green='\033[0;32m'
yellow='\033[1;33m'
red='\033[0;31m'
blue='\033[0;34m'
bold='\033[1m'
reset='\033[0m'

mkdir -p /tmp
exec > >(tee -a "$LOG_FILE") 2>&1

ok(){ OK=$((OK+1)); printf "${green}[OK]${reset} %s\n" "$*"; }
warn(){ WARN=$((WARN+1)); printf "${yellow}[AVISO]${reset} %s\n" "$*"; }
fail(){ FAIL=$((FAIL+1)); printf "${red}[FALHA]${reset} %s\n" "$*"; }
info(){ printf "${blue}[INFO]${reset} %s\n" "$*"; }

title(){
  echo
  echo "============================================================"
  printf " ${bold}%s${reset}\n" "$*"
  echo "============================================================"
}

section(){
  echo
  printf "${bold}%s${reset}\n" "$*"
  echo "------------------------------------------------------------"
}

kv(){
  printf "  %-28s: %s\n" "$1" "$2"
}

line(){
  echo "------------------------------------------------------------"
}

need_root(){
  if [[ "${EUID}" -ne 0 ]]; then
    fail "Execute com sudo para diagnostico completo: sudo bash $0"
    echo "Log: $LOG_FILE"
    exit 1
  fi
}

load_state(){
  FINAL_IP=""
  PANEL_PORT=""
  TZ_NVR=""
  NETWORK_MODE=""
  EXTERNAL_HOST=""
  EXTERNAL_PORT=""
  RECORDINGS_REAL_DIR=""
  RECORDINGS_SYSTEM_DIR=""

  if [[ -f "$STATE_FILE" ]]; then
    # shellcheck disable=SC1090
    source "$STATE_FILE" 2>/dev/null || true
    ok "Estado da instalacao encontrado"
  else
    warn "Arquivo de estado nao encontrado: $STATE_FILE"
  fi

  PANEL_PORT="${PANEL_PORT:-48902}"
  RECORDINGS_SYSTEM_DIR="${RECORDINGS_SYSTEM_DIR:-$RECORDINGS_DIR}"
}

network_mode_label(){
  case "${1:-}" in
    local) echo "Apenas local" ;;
    external) echo "Apenas VPS/internet" ;;
    hybrid) echo "Local + internet" ;;
    "") echo "nao informado" ;;
    *) echo "$1" ;;
  esac
}

http_code(){
  local url="$1"
  local host="${2:-}"
  local code

  if [[ -n "$host" ]]; then
    code="$(curl -sS --max-time 5 -o /dev/null -w '%{http_code}' -H "Host: $host" "$url" 2>/dev/null || echo 000)"
  else
    code="$(curl -sS --max-time 5 -o /dev/null -w '%{http_code}' "$url" 2>/dev/null || echo 000)"
  fi

  echo "$code"
}

human_status(){
  local code="$1"
  if [[ "$code" =~ ^[23] ]]; then
    ok "$2 HTTP $code"
  else
    fail "$2 HTTP $code"
  fi
}

redact(){
  sed -E \
    -e 's#(rtsp://)([^:@/[:space:]]+):([^@/[:space:]]+)@#\1***:***@#g' \
    -e 's#(user=)[^_&[:space:]]+#\1***#g' \
    -e 's#(_password=)[^_&[:space:]]+#\1***#g' \
    -e 's#("pass"[[:space:]]*:[[:space:]]*")[^"]*#\1***#g' \
    -e 's#("password"[[:space:]]*:[[:space:]]*")[^"]*#\1***#g'
}

check_commands(){
  section "PROGRAMAS"

  local cmd
  for cmd in docker curl jq awk sed find df ip date; do
    if command -v "$cmd" >/dev/null 2>&1; then
      ok "$cmd encontrado"
    else
      fail "$cmd nao encontrado"
    fi
  done
}

show_system(){
  section "SERVIDOR"

  kv "Data/hora" "$(date '+%Y-%m-%d %H:%M:%S %Z')"
  kv "Usuario" "$(id -un)"
  kv "Hostname" "$(hostname)"
  kv "Kernel" "$(uname -srmo)"

  if command -v lsb_release >/dev/null 2>&1; then
    kv "Sistema" "$(lsb_release -ds 2>/dev/null | tr -d '"')"
  elif [[ -f /etc/os-release ]]; then
    kv "Sistema" "$(awk -F= '/^PRETTY_NAME=/{gsub(/"/,"",$2); print $2}' /etc/os-release)"
  fi

  local iface ip_addr gateway
  iface="$(ip route | awk '/default/ {print $5; exit}' 2>/dev/null || true)"
  ip_addr="$(ip -4 -o addr show scope global 2>/dev/null | awk -v dev="$iface" '$2==dev {split($4,a,"/"); print a[1]"/"a[2]; exit}')"
  gateway="$(ip route | awk '/default/ {print $3; exit}' 2>/dev/null || true)"
  kv "Interface padrao" "${iface:-nao detectada}"
  kv "IP local atual" "${ip_addr:-nao detectado}"
  kv "Gateway" "${gateway:-nao detectado}"
}

show_install_config(){
  section "CONFIGURACAO DO NEXUS NVR"

  kv "Raiz do sistema" "$NVR_ROOT"
  kv "Arquivo de estado" "$STATE_FILE"
  kv "Modo de rede" "$(network_mode_label "${NETWORK_MODE:-}")"
  kv "IP local final" "${FINAL_IP:-nao informado}"
  kv "Porta painel/API" "${PANEL_PORT:-nao informada}"
  kv "Fuso horario" "${TZ_NVR:-nao informado}"

  if [[ -n "${EXTERNAL_HOST:-}" ]]; then
    kv "Acesso externo" "${EXTERNAL_HOST}:${EXTERNAL_PORT:-$PANEL_PORT}"
  else
    kv "Acesso externo" "nao configurado"
  fi
}

check_docker(){
  section "DOCKER E CONTAINERS"

  if ! command -v docker >/dev/null 2>&1; then
    fail "Docker nao encontrado"
    return
  fi

  if docker info >/dev/null 2>&1; then
    ok "Docker respondendo"
  else
    fail "Docker nao esta respondendo"
    return
  fi

  docker ps --format '  {{.Names}}\t{{.Status}}' | sort

  local required=(go2rtc nvr-frontend visualizador_videos nexus_api nginx-proxy-manager_app_1)
  local c status
  line
  for c in "${required[@]}"; do
    status="$(docker inspect -f '{{.State.Status}}' "$c" 2>/dev/null || true)"
    if [[ "$status" == "running" ]]; then
      ok "Container $c rodando"
    elif [[ -n "$status" ]]; then
      fail "Container $c existe, mas esta: $status"
    else
      fail "Container $c nao encontrado"
    fi
  done

  if docker ps --format '{{.Names}}' | grep -q '^gravador_'; then
    ok "Gravador(es) encontrado(s): $(docker ps --format '{{.Names}}' | grep '^gravador_' | paste -sd, -)"
  else
    warn "Nenhum container gravador_ rodando"
  fi
}

check_ports(){
  section "PORTAS"

  local ports=("${PANEL_PORT:-48902}" 81 443 1984 3000 8085 9000 8554)
  local p

  if command -v ss >/dev/null 2>&1; then
    for p in "${ports[@]}"; do
      if ss -lntup 2>/dev/null | grep -q ":$p "; then
        ok "Porta TCP $p em escuta"
      else
        warn "Porta TCP $p nao apareceu em escuta"
      fi
    done

    if ss -lnup 2>/dev/null | grep -q ":${PANEL_PORT:-48902} "; then
      ok "Porta UDP ${PANEL_PORT:-48902} em escuta para RTC"
    else
      warn "Porta UDP ${PANEL_PORT:-48902} nao apareceu em escuta"
    fi
  else
    warn "Comando ss nao encontrado; pulando portas"
  fi
}

check_http(){
  section "TESTES HTTP"

  local host="${FINAL_IP:-127.0.0.1}"
  local port="${PANEL_PORT:-48902}"

  human_status "$(http_code "http://127.0.0.1:$port/" "$host")" "Painel via proxy"
  human_status "$(http_code "http://127.0.0.1:$port/maestro/config" "$host")" "API via proxy"
  human_status "$(http_code "http://127.0.0.1:3000/maestro/config")" "API direta"
  human_status "$(http_code "http://127.0.0.1:1984/api/streams")" "Go2RTC direto"
  human_status "$(http_code "http://127.0.0.1:8085/login")" "Visualizador de videos"
}

check_recordings(){
  section "GRAVACOES E DISCO"

  local real=""
  if [[ -L "$RECORDINGS_DIR" || -d "$RECORDINGS_DIR" ]]; then
    real="$(readlink -f "$RECORDINGS_DIR" 2>/dev/null || true)"
  fi

  [[ -n "${RECORDINGS_REAL_DIR:-}" ]] && kv "Pasta real configurada" "$RECORDINGS_REAL_DIR"
  kv "Caminho do sistema" "$RECORDINGS_DIR"
  kv "Pasta real detectada" "${real:-nao encontrada}"

  if [[ -n "$real" && -d "$real" ]]; then
    ok "Pasta de gravacoes existe"
    df -hT "$real" 2>/dev/null | awk 'NR==1 || NR==2 {print "  " $0}'

    local last_file
    last_file="$(find -L "$real" -type f \( -name '*.mkv' -o -name '*.mp4' -o -name '*.ts' \) -printf '%T@ %p %s\n' 2>/dev/null | sort -n | tail -1 || true)"
    if [[ -n "$last_file" ]]; then
      local epoch path size when
      epoch="$(awk '{print $1}' <<<"$last_file")"
      size="$(awk '{print $NF}' <<<"$last_file")"
      path="$(sed -E 's/^[^ ]+ //; s/ [0-9]+$//' <<<"$last_file")"
      when="$(date -d "@${epoch%.*}" '+%Y-%m-%d %H:%M:%S' 2>/dev/null || echo desconhecido)"
      ok "Ultima gravacao: $when"
      kv "Arquivo" "$path"
      kv "Tamanho" "$size bytes"
    else
      warn "Nenhum video encontrado na pasta de gravacoes"
    fi
  else
    fail "Pasta de gravacoes nao encontrada"
  fi
}

check_cameras(){
  section "CAMERAS"

  if [[ -f "$API_CONFIG" ]] && command -v jq >/dev/null 2>&1; then
    local active total
    total="$(jq 'length' "$API_CONFIG" 2>/dev/null || echo 0)"
    active="$(jq '[.[] | select(.active == true)] | length' "$API_CONFIG" 2>/dev/null || echo 0)"
    kv "Total configurado" "$total"
    kv "Ativas" "$active"

    jq -r 'to_entries[] | select(.value.active == true) | "  - id " + .key + ": " + (.value.name // "sem_nome") + " | gravacao=" + ((.value.rec_active // false)|tostring) + " | stream=" + (.value.stream // "")' "$API_CONFIG" 2>/dev/null || true
    [[ "$active" -gt 0 ]] && ok "Ha camera ativa" || warn "Nenhuma camera ativa"
  else
    warn "Config da API nao encontrada ou jq indisponivel: $API_CONFIG"
  fi

  if [[ -f "$GO2RTC_CONFIG" ]]; then
    echo
    echo "Go2RTC configurado:"
    sed -n '1,120p' "$GO2RTC_CONFIG" | redact
    ok "go2rtc.yaml encontrado"
  else
    fail "go2rtc.yaml nao encontrado"
  fi
}

check_retention(){
  section "RETENCAO E CRON"

  if [[ -f "$RETENTION_CONFIG" ]]; then
    ok "Config de retencao encontrada"
    sed -n '1,80p' "$RETENTION_CONFIG" | sed 's/^/  /'
  else
    warn "Config de retencao nao encontrada"
  fi

  if crontab -l -u root 2>/dev/null | grep -q 'NEXUS_NVR_RETENCAO'; then
    ok "Cron da retencao instalado"
  else
    warn "Cron da retencao nao encontrado"
  fi

  if crontab -l -u root 2>/dev/null | grep -q 'cria_pasta_camera.sh'; then
    ok "Cron de criacao de pastas instalado"
  else
    warn "Cron de criacao de pastas nao encontrado"
  fi
}

check_logs(){
  section "LOGS RECENTES"

  if ! command -v docker >/dev/null 2>&1 || ! docker info >/dev/null 2>&1; then
    warn "Docker indisponivel; pulando logs"
    return
  fi

  local containers=(nexus_api go2rtc nginx-proxy-manager_app_1)
  local c
  for c in "${containers[@]}"; do
    echo
    echo "[$c]"
    docker logs --tail 40 "$c" 2>&1 | tr '\r' '\n' | redact | tail -20 || warn "Nao consegui ler logs de $c"
  done

  local rec
  rec="$(docker ps --format '{{.Names}}' | grep '^gravador_' | head -1 || true)"
  if [[ -n "$rec" ]]; then
    echo
    echo "[$rec]"
    docker logs --tail 80 "$rec" 2>&1 \
      | tr '\r' '\n' \
      | redact \
      | grep -Ev '^(frame=|$)' \
      | tail -25 || warn "Nao consegui ler logs de $rec"
  fi
}

summary(){
  title "RESUMO"

  kv "OK" "$OK"
  kv "Avisos" "$WARN"
  kv "Falhas" "$FAIL"
  kv "Log" "$LOG_FILE"

  echo
  if (( FAIL > 0 )); then
    fail "Diagnostico encontrou falhas que precisam de correcao."
    exit 1
  fi

  if (( WARN > 0 )); then
    warn "Diagnostico concluiu com avisos. Revise os pontos acima."
    exit 0
  fi

  ok "Diagnostico concluido sem falhas."
}

main(){
  title "NEXUS NVR - DIAGNOSTICO"
  kv "Versao" "$VERSION"
  kv "Log" "$LOG_FILE"

  need_root
  load_state
  check_commands
  show_system
  show_install_config
  check_docker
  check_ports
  check_http
  check_recordings
  check_cameras
  check_retention
  check_logs
  summary
}

main "$@"
