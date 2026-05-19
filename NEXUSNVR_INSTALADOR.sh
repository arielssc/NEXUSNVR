#!/usr/bin/env bash
# Nexus NVR Auto Installer / Verificador / Reparador
# Coloque este arquivo na mesma pasta da pasta "nexus_nvr_pacote".
# Execute: sudo bash NEXUSNVR_INSTALADOR.sh

set -uo pipefail

VERSION="2026-05-19-publico-10.13-pacote-nvr"
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PACKAGE_DIR="${SCRIPT_DIR}/nexus_nvr_pacote"
TARGET="/home/nexus"
COMPOSE_DIR="${TARGET}/nvr-compose"
COMPOSE_FILE="${COMPOSE_DIR}/docker-compose.yml"
STATE_FILE="${TARGET}/nvr_auto_state.env"
LOG_FILE="/tmp/nexus_nvr_auto_$(date +%Y%m%d_%H%M%S).log"

DEFAULT_FINAL_LAST="27"
DEFAULT_PANEL_PORT="48902"
DEFAULT_TZ="America/Sao_Paulo"
DEFAULT_NETWORK_MODE="hybrid"
DEFAULT_NPM_EMAIL="admin@nexusnvr.local"
DEFAULT_NPM_PASS="nexusnvr1234"
DEFAULT_FB_USER="nexusnvr"
DEFAULT_FB_PASS="nexusnvr1234"

OK=0
WARN=0
FAIL=0
FIX=0
IP_APPLIED="0"

RUN_USER="${SUDO_USER:-$(logname 2>/dev/null || echo root)}"

mkdir -p /tmp
exec > >(tee -a "$LOG_FILE") 2>&1

ok(){ OK=$((OK+1)); echo "[OK] $*"; }
warn(){ WARN=$((WARN+1)); echo "[AVISO] $*"; }
fail(){ FAIL=$((FAIL+1)); echo "[FALHA] $*"; }
fix(){ FIX=$((FIX+1)); echo "[CORRIGIDO] $*"; }
die(){ echo; echo "[ERRO CRITICO] $*"; echo "Log: $LOG_FILE"; exit 1; }
sec(){ echo; echo "============================================================"; echo ">>> $*"; echo "============================================================"; }

need_root(){
  sec "Inicializando"
  [[ "$EUID" -eq 0 ]] || die "Rode com sudo: sudo bash $(basename "$0")"
  ok "Rodando como root/sudo"
  echo "Versão: $VERSION"
  echo "Log: $LOG_FILE"
}

detect_network(){
  sec "Detectando rede"
  IFACE="$(ip route | awk '/default/ {print $5; exit}')"
  GATEWAY="$(ip route | awk '/default/ {print $3; exit}')"
  CURRENT_IP="$(ip -4 -o addr show scope global | awk -v dev="$IFACE" '$2==dev {split($4,a,"/"); print a[1]; exit}')"
  PREFIX="$(ip -4 -o addr show scope global | awk -v dev="$IFACE" '$2==dev {split($4,a,"/"); print a[2]; exit}')"
  PREFIX="${PREFIX:-24}"

  [[ -n "$IFACE" ]] || die "Não detectei interface padrão."
  [[ -n "$GATEWAY" ]] || die "Não detectei gateway."
  [[ -n "$CURRENT_IP" ]] || die "Não detectei IP atual."

  BASE3="$(echo "$GATEWAY" | awk -F. '{print $1"."$2"."$3}')"
  IS_WIFI="0"
  [[ -d "/sys/class/net/${IFACE}/wireless" ]] && IS_WIFI="1"

  ok "Interface: $IFACE"
  ok "IP atual: $CURRENT_IP/$PREFIX"
  ok "Gateway: $GATEWAY"
  ok "Rede sugerida: ${BASE3}.x"
  [[ "$IS_WIFI" == "1" ]] && ok "Tipo: Wi-Fi" || ok "Tipo: Ethernet/cabo"
}

load_state_if_final(){
  FINAL_VERIFY_ONLY="0"
  if [[ -f "$STATE_FILE" ]]; then
    # shellcheck disable=SC1090
    source "$STATE_FILE" || true
    if [[ -n "${FINAL_IP:-}" && "$CURRENT_IP" == "$FINAL_IP" ]]; then
      echo "Estado anterior detectado. IP atual já é o IP final escolhido: $FINAL_IP"
      read -r -p "Fazer verificação final usando configuração salva? [S/n]: " ans
      case "$ans" in
        n|N) FINAL_VERIFY_ONLY="0" ;;
        *) FINAL_VERIFY_ONLY="1" ;;
      esac
    fi
  fi
}

confirm_param(){
  local label="$1"
  local value="$2"
  local ans=""

  while true; do
    read -r -p "Confirmar ${label}: ${value} ? [s/N]: " ans
    case "$ans" in
      s|S|sim|SIM|Sim) return 0 ;;
      n|N|nao|não|NAO|NÃO|"") return 1 ;;
      *) echo "Responda s ou n." ;;
    esac
  done
}

valid_port(){
  local p="$1"
  [[ "$p" =~ ^[0-9]+$ ]] && [[ "$p" -ge 1 ]] && [[ "$p" -le 65535 ]]
}

valid_ip_last(){
  local p="$1"
  [[ "$p" =~ ^[0-9]+$ ]] && [[ "$p" -ge 2 ]] && [[ "$p" -le 254 ]]
}

network_mode_label(){
  case "${1:-}" in
    local) echo "Apenas local" ;;
    external) echo "Apenas VPS/internet" ;;
    hybrid) echo "Local + internet" ;;
    *) echo "${1:-desconhecido}" ;;
  esac
}

build_webrtc_candidates(){
  local candidates=()

  case "${NETWORK_MODE:-hybrid}" in
    local)
      candidates+=("${FINAL_IP}:${PANEL_PORT}")
      ;;
    external)
      [[ -n "${EXTERNAL_HOST:-}" ]] && candidates+=("${EXTERNAL_HOST}:${EXTERNAL_PORT}")
      ;;
    hybrid|*)
      [[ -n "${EXTERNAL_HOST:-}" ]] && candidates+=("${EXTERNAL_HOST}:${EXTERNAL_PORT}")
      candidates+=("${FINAL_IP}:${PANEL_PORT}")
      ;;
  esac

  printf "%s\n" "${candidates[@]}" | awk 'NF && !seen[$0]++' | paste -sd, -
}

