#!/usr/bin/env bash
# ============================================================
# Nexus NVR - Backup de Configuracoes
# ============================================================

set -Eeuo pipefail

VERSION="2026-05-19-backup-1.0"
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
BACKUP_DIR="${BACKUP_DIR:-$SCRIPT_DIR/backups}"
NVR_ROOT="${NVR_ROOT:-/home/nexus}"
STATE_FILE="$NVR_ROOT/nvr_auto_state.env"
API_CONFIG="$NVR_ROOT/api/nvr_config.json"
GO2RTC_CONFIG="$NVR_ROOT/go2rtc/go2rtc.yaml"
RETENTION_CONFIG="$NVR_ROOT/retencao_nvr.conf"
COMPOSE_FILE="$NVR_ROOT/nvr-compose/docker-compose.yml"
PROXY_DIR="$NVR_ROOT/nginx/conf.d"
RECORDINGS_DIR="$NVR_ROOT/gravacoes"
LOG_FILE="/tmp/nexus_nvr_backup_$(date +%Y%m%d_%H%M%S).log"

OK=0
WARN=0
FAIL=0

green='\033[0;32m'
yellow='\033[1;33m'
red='\033[0;31m'
bold='\033[1m'
reset='\033[0m'

mkdir -p /tmp
exec > >(tee -a "$LOG_FILE") 2>&1

ok(){ OK=$((OK+1)); printf "${green}[OK]${reset} %s\n" "$*"; }
warn(){ WARN=$((WARN+1)); printf "${yellow}[AVISO]${reset} %s\n" "$*"; }
fail(){ FAIL=$((FAIL+1)); printf "${red}[FALHA]${reset} %s\n" "$*"; }
die(){ fail "$*"; summary; exit 1; }

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

kv(){ printf "  %-28s: %s\n" "$1" "$2"; }

need_root(){
  [[ "$EUID" -eq 0 ]] || die "Execute com sudo: sudo bash $0"
}

load_state(){
  PANEL_PORT="48902"
  FINAL_IP="127.0.0.1"
  RECORDINGS_REAL_DIR=""
  if [[ -f "$STATE_FILE" ]]; then
    # shellcheck disable=SC1090
    source "$STATE_FILE" || true
  fi
  PANEL_PORT="${PANEL_PORT:-48902}"
  FINAL_IP="${FINAL_IP:-127.0.0.1}"
}

http_code(){
  local url="$1"
  local host="${2:-}"
  if [[ -n "$host" ]]; then
    curl -sS --max-time 5 -o /dev/null -w '%{http_code}' -H "Host: $host" "$url" 2>/dev/null || echo 000
  else
    curl -sS --max-time 5 -o /dev/null -w '%{http_code}' "$url" 2>/dev/null || echo 000
  fi
}

require_file(){
  local file="$1"
  [[ -f "$file" ]] && ok "Arquivo encontrado: $file" || die "Arquivo obrigatorio nao encontrado: $file"
}

validate_system(){
  section "VALIDACAO ANTES DO BACKUP"

  command -v docker >/dev/null 2>&1 || die "Docker nao encontrado"
  command -v curl >/dev/null 2>&1 || die "curl nao encontrado"
  command -v tar >/dev/null 2>&1 || die "tar nao encontrado"
  command -v jq >/dev/null 2>&1 || die "jq nao encontrado"
  ok "Programas basicos encontrados"

  docker info >/dev/null 2>&1 || die "Docker nao esta respondendo"
  ok "Docker respondendo"

  local required=(go2rtc nvr-frontend visualizador_videos nexus_api nvr_proxy)
  local c status
  for c in "${required[@]}"; do
    status="$(docker inspect -f '{{.State.Status}}' "$c" 2>/dev/null || true)"
    [[ "$status" == "running" ]] && ok "Container $c rodando" || die "Container $c nao esta rodando"
  done

  if docker ps --format '{{.Names}}' | grep -q '^gravador_'; then
    ok "Motor(es) de gravacao rodando: $(docker ps --format '{{.Names}}' | grep '^gravador_' | paste -sd, -)"
  else
    warn "Nenhum motor gravador_ rodando. Backup sera feito mesmo assim."
  fi

  local code
  code="$(http_code "http://127.0.0.1:${PANEL_PORT}/" "$FINAL_IP")"
  [[ "$code" =~ ^[23] ]] && ok "Painel via proxy HTTP $code" || die "Painel via proxy falhou HTTP $code"

  code="$(http_code "http://127.0.0.1:${PANEL_PORT}/maestro/config" "$FINAL_IP")"
  [[ "$code" =~ ^[23] ]] && ok "API via proxy HTTP $code" || die "API via proxy falhou HTTP $code"

  code="$(http_code "http://127.0.0.1:1984/api/streams")"
  [[ "$code" =~ ^[23] ]] && ok "Go2RTC HTTP $code" || die "Go2RTC falhou HTTP $code"

  require_file "$STATE_FILE"
  require_file "$API_CONFIG"
  require_file "$GO2RTC_CONFIG"

  local real
  real="$(readlink -f "$RECORDINGS_DIR" 2>/dev/null || true)"
  [[ -n "$real" && -d "$real" ]] && ok "Pasta de gravacoes preservada fora do backup: $real" || warn "Pasta de gravacoes nao detectada"
}

