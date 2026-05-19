#!/usr/bin/env bash
# ============================================================
# Nexus NVR - Limpeza e Remocao
# ============================================================

set -Eeuo pipefail

VERSION="2026-05-19-limpeza-2.1-modos"
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
NVR_ROOT="${NVR_ROOT:-/home/nexus}"
STATE_FILE="$NVR_ROOT/nvr_auto_state.env"
COMPOSE_DIR="$NVR_ROOT/nvr-compose"
COMPOSE_FILE="$COMPOSE_DIR/docker-compose.yml"
RECORDINGS_SYSTEM_DIR="$NVR_ROOT/gravacoes"
PRESERVE_ROOT="${PRESERVE_ROOT:-$SCRIPT_DIR/preservados}"
LOG_FILE="/tmp/nexus_nvr_limpeza_$(date +%Y%m%d_%H%M%S).log"

OK=0
WARN=0
FAIL=0
CHANGED=0

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

kv(){ printf "  %-30s: %s\n" "$1" "$2"; }

need_root(){
  if [[ "$EUID" -ne 0 ]]; then
    fail "Execute com sudo: sudo bash $0"
    exit 1
  fi
}

cmd_exists(){
  command -v "$1" >/dev/null 2>&1
}

load_state(){
  FINAL_IP=""
  PANEL_PORT=""
  NETWORK_MODE=""
  EXTERNAL_HOST=""
  EXTERNAL_PORT=""
  RECORDINGS_REAL_DIR=""
  RECORDINGS_SYSTEM_DIR_STATE=""

  if [[ -f "$STATE_FILE" ]]; then
    # shellcheck disable=SC1090
    source "$STATE_FILE" 2>/dev/null || true
  fi

  PANEL_PORT="${PANEL_PORT:-48902}"
  RECORDINGS_SYSTEM_DIR="${RECORDINGS_SYSTEM_DIR_STATE:-${RECORDINGS_SYSTEM_DIR:-$NVR_ROOT/gravacoes}}"
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

confirm_text(){
  local prompt="$1"
  local expected="$2"
  local ans=""
  echo
  warn "$prompt"
  read -r -p "Digite exatamente ${expected} para confirmar: " ans || true
  [[ "$ans" == "$expected" ]]
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

nvr_container_names(){
  if ! cmd_exists docker; then return 0; fi
  {
    for name in nexus_api go2rtc nvr-frontend visualizador_videos nvr_proxy nginx-proxy-manager_app_1; do
      docker ps -a --format '{{.Names}}' 2>/dev/null | grep -Fx "$name" || true
    done
    docker ps -a --format '{{.Names}}' 2>/dev/null | grep -E '^gravador_' || true
  } | sort -u
}

non_nvr_container_names(){
  if ! cmd_exists docker; then return 0; fi
  local all nvr
  all="$(docker ps -a --format '{{.Names}}' 2>/dev/null | sort -u || true)"
  nvr="$(nvr_container_names || true)"
  [[ -z "$all" ]] && return 0
  comm -23 <(echo "$all") <(echo "$nvr" | sort -u)
}

docker_non_nvr_networks(){
  if ! cmd_exists docker; then return 0; fi
  docker network ls --format '{{.Name}}' 2>/dev/null \
    | grep -Ev '^(bridge|host|none|nvr-compose_default)$' \
    | sort -u || true
}

docker_non_nvr_volumes(){
  if ! cmd_exists docker; then return 0; fi
  docker volume ls -q 2>/dev/null \
    | grep -Ev '^(nvr|nexus)' \
    | sort -u || true
}

pause_enter(){
  local msg="${1:-Pressione Enter para continuar...}"
  read -r -p "$msg" _ || true
}

detect_recordings_real(){
  load_state

  if [[ -n "${RECORDINGS_REAL_DIR:-}" && -e "$RECORDINGS_REAL_DIR" ]]; then
    readlink -f "$RECORDINGS_REAL_DIR" 2>/dev/null || echo "$RECORDINGS_REAL_DIR"
    return 0
  fi

  if [[ -L "$RECORDINGS_SYSTEM_DIR" || -d "$RECORDINGS_SYSTEM_DIR" ]]; then
    readlink -f "$RECORDINGS_SYSTEM_DIR" 2>/dev/null || true
    return 0
  fi

  local candidate
  for candidate in /dados/nexus/gravacoes /data/nexus/gravacoes /srv/nexus/gravacoes /mnt/*/nexus/gravacoes /media/*/nexus/gravacoes; do
    if [[ -d "$candidate" ]]; then
      readlink -f "$candidate" 2>/dev/null || echo "$candidate"
      return 0
    fi
  done

  return 1
}

safe_nvr_path(){
  local p="$1"
  [[ -n "$p" ]] || return 1

  case "$p" in
    "$NVR_ROOT"|"$NVR_ROOT"/*|/tmp/nexus_nvr_*.log|/tmp/nexus_nvr_auto_*.log) return 0 ;;
    *) return 1 ;;
  esac
}

safe_recordings_path(){
  local p="$1"
  [[ -n "$p" ]] || return 1

  case "$p" in
    "/"|"/home"|"/root"|"/etc"|"/usr"|"/var"|"/opt"|"/tmp"|"/srv"|"/mnt"|"/media"|"/dados"|"/data"|"/DADOS")
      return 1
      ;;
  esac

  case "$p" in
    "$NVR_ROOT/gravacoes"|"$NVR_ROOT/gravacoes/"*) return 0 ;;
    */nexus/gravacoes|*/nexus/gravacoes/*) return 0 ;;
    *) return 1 ;;
  esac
}

remove_path(){
  local p="$1"
  if [[ -e "$p" || -L "$p" ]]; then
    if safe_nvr_path "$p"; then
      rm -rf -- "$p"
      CHANGED=$((CHANGED+1))
      ok "Removido: $p"
    else
      fail "Bloqueado por seguranca: $p"
      return 1
    fi
  fi
}

show_status(){
  load_state

  title "STATUS DO NEXUS NVR"
  kv "Versao do script" "$VERSION"
  kv "Raiz do sistema" "$NVR_ROOT"
  kv "Arquivo de estado" "$STATE_FILE"
  kv "Modo de rede" "$(network_mode_label "$NETWORK_MODE")"
  kv "IP local final" "${FINAL_IP:-nao informado}"
  kv "Porta" "${PANEL_PORT:-nao informada}"
  [[ -n "${EXTERNAL_HOST:-}" ]] && kv "Acesso externo" "${EXTERNAL_HOST}:${EXTERNAL_PORT:-$PANEL_PORT}" || kv "Acesso externo" "nao configurado"
  kv "Log desta execucao" "$LOG_FILE"

  section "ARQUIVOS"
  local paths=(
    "$NVR_ROOT"
    "$STATE_FILE"
    "$COMPOSE_FILE"
    "$NVR_ROOT/api"
    "$NVR_ROOT/go2rtc"
    "$NVR_ROOT/nvr-web"
    "$NVR_ROOT/nginx"
    "$NVR_ROOT/nginx-proxy-manager"
    "$NVR_ROOT/filebrowser_config"
    "$NVR_ROOT/filebrowser_db"
    "$NVR_ROOT/cron"
    "$NVR_ROOT/cria_pasta_camera.sh"
  )

  local any=0 p
  for p in "${paths[@]}"; do
    if [[ -e "$p" || -L "$p" ]]; then
      ls -ld "$p" 2>/dev/null || true
      any=1
    fi
  done
  [[ "$any" -eq 0 ]] && info "Nenhum arquivo principal do NVR encontrado."

  section "GRAVACOES"
  local rec
  rec="$(detect_recordings_real 2>/dev/null || true)"
  kv "Caminho do sistema" "$RECORDINGS_SYSTEM_DIR"
  kv "Pasta real detectada" "${rec:-nenhuma}"
  if [[ -n "$rec" && -d "$rec" ]]; then
    [[ -L "$RECORDINGS_SYSTEM_DIR" ]] && kv "Link" "$RECORDINGS_SYSTEM_DIR -> $(readlink "$RECORDINGS_SYSTEM_DIR" 2>/dev/null || true)"
    du -sh "$rec" 2>/dev/null | awk '{printf "  %-30s: %s\n", "Uso", $1}'
    find -L "$rec" -type f 2>/dev/null | wc -l | awk '{printf "  %-30s: %s\n", "Arquivos", $1}'
  fi

  section "CONTAINERS DO NVR"
  if cmd_exists docker && docker info >/dev/null 2>&1; then
    local nvr
    nvr="$(nvr_container_names || true)"
    if [[ -n "$nvr" ]]; then
      printf "  %-32s %-24s %s\n" "NOME" "STATUS" "PORTAS"
      while read -r c; do
        [[ -z "$c" ]] && continue
        local status ports
        status="$(docker inspect -f '{{.State.Status}}' "$c" 2>/dev/null || echo desconhecido)"
        ports="$(docker port "$c" 2>/dev/null | paste -sd, - || true)"
        printf "  %-32s %-24s %s\n" "$c" "$status" "${ports:-sem portas publicadas}"
      done <<< "$nvr"
    else
      info "Nenhum container do NVR encontrado."
    fi

    section "CONTAINERS DE OUTROS SISTEMAS"
    local others
    others="$(non_nvr_container_names || true)"
    if [[ -n "$others" ]]; then
      printf "  %-32s %-24s %s\n" "NOME" "STATUS" "PORTAS"
      while read -r c; do
        [[ -z "$c" ]] && continue
        local status ports
        status="$(docker inspect -f '{{.State.Status}}' "$c" 2>/dev/null || echo desconhecido)"
        ports="$(docker port "$c" 2>/dev/null | paste -sd, - || true)"
        printf "  %-32s %-24s %s\n" "$c" "$status" "${ports:-sem portas publicadas}"
      done <<< "$others"
    else
      info "Nenhum container externo encontrado."
    fi
  else
    warn "Docker nao encontrado ou nao respondendo."
  fi

  section "DEPENDENCIAS GLOBAIS"
  cmd_exists docker && kv "Docker" "instalado" || kv "Docker" "nao encontrado"
  cmd_exists node && kv "Node.js" "$(node -v 2>/dev/null || echo instalado)" || kv "Node.js" "nao encontrado"
  cmd_exists npm && kv "npm" "$(npm -v 2>/dev/null || echo instalado)" || kv "npm" "nao encontrado"

  section "CRON DO NVR"
  crontab -l -u root 2>/dev/null | grep -E 'NEXUS_NVR_RETENCAO|NEXUS_NVR_CRIAR_PASTAS|/home/nexus/cria_pasta_camera.sh|/home/nexus/cron/' || info "Nenhuma linha de cron do NVR encontrada."
}

remove_containers(){
  section "REMOVENDO CONTAINERS DO NVR"

  if ! cmd_exists docker || ! docker info >/dev/null 2>&1; then
    warn "Docker nao encontrado ou nao respondendo."
    return 0
  fi

  local containers
  containers="$(nvr_container_names || true)"
  if [[ -z "$containers" ]]; then
    warn "Nenhum container do NVR encontrado."
    return 0
  fi

  while read -r c; do
    [[ -z "$c" ]] && continue
    docker rm -f "$c" >/dev/null 2>&1 || true
    CHANGED=$((CHANGED+1))
    ok "Container removido: $c"
  done <<< "$containers"
}

remove_networks(){
  section "REMOVENDO REDES DO NVR"

  if ! cmd_exists docker || ! docker info >/dev/null 2>&1; then
    warn "Docker nao encontrado ou nao respondendo."
    return 0
  fi

  local net
  for net in nvr-compose_default; do
    if docker network inspect "$net" >/dev/null 2>&1; then
      docker network rm "$net" >/dev/null 2>&1 || true
      CHANGED=$((CHANGED+1))
      ok "Rede removida: $net"
    else
      info "Rede nao encontrada: $net"
    fi
  done
}

remove_cron(){
  section "REMOVENDO CRON DO NVR"

  local before after
  before="$(mktemp)"
  after="$(mktemp)"

  if crontab -l -u root > "$before" 2>/dev/null; then
    grep -vE 'NEXUS_NVR_RETENCAO|NEXUS_NVR_CRIAR_PASTAS|/home/nexus/cria_pasta_camera.sh|/home/nexus/cron/' "$before" > "$after" || true
    crontab -u root "$after"
    CHANGED=$((CHANGED+1))
    ok "Linhas de cron do NVR removidas."
  else
    warn "Root sem crontab ou sem permissao para ler."
  fi

  rm -f "$before" "$after"
}

remove_temp_logs(){
  section "REMOVENDO LOGS TEMPORARIOS DO NVR"

  local found=0 f
  shopt -s nullglob
  for f in /tmp/nexus_nvr_auto_*.log /tmp/nexus_nvr_backup_*.log /tmp/nexus_nvr_restaurar_*.log /tmp/nexus_nvr_diagnostico_*.log /tmp/nexus_nvr_limpeza_*.log; do
    [[ "$f" == "$LOG_FILE" ]] && continue
    rm -f -- "$f"
    found=1
  done
  shopt -u nullglob

  [[ "$found" -eq 1 ]] && ok "Logs temporarios antigos removidos." || info "Nenhum log temporario antigo encontrado."
}

remove_docker_if_safe(){
  section "REMOCAO OPCIONAL DO DOCKER"

  if ! cmd_exists docker; then
    warn "Docker nao encontrado."
    return 0
  fi

  if ! yes_no "Deseja remover Docker/containerd se nao houver uso por outros servicos?" "N"; then
    ok "Docker mantido."
    return 0
  fi

  local others networks volumes blockers=0
  others="$(non_nvr_container_names || true)"
  networks="$(docker_non_nvr_networks || true)"
  volumes="$(docker_non_nvr_volumes || true)"

  if [[ -n "$others" ]]; then
    warn "Docker nao sera removido porque existem containers que nao sao do Nexus NVR:"
    echo "$others" | sed 's/^/  - /'
    blockers=1
  fi

  if [[ -n "$networks" ]]; then
    warn "Docker nao sera removido porque existem redes Docker externas ao Nexus NVR:"
    echo "$networks" | sed 's/^/  - /'
    blockers=1
  fi

  if [[ -n "$volumes" ]]; then
    warn "Docker nao sera removido porque existem volumes Docker externos ao Nexus NVR:"
    echo "$volumes" | sed 's/^/  - /'
    blockers=1
  fi

  if [[ "$blockers" -eq 1 ]]; then
    pause_enter "Docker foi preservado. Pressione Enter para continuar..."
    return 0
  fi

  confirm_text "Nenhum uso externo do Docker foi detectado. Confirma remover Docker/containerd do servidor?" "REMOVER DOCKER" || {
    warn "Remocao do Docker cancelada."
    return 0
  }

  systemctl stop docker 2>/dev/null || true
  systemctl stop containerd 2>/dev/null || true

  if cmd_exists apt-get; then
    export DEBIAN_FRONTEND=noninteractive
    apt-get purge -y docker.io docker-compose docker-compose-plugin docker-ce docker-ce-cli docker-buildx-plugin containerd containerd.io runc 2>/dev/null || true
    apt-get autoremove -y 2>/dev/null || true
    apt-get autoclean -y 2>/dev/null || true
    CHANGED=$((CHANGED+1))
    ok "Pacotes Docker/containerd removidos quando existiam."
  else
    warn "apt-get nao encontrado; nao removi pacotes Docker."
  fi

  rm -rf /var/lib/docker /var/lib/containerd /etc/docker 2>/dev/null || true
  ok "Dados globais do Docker removidos."
}

remove_node_if_safe(){
  section "REMOCAO OPCIONAL DO NODE/NPM"

  if ! cmd_exists node && ! cmd_exists npm; then
    warn "Node/npm nao encontrados."
    return 0
  fi

  if ! yes_no "Deseja remover Node/npm do host se nao houver indicio de uso externo?" "N"; then
    ok "Node/npm mantidos."
    return 0
  fi

  local blockers=0
  if pgrep -af 'node|npm' 2>/dev/null | grep -vE 'NEXUSNVR_LIMPEZA|grep|/home/nexus|nexus_api' >/tmp/nexus_node_processes.$$; then
    warn "Node/npm nao sera removido porque existem processos Node fora do Nexus NVR:"
    sed 's/^/  - /' /tmp/nexus_node_processes.$$
    blockers=1
  fi
  rm -f /tmp/nexus_node_processes.$$

  if find /etc/systemd/system /lib/systemd/system -maxdepth 1 -type f 2>/dev/null | xargs grep -IlE 'node|npm' 2>/dev/null | grep -vEi 'nexus|nvr' >/tmp/nexus_node_services.$$; then
    warn "Node/npm nao sera removido porque existem servicos systemd que parecem usar Node:"
    sed 's/^/  - /' /tmp/nexus_node_services.$$
    blockers=1
  fi
  rm -f /tmp/nexus_node_services.$$

  if [[ "$blockers" -eq 1 ]]; then
    pause_enter "Node/npm foram preservados. Pressione Enter para continuar..."
    return 0
  fi

  confirm_text "Nenhum uso externo de Node/npm foi detectado. Confirma remover Node/npm do servidor?" "REMOVER NODE" || {
    warn "Remocao de Node/npm cancelada."
    return 0
  }

  if cmd_exists apt-get; then
    export DEBIAN_FRONTEND=noninteractive
    apt-get purge -y nodejs npm 2>/dev/null || true
    apt-get autoremove -y 2>/dev/null || true
    apt-get autoclean -y 2>/dev/null || true
    CHANGED=$((CHANGED+1))
    ok "Node/npm removidos quando existiam."
  else
    warn "apt-get nao encontrado; nao removi Node/npm."
  fi
}

preserve_recordings(){
  local rec="$1"
  [[ -n "$rec" && -d "$rec" ]] || return 0

  if [[ "$rec" == "$NVR_ROOT"/* ]]; then
    mkdir -p "$PRESERVE_ROOT"
    chmod 700 "$PRESERVE_ROOT" 2>/dev/null || true
    local dest="$PRESERVE_ROOT/gravacoes_$(date +%Y%m%d_%H%M%S)"
    mv "$rec" "$dest"
    CHANGED=$((CHANGED+1))
    ok "Gravacoes preservadas em: $dest"
  else
    ok "Gravacoes externas preservadas em: $rec"
    if [[ -L "$RECORDINGS_SYSTEM_DIR" ]]; then
      rm -f "$RECORDINGS_SYSTEM_DIR"
      CHANGED=$((CHANGED+1))
      ok "Link do sistema removido: $RECORDINGS_SYSTEM_DIR"
    fi
  fi
}

delete_recordings(){
  local rec="$1"
  [[ -n "$rec" && -e "$rec" ]] || {
    warn "Nenhuma pasta real de gravacoes encontrada."
    return 0
  }

  if ! safe_recordings_path "$rec"; then
    fail "Bloqueado: caminho de gravacoes nao parece seguro para apagar: $rec"
    return 1
  fi

  rm -rf -- "$rec"
  CHANGED=$((CHANGED+1))
  ok "Gravacoes removidas: $rec"

  if [[ -L "$RECORDINGS_SYSTEM_DIR" ]]; then
    rm -f "$RECORDINGS_SYSTEM_DIR"
    ok "Link do sistema removido: $RECORDINGS_SYSTEM_DIR"
  fi
}

remove_files(){
  local recordings_policy="$1"
  section "REMOVENDO ARQUIVOS DO NVR"

  local rec
  rec="$(detect_recordings_real 2>/dev/null || true)"

  case "$recordings_policy" in
    keep) preserve_recordings "$rec" ;;
    delete) delete_recordings "$rec" ;;
    none) info "Gravacoes nao serao alteradas nesta operacao." ;;
  esac

  if [[ -e "$NVR_ROOT" || -L "$NVR_ROOT" ]]; then
    remove_path "$NVR_ROOT"
  else
    warn "Pasta $NVR_ROOT nao existe."
  fi
}

remove_state_only(){
  section "REMOVENDO STATE/CONTINUACAO"

  local found=0
  if [[ -f "$STATE_FILE" ]]; then
    rm -f "$STATE_FILE"
    found=1
    CHANGED=$((CHANGED+1))
    ok "Removido: $STATE_FILE"
  fi

  if [[ -d "$NVR_ROOT" ]]; then
    while IFS= read -r f; do
      [[ -z "$f" ]] && continue
      if safe_nvr_path "$f"; then
        rm -f "$f"
        found=1
        CHANGED=$((CHANGED+1))
        ok "Removido: $f"
      fi
    done < <(find "$NVR_ROOT" -maxdepth 2 -type f \( -iname '*state*.env' -o -iname '*continuacao*.env' -o -iname '*resume*.env' \) 2>/dev/null)
  fi

  if [[ "$found" -eq 0 ]]; then
    warn "Nenhum arquivo state/continuacao encontrado."
  fi
  return 0
}

post_summary(){
  title "RESUMO DA LIMPEZA"
  kv "OK" "$OK"
  kv "Avisos" "$WARN"
  kv "Falhas" "$FAIL"
  kv "Alteracoes feitas" "$CHANGED"
  kv "Log" "$LOG_FILE"
}

mode_complete(){
  title "LIMPEZA COMPLETA"
  warn "Remove o Nexus NVR inteiro."
  warn "Pergunta se deve apagar videos."
  warn "Pergunta se deve remover Docker/Node, mas so remove se nao detectar uso externo."
  show_status

  confirm_text "Confirma iniciar a limpeza completa do Nexus NVR?" "LIMPEZA COMPLETA" || {
    warn "Operacao cancelada."
    return 0
  }

  local recordings_policy="keep"
  if yes_no "Deseja apagar os videos gravados do Nexus NVR?" "N"; then
    recordings_policy="delete"
  else
    recordings_policy="keep"
  fi

  remove_containers
  remove_networks
  remove_cron
  remove_state_only
  remove_files "$recordings_policy"
  remove_temp_logs
  remove_docker_if_safe
  remove_node_if_safe
  post_summary
}

mode_standard(){
  title "REMOVER NVR MANTENDO VIDEOS E DOCKER"
  warn "Remove containers, redes, cron, logs, state e arquivos do Nexus NVR."
  warn "Mantem videos, Docker, Node/npm e qualquer outro servico do servidor."
  show_status

  confirm_text "Confirma remover o Nexus NVR mantendo videos e Docker?" "REMOVER NVR" || {
    warn "Operacao cancelada."
    return 0
  }

  remove_containers
  remove_networks
  remove_cron
  remove_state_only
  remove_files "keep"
  remove_temp_logs
  post_summary
}

mode_residue(){
  title "REMOVER RESIDUOS SEM MEXER NOS VIDEOS"
  warn "Remove containers, redes, cron, logs e state. Nao remove a pasta /home/nexus nem videos."
  show_status

  confirm_text "Confirma remover apenas residuos do Nexus NVR?" "REMOVER RESIDUOS" || {
    warn "Operacao cancelada."
    return 0
  }

  remove_containers
  remove_networks
  remove_cron
  remove_state_only
  remove_temp_logs
  post_summary
}

mode_state(){
  title "REMOVER APENAS STATE"
  warn "Remove apenas arquivos de continuacao/state do instalador."
  confirm_text "Confirma remover apenas state/continuacao?" "REMOVER STATE" || {
    warn "Operacao cancelada."
    return 0
  }
  remove_state_only
  post_summary
}

menu(){
  while true; do
    title "NEXUS NVR - LIMPEZA E REMOCAO"
    echo "0) Ver status / analisar"
    echo "1) Limpeza completa"
    echo "2) Remover NVR mantendo videos e Docker"
    echo "3) Remover residuos sem mexer nos videos"
    echo "4) Remover apenas state/continuacao"
    echo "5) Sair"
    echo
    echo "Modo 1 pode remover Docker/Node somente se nao houver uso externo detectado."
    echo "Nenhum modo remove Ubuntu, APK ou /DADOS."
    echo
    read -r -p "Escolha uma opcao: " opt || true

    case "${opt:-}" in
      0) show_status ;;
      1) mode_complete ;;
      2) mode_standard ;;
      3) mode_residue ;;
      4) mode_state ;;
      5) echo "Saindo."; exit 0 ;;
      *) warn "Opcao invalida." ;;
    esac

    echo
    read -r -p "Pressione Enter para voltar ao menu..." _ || true
  done
}

main(){
  need_root
  load_state
  menu
}

main "$@"