detect_recording_storage_options(){
  STORAGE_TARGETS=()
  STORAGE_TYPES=()
  STORAGE_SIZES=()
  STORAGE_AVAILS=()
  STORAGE_PATHS=()

  while read -r src fstype size used avail usep target; do
    [[ -z "${target:-}" ]] && continue

    case "$fstype" in
      tmpfs|devtmpfs|squashfs|overlay|proc|sysfs|cgroup|cgroup2|securityfs|pstore|efivarfs|tracefs|debugfs|configfs|fusectl|ramfs|autofs|rpc_pipefs)
        continue
        ;;
    esac

    case "$target" in
      /|/home|/dados|/data|/srv|/mnt/*|/media/*)
        ;;
      *)
        continue
        ;;
    esac

    case "$target" in
      /boot*|/run*|/dev*|/proc*|/sys*|/snap*|/var/lib/docker*|/var/snap*)
        continue
        ;;
    esac

    local rec_path
    if [[ "$target" == "/" || "$target" == "/home" ]]; then
      rec_path="/home/nexus/gravacoes"
    else
      rec_path="${target%/}/nexus/gravacoes"
    fi

    STORAGE_TARGETS+=("$target")
    STORAGE_TYPES+=("$fstype")
    STORAGE_SIZES+=("$size")
    STORAGE_AVAILS+=("$avail")
    STORAGE_PATHS+=("$rec_path")
  done < <(df -hPT | awk 'NR>1 {print $1, $2, $3, $4, $5, $6, $7}')

  if [[ "${#STORAGE_TARGETS[@]}" -eq 0 ]]; then
    STORAGE_TARGETS=("/")
    STORAGE_TYPES=("unknown")
    STORAGE_SIZES=("?")
    STORAGE_AVAILS=("?")
    STORAGE_PATHS=("/home/nexus/gravacoes")
  fi
}

ask_recording_storage(){
  sec "Escolha do disco das gravações"

  detect_recording_storage_options

  echo "Escolha em qual disco/montagem os vídeos serão salvos."
  echo "O sistema continuará usando o caminho padrão /home/nexus/gravacoes."
  echo "Se outro disco for escolhido, será criado um link para a pasta real."
  echo

  local default_idx=1
  local i
  for i in "${!STORAGE_TARGETS[@]}"; do
    if [[ "${STORAGE_TARGETS[$i]}" == "/dados" ]]; then
      default_idx=$((i+1))
      break
    fi
  done

  for i in "${!STORAGE_TARGETS[@]}"; do
    local n=$((i+1))
    echo "$n) Montagem: ${STORAGE_TARGETS[$i]}"
    echo "   Tipo: ${STORAGE_TYPES[$i]} | Total: ${STORAGE_SIZES[$i]} | Livre: ${STORAGE_AVAILS[$i]}"
    echo "   Pasta real dos vídeos: ${STORAGE_PATHS[$i]}"
    echo
  done

  local choice
  while true; do
    read -r -p "Escolha o disco das gravações [${default_idx}]: " choice
    choice="${choice:-$default_idx}"

    if [[ ! "$choice" =~ ^[0-9]+$ ]]; then
      echo "Digite apenas o número da opção."
      continue
    fi

    if [[ "$choice" -lt 1 || "$choice" -gt "${#STORAGE_TARGETS[@]}" ]]; then
      echo "Opção inválida."
      continue
    fi

    local idx=$((choice-1))
    RECORDINGS_MOUNT="${STORAGE_TARGETS[$idx]}"
    RECORDINGS_REAL_DIR="${STORAGE_PATHS[$idx]}"
    RECORDINGS_SYSTEM_DIR="/home/nexus/gravacoes"

    echo
    echo "Gravações:"
    echo "  Montagem escolhida: $RECORDINGS_MOUNT"
    echo "  Pasta real: $RECORDINGS_REAL_DIR"
    echo "  Caminho usado pelo sistema: $RECORDINGS_SYSTEM_DIR"

    if confirm_param "disco/pasta das gravações" "$RECORDINGS_REAL_DIR"; then
      break
    fi
  done
}

setup_recording_storage(){
  sec "Configurando armazenamento das gravações"

  RECORDINGS_SYSTEM_DIR="${RECORDINGS_SYSTEM_DIR:-/home/nexus/gravacoes}"
  RECORDINGS_REAL_DIR="${RECORDINGS_REAL_DIR:-$RECORDINGS_SYSTEM_DIR}"
  RECORDINGS_MOUNT="${RECORDINGS_MOUNT:-/}"

  # Valida a montagem escolhida antes de criar a pasta final.
  # findmnt -T falha se o caminho final ainda não existe; por isso validamos a montagem/base.
  if [[ ! -d "$RECORDINGS_MOUNT" ]] || ! findmnt -T "$RECORDINGS_MOUNT" >/dev/null 2>&1; then
    die "A montagem escolhida para gravações não parece válida: $RECORDINGS_MOUNT"
  fi

  case "$RECORDINGS_MOUNT" in
    /boot*|/run*|/dev*|/proc*|/sys*|/snap*|/var/lib/docker*|/var/snap*)
      die "Montagem recusada por segurança: $RECORDINGS_MOUNT"
      ;;
  esac

  mkdir -p "$RECORDINGS_REAL_DIR" || die "Não consegui criar a pasta real das gravações: $RECORDINGS_REAL_DIR"

  # Confere se a pasta real ficou dentro da montagem escolhida.
  local real_mount
  real_mount="$(findmnt -n -T "$RECORDINGS_REAL_DIR" -o TARGET 2>/dev/null | head -1 || true)"
  if [[ -z "$real_mount" ]]; then
    die "Não consegui identificar a montagem real da pasta: $RECORDINGS_REAL_DIR"
  fi

  if [[ "$RECORDINGS_MOUNT" != "/" && "$real_mount" != "$RECORDINGS_MOUNT" ]]; then
    die "A pasta $RECORDINGS_REAL_DIR ficou na montagem $real_mount, mas o escolhido foi $RECORDINGS_MOUNT"
  fi

  local testfile="$RECORDINGS_REAL_DIR/.nvr_write_test_$$"
  if ! echo "teste" > "$testfile" 2>/dev/null; then
    die "Sem permissão de escrita em: $RECORDINGS_REAL_DIR"
  fi
  rm -f "$testfile"

  if [[ "$RECORDINGS_REAL_DIR" != "$RECORDINGS_SYSTEM_DIR" ]]; then
    mkdir -p "$(dirname "$RECORDINGS_SYSTEM_DIR")"

    if [[ -L "$RECORDINGS_SYSTEM_DIR" ]]; then
      ln -sfn "$RECORDINGS_REAL_DIR" "$RECORDINGS_SYSTEM_DIR"
    elif [[ -d "$RECORDINGS_SYSTEM_DIR" ]]; then
      if find "$RECORDINGS_SYSTEM_DIR" -mindepth 1 -maxdepth 1 2>/dev/null | grep -q .; then
        shopt -s dotglob nullglob
        mv "$RECORDINGS_SYSTEM_DIR"/* "$RECORDINGS_REAL_DIR"/ 2>/dev/null || true
        shopt -u dotglob nullglob
      fi
      rmdir "$RECORDINGS_SYSTEM_DIR" 2>/dev/null || rm -rf "$RECORDINGS_SYSTEM_DIR"
      ln -s "$RECORDINGS_REAL_DIR" "$RECORDINGS_SYSTEM_DIR"
    elif [[ -e "$RECORDINGS_SYSTEM_DIR" ]]; then
      mv "$RECORDINGS_SYSTEM_DIR" "${RECORDINGS_SYSTEM_DIR}.backup_$(date +%Y%m%d_%H%M%S)"
      ln -s "$RECORDINGS_REAL_DIR" "$RECORDINGS_SYSTEM_DIR"
    else
      ln -s "$RECORDINGS_REAL_DIR" "$RECORDINGS_SYSTEM_DIR"
    fi

    ok "Link criado: $RECORDINGS_SYSTEM_DIR -> $RECORDINGS_REAL_DIR"
  else
    mkdir -p "$RECORDINGS_SYSTEM_DIR"
    ok "Usando pasta padrão: $RECORDINGS_SYSTEM_DIR"
  fi

  chown -R nexus:nexus "$RECORDINGS_REAL_DIR" 2>/dev/null || true
  chmod -R 775 "$RECORDINGS_REAL_DIR" 2>/dev/null || true

  ok "Gravações serão salvas fisicamente em: $RECORDINGS_REAL_DIR"
}



ask_config(){
  sec "Perguntas de configuração"

  echo "Este assistente vai preparar o Nexus NVR para uso local, em VPS/internet ou nos dois cenários."
  echo "A porta do painel é definida por você. Ela não é fixa; o mesmo valor será usado nas rotas TCP do painel e UDP do RTC quando aplicável."
  echo
  echo "IP atual detectado: $CURRENT_IP"
  echo "Gateway detectado: $GATEWAY"
  echo "Rede detectada: ${BASE3}.x"
  echo

  while true; do
    read -r -p "Final do IP local do servidor [${DEFAULT_FINAL_LAST}]: " ip_last
    ip_last="${ip_last:-$DEFAULT_FINAL_LAST}"

    if ! valid_ip_last "$ip_last"; then
      echo "Digite um final de IP válido entre 2 e 254."
      continue
    fi

    FINAL_IP="${BASE3}.${ip_last}"

    if confirm_param "IP local final do servidor" "$FINAL_IP"; then
      break
    fi
  done

  while true; do
    read -r -p "Porta do painel/API Nexus NVR (obrigatório): " PANEL_PORT

    if [[ -z "$PANEL_PORT" ]]; then
      echo "A porta é obrigatória. Digite uma porta."
      continue
    fi

    if ! valid_port "$PANEL_PORT"; then
      echo "Porta inválida. Digite um número entre 1 e 65535."
      continue
    fi

    if confirm_param "porta do painel/API" "$PANEL_PORT"; then
      break
    fi
  done

  while true; do
    read -r -p "Fuso horário [${DEFAULT_TZ}]: " tz_in
    TZ_NVR="${tz_in:-$DEFAULT_TZ}"

    if confirm_param "fuso horário" "$TZ_NVR"; then
      break
    fi
  done

  EXTERNAL_HOST=""
  EXTERNAL_PORT="$PANEL_PORT"

  while true; do
    echo
    echo "Modo de rede:"
    echo "  1) Apenas local"
    echo "     Use quando o celular/app acessará somente a mesma rede do servidor."
    echo "  2) Apenas VPS/internet"
    echo "     Use quando o servidor será acessado somente por IP público ou domínio."
    echo "  3) Local + internet"
    echo "     Use quando o mesmo servidor precisa funcionar dentro do Wi-Fi local e também fora dele."
    echo
    echo "Observação: no modo Local + internet, o Go2RTC anuncia os dois caminhos para reduzir conflito quando o app está no mesmo Wi-Fi do servidor."
    read -r -p "Escolha o modo de rede [3]: " mode_choice
    mode_choice="${mode_choice:-3}"

    case "$mode_choice" in
      1) NETWORK_MODE="local" ;;
      2) NETWORK_MODE="external" ;;
      3) NETWORK_MODE="hybrid" ;;
      *) echo "Escolha 1, 2 ou 3."; continue ;;
    esac

    if confirm_param "modo de rede" "$(network_mode_label "$NETWORK_MODE")"; then
      break
    fi
  done

  if [[ "$NETWORK_MODE" == "external" || "$NETWORK_MODE" == "hybrid" ]]; then
    while true; do
      read -r -p "IP público ou domínio externo: " EXTERNAL_HOST
      [[ -n "$EXTERNAL_HOST" ]] || { echo "Campo obrigatório para este modo."; continue; }
      confirm_param "IP público/domínio externo" "$EXTERNAL_HOST" && break
    done

    while true; do
      read -r -p "A porta externa será a mesma ${PANEL_PORT}? [S/n]: " same_port
      case "$same_port" in
        n|N|nao|não|NAO|NÃO)
          while true; do
            read -r -p "Porta externa: " EXTERNAL_PORT
            [[ -n "$EXTERNAL_PORT" ]] || { echo "Campo obrigatório."; continue; }
            valid_port "$EXTERNAL_PORT" || { echo "Porta inválida."; continue; }
            confirm_param "porta externa" "$EXTERNAL_PORT" && break
          done
          ;;
        *)
          EXTERNAL_PORT="$PANEL_PORT"
          confirm_param "porta externa" "$EXTERNAL_PORT" || continue
          ;;
      esac
      break
    done
  else
    EXTERNAL_HOST=""
    EXTERNAL_PORT="$PANEL_PORT"
  fi

  if [[ "$NETWORK_MODE" == "local" ]]; then
    confirm_param "acesso externo" "desativado" || die "Cancelado pelo usuário."
  else
    confirm_param "acesso externo" "ativado em ${EXTERNAL_HOST}:${EXTERNAL_PORT}" || die "Cancelado pelo usuário."
  fi

  ask_recording_storage

  NPM_EMAIL="$DEFAULT_NPM_EMAIL"
  NPM_PASS="$DEFAULT_NPM_PASS"
  FB_USER="$DEFAULT_FB_USER"
  FB_PASS="$DEFAULT_FB_PASS"

  echo
  echo "Resumo da instalação:"
  echo "  Modo de rede: $(network_mode_label "$NETWORK_MODE")"
  echo "  IP local final: $FINAL_IP"
  echo "  Porta local do painel/API: $PANEL_PORT"
  [[ -n "$EXTERNAL_HOST" ]] && echo "  Acesso externo: ${EXTERNAL_HOST}:${EXTERNAL_PORT}" || echo "  Acesso externo: desativado"
  echo "Gravações:"
  echo "  Caminho do sistema: ${RECORDINGS_SYSTEM_DIR:-/home/nexus/gravacoes}"
  echo "  Pasta real: ${RECORDINGS_REAL_DIR:-/home/nexus/gravacoes}"
  echo "Serviços:"
  echo "  Nexus NVR: painel, API, live Go2RTC, gravador FFmpeg e visualizador de vídeos"
  echo "Credenciais iniciais:"
  echo "  Nginx Proxy Manager: $NPM_EMAIL / $NPM_PASS"
  echo "  Filebrowser: $FB_USER / $FB_PASS"
  echo
  echo "Antes de publicar ou entregar o servidor, altere as senhas padrão."
  echo
  read -r -p "Digite CONTINUAR para iniciar: " confirm
  [[ "$confirm" == "CONTINUAR" ]] || die "Cancelado pelo usuário."

  mkdir -p "$TARGET"
  cat > "$STATE_FILE" <<EOF
FINAL_IP="$FINAL_IP"
PANEL_PORT="$PANEL_PORT"
TZ_NVR="$TZ_NVR"
NETWORK_MODE="$NETWORK_MODE"
EXTERNAL_HOST="$EXTERNAL_HOST"
EXTERNAL_PORT="$EXTERNAL_PORT"
RECORDINGS_MOUNT="$RECORDINGS_MOUNT"
RECORDINGS_REAL_DIR="$RECORDINGS_REAL_DIR"
RECORDINGS_SYSTEM_DIR="$RECORDINGS_SYSTEM_DIR"
NPM_EMAIL="$NPM_EMAIL"
NPM_PASS="$NPM_PASS"
FB_USER="$FB_USER"
FB_PASS="$FB_PASS"
PHASE="CONFIGURED"
EOF
  chmod 600 "$STATE_FILE" 2>/dev/null || true
}


check_package(){
  sec "Verificando pacote do Nexus NVR"
  [[ -d "$PACKAGE_DIR" ]] || die "Não encontrei ${PACKAGE_DIR}"

  # Arquivos obrigatórios do NVR.
  local required=(
    "api/api.js"
    "api/nvr_config.json"
    "go2rtc/go2rtc.yaml"
    "frontend/index.html"
  )

  for f in "${required[@]}"; do
    [[ -f "${PACKAGE_DIR}/${f}" ]] && ok "Encontrado: $f" || die "Faltando: ${PACKAGE_DIR}/${f}"
  done

  ok "Pacote NVR verificado. IoT/portão não faz parte deste pacote."

  # Scanner público/genérico de dados sensíveis no pacote do NVR.
  # Ignora backups e evita falso positivo em código como startsWith("rtsp://").
  local sensitive_regex='(rtsp://[^[:space:]"\047]+(@|[0-9]{1,3}(\.[0-9]{1,3}){3}|[A-Za-z0-9.-]+\.[A-Za-z]{2,})|user=.*password=|password[[:space:]]*[:=]|pass[[:space:]]*[:=]|senha[[:space:]]*[:=]|ssid[[:space:]]*[:=]|token[[:space:]]*[:=]|secret[[:space:]]*[:=])'
  if grep -RInE "$sensitive_regex" "$PACKAGE_DIR" \
      --exclude-dir=node_modules \
      --exclude-dir=.git \
      --exclude="*.backup_*" \
      --exclude="*.bak" \
      --exclude="*~" \
      --exclude="*.db" \
      --exclude="*.sqlite" \
      --exclude="*.sqlite3" \
      --exclude="*.mp4" \
      --exclude="*.mkv" \
      >/tmp/nvr_sensitive.txt 2>/dev/null; then
    warn "Possíveis dados sensíveis reais encontrados no pacote do NVR:"
    cat /tmp/nvr_sensitive.txt
    echo
    warn "Revise se isso é exemplo público ou dado real antes de publicar/instalar."
    read -r -p "Continuar mesmo assim? [s/N]: " c
    [[ "$c" =~ ^[sS] ]] || die "Limpe os dados sensíveis antes de continuar."
  else
    ok "Pacote sem padrões sensíveis fortes"
  fi
}

install_deps(){
  sec "Verificando programas e dependências"

  export DEBIAN_FRONTEND=noninteractive
  local need_update=0

  pkg_installed(){
    dpkg -s "$1" >/dev/null 2>&1
  }

  install_missing_packages(){
    local missing=()
    local p
    for p in "$@"; do
      if pkg_installed "$p"; then
        ok "Dependência já instalada: $p"
      else
        warn "Dependência ausente: $p"
        missing+=("$p")
      fi
    done

    if (( ${#missing[@]} > 0 )); then
      sec "Instalando dependências ausentes"
      apt-get update || die "apt-get update falhou"
      apt-get install -y "${missing[@]}" || die "Falha ao instalar dependências ausentes"
    else
      ok "Todas as dependências básicas já estão instaladas"
    fi
  }

  docker_other_containers(){
    if ! command -v docker >/dev/null 2>&1; then
      return 0
    fi
    local all nvr
    all="$(docker ps -a --format '{{.Names}}' 2>/dev/null | sort -u || true)"
    nvr="$({
      for n in nexus_api go2rtc nvr-frontend visualizador_videos nginx-proxy-manager_app_1; do
        echo "$all" | grep -Fx "$n" || true
      done
      echo "$all" | grep -E '^gravador_' || true
    } | sort -u)"
    if [[ -z "$all" ]]; then
      return 0
    fi
    comm -23 <(echo "$all") <(echo "$nvr")
  }

  purge_docker_stack(){
    warn "Removendo Docker/containerd e dados Docker locais."
    local others
    others="$(docker_other_containers || true)"
    if [[ -n "$others" ]]; then
      warn "Existem containers que NÃO parecem ser do Nexus NVR:"
      echo "$others"
      warn "Reinstalar Docker pode afetar esses sistemas."
      read -r -p "Digite REINSTALAR DOCKER MESMO para continuar: " confirm_docker
      [[ "$confirm_docker" == "REINSTALAR DOCKER MESMO" ]] || die "Reinstalação do Docker cancelada para preservar outros sistemas."
    else
      read -r -p "Digite REINSTALAR DOCKER para confirmar: " confirm_docker
      [[ "$confirm_docker" == "REINSTALAR DOCKER" ]] || die "Reinstalação do Docker cancelada."
    fi

    systemctl stop docker 2>/dev/null || true
    systemctl stop containerd 2>/dev/null || true

    apt-get purge -y docker.io docker-compose docker-compose-plugin docker-ce docker-ce-cli docker-buildx-plugin containerd.io containerd runc 2>/dev/null || true
    apt-get autoremove -y || true

    rm -rf /var/lib/docker /var/lib/containerd /etc/docker
    fix "Docker/containerd antigos removidos"
  }

  install_docker_engine(){
    sec "Instalando Docker"
    install -m 0755 -d /etc/apt/keyrings
    rm -f /etc/apt/keyrings/docker.gpg

    if curl -fsSL https://download.docker.com/linux/ubuntu/gpg | gpg --dearmor -o /etc/apt/keyrings/docker.gpg; then
      chmod a+r /etc/apt/keyrings/docker.gpg
      . /etc/os-release
      CODENAME="${VERSION_CODENAME:-$(lsb_release -cs)}"
      echo "deb [arch=$(dpkg --print-architecture) signed-by=/etc/apt/keyrings/docker.gpg] https://download.docker.com/linux/ubuntu ${CODENAME} stable" > /etc/apt/sources.list.d/docker.list
      apt-get update
      apt-get install -y docker-ce docker-ce-cli containerd.io docker-buildx-plugin docker-compose-plugin || apt-get install -y docker.io docker-compose-plugin docker-compose || die "Docker falhou"
    else
      warn "Falha ao baixar chave oficial Docker. Tentando Docker do repositório Ubuntu."
      apt-get update
      apt-get install -y docker.io docker-compose-plugin docker-compose || die "Docker falhou"
    fi

    fix "Docker instalado"
  }

  ensure_docker(){
    sec "Verificando Docker"

    if command -v docker >/dev/null 2>&1; then
      ok "Docker encontrado: $(docker --version 2>/dev/null || echo instalado)"

      if systemctl is-active --quiet docker 2>/dev/null || docker info >/dev/null 2>&1; then
        ok "Docker está funcional"
      else
        warn "Docker existe, mas não está ativo/respondendo. Tentando iniciar."
        systemctl enable --now docker 2>/dev/null || true
      fi

      if docker info >/dev/null 2>&1; then
        read -r -p "Usar Docker existente? [S/n]: " use_docker
        use_docker="${use_docker:-S}"
        if [[ "$use_docker" =~ ^[nN]$ ]]; then
          purge_docker_stack
          install_docker_engine
        else
          ok "Usando Docker existente"
        fi
      else
        warn "Docker instalado, mas ainda não responde."
        read -r -p "Reinstalar Docker? [s/N]: " reinstall_bad
        if [[ "$reinstall_bad" =~ ^[sS]$ ]]; then
          purge_docker_stack
          install_docker_engine
        else
          die "Docker não está funcional. Corrija ou permita reinstalar."
        fi
      fi
    else
      warn "Docker não encontrado."
      read -r -p "Instalar Docker agora? [S/n]: " install_docker
      install_docker="${install_docker:-S}"
      [[ "$install_docker" =~ ^[sS]$ ]] || die "Docker é obrigatório para o Nexus NVR."
      install_docker_engine
    fi

    systemctl enable --now docker || die "Docker não iniciou"
  }

  ensure_compose(){
    sec "Verificando Docker Compose"

    if docker compose version >/dev/null 2>&1; then
      COMPOSE_CMD="docker compose"
      ok "Compose plugin encontrado: $(docker compose version 2>/dev/null | head -1)"
      read -r -p "Usar Docker Compose existente? [S/n]: " use_compose
      use_compose="${use_compose:-S}"
      if [[ "$use_compose" =~ ^[nN]$ ]]; then
        warn "Reinstalando Docker Compose plugin"
        apt-get update
        apt-get install -y --reinstall docker-compose-plugin || apt-get install -y docker-compose-plugin docker-compose || die "Compose falhou"
        COMPOSE_CMD="docker compose"
      fi
    elif command -v docker-compose >/dev/null 2>&1; then
      COMPOSE_CMD="docker-compose"
      ok "docker-compose legado encontrado: $($COMPOSE_CMD version 2>/dev/null | head -1)"
      read -r -p "Usar docker-compose existente? [S/n]: " use_compose
      use_compose="${use_compose:-S}"
      if [[ "$use_compose" =~ ^[nN]$ ]]; then
        warn "Instalando Docker Compose plugin"
        apt-get update
        apt-get install -y docker-compose-plugin || apt-get install -y docker-compose || die "Compose falhou"
        COMPOSE_CMD="docker compose"
      fi
    else
      warn "Docker Compose não encontrado. Instalando."
      apt-get update
      apt-get install -y docker-compose-plugin || apt-get install -y docker-compose || die "Compose ausente"
      COMPOSE_CMD="docker compose"
    fi

    ok "Compose em uso: $($COMPOSE_CMD version 2>/dev/null | head -1)"
  }

  check_optional_node(){
    sec "Verificando Node.js/npm do host"

    local has_node=0
    local has_npm=0
    command -v node >/dev/null 2>&1 && has_node=1 || true
    command -v npm >/dev/null 2>&1 && has_npm=1 || true

    if (( has_node == 1 )); then
      ok "Node.js encontrado no host: $(node -v 2>/dev/null || true)"
    else
      info "Node.js não encontrado no host. OK: a API roda dentro do container."
    fi

    if (( has_npm == 1 )); then
      ok "npm encontrado no host: $(npm -v 2>/dev/null || true)"
    else
      info "npm não encontrado no host. OK: não é obrigatório no host."
    fi

    if (( has_node == 1 || has_npm == 1 )); then
      warn "O Nexus NVR não precisa de Node/npm instalados no host; usa Node dentro do Docker."
      read -r -p "Manter Node/npm do host? [S/n]: " keep_node
      keep_node="${keep_node:-S}"
      if [[ "$keep_node" =~ ^[nN]$ ]]; then
        apt-get purge -y nodejs npm 2>/dev/null || true
        apt-get autoremove -y || true
        fix "Node/npm do host removidos"
      else
        ok "Node/npm do host mantidos"
      fi
    fi
  }

  install_missing_packages ca-certificates curl gnupg lsb-release python3 sqlite3 cron iproute2 iputils-ping net-tools openssl jq
  systemctl enable --now cron || die "Cron não iniciou"

  ensure_docker
  ensure_compose
  check_optional_node

  ok "Verificação de programas concluída"
}

prepare_files(){
  sec "Criando estrutura e copiando pacote"
  id nexus >/dev/null 2>&1 || adduser --disabled-password --gecos "" nexus
  ok "Usuário nexus pronto"

  mkdir -p "$TARGET"/{nvr-web,api,go2rtc,filebrowser_config,filebrowser_db,nginx-proxy-manager/data/nginx/proxy_host,nginx-proxy-manager/letsencrypt,scripts,gravacoes,nvr-compose,logs}

  cp -a "$PACKAGE_DIR/frontend/." "$TARGET/nvr-web/"
  cp -a "$PACKAGE_DIR/api/." "$TARGET/api/"
  cp -a "$PACKAGE_DIR/go2rtc/." "$TARGET/go2rtc/"
  # IoT/portão não é instalado por este script.
  # Use NEXUSNVR_PORTAO.sh separado quando quiser o portão.
  [[ -d "$PACKAGE_DIR/scripts" ]] && cp -a "$PACKAGE_DIR/scripts/." "$TARGET/scripts/" || true

  [[ -f "$TARGET/scripts/cria_pasta_camera.sh" ]] || create_folder_script
  chmod +x "$TARGET/scripts/cria_pasta_camera.sh"
  cp -a "$TARGET/scripts/cria_pasta_camera.sh" "$TARGET/cria_pasta_camera.sh"

  setup_recording_storage

  chown -R nexus:nexus "$TARGET/gravacoes" 2>/dev/null || true
  chmod -R 775 "$TARGET/gravacoes" 2>/dev/null || true
  chmod -R 777 "$TARGET/filebrowser_config" "$TARGET/filebrowser_db" 2>/dev/null || true

  patch_api_webrtc_env

  ok "Arquivos copiados e configurados"
}

create_folder_script(){
  cat > "$TARGET/scripts/cria_pasta_camera.sh" <<'EOF'
#!/bin/bash
DATA_HOJE=$(TZ='America/Sao_Paulo' date +%d-%m-%Y)
DATA_AMANHA=$(TZ='America/Sao_Paulo' date -d 'tomorrow' +%d-%m-%Y)
BASE_DIR="/home/nexus/gravacoes"
CONFIG="/home/nexus/go2rtc/go2rtc.yaml"
mkdir -p "$BASE_DIR"
[ -f "$CONFIG" ] || exit 0
IFS=$'\n'
CAMERAS=$(grep "^  " "$CONFIG" | awk -F':' '{print $1}' | sed -e 's/^[ \t]*//' -e 's/[ \t]*$//' | grep -v '^$' || true)
for CAMERA in $CAMERAS; do
  mkdir -p "$BASE_DIR/$CAMERA/$DATA_HOJE" "$BASE_DIR/$CAMERA/$DATA_AMANHA"
  chown -R nexus:nexus "$BASE_DIR/$CAMERA" 2>/dev/null || true
  chmod -R 775 "$BASE_DIR/$CAMERA" 2>/dev/null || true
