#!/usr/bin/env bash
# ============================================================
# Nexus NVR - Restauracao de Configuracoes
# ============================================================

set -Eeuo pipefail

VERSION="2026-05-19-restaurar-1.0"
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
BACKUP_SCRIPT="$SCRIPT_DIR/NEXUSNVR_BACKUP.sh"
NVR_ROOT="${NVR_ROOT:-/home/nexus}"
STATE_FILE="$NVR_ROOT/nvr_auto_state.env"
API_CONFIG="$NVR_ROOT/api/nvr_config.json"
GO2RTC_CONFIG="$NVR_ROOT/go2rtc/go2rtc.yaml"
RETENTION_CONFIG="$NVR_ROOT/retencao_nvr.conf"
COMPOSE_FILE="$NVR_ROOT/nvr-compose/docker-compose.yml"
PROXY_DIR="$NVR_ROOT/nginx/conf.d"
RECORDINGS_DIR="$NVR_ROOT/gravacoes"
LOG_FILE="/tmp/nexus_nvr_restaurar_$(date +%Y%m%d_%H%M%S).log"

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

usage(){
  cat <<EOF
Uso:
  sudo bash $0 /caminho/backup.tar.gz

O restaurador aplica apenas configuracoes do Nexus NVR.
Ele nao restaura videos, Docker inteiro, imagens ou programas do sistema.
EOF
}

need_root(){
  [[ "$EUID" -eq 0 ]] || die "Execute com sudo: sudo bash $0 backup.tar.gz"
}