copy_if_exists(){
  local src="$1"
  local dst="$2"
  if [[ -e "$src" ]]; then
    mkdir -p "$(dirname "$dst")"
    cp -a "$src" "$dst"
    ok "Incluido: $src"
  else
    warn "Nao encontrado, ignorado: $src"
  fi
}

create_backup(){
  section "GERANDO BACKUP"

  mkdir -p "$BACKUP_DIR"
  chmod 700 "$BACKUP_DIR" 2>/dev/null || true

  local stamp staging archive
  stamp="$(date +%Y%m%d_%H%M%S)"
  staging="$(mktemp -d /tmp/nexus_nvr_backup_staging_XXXXXX)"
  archive="$BACKUP_DIR/nexus_nvr_config_backup_${stamp}.tar.gz"

  mkdir -p "$staging"/{config,proxy,cron,meta}

  copy_if_exists "$STATE_FILE" "$staging/config/nvr_auto_state.env"
  copy_if_exists "$API_CONFIG" "$staging/config/nvr_config.json"
  copy_if_exists "$GO2RTC_CONFIG" "$staging/config/go2rtc.yaml"
  copy_if_exists "$RETENTION_CONFIG" "$staging/config/retencao_nvr.conf"
  copy_if_exists "$COMPOSE_FILE" "$staging/config/docker-compose.yml"

  if [[ -d "$PROXY_DIR" ]]; then
    cp -a "$PROXY_DIR/." "$staging/proxy/"
    ok "Incluido proxy interno do Nginx"
  else
    warn "Proxy interno nao encontrado: $PROXY_DIR"
  fi

  crontab -l -u root > "$staging/cron/root.crontab" 2>/dev/null || true
  ok "Cron root exportado"

  docker ps --format 'table {{.Names}}\t{{.Status}}\t{{.Ports}}' > "$staging/meta/docker_ps.txt" 2>/dev/null || true
  readlink -f "$RECORDINGS_DIR" > "$staging/meta/recordings_real_path.txt" 2>/dev/null || true
  date '+%Y-%m-%d %H:%M:%S %Z' > "$staging/meta/created_at.txt"

  cat > "$staging/manifest.txt" <<EOF
NEXUS_NVR_BACKUP_VERSION="$VERSION"
CREATED_AT="$(date '+%Y-%m-%d %H:%M:%S %Z')"
HOSTNAME="$(hostname)"
NVR_ROOT="$NVR_ROOT"
PANEL_PORT="${PANEL_PORT:-}"
FINAL_IP="${FINAL_IP:-}"
BACKUP_TYPE="config-only"
INCLUDES_VIDEOS="no"
EOF

  tar -C "$staging" -czf "$archive" .
  chmod 600 "$archive" 2>/dev/null || true
  rm -rf "$staging"

  ok "Backup criado"
  kv "Arquivo" "$archive"
  kv "Tamanho" "$(du -h "$archive" | awk '{print $1}')"
}

summary(){
  title "RESUMO"
  kv "OK" "$OK"
  kv "Avisos" "$WARN"
  kv "Falhas" "$FAIL"
  kv "Log" "$LOG_FILE"
}

main(){
  title "NEXUS NVR - BACKUP DE CONFIGURACOES"
  kv "Versao" "$VERSION"
  kv "Destino" "$BACKUP_DIR"
  kv "Log" "$LOG_FILE"

  need_root
  load_state
  validate_system
  create_backup
  summary
}

main "$@"