done
unset IFS
EOF
}

patch_api_webrtc_env(){
  sec "Validando API: WebRTC, timezone e gravadores"

  if grep -q "buildRecorderArgs" "$TARGET/api/api.js" 2>/dev/null && grep -q "WEBRTC_CANDIDATES" "$TARGET/api/api.js" 2>/dev/null; then
    ok "API nova detectada: valida entradas, preserva WebRTC e usa Docker sem comando shell montado por texto"
    return 0
  fi

  python3 - "$TARGET/api/api.js" <<'PYAPI'
from pathlib import Path
from datetime import datetime
import sys

api = Path(sys.argv[1])
if not api.exists():
    raise SystemExit(f"API nao encontrada: {api}")

s = api.read_text(encoding="utf-8", errors="replace")
orig = s
changes = []

# 1) Preservar bloco WebRTC/candidates quando a API recriar go2rtc.yaml.
if not ("WEBRTC_CANDIDATES" in s and "process.env.WEBRTC_CANDIDATES" in s):
    old_start = '                // 2. Reconstrói o arquivo YAML do Go2RTC apenas com as ativas'
    old_end = '                // 3. Reinicia Go2RTC para pegar o novo Live'

    start = s.find(old_start)
    end = s.find(old_end)

    if start == -1 or end == -1:
        raise SystemExit("ERRO: trecho esperado do YAML nao encontrado em api.js")

    new_block = """                // 2. Reconstrói o arquivo YAML do Go2RTC apenas com as ativas
                let yamlContent = "streams:\n";
                for (let i = 1; i <= 4; i++) {
                    let c = db[i];
                    if (c && c.active && c.name && c.url && !c.url.includes('[IP]')) {
                        yamlContent += `  ${c.name}: ${c.url}\n`;
                    }
                }

                const webrtcCandidates = (process.env.WEBRTC_CANDIDATES || "")
                    .split(",")
                    .map(v => v.trim())
                    .filter(Boolean);

                yamlContent += "\n";
                yamlContent += "# Nexus NVR - WebRTC pela mesma porta publica do painel\n";
                yamlContent += "# TCP fica no Nginx; UDP da mesma porta vai para o Go2RTC.\n";
                yamlContent += "webrtc:\n";
                yamlContent += "  listen: \":8555\"\n";

                if (webrtcCandidates.length > 0) {
                    yamlContent += "  candidates:\n";
                    for (const candidate of webrtcCandidates) {
                        yamlContent += `    - ${candidate}\n`;
                    }
                }

                fs.writeFileSync(YAML_PATH, yamlContent);

                // 3. Reinicia Go2RTC para pegar o novo Live"""

    s = s[:start] + new_block + s[end + len(old_end):]
    changes.append("WebRTC/candidates")
else:
    print("API ja preserva WEBRTC_CANDIDATES.")

# 2) Fuso do gravador: vem da câmera, depois do TZ do container/API, depois São Paulo.
replacements = {
    "const tz = cam.tz || 'GMT3';": "const tz = cam.tz || process.env.TZ || 'America/Sao_Paulo';",
    'const tz = cam.tz || "GMT3";': "const tz = cam.tz || process.env.TZ || 'America/Sao_Paulo';",
    "const tz = cam.tz || 'America/Sao_Paulo';": "const tz = cam.tz || process.env.TZ || 'America/Sao_Paulo';",
    'const tz = cam.tz || "America/Sao_Paulo";': "const tz = cam.tz || process.env.TZ || 'America/Sao_Paulo';",
}
for a, b in replacements.items():
    if a in s:
        s = s.replace(a, b)
        changes.append("TZ fallback")

# 3) O container FFmpeg precisa dos dados reais de timezone do host.
#    Apenas -e TZ não basta em algumas imagens; sem zoneinfo ele pode ficar em UTC.
lines = s.splitlines()
cleaned = []
for line in lines:
    if "/usr/share/zoneinfo:/usr/share/zoneinfo:ro" in line:
        continue
    if "/etc/localtime:/etc/localtime:ro" in line:
        continue
    if "/etc/timezone:/etc/timezone:ro" in line:
        continue
    cleaned.append(line)

out = []
inserted = False
for line in cleaned:
    out.append(line)
    if "ffmpegCmd += `  -e TZ=${tz}" in line:
        out.append("                    ffmpegCmd += `  -v /usr/share/zoneinfo:/usr/share/zoneinfo:ro \\\\\\n`;")
        out.append("                    ffmpegCmd += `  -v /etc/localtime:/etc/localtime:ro \\\\\\n`;")
        out.append("                    ffmpegCmd += `  -v /etc/timezone:/etc/timezone:ro \\\\\\n`;")
        inserted = True

s = "\n".join(out) + "\n"

if inserted:
    changes.append("mount timezone host")
else:
    print("AVISO: linha -e TZ=${tz} do gravador nao encontrada; mounts de timezone nao inseridos.")

if s != orig:
    bk = api.with_name(api.name + ".backup_api_patch_" + datetime.now().strftime("%Y%m%d_%H%M%S"))
    bk.write_text(orig, encoding="utf-8")
    api.write_text(s, encoding="utf-8")
    print(f"API corrigida: {api}")
    print(f"Backup: {bk}")
    print("Alteracoes:", ", ".join(dict.fromkeys(changes)) if changes else "ajustes aplicados")
else:
    print("API ja estava corrigida.")
PYAPI

  ok "API pronta para WebRTC e gravadores no fuso correto"
}