load_state(){
  PANEL_PORT="48902"
  FINAL_IP="127.0.0.1"
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

validate_installed_system(){
  section "VALIDACAO DO SISTEMA INSTALADO"

  command -v docker >/dev/null 2>&1 || die "Docker nao encontrado"
  command -v curl >/dev/null 2>&1 || die "curl nao encontrado"
  command -v jq >/dev/null 2>&1 || die "jq nao encontrado"
  command -v tar >/dev/null 2>&1 || die "tar nao encontrado"
  ok "Programas basicos encontrados"

  docker info >/dev/null 2>&1 || die "Docker nao esta respondendo"
  ok "Docker respondendo"

  local required=(go2rtc nvr-frontend visualizador_videos nexus_api nvr_proxy)
  local c status
  for c in "${required[@]}"; do
    status="$(docker inspect -f '{{.State.Status}}' "$c" 2>/dev/null || true)"
    [[ "$status" == "running" ]] && ok "Container $c rodando" || die "Container $c nao esta rodando"
  done

  local code
  code="$(http_code "http://127.0.0.1:${PANEL_PORT}/maestro/config" "$FINAL_IP")"
  [[ "$code" =~ ^[23] ]] && ok "API atual HTTP $code" || die "API atual falhou HTTP $code"

  local real
  real="$(readlink -f "$RECORDINGS_DIR" 2>/dev/null || true)"
  [[ -n "$real" && -d "$real" ]] && ok "Pasta de gravacoes detectada: $real" || warn "Pasta de gravacoes nao detectada"
}

validate_archive(){
  local archive="$1"
  section "VALIDACAO DO BACKUP"

  [[ -f "$archive" ]] || die "Backup nao encontrado: $archive"
  tar -tzf "$archive" >/dev/null || die "Arquivo de backup invalido ou corrompido"
  ok "Arquivo tar.gz valido"

  RESTORE_TMP="$(mktemp -d /tmp/nexus_nvr_restore_XXXXXX)"
  tar -xzf "$archive" -C "$RESTORE_TMP"

  [[ -f "$RESTORE_TMP/manifest.txt" ]] || die "Manifesto ausente no backup"
  [[ -f "$RESTORE_TMP/config/nvr_config.json" ]] || die "nvr_config.json ausente no backup"
  [[ -f "$RESTORE_TMP/config/go2rtc.yaml" ]] || die "go2rtc.yaml ausente no backup"

  jq empty "$RESTORE_TMP/config/nvr_config.json" >/dev/null || die "nvr_config.json do backup nao e JSON valido"
  ok "Backup contem configuracoes principais validas"

  echo
  sed -n '1,80p' "$RESTORE_TMP/manifest.txt" | sed 's/^/  /'
}

make_pre_restore_backup(){
  section "BACKUP AUTOMATICO ANTES DE RESTAURAR"

  if [[ -x "$BACKUP_SCRIPT" ]]; then
    BACKUP_DIR="$SCRIPT_DIR/backups/pre_restore" "$BACKUP_SCRIPT"
    ok "Backup automatico pre-restauracao concluido"
  else
    warn "Script de backup nao encontrado/executavel; pulando backup automatico"
  fi
}

copy_if_exists(){
  local src="$1"
  local dst="$2"
  if [[ -e "$src" ]]; then
    mkdir -p "$(dirname "$dst")"
    cp -a "$src" "$dst"
    ok "Restaurado: $dst"
  else
    warn "Item nao existe no backup: $src"
  fi
}

restore_cron_nvr_lines(){
  local backup_cron="$RESTORE_TMP/cron/root.crontab"
  local current tmp
  current="$(mktemp)"
  tmp="$(mktemp)"

  crontab -l -u root > "$current" 2>/dev/null || true
  grep -v 'NEXUS_NVR_RETENCAO' "$current" | grep -v 'cria_pasta_camera.sh' > "$tmp" || true

  if [[ -f "$backup_cron" ]]; then
    grep 'NEXUS_NVR_RETENCAO\|cria_pasta_camera.sh' "$backup_cron" >> "$tmp" || true
  fi

  awk 'NF && !seen[$0]++' "$tmp" | crontab -u root -
  rm -f "$current" "$tmp"
  ok "Cron do Nexus NVR restaurado sem sobrescrever tarefas externas"
}

apply_files(){
  section "APLICANDO CONFIGURACOES"

  copy_if_exists "$RESTORE_TMP/config/nvr_auto_state.env" "$STATE_FILE"
  copy_if_exists "$RESTORE_TMP/config/nvr_config.json" "$API_CONFIG"
  copy_if_exists "$RESTORE_TMP/config/go2rtc.yaml" "$GO2RTC_CONFIG"
  copy_if_exists "$RESTORE_TMP/config/retencao_nvr.conf" "$RETENTION_CONFIG"
  copy_if_exists "$RESTORE_TMP/config/docker-compose.yml" "$COMPOSE_FILE"

  if [[ -d "$RESTORE_TMP/proxy" ]]; then
    mkdir -p "$PROXY_DIR"
    cp -a "$RESTORE_TMP/proxy/." "$PROXY_DIR/"
    ok "Proxy interno restaurado"
  else
    warn "Backup sem pasta proxy"
  fi

  chmod 600 "$STATE_FILE" "$API_CONFIG" "$RETENTION_CONFIG" 2>/dev/null || true
  restore_cron_nvr_lines
}

restart_services(){
  section "REINICIANDO SERVICOS"

  docker restart nexus_api go2rtc >/dev/null
  ok "API e Go2RTC reiniciados"

  if docker exec nvr_proxy nginx -t >/dev/null 2>&1; then
    docker exec nvr_proxy nginx -s reload >/dev/null 2>&1 || true
    ok "Nginx recarregado"
  else
    warn "Nginx nao aceitou teste agora"
  fi

  sleep 3
  load_state
}

reapply_cameras(){
  section "RECRIANDO MOTORES DAS CAMERAS"

  local active_count
  active_count="$(jq '[.[] | select(.active == true)] | length' "$API_CONFIG")"
  kv "Cameras ativas" "$active_count"

  if [[ "$active_count" -eq 0 ]]; then
    warn "Nenhuma camera ativa para recriar"
    return
  fi

  jq -c 'to_entries[] | select(.value.active == true) | {id:.key, oldName:.value.name, config:.value}' "$API_CONFIG" |
  while read -r payload; do
    local name code body tmp_body
    name="$(jq -r '.config.name' <<<"$payload")"
    tmp_body="$(mktemp)"
    code="$(curl -sS --max-time 60 -o "$tmp_body" -w '%{http_code}' \
      -H 'Content-Type: application/json' \
      --data "$payload" \
      http://127.0.0.1:3000/maestro/save-cam 2>/dev/null || echo 000)"
    body="$(cat "$tmp_body")"
    rm -f "$tmp_body"

    if [[ "$code" =~ ^[23] ]]; then
      ok "Camera $name reaplicada"
    else
      fail "Falha ao reaplicar camera $name HTTP $code: $body"
      return 1
    fi
  done
}

validate_after_restore(){
  section "VALIDACAO APOS RESTAURAR"

  local required=(go2rtc nvr-frontend visualizador_videos nexus_api nvr_proxy)
  local c status
  for c in "${required[@]}"; do
    status="$(docker inspect -f '{{.State.Status}}' "$c" 2>/dev/null || true)"
    [[ "$status" == "running" ]] && ok "Container $c rodando" || die "Container $c nao esta rodando apos restauracao"
  done

  local code
  code="$(http_code "http://127.0.0.1:${PANEL_PORT}/" "$FINAL_IP")"
  [[ "$code" =~ ^[23] ]] && ok "Painel HTTP $code" || die "Painel falhou HTTP $code"

  code="$(http_code "http://127.0.0.1:${PANEL_PORT}/maestro/config" "$FINAL_IP")"
  [[ "$code" =~ ^[23] ]] && ok "API via proxy HTTP $code" || die "API via proxy falhou HTTP $code"

  code="$(http_code "http://127.0.0.1:1984/api/streams")"
  [[ "$code" =~ ^[23] ]] && ok "Go2RTC HTTP $code" || die "Go2RTC falhou HTTP $code"

  if docker ps --format '{{.Names}}' | grep -q '^gravador_'; then
    ok "Motor(es) de gravacao rodando: $(docker ps --format '{{.Names}}' | grep '^gravador_' | paste -sd, -)"
  else
    warn "Nenhum motor gravador_ rodando apos restauracao"
  fi
}

summary(){
  title "RESUMO"
  kv "OK" "$OK"
  kv "Avisos" "$WARN"
  kv "Falhas" "$FAIL"
  kv "Log" "$LOG_FILE"
}

main(){
  title "NEXUS NVR - RESTAURAR CONFIGURACOES"
  kv "Versao" "$VERSION"
  kv "Log" "$LOG_FILE"

  local archive="${1:-}"
  if [[ -z "$archive" ]]; then
    usage
    exit 1
  fi

  need_root
  load_state
  validate_installed_system
  validate_archive "$archive"
  make_pre_restore_backup
  apply_files
  restart_services
  reapply_cameras
  validate_after_restore

  rm -rf "${RESTORE_TMP:-}"
  summary
}

main "$@"