set_timezone(){
  sec "Corrigindo horário"
  timedatectl set-timezone "$TZ_NVR" 2>/dev/null && ok "Host em $TZ_NVR" || warn "Não consegui ajustar timezone com timedatectl"
}

write_compose(){
  sec "Criando docker-compose"
  mkdir -p "$COMPOSE_DIR"

  local WEBRTC_CANDIDATES
  WEBRTC_CANDIDATES="$(build_webrtc_candidates)"
  [[ -n "$WEBRTC_CANDIDATES" ]] || WEBRTC_CANDIDATES="${FINAL_IP}:${PANEL_PORT}"

  cat > "$COMPOSE_FILE" <<EOF
services:
  go2rtc:
    image: alexxit/go2rtc:latest
    container_name: go2rtc
    restart: unless-stopped
    ports:
      - "1984:1984"
      - "8554:8554"
      # WebRTC/RTC usa UDP na mesma porta publica do painel.
      # Assim o Nginx continua em TCP ${PANEL_PORT}->80 e o go2rtc recebe UDP ${PANEL_PORT}->8555.
      # Nao abrimos a 8555 publicamente.
      - "${PANEL_PORT}:8555/udp"
    volumes:
      - /home/nexus/go2rtc:/config
    command: ["go2rtc", "-config", "/config/go2rtc.yaml"]

  nvr-frontend:
    image: nginx:alpine
    container_name: nvr-frontend
    restart: unless-stopped
    ports:
      - "9000:80"
    volumes:
      - /home/nexus/nvr-web:/usr/share/nginx/html:ro

  visualizador_videos:
    image: filebrowser/filebrowser
    container_name: visualizador_videos
    restart: unless-stopped
    ports:
      - "8085:80"
    volumes:
      - /home/nexus/gravacoes:/srv
      - /home/nexus/filebrowser_config:/config
      - /home/nexus/filebrowser_db:/database

  nexus_api:
    image: node:18-alpine
    container_name: nexus_api
    restart: unless-stopped
    environment:
      - TZ=$TZ_NVR
      - WEBRTC_CANDIDATES=$WEBRTC_CANDIDATES
    ports:
      - "3000:3000"
    volumes:
      - /home/nexus/api:/app
      - /home/nexus/go2rtc/go2rtc.yaml:/data/go2rtc.yaml
      - /var/run/docker.sock:/var/run/docker.sock
    command: ["sh", "-c", "apk add --no-cache docker-cli tzdata && node /app/api.js"]


  nginx-proxy-manager:
    image: jc21/nginx-proxy-manager:latest
    container_name: nginx-proxy-manager_app_1
    restart: unless-stopped
    ports:
      - "${PANEL_PORT}:80"
      - "81:81"
      - "443:443"
    extra_hosts:
      - "host.docker.internal:host-gateway"
    volumes:
      - /home/nexus/nginx-proxy-manager/data:/data
      - /home/nexus/nginx-proxy-manager/letsencrypt:/etc/letsencrypt
EOF
  ok "Compose criado"
}

configure_proxy_file(){
  local ip="$1"
  sec "Configurando proxy para $ip:$PANEL_PORT"
  local names="$ip"
  [[ -n "$FINAL_IP" && "$FINAL_IP" != "$ip" ]] && names="$names $FINAL_IP"
  [[ -n "$EXTERNAL_HOST" ]] && names="$names $EXTERNAL_HOST"
  names="$(echo "$names" | tr ' ' '\n' | awk 'NF && !seen[$0]++' | xargs)"

  mkdir -p "$TARGET/nginx-proxy-manager/data/nginx/proxy_host"
  cat > "$TARGET/nginx-proxy-manager/data/nginx/proxy_host/5.conf" <<EOF
# Nexus NVR - gerado automaticamente
server {
  listen 80;
  listen [::]:80;
  server_name $names;
  client_max_body_size 0;
  proxy_http_version 1.1;

  proxy_set_header Upgrade \$http_upgrade;
  proxy_set_header Connection \$http_connection;
  proxy_set_header Host \$http_host;
  proxy_set_header X-Forwarded-Scheme \$scheme;
  proxy_set_header X-Forwarded-Proto \$scheme;
  proxy_set_header X-Forwarded-For \$remote_addr;
  proxy_set_header X-Real-IP \$remote_addr;
  add_header X-Served-By "$ip" always;

  # API principal do Nexus
  location /maestro/ {
    proxy_pass http://nexus_api:3000;
  }

  # Go2RTC / Live
  # Usa nomes internos dos containers na rede Docker.
  # Funciona tanto em servidor local quanto em VPS/Oracle.
  # Para WebSocket, força Host e Origin para o endereço real aberto no app.
  # Isso evita o erro do Go2RTC:
  # websocket: request origin not allowed.
  # Mantém as rotas principais usadas no sistema original e rotas extras para evitar conflito com Filebrowser.
  location /stream.html {
    proxy_pass http://go2rtc:1984;
  }

  location /video-rtc.js {
    proxy_pass http://go2rtc:1984;
  }

  location /video-stream.js {
    proxy_pass http://go2rtc:1984;
  }

  location /api/ws {
    proxy_set_header Upgrade \$http_upgrade;
    proxy_set_header Connection "Upgrade";
    proxy_set_header Host \$http_host;
    proxy_set_header Origin \$scheme://\$http_host;
    proxy_set_header X-Forwarded-Host \$http_host;
    proxy_read_timeout 3600s;
    proxy_send_timeout 3600s;
    proxy_buffering off;
    proxy_pass http://go2rtc:1984;
  }

  location /api/webrtc {
    proxy_set_header Upgrade \$http_upgrade;
    proxy_set_header Connection "Upgrade";
    proxy_set_header Host \$http_host;
    proxy_set_header Origin \$scheme://\$http_host;
    proxy_set_header X-Forwarded-Host \$http_host;
    proxy_read_timeout 3600s;
    proxy_send_timeout 3600s;
    proxy_buffering off;
    proxy_pass http://go2rtc:1984;
  }

  location /api/streams {
    proxy_pass http://go2rtc:1984;
  }

  location /api/stream {
    proxy_pass http://go2rtc:1984;
  }

  location /api/mse {
    proxy_set_header Upgrade \$http_upgrade;
    proxy_set_header Connection "Upgrade";
    proxy_set_header Host \$http_host;
    proxy_set_header Origin \$scheme://\$http_host;
    proxy_set_header X-Forwarded-Host \$http_host;
    proxy_read_timeout 3600s;
    proxy_send_timeout 3600s;
    proxy_buffering off;
    proxy_pass http://go2rtc:1984;
  }

  location /api/hls {
    proxy_pass http://go2rtc:1984;
  }

  location /api/frame {
    proxy_pass http://go2rtc:1984;
  }

  # Filebrowser / Gravações
  # Precisa ficar depois das rotas específicas do Go2RTC.
  location /api/ {
    proxy_pass http://visualizador_videos:80;
  }

  # Página informativa
  location / {
    proxy_pass http://nvr-frontend:80;
  }
}
EOF
  ok "Arquivo de proxy gerado para: $names"
}

configure_go2rtc_webrtc(){
  sec "Configurando WebRTC/RTC do Go2RTC"

  local cfg="$TARGET/go2rtc/go2rtc.yaml"
  [[ -f "$cfg" ]] || { warn "go2rtc.yaml não encontrado para configurar WebRTC"; return 0; }

  local candidates
  candidates="$(build_webrtc_candidates)"
  [[ -n "$candidates" ]] || candidates="${FINAL_IP}:${PANEL_PORT}"

  python3 - "$cfg" "$candidates" <<'PY'
from pathlib import Path
import sys

path = Path(sys.argv[1])
candidates_arg = sys.argv[2]

lines = path.read_text(encoding="utf-8", errors="replace").splitlines()

# Remove bloco top-level webrtc existente para evitar duplicidade.
out = []
i = 0
while i < len(lines):
    line = lines[i]
    if line.startswith("webrtc:"):
        i += 1
        while i < len(lines):
            nxt = lines[i]
            if nxt and not nxt.startswith((" ", "\t")) and not nxt.startswith("#"):
                break
            i += 1
        continue
    out.append(line)
    i += 1

candidates = []
for c in candidates_arg.split(","):
    c = c.strip()
    if c and c not in candidates:
        candidates.append(c)

if out and out[-1].strip():
    out.append("")
out.append("# Nexus NVR: WebRTC/RTC")
out.append("# TCP do painel continua no Nginx; UDP da mesma porta vai para o Go2RTC.")
out.append("webrtc:")
out.append('  listen: ":8555"')
out.append("  candidates:")
for c in candidates:
    out.append(f"    - {c}")

path.write_text("\n".join(out) + "\n", encoding="utf-8")
PY

  echo "Candidatos RTC configurados:"
  echo "$candidates" | tr ',' '\n' | sed 's/^/  - /'
  echo
  echo "IMPORTANTE:"
  if [[ "$NETWORK_MODE" == "external" || "$NETWORK_MODE" == "hybrid" ]]; then
    echo "  Para RTC externo, libere também UDP ${EXTERNAL_PORT:-$PANEL_PORT} na Oracle/roteador."
  fi
  echo "  A porta TCP ${PANEL_PORT} continua sendo do painel via Nginx."
  ok "WebRTC/RTC configurado no go2rtc.yaml"
}


init_filebrowser_db(){
  sec "Inicializando Filebrowser com login padrão"
  rm -f "$TARGET/filebrowser_db/filebrowser.db"
  mkdir -p "$TARGET/filebrowser_db" "$TARGET/filebrowser_config"
  chmod -R 777 "$TARGET/filebrowser_config" "$TARGET/filebrowser_db"

  docker run --rm \
    -v "$TARGET/gravacoes:/srv" \
    -v "$TARGET/filebrowser_db:/database" \
    -v "$TARGET/filebrowser_config:/config" \
    filebrowser/filebrowser \
    -d /database/filebrowser.db config init >/dev/null 2>&1 || true

  docker run --rm \
    -v "$TARGET/gravacoes:/srv" \
    -v "$TARGET/filebrowser_db:/database" \
    -v "$TARGET/filebrowser_config:/config" \
    filebrowser/filebrowser \
    -d /database/filebrowser.db config set --root /srv --address 0.0.0.0 --port 80 >/dev/null 2>&1 || true

  docker run --rm \
    -v "$TARGET/gravacoes:/srv" \
    -v "$TARGET/filebrowser_db:/database" \
    -v "$TARGET/filebrowser_config:/config" \
    filebrowser/filebrowser \
    -d /database/filebrowser.db users add "$FB_USER" "$FB_PASS" --perm.admin >/tmp/fb_user.out 2>/tmp/fb_user.err

  if grep -q "$FB_USER" /tmp/fb_user.out 2>/dev/null; then
    ok "Filebrowser criado: $FB_USER / $FB_PASS"
  else
    warn "Não consegui criar usuário Filebrowser. Saída:"
    cat /tmp/fb_user.out 2>/dev/null || true
    cat /tmp/fb_user.err 2>/dev/null || true
  fi

  chmod -R 777 "$TARGET/filebrowser_config" "$TARGET/filebrowser_db"
}

start_docker(){
  sec "Subindo containers"
  cd "$COMPOSE_DIR" || die "Sem compose dir"
  $COMPOSE_CMD pull || warn "Pull teve avisos"
  init_filebrowser_db

  docker rm -f go2rtc nvr-frontend visualizador_videos nexus_api nginx-proxy-manager_app_1 gravador_Rua gravador_teste_nexus >/dev/null 2>&1 || true

  $COMPOSE_CMD up -d || die "Falha ao subir compose"
  sleep 12

  if docker exec nginx-proxy-manager_app_1 nginx -t >/dev/null 2>&1; then
    docker exec nginx-proxy-manager_app_1 nginx -s reload >/dev/null 2>&1 || true
    ok "Nginx recarregado"
  else
    warn "Nginx ainda não aceitou configuração; pode corrigir após iniciar completamente."
  fi

  docker ps --format "table {{.Names}}\t{{.Status}}\t{{.Ports}}"
}

setup_npm_login(){
  sec "Configurando login padrão do Nginx Proxy Manager"

  local token=""
  local login_resp=""
  local create_resp=""
  local api_ready="0"

  echo "[INFO] Aguardando backend do Nginx Proxy Manager ficar pronto..."

  for i in {1..90}; do
    # Se a API responder qualquer coisa JSON/erro válido, já está acordada.
    if curl -m 5 -s "http://127.0.0.1:81/api" >/tmp/npm_api_wait.out 2>/dev/null; then
      api_ready="1"
      break
    fi

    # Algumas versões não respondem /api, mas respondem POST /api/tokens.
    login_resp="$(curl -m 5 -s -X POST "http://127.0.0.1:81/api/tokens" \
      -H "Content-Type: application/json" \
      -d "{\"identity\":\"$NPM_EMAIL\",\"secret\":\"$NPM_PASS\"}" || true)"
    if echo "$login_resp" | grep -Eq 'token|error|message'; then
      api_ready="1"
      break
    fi

    sleep 2
  done

  if [[ "$api_ready" != "1" ]]; then
    warn "Backend do NPM não respondeu a tempo. Vou tentar criar/login mesmo assim."
  else
    ok "Backend do NPM respondeu"
  fi

  # 1) Tenta login com o usuário padrão Nexus, caso já exista.
  for i in {1..15}; do
    login_resp="$(curl -m 8 -s -X POST "http://127.0.0.1:81/api/tokens" \
      -H "Content-Type: application/json" \
      -d "{\"identity\":\"$NPM_EMAIL\",\"secret\":\"$NPM_PASS\"}" || true)"

    token="$(echo "$login_resp" | python3 -c 'import sys,json
try:
    print(json.load(sys.stdin).get("token",""))
except Exception:
    print("")' 2>/dev/null)"

    if [[ -n "$token" ]]; then
      ok "Login NPM padrão já funciona: $NPM_EMAIL / $NPM_PASS"
      return 0
    fi
    sleep 1
  done

  # 2) Tenta criar o primeiro usuário. Em versões novas isso é permitido sem autenticação
  # somente quando ainda não existe nenhum usuário ativo.
  for i in {1..45}; do
    create_resp="$(curl -m 12 -s -X POST "http://127.0.0.1:81/api/users" \
      -H "Content-Type: application/json" \
      -d "{\"name\":\"Nexus NVR\",\"nickname\":\"Admin\",\"email\":\"$NPM_EMAIL\",\"roles\":[\"admin\"],\"is_disabled\":false,\"auth\":{\"type\":\"password\",\"secret\":\"$NPM_PASS\"}}" || true)"

    if echo "$create_resp" | grep -q "\"email\":\"$NPM_EMAIL\""; then
      ok "Primeiro usuário NPM criado: $NPM_EMAIL / $NPM_PASS"
      break
    fi

    # Se já existir, o login deve funcionar logo depois.
    if echo "$create_resp" | grep -Eiq "already|exist|duplicate|unique"; then
      warn "Usuário NPM parece já existir; testando login."
      break
    fi

    sleep 2
  done

  # 3) Testa login novamente após criação.
  for i in {1..20}; do
    login_resp="$(curl -m 8 -s -X POST "http://127.0.0.1:81/api/tokens" \
      -H "Content-Type: application/json" \
      -d "{\"identity\":\"$NPM_EMAIL\",\"secret\":\"$NPM_PASS\"}" || true)"

    token="$(echo "$login_resp" | python3 -c 'import sys,json
try:
    print(json.load(sys.stdin).get("token",""))
except Exception:
    print("")' 2>/dev/null)"

    if [[ -n "$token" ]]; then
      ok "Login NPM testado com sucesso: $NPM_EMAIL / $NPM_PASS"
      return 0
    fi
    sleep 2
  done

  # 4) Compatibilidade com versões antigas: admin@example.com/changeme.
  local old_token
  old_token="$(curl -m 8 -s -X POST "http://127.0.0.1:81/api/tokens" \
    -H "Content-Type: application/json" \
    -d '{"identity":"admin@example.com","secret":"changeme"}' | python3 -c 'import sys,json
try:
    print(json.load(sys.stdin).get("token",""))
except Exception:
    print("")' 2>/dev/null)"

  if [[ -n "$old_token" ]]; then
    curl -m 10 -s -X PUT "http://127.0.0.1:81/api/users/1" \
      -H "Authorization: Bearer $old_token" -H "Content-Type: application/json" \
      -d "{\"name\":\"Nexus NVR\",\"nickname\":\"Admin\",\"email\":\"$NPM_EMAIL\",\"roles\":[\"admin\"],\"is_disabled\":false}" >/dev/null 2>&1 || true

    curl -m 10 -s -X PUT "http://127.0.0.1:81/api/users/1/auth" \
      -H "Authorization: Bearer $old_token" -H "Content-Type: application/json" \
      -d "{\"type\":\"password\",\"current\":\"changeme\",\"secret\":\"$NPM_PASS\"}" >/dev/null 2>&1 || true

    login_resp="$(curl -m 8 -s -X POST "http://127.0.0.1:81/api/tokens" \
      -H "Content-Type: application/json" \
      -d "{\"identity\":\"$NPM_EMAIL\",\"secret\":\"$NPM_PASS\"}" || true)"
    token="$(echo "$login_resp" | python3 -c 'import sys,json
try:
    print(json.load(sys.stdin).get("token",""))
except Exception:
    print("")' 2>/dev/null)"

    [[ -n "$token" ]] && { ok "NPM antigo atualizado e login testado"; return 0; }
  fi

  warn "Não consegui configurar/login NPM automaticamente. Última resposta de criação:"
  echo "$create_resp"
}

cron_setup(){
  sec "Configurando cron"
  local tmp
  tmp="$(mktemp)"

  # Mantem a retencao profissional como unica responsavel por apagar videos.
  # Remove tambem a limpeza legada criada por versoes antigas do instalador.
  crontab -l 2>/dev/null \
    | grep -v '/home/nexus/cria_pasta_camera.sh' \
    | grep -v "find /home/nexus/gravacoes -type f -name '\\*.mp4' -mtime +1 -delete" \
    | grep -v 'find /home/nexus/gravacoes -type f -name '\''\*.mp4'\'' -mtime +1 -delete' \
    > "$tmp" || true

  echo "49 23 * * * /home/nexus/cria_pasta_camera.sh" >> "$tmp"
  crontab "$tmp"
  rm -f "$tmp"
  ok "Cron configurado sem limpeza legada de videos"
}

http_code(){
  local url="$1"; local host="${2:-}"
  if [[ -n "$host" ]]; then
    curl -m 15 -s -o /tmp/nvr_body -w "%{http_code}" -H "Host: $host" "$url" 2>/dev/null
  else
    curl -m 15 -s -o /tmp/nvr_body -w "%{http_code}" "$url" 2>/dev/null
  fi
}

wait_get(){
  local desc="$1"
  local url="$2"
  local host="${3:-}"
  local expect="${4:-^200$}"
  local code="000"

  for i in {1..45}; do
    code="$(http_code "$url" "$host")"
    if echo "$code" | grep -Eq "$expect"; then
      ok "$desc HTTP $code"
      return 0
    fi
    sleep 2
  done

  fail "$desc HTTP $code"
  return 1
}

test_filebrowser_login(){
  local resp
  resp="$(curl -m 12 -s -X POST -H "Content-Type: application/json" \
    -d "{\"username\":\"$FB_USER\",\"password\":\"$FB_PASS\"}" \
    http://127.0.0.1:8085/api/login || true)"
  if echo "$resp" | grep -Eq '^[A-Za-z0-9_-]+\.[A-Za-z0-9_-]+\.[A-Za-z0-9_-]+'; then
    ok "Login Filebrowser OK: $FB_USER / $FB_PASS"
    return 0
  fi
  warn "Login Filebrowser falhou. Tentando corrigir com container parado."
  docker stop visualizador_videos >/dev/null 2>&1 || true
  chmod -R 777 "$TARGET/filebrowser_config" "$TARGET/filebrowser_db"
  docker run --rm \
    -v "$TARGET/gravacoes:/srv" \
    -v "$TARGET/filebrowser_db:/database" \
    -v "$TARGET/filebrowser_config:/config" \
    filebrowser/filebrowser \
    -d /database/filebrowser.db users add "$FB_USER" "$FB_PASS" --perm.admin >/tmp/fb_fix.out 2>/tmp/fb_fix.err || true
  docker start visualizador_videos >/dev/null 2>&1 || true
  sleep 8
  resp="$(curl -m 12 -s -X POST -H "Content-Type: application/json" \
    -d "{\"username\":\"$FB_USER\",\"password\":\"$FB_PASS\"}" \
    http://127.0.0.1:8085/api/login || true)"
  if echo "$resp" | grep -Eq '^[A-Za-z0-9_-]+\.[A-Za-z0-9_-]+\.[A-Za-z0-9_-]+'; then
    fix "Login Filebrowser corrigido"
  else
    fail "Login Filebrowser não funcionou mesmo após correção"
    cat /tmp/fb_fix.out 2>/dev/null || true
    cat /tmp/fb_fix.err 2>/dev/null || true
  fi
}

test_services(){
  sec "Testando serviços no IP $CURRENT_IP"
  local c

  for container in go2rtc nvr-frontend visualizador_videos nexus_api nginx-proxy-manager_app_1; do
    docker ps --format '{{.Names}}' | grep -qx "$container" && ok "$container rodando" || fail "$container não está rodando"
  done

  wait_get "Frontend informativo 9000" "http://127.0.0.1:9000" "" "^(200|301|302)$"
  wait_get "Proxy/painel porta $PANEL_PORT" "http://127.0.0.1:${PANEL_PORT}" "$CURRENT_IP" "^200$"
  wait_get "API principal" "http://127.0.0.1:3000/maestro/config" "" "^200$"
  wait_get "API principal via proxy" "http://127.0.0.1:${PANEL_PORT}/maestro/config" "$CURRENT_IP" "^200$"
  wait_get "Go2RTC direto" "http://127.0.0.1:1984" "" "^200$"
  wait_get "Go2RTC via proxy" "http://127.0.0.1:${PANEL_PORT}/stream.html" "$CURRENT_IP" "^200$"
  wait_get "Filebrowser" "http://127.0.0.1:8085/login" "" "^(200|301|302|401|403|404)$" || warn "Filebrowser ainda não respondeu como esperado"
  test_filebrowser_login
}

test_time(){
  sec "Testando horários"
  echo "HOST: $(date)"
  echo "NEXUS_API: $(docker exec nexus_api date 2>/dev/null || echo indisponivel)"
  if docker exec nexus_api date 2>/dev/null | grep -Eq ' -03|BRT|GMT'; then
    ok "nexus_api com horário local aparente"
  else
    warn "nexus_api pode estar com fuso diferente"
  fi
}

active_camera_count(){
  python3 - <<'PY'
import json, pathlib
p=pathlib.Path("/home/nexus/api/nvr_config.json")
try: db=json.loads(p.read_text())
except Exception: print(0); raise SystemExit
print(sum(1 for c in db.values() if c.get("active") and c.get("name") and (c.get("url") or c.get("recurl"))))
PY
}

test_recording(){
  sec "Testando gravação"
  /home/nexus/cria_pasta_camera.sh || true

  local n
  n="$(active_camera_count 2>/dev/null || echo 0)"
  if [[ "$n" =~ ^[0-9]+$ && "$n" -gt 0 ]]; then
    ok "Há câmera configurada. O teste real será feito pelo painel/API após salvar câmera."
    return 0
  fi

  warn "Nenhuma câmera configurada. Fazendo teste sintético com FFmpeg."
  local day out size
  day="$(TZ="$TZ_NVR" date +%d-%m-%Y)"
  mkdir -p "$TARGET/gravacoes/_teste/$day"
  out="$TARGET/gravacoes/_teste/$day/teste_$(TZ="$TZ_NVR" date +%H-%M-%S).mkv"

  docker run --rm --name gravador_teste_nexus \
    -e TZ="$TZ_NVR" \
    -v "$TARGET/gravacoes:/gravacoes" \
    jrottenberg/ffmpeg:latest \
    -hide_banner -loglevel error -y \
    -f lavfi -i testsrc=duration=8:size=640x360:rate=15 \
    -c:v mpeg4 -q:v 5 \
    "/gravacoes/_teste/$day/$(basename "$out")" >/dev/null 2>&1

  if [[ -f "$out" ]]; then
    size="$(stat -c%s "$out")"
    if [[ "$size" -gt 50000 ]]; then
      ok "Vídeo sintético criado: $out ($size bytes)"
      rm -rf "$TARGET/gravacoes/_teste"         && ok "Pasta de teste removida: $TARGET/gravacoes/_teste"         || warn "Não consegui remover pasta de teste: $TARGET/gravacoes/_teste"
    else
      fail "Vídeo sintético pequeno: $size bytes"
      warn "Mantive a pasta _teste para diagnóstico."
    fi
  else
    fail "Vídeo sintético não foi criado"
  fi
}

configure_static_ip(){
  sec "Mudança para IP final"
  if [[ "$CURRENT_IP" == "$FINAL_IP" ]]; then
    ok "Já está no IP final: $FINAL_IP"
    IP_APPLIED="1"
    return 0
  fi

  echo "Sistema testado no IP atual: $CURRENT_IP"
  echo "IP final desejado: $FINAL_IP"
  echo "Desligue/remova da rede qualquer equipamento que use $FINAL_IP."
  read -r -p "Deseja aplicar IP fixo $FINAL_IP agora? [s/N]: " ans
  [[ "$ans" =~ ^[sS] ]] || { warn "IP não alterado. Rode novamente quando quiser finalizar."; IP_APPLIED="0"; return 0; }

  if ping -c 3 -W 1 "$FINAL_IP" >/dev/null 2>&1; then
    fail "IP $FINAL_IP respondeu ping. Não vou aplicar para evitar conflito."
    return 1
  fi
  ok "IP $FINAL_IP parece livre"

  local np="/etc/netplan/01-netcfg.yaml"
  local backup="/etc/netplan/01-netcfg.yaml.bak_nexus_$(date +%Y%m%d_%H%M%S)"
  cp "$np" "$backup" 2>/dev/null || cp /etc/netplan/*.yaml "$backup" 2>/dev/null || true
  ok "Backup Netplan: $backup"

  if [[ "$IS_WIFI" == "1" ]]; then
    read -r ssid pass < <(python3 - <<'PY'
import glob,re
txt="\n".join(open(f,errors="ignore").read() for f in glob.glob("/etc/netplan/*.yaml"))
m=re.search(r'access-points:\s*\n\s*["\']?([^:"\'\n]+)["\']?\s*:\s*\n\s*password:\s*["\']?([^"\'\n]+)', txt)
print((m.group(1)+" "+m.group(2)) if m else " ")
PY
)
    [[ -n "$ssid" ]] || read -r -p "SSID Wi-Fi: " ssid
    if [[ -z "$pass" ]]; then read -r -s -p "Senha Wi-Fi: " pass; echo; fi
    cat > "$np" <<EOF
network:
  version: 2
  renderer: networkd
  wifis:
    $IFACE:
      dhcp4: false
      addresses:
        - $FINAL_IP/$PREFIX
      routes:
        - to: default
          via: $GATEWAY
      nameservers:
        addresses:
          - $GATEWAY
          - 8.8.8.8
      access-points:
        "$ssid":
          password: "$pass"
EOF
  else
    cat > "$np" <<EOF
network:
  version: 2
  renderer: networkd
  ethernets:
    $IFACE:
      dhcp4: false
      addresses:
        - $FINAL_IP/$PREFIX
      routes:
        - to: default
          via: $GATEWAY
      nameservers:
        addresses:
          - $GATEWAY
          - 8.8.8.8
EOF
  fi

  chmod 600 "$np"
  netplan generate || { fail "Netplan inválido. Restaurando."; cp "$backup" "$np"; return 1; }

  configure_proxy_file "$FINAL_IP"
  echo "Ao aplicar, o SSH pode cair. Reconecte em: ssh $RUN_USER@$FINAL_IP"
  echo "Depois rode novamente: sudo bash $SCRIPT_DIR/$(basename "$0")"
  read -r -p "Digite APLICAR para aplicar agora: " c
  [[ "$c" == "APLICAR" ]] || { warn "Aplicação cancelada."; return 0; }

  echo "PHASE=\"WAIT_FINAL_VERIFY\"" >> "$STATE_FILE"
  netplan apply || { fail "netplan apply falhou"; cp "$backup" "$np"; netplan apply || true; IP_APPLIED="0"; return 1; }
  IP_APPLIED="1"
  sleep 8

  # Se o SSH não cair e o script continuar, já reinicia os containers com o IP novo.
  detect_network || true
  if [[ "${CURRENT_IP:-}" == "$FINAL_IP" ]]; then
    configure_proxy_file "$FINAL_IP"
    configure_go2rtc_webrtc
    restart_containers_after_ip_change
    test_services
  else
    warn "IP atual ainda não parece ser $FINAL_IP. Reconecte no IP final e rode o script novamente para verificação."
  fi
}

restart_containers_after_ip_change(){
  sec "Reiniciando containers após troca/verificação de IP"

  local containers=(
    go2rtc
    nvr-frontend
    visualizador_videos
    nexus_api
    nginx-proxy-manager_app_1
  )

  local restarted=0
  for c in "${containers[@]}"; do
    if docker ps -a --format '{{.Names}}' | grep -qx "$c"; then
      docker restart "$c" >/dev/null 2>&1 \
        && { ok "Container reiniciado: $c"; restarted=$((restarted+1)); } \
        || warn "Não consegui reiniciar: $c"
    else
      warn "Container não encontrado para reiniciar: $c"
    fi
  done

  if [[ "$restarted" -gt 0 ]]; then
    echo "[INFO] Aguardando containers estabilizarem após restart..."
    sleep 20
  fi

  if docker exec nginx-proxy-manager_app_1 nginx -t >/dev/null 2>&1; then
    docker exec nginx-proxy-manager_app_1 nginx -s reload >/dev/null 2>&1 || true
    ok "Nginx recarregado após restart"
  else
    warn "Nginx não aceitou teste após restart; os testes finais vão indicar se há falha."
  fi
}

final_summary(){
  sec "Resumo"
  ACCESS_IP="$CURRENT_IP"
  [[ "$IP_APPLIED" == "1" ]] && ACCESS_IP="$FINAL_IP"
  echo "OK: $OK"
  echo "Avisos: $WARN"
  echo "Falhas: $FAIL"
  echo "Correções: $FIX"
  echo
  echo "Modo de rede: $(network_mode_label "${NETWORK_MODE:-hybrid}")"
  echo "Acesso local:"
  if [[ "${NETWORK_MODE:-hybrid}" != "external" ]]; then
    echo "  http://${ACCESS_IP}:${PANEL_PORT}"
  else
    echo "  desativado como rota do app neste modo"
  fi
  if [[ "$IP_APPLIED" != "1" && "$CURRENT_IP" != "$FINAL_IP" ]]; then
    echo "  IP final escolhido, ainda não aplicado: http://${FINAL_IP}:${PANEL_PORT}"
  fi
  [[ -n "$EXTERNAL_HOST" ]] && echo "Acesso externo configurado no proxy: http://${EXTERNAL_HOST}:${EXTERNAL_PORT}"
  if [[ -n "$EXTERNAL_HOST" ]]; then
    echo "RTC/WebRTC externo:"
    echo "  Liberar também UDP ${EXTERNAL_PORT} para usar RTC sem cair para MSE."
    echo "  Não precisa abrir TCP 8555; o script usa UDP ${EXTERNAL_PORT}->go2rtc."
  fi
  echo
  echo "Gravações:"
  echo "  Caminho do sistema: ${RECORDINGS_SYSTEM_DIR:-/home/nexus/gravacoes}"
  echo "  Pasta real: ${RECORDINGS_REAL_DIR:-/home/nexus/gravacoes}"
  echo
  echo "Credenciais padrão:"
  echo "  Nginx Proxy Manager: $NPM_EMAIL / $NPM_PASS"
  echo "  Filebrowser: $FB_USER / $FB_PASS"
  echo
  echo "Observação: o painel do Nginx Proxy Manager pode mostrar 0 Proxy Hosts."
  echo "As rotas do Nexus NVR são geradas automaticamente por arquivo interno do Nginx."
  echo
  echo "IMPORTANTE: altere as senhas padrão após o primeiro acesso."
  echo "Log: $LOG_FILE"
  mkdir -p "$TARGET/logs" 2>/dev/null || true
  cp "$LOG_FILE" "$TARGET/logs/" 2>/dev/null || true
}

main(){
  need_root
  detect_network
  load_state_if_final
  if [[ "${FINAL_VERIFY_ONLY:-0}" != "1" ]]; then
    ask_config
  else
    # shellcheck disable=SC1090
    source "$STATE_FILE"

    NPM_EMAIL="${NPM_EMAIL:-$DEFAULT_NPM_EMAIL}"
    NPM_PASS="${NPM_PASS:-$DEFAULT_NPM_PASS}"
    FB_USER="${FB_USER:-$DEFAULT_FB_USER}"
    FB_PASS="${FB_PASS:-$DEFAULT_FB_PASS}"
    NETWORK_MODE="${NETWORK_MODE:-$DEFAULT_NETWORK_MODE}"
    RECORDINGS_MOUNT="${RECORDINGS_MOUNT:-/}"
    RECORDINGS_REAL_DIR="${RECORDINGS_REAL_DIR:-/home/nexus/gravacoes}"
    RECORDINGS_SYSTEM_DIR="${RECORDINGS_SYSTEM_DIR:-/home/nexus/gravacoes}"
  fi

  check_package

  if [[ "${FINAL_VERIFY_ONLY:-0}" == "1" ]]; then
    sec "Modo verificação final"
    ok "IP final escolhido detectado: $CURRENT_IP"
    ok "Não vou reinstalar Docker, recopyar arquivos nem recriar containers."
    configure_proxy_file "$CURRENT_IP"
    configure_go2rtc_webrtc
    if docker exec nginx-proxy-manager_app_1 nginx -t >/dev/null 2>&1; then
      docker exec nginx-proxy-manager_app_1 nginx -s reload >/dev/null 2>&1 || true
      ok "Nginx recarregado"
    else
      warn "Nginx não aceitou reload agora; vou continuar os testes."
    fi

    # Após a troca de IP, reinicia os containers para evitar cache/rotas antigas.
    restart_containers_after_ip_change

    setup_npm_login
    test_services
    test_time
    test_recording
    setup_npm_login
    IP_APPLIED="1"
    final_summary
    exit 0
  fi

  install_deps
  prepare_files
  set_timezone
  write_compose
  configure_proxy_file "$CURRENT_IP"
  configure_go2rtc_webrtc
  cron_setup
  start_docker
  setup_npm_login
  test_services
  test_time
  test_recording

  # Reforço: em algumas versões o NPM só libera criação da primeira conta
  # depois que o backend e as migrações terminam totalmente.
  setup_npm_login

  configure_static_ip
  final_summary
}

main "$@"
