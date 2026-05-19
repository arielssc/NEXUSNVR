#!/usr/bin/env bash
# ============================================================
# Nexus IoT Portao - Instalador / Diagnostico / Removedor
# ============================================================

set -Eeuo pipefail

VERSION="2026-05-19-iot-portao-2.0"
APP_NAME="api-portao"
ROOT_DIR="/opt/nexus-iot-portao"
API_DIR="$ROOT_DIR/api"
APP_FILE="$API_DIR/api_portao.js"
CONFIG_FILE="$ROOT_DIR/portao.env"
MOSQ_DIR="$ROOT_DIR/mosquitto"
MOSQ_CONF="$MOSQ_DIR/config/mosquitto.conf"
MOSQ_CONTAINER="nexus_iot_mosquitto"
LEGACY_MOSQ_DIR="/opt/mosquitto"
LEGACY_MOSQ_CONTAINER="mosquitto"
LOG_FILE="/tmp/nexus_iot_portao_$(date +%Y%m%d_%H%M%S).log"

DEFAULT_API_PORT="8081"
DEFAULT_MQTT_PORT="1883"
DEFAULT_TOPIC_CMD="casa/portao/comando"
DEFAULT_TOPIC_STATUS="casa/portao/status"
DEFAULT_TOPIC_CONEXAO="casa/portao/conexao"
DEFAULT_TOPIC_TRAVA="casa/portao/trava"

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

ask(){
  local prompt="$1"
  local default="$2"
  local value
  read -r -p "$prompt [$default]: " value || true
  echo "${value:-$default}"
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

confirm_text(){
  local prompt="$1"
  local expected="$2"
  local ans
  echo
  warn "$prompt"
  read -r -p "Digite exatamente ${expected} para confirmar: " ans || true
  [[ "$ans" == "$expected" ]]
}

pause_enter(){
  read -r -p "${1:-Pressione Enter para continuar...}" _ || true
}

valid_port(){
  local p="$1"
  [[ "$p" =~ ^[0-9]+$ ]] && [[ "$p" -ge 1 ]] && [[ "$p" -le 65535 ]]
}

valid_topic(){
  local t="$1"
  [[ -n "$t" ]] && [[ "$t" != *" "* ]] && [[ "$t" != *$'\t'* ]]
}

get_default_user(){
  if [[ -n "${SUDO_USER:-}" && "${SUDO_USER}" != "root" ]]; then
    echo "$SUDO_USER"
  elif id ubuntu >/dev/null 2>&1; then
    echo "ubuntu"
  else
    logname 2>/dev/null || echo "root"
  fi
}

run_as_user(){
  local user="$1"
  shift
  if [[ "$user" == "root" ]]; then
    bash -lc "$*"
  else
    su - "$user" -c "$*"
  fi
}

public_ip(){
  curl -4 -s --max-time 4 ifconfig.me 2>/dev/null || \
  curl -4 -s --max-time 4 https://api.ipify.org 2>/dev/null || \
  hostname -I 2>/dev/null | awk '{print $1}' || true
}

load_config(){
  APP_USER="$(get_default_user)"
  API_PORT="$DEFAULT_API_PORT"
  MQTT_PORT="$DEFAULT_MQTT_PORT"
  TOPIC_CMD="$DEFAULT_TOPIC_CMD"
  TOPIC_STATUS="$DEFAULT_TOPIC_STATUS"
  TOPIC_CONEXAO="$DEFAULT_TOPIC_CONEXAO"
  TOPIC_TRAVA="$DEFAULT_TOPIC_TRAVA"

  if [[ -f "$CONFIG_FILE" ]]; then
    # shellcheck disable=SC1090
    source "$CONFIG_FILE" 2>/dev/null || true
  fi

  API_PORT="${API_PORT:-$DEFAULT_API_PORT}"
  MQTT_PORT="${MQTT_PORT:-$DEFAULT_MQTT_PORT}"
}

detect_api_port(){
  load_config
  if [[ -f "$APP_FILE" ]]; then
    grep -oE 'const API_PORT = [0-9]+' "$APP_FILE" | grep -oE '[0-9]+' | head -1 && return 0
  fi
  echo "$API_PORT"
}

detect_mqtt_port(){
  load_config
  if [[ -f "$MOSQ_CONF" ]]; then
    awk '/^[[:space:]]*listener[[:space:]]+[0-9]+/ {print $2; exit}' "$MOSQ_CONF" && return 0
  fi
  echo "$MQTT_PORT"
}

pm2_app_exists_for_user(){
  local user="$1"
  id "$user" >/dev/null 2>&1 || return 1
  cmd_exists pm2 || return 1
  run_as_user "$user" "pm2 jlist 2>/dev/null" | grep -q "\"name\":\"$APP_NAME\""
}

port_is_listening(){
  local port="$1"
  ss -ltnp 2>/dev/null | grep -qE "[:.]${port}[[:space:]]"
}

container_uses_port(){
  local container="$1"
  local port="$2"
  docker ps -a --format '{{.Names}} {{.Ports}}' 2>/dev/null | awk -v c="$container" -v p=":$port" '$1==c && index($0,p){found=1} END{exit !found}'
}

legacy_mosquitto_is_nexus(){
  docker inspect "$LEGACY_MOSQ_CONTAINER" >/dev/null 2>&1 || return 1
  docker inspect "$LEGACY_MOSQ_CONTAINER" --format '{{range .Mounts}}{{.Source}}{{"\n"}}{{end}}' 2>/dev/null | grep -q "^$LEGACY_MOSQ_DIR"
}

show_port_users(){
  local port="$1"
  warn "A porta TCP $port esta em uso."
  echo
  echo "Processos:"
  ss -ltnp 2>/dev/null | grep -E "[:.]${port}[[:space:]]" || true
  echo
  echo "Containers:"
  docker ps -a --format 'table {{.Names}}\t{{.Ports}}\t{{.Status}}' 2>/dev/null | grep -E "(:${port}->|0\.0\.0\.0:${port}|:::${port}|${port}/tcp|NAMES)" || true
}

release_own_port_if_possible(){
  local port="$1"
  local released=0

  if container_uses_port "$MOSQ_CONTAINER" "$port"; then
    warn "Removendo container antigo do Nexus IoT que usa a porta $port: $MOSQ_CONTAINER"
    docker rm -f "$MOSQ_CONTAINER" >/dev/null 2>&1 || true
    released=1
  fi

  if container_uses_port "$LEGACY_MOSQ_CONTAINER" "$port" && legacy_mosquitto_is_nexus; then
    warn "Removendo Mosquitto legado do Nexus IoT que usa a porta $port: $LEGACY_MOSQ_CONTAINER"
    docker rm -f "$LEGACY_MOSQ_CONTAINER" >/dev/null 2>&1 || true
    released=1
  fi

  if [[ "$port" == "$API_PORT" ]] && pm2_app_exists_for_user "$APP_USER"; then
    warn "Removendo PM2 antigo $APP_NAME do usuario $APP_USER"
    run_as_user "$APP_USER" "pm2 delete '$APP_NAME' >/dev/null 2>&1 || true"
    run_as_user "$APP_USER" "pm2 save >/dev/null 2>&1 || true"
    released=1
  fi

  if [[ "$released" -eq 1 ]]; then
    sleep 2
  fi
  return 0
}

resolve_port(){
  local var_name="$1"
  local current_port="$2"
  local label="$3"

  while true; do
    valid_port "$current_port" || {
      warn "Porta invalida para $label."
      read -r -p "Digite outra porta: " current_port || true
      continue
    }

    release_own_port_if_possible "$current_port"

    if ! port_is_listening "$current_port"; then
      printf -v "$var_name" '%s' "$current_port"
      ok "$label definido na porta $current_port"
      return 0
    fi

    show_port_users "$current_port"
    warn "A porta esta ocupada por algo que nao foi identificado como Nexus IoT Portao."
    echo "1) Escolher outra porta"
    echo "2) Cancelar instalacao"
    read -r -p "Escolha [1/2]: " opt || true
    case "${opt:-}" in
      1) read -r -p "Nova porta para $label: " current_port || true ;;
      2) fail "Instalacao cancelada."; exit 1 ;;
      *) warn "Opcao invalida." ;;
    esac
  done
}

install_dependencies(){
  section "DEPENDENCIAS"
  export DEBIAN_FRONTEND=noninteractive

  apt-get update
  apt-get install -y curl ca-certificates gnupg lsb-release iptables-persistent

  if ! cmd_exists docker; then
    apt-get install -y docker.io
    ok "Docker instalado"
  else
    ok "Docker ja instalado: $(docker -v 2>/dev/null)"
  fi
  systemctl enable --now docker

  local node_major=0
  if cmd_exists node; then
    node_major="$(node -v | sed 's/^v//' | cut -d. -f1)"
  fi

  if [[ "${node_major:-0}" -lt 18 ]]; then
    curl -fsSL https://deb.nodesource.com/setup_20.x | bash -
    apt-get install -y nodejs
    ok "Node.js instalado"
  else
    ok "Node.js ja instalado: $(node -v)"
  fi

  if ! cmd_exists pm2; then
    npm install -g pm2
    ok "PM2 instalado"
  else
    ok "PM2 ja instalado: $(pm2 -v)"
  fi
}

add_firewall_rule(){
  local port="$1"
  if iptables -C INPUT -p tcp -m tcp --dport "$port" -j ACCEPT 2>/dev/null; then
    ok "Firewall local ja libera TCP $port"
  else
    iptables -I INPUT 1 -p tcp -m tcp --dport "$port" -j ACCEPT
    CHANGED=$((CHANGED+1))
    ok "Firewall local liberado TCP $port"
  fi
}

remove_firewall_rule(){
  local port="$1"
  local removed=0
  while iptables -C INPUT -p tcp -m tcp --dport "$port" -j ACCEPT 2>/dev/null; do
    iptables -D INPUT -p tcp -m tcp --dport "$port" -j ACCEPT || break
    removed=1
  done
  [[ "$removed" -eq 1 ]] && ok "Regra TCP $port removida"
}

save_firewall_rules(){
  if cmd_exists netfilter-persistent; then
    netfilter-persistent save >/dev/null 2>&1 || true
  elif [[ -d /etc/iptables ]]; then
    iptables-save > /etc/iptables/rules.v4 || true
  fi
}

create_mosquitto(){
  section "MOSQUITTO"
  mkdir -p "$MOSQ_DIR/config" "$MOSQ_DIR/data" "$MOSQ_DIR/log"
  chown -R 1883:1883 "$MOSQ_DIR/data" "$MOSQ_DIR/log" || true

  cat > "$MOSQ_CONF" <<EOF
# Nexus IoT Portao - Mosquitto
persistence true
persistence_location /mosquitto/data/
log_dest file /mosquitto/log/mosquitto.log
listener ${MQTT_PORT}
allow_anonymous true
EOF

  docker rm -f "$MOSQ_CONTAINER" >/dev/null 2>&1 || true
  if docker inspect "$LEGACY_MOSQ_CONTAINER" >/dev/null 2>&1 && legacy_mosquitto_is_nexus; then
    docker rm -f "$LEGACY_MOSQ_CONTAINER" >/dev/null 2>&1 || true
  fi

  docker run -d \
    --name "$MOSQ_CONTAINER" \
    --restart unless-stopped \
    -p "${MQTT_PORT}:${MQTT_PORT}" \
    -v "$MOSQ_CONF:/mosquitto/config/mosquitto.conf" \
    -v "$MOSQ_DIR/data:/mosquitto/data" \
    -v "$MOSQ_DIR/log:/mosquitto/log" \
    eclipse-mosquitto:latest >/dev/null

  CHANGED=$((CHANGED+1))
  ok "Mosquitto iniciado em TCP $MQTT_PORT"
}

create_node_app(){
  section "API DO PORTAO"
  mkdir -p "$API_DIR"

  cat > "$API_DIR/package.json" <<'JSON'
{
  "name": "nexus-iot-portao",
  "version": "1.0.0",
  "private": true,
  "main": "api_portao.js",
  "dependencies": {
    "mqtt": "^5.15.1",
    "socket.io": "^4.8.3"
  }
}
JSON

  cat > "$APP_FILE" <<'NODE'
const http = require('http');
const mqtt = require('mqtt');
const { Server } = require('socket.io');

const API_PORT = __API_PORT__;
const MQTT_BROKER = 'mqtt://localhost:__MQTT_PORT__';
const TOPIC_CMD = '__TOPIC_CMD__';
const TOPIC_STATUS = '__TOPIC_STATUS__';
const TOPIC_CONEXAO = '__TOPIC_CONEXAO__';
const TOPIC_TRAVA = '__TOPIC_TRAVA__';

let estadoPortao = 'fechado';
let estadoConexao = 'Off';
let estadoTrava = 'Off';

const mqttClient = mqtt.connect(MQTT_BROKER);

mqttClient.on('connect', () => {
  console.log(`MQTT conectado em ${MQTT_BROKER}`);
  mqttClient.subscribe([TOPIC_STATUS, TOPIC_CONEXAO, TOPIC_TRAVA]);
});

mqttClient.on('error', (err) => {
  console.error('Erro MQTT:', err.message);
});

const server = http.createServer((req, res) => {
  res.setHeader('Access-Control-Allow-Origin', '*');
  res.setHeader('Access-Control-Allow-Methods', 'GET, POST, OPTIONS');
  res.setHeader('Access-Control-Allow-Headers', 'Content-Type');

  if (req.method === 'OPTIONS') {
    res.writeHead(204);
    return res.end();
  }

  if (req.method === 'GET' && req.url === '/maestro/portao/status') {
    res.writeHead(200, { 'Content-Type': 'application/json' });
    return res.end(JSON.stringify({
      status: estadoPortao,
      conexao: estadoConexao,
      trava: estadoTrava
    }));
  }

  if (req.method === 'POST') {
    if (req.url === '/maestro/portao') {
      mqttClient.publish(TOPIC_CMD, 'PULSO');
      res.writeHead(200, { 'Content-Type': 'application/json' });
      return res.end(JSON.stringify({ msg: 'Pulso enviado!' }));
    }

    if (req.url === '/maestro/portao/travar') {
      mqttClient.publish(TOPIC_CMD, 'TRAVAR', { retain: true });
      res.writeHead(200, { 'Content-Type': 'application/json' });
      return res.end(JSON.stringify({ msg: 'Trava acionada!' }));
    }

    if (req.url === '/maestro/portao/destravar') {
      mqttClient.publish(TOPIC_CMD, 'DESTRAVAR', { retain: true });
      res.writeHead(200, { 'Content-Type': 'application/json' });
      return res.end(JSON.stringify({ msg: 'Trava liberada!' }));
    }
  }

  res.writeHead(404);
  res.end();
});

const io = new Server(server, {
  cors: { origin: '*', methods: ['GET', 'POST'] }
});

io.on('connection', (socket) => {
  socket.emit('atualizacao_portao', {
    status: estadoPortao,
    conexao: estadoConexao,
    trava: estadoTrava
  });
});

mqttClient.on('message', (topic, message) => {
  const msg = message.toString().trim();
  console.log(`MQTT ${topic}: ${msg}`);

  if (topic.includes('status')) {
    estadoPortao = msg;
  } else if (topic.includes('conexao')) {
    estadoConexao = msg;
  } else if (topic.includes('trava')) {
    estadoTrava = msg;
  }

  io.emit('atualizacao_portao', {
    status: estadoPortao,
    conexao: estadoConexao,
    trava: estadoTrava
  });
});

server.listen(API_PORT, () => {
  console.log(`Nexus IoT Portao online na porta ${API_PORT}`);
});
NODE

  sed -i \
    -e "s|__API_PORT__|$API_PORT|g" \
    -e "s|__MQTT_PORT__|$MQTT_PORT|g" \
    -e "s|__TOPIC_CMD__|$TOPIC_CMD|g" \
    -e "s|__TOPIC_STATUS__|$TOPIC_STATUS|g" \
    -e "s|__TOPIC_CONEXAO__|$TOPIC_CONEXAO|g" \
    -e "s|__TOPIC_TRAVA__|$TOPIC_TRAVA|g" \
    "$APP_FILE"

  cat > "$CONFIG_FILE" <<EOF
APP_USER="$APP_USER"
API_PORT="$API_PORT"
MQTT_PORT="$MQTT_PORT"
TOPIC_CMD="$TOPIC_CMD"
TOPIC_STATUS="$TOPIC_STATUS"
TOPIC_CONEXAO="$TOPIC_CONEXAO"
TOPIC_TRAVA="$TOPIC_TRAVA"
EOF
  chmod 600 "$CONFIG_FILE" 2>/dev/null || true

  chown -R "$APP_USER:$APP_USER" "$ROOT_DIR"
  run_as_user "$APP_USER" "cd '$API_DIR' && npm install --omit=dev"
  ok "API preparada em $API_DIR"
}

setup_pm2(){
  section "PM2"
  run_as_user "$APP_USER" "pm2 delete '$APP_NAME' >/dev/null 2>&1 || true"
  run_as_user "$APP_USER" "cd '$API_DIR' && pm2 start '$APP_FILE' --name '$APP_NAME'"
  run_as_user "$APP_USER" "pm2 save"
  env PATH="$PATH:/usr/bin" pm2 startup systemd -u "$APP_USER" --hp "/home/$APP_USER" >/tmp/nexus_iot_pm2_startup.log 2>&1 || true
  systemctl enable "pm2-$APP_USER" >/dev/null 2>&1 || true
  systemctl restart "pm2-$APP_USER" >/dev/null 2>&1 || true
  CHANGED=$((CHANGED+1))
  ok "PM2 configurado para $APP_NAME"
}

http_code(){
  local url="$1"
  curl -sS --max-time 6 -o /dev/null -w '%{http_code}' "$url" 2>/dev/null || echo 000
}

validate_services(){
  section "VALIDACAO"
  local code
  code="$(http_code "http://127.0.0.1:$API_PORT/maestro/portao/status")"
  [[ "$code" =~ ^[23] ]] && ok "API HTTP $code" || fail "API HTTP $code"

  code="$(http_code "http://127.0.0.1:$API_PORT/socket.io/?EIO=4&transport=polling")"
  [[ "$code" =~ ^[23] ]] && ok "Socket.IO HTTP $code" || warn "Socket.IO HTTP $code"

  if docker ps --format '{{.Names}}' | grep -qx "$MOSQ_CONTAINER"; then
    ok "Container $MOSQ_CONTAINER rodando"
  else
    fail "Container $MOSQ_CONTAINER nao esta rodando"
  fi

  if pm2_app_exists_for_user "$APP_USER"; then
    ok "PM2 $APP_NAME encontrado no usuario $APP_USER"
  else
    fail "PM2 $APP_NAME nao encontrado no usuario $APP_USER"
  fi
}

show_summary(){
  local ip
  ip="$(public_ip)"
  title "INSTALACAO CONCLUIDA"
  echo "Configurar no APK / Aba Conexao / Portao:"
  kv "Protocolo" "http"
  kv "Modo" "VPS ou Automatico"
  kv "Host" "${ip:-IP_PUBLICO_DA_VPS}"
  kv "Porta API" "$API_PORT"
  echo
  echo "Configurar no ESP:"
  kv "Broker MQTT" "${ip:-IP_PUBLICO_DA_VPS}"
  kv "Porta MQTT" "$MQTT_PORT"
  kv "Topico comando" "$TOPIC_CMD"
  kv "Topico status" "$TOPIC_STATUS"
  kv "Topico conexao" "$TOPIC_CONEXAO"
  kv "Topico trava" "$TOPIC_TRAVA"
  echo
  echo "Rotas mantidas para o APK:"
  echo "  GET  http://${ip:-IP_PUBLICO_DA_VPS}:$API_PORT/maestro/portao/status"
  echo "  POST http://${ip:-IP_PUBLICO_DA_VPS}:$API_PORT/maestro/portao"
  echo "  POST http://${ip:-IP_PUBLICO_DA_VPS}:$API_PORT/maestro/portao/travar"
  echo "  POST http://${ip:-IP_PUBLICO_DA_VPS}:$API_PORT/maestro/portao/destravar"
  echo
  warn "Na VPS/Oracle, libere TCP $API_PORT e TCP $MQTT_PORT na Security List/NSG."
}

install_system(){
  need_root
  title "INSTALAR NEXUS IOT PORTAO"

  local default_user
  default_user="$(get_default_user)"
  APP_USER="$(ask 'Usuario Linux que vai rodar a API via PM2' "$default_user")"
  API_PORT="$(ask 'Porta da API para o app/celular' "$DEFAULT_API_PORT")"
  MQTT_PORT="$(ask 'Porta MQTT para o ESP' "$DEFAULT_MQTT_PORT")"
  TOPIC_CMD="$(ask 'Topico MQTT de comando' "$DEFAULT_TOPIC_CMD")"
  TOPIC_STATUS="$(ask 'Topico MQTT de status do portao' "$DEFAULT_TOPIC_STATUS")"
  TOPIC_CONEXAO="$(ask 'Topico MQTT de conexao do ESP' "$DEFAULT_TOPIC_CONEXAO")"
  TOPIC_TRAVA="$(ask 'Topico MQTT de trava' "$DEFAULT_TOPIC_TRAVA")"

  id "$APP_USER" >/dev/null 2>&1 || { fail "Usuario $APP_USER nao existe."; exit 1; }
  valid_port "$API_PORT" || { fail "Porta API invalida."; exit 1; }
  valid_port "$MQTT_PORT" || { fail "Porta MQTT invalida."; exit 1; }
  valid_topic "$TOPIC_CMD" || { fail "Topico comando invalido."; exit 1; }
  valid_topic "$TOPIC_STATUS" || { fail "Topico status invalido."; exit 1; }
  valid_topic "$TOPIC_CONEXAO" || { fail "Topico conexao invalido."; exit 1; }
  valid_topic "$TOPIC_TRAVA" || { fail "Topico trava invalido."; exit 1; }

  section "RESUMO"
  kv "Usuario PM2" "$APP_USER"
  kv "API" "TCP $API_PORT"
  kv "MQTT" "TCP $MQTT_PORT"
  kv "Raiz" "$ROOT_DIR"
  kv "Container MQTT" "$MOSQ_CONTAINER"

  confirm_text "Confirma instalar/substituir o Nexus IoT Portao?" "INSTALAR PORTAO" || {
    warn "Instalacao cancelada."
    exit 0
  }

  install_dependencies
  resolve_port API_PORT "$API_PORT" "API do app/celular"
  resolve_port MQTT_PORT "$MQTT_PORT" "MQTT do ESP"
  create_mosquitto
  create_node_app
  setup_pm2
  add_firewall_rule "$API_PORT"
  add_firewall_rule "$MQTT_PORT"
  save_firewall_rules
  sleep 4
  validate_services
  show_summary
}

show_status(){
  load_config
  title "STATUS NEXUS IOT PORTAO"
  kv "Versao" "$VERSION"
  kv "Raiz" "$ROOT_DIR"
  kv "API dir" "$API_DIR"
  kv "Mosquitto dir" "$MOSQ_DIR"
  kv "Usuario PM2" "$APP_USER"
  kv "Porta API" "$API_PORT"
  kv "Porta MQTT" "$MQTT_PORT"
  kv "Log" "$LOG_FILE"

  section "ARQUIVOS"
  for p in "$ROOT_DIR" "$API_DIR" "$APP_FILE" "$CONFIG_FILE" "$MOSQ_DIR" "$MOSQ_CONF"; do
    [[ -e "$p" ]] && ls -ld "$p" 2>/dev/null || true
  done

  section "PROCESSOS"
  if cmd_exists docker && docker info >/dev/null 2>&1; then
    docker ps -a --format 'table {{.Names}}\t{{.Status}}\t{{.Ports}}' | grep -E "NAMES|^$MOSQ_CONTAINER|^$LEGACY_MOSQ_CONTAINER" || true
  else
    warn "Docker nao encontrado ou nao respondendo."
  fi

  if cmd_exists pm2 && id "$APP_USER" >/dev/null 2>&1; then
    run_as_user "$APP_USER" "pm2 list" || true
  else
    warn "PM2 nao encontrado ou usuario invalido."
  fi

  section "TESTES"
  local code
  code="$(http_code "http://127.0.0.1:$API_PORT/maestro/portao/status")"
  [[ "$code" =~ ^[23] ]] && ok "API HTTP $code" || warn "API HTTP $code"
  code="$(http_code "http://127.0.0.1:$API_PORT/socket.io/?EIO=4&transport=polling")"
  [[ "$code" =~ ^[23] ]] && ok "Socket.IO HTTP $code" || warn "Socket.IO HTTP $code"

  if iptables -C INPUT -p tcp -m tcp --dport "$API_PORT" -j ACCEPT 2>/dev/null; then
    ok "Firewall local libera TCP $API_PORT"
  else
    warn "Firewall local sem regra TCP $API_PORT"
  fi

  if iptables -C INPUT -p tcp -m tcp --dport "$MQTT_PORT" -j ACCEPT 2>/dev/null; then
    ok "Firewall local libera TCP $MQTT_PORT"
  else
    warn "Firewall local sem regra TCP $MQTT_PORT"
  fi
}

remove_pm2_app(){
  local user="$1"
  if id "$user" >/dev/null 2>&1 && cmd_exists pm2; then
    run_as_user "$user" "pm2 delete '$APP_NAME' >/dev/null 2>&1 || true"
    run_as_user "$user" "pm2 save >/dev/null 2>&1 || true"
    CHANGED=$((CHANGED+1))
    ok "PM2 $APP_NAME removido do usuario $user se existia"
  fi
}

remove_iot_files(){
  if [[ -d "$ROOT_DIR" ]]; then
    rm -rf "$ROOT_DIR"
    CHANGED=$((CHANGED+1))
    ok "Arquivos removidos: $ROOT_DIR"
  fi

  if [[ -d "$LEGACY_MOSQ_DIR" ]]; then
    rm -rf "$LEGACY_MOSQ_DIR"
    CHANGED=$((CHANGED+1))
    ok "Mosquitto legado removido: $LEGACY_MOSQ_DIR"
  fi
}

remove_mosquitto(){
  if cmd_exists docker; then
    docker rm -f "$MOSQ_CONTAINER" >/dev/null 2>&1 || true
    if docker inspect "$LEGACY_MOSQ_CONTAINER" >/dev/null 2>&1 && legacy_mosquitto_is_nexus; then
      docker rm -f "$LEGACY_MOSQ_CONTAINER" >/dev/null 2>&1 || true
    fi
    CHANGED=$((CHANGED+1))
    ok "Containers Mosquitto do Nexus IoT removidos se existiam"
  fi
}

other_docker_usage(){
  cmd_exists docker || return 1
  docker ps -a --format '{{.Names}}' 2>/dev/null | grep -Ev "^($MOSQ_CONTAINER|$LEGACY_MOSQ_CONTAINER)$" | grep -q .
}

remove_globals_if_safe(){
  section "DEPENDENCIAS GLOBAIS OPCIONAIS"

  if yes_no "Deseja remover PM2 global se nao houver outros apps PM2?" "N"; then
    local apps=""
    if cmd_exists pm2; then
      apps="$(pm2 jlist 2>/dev/null | grep -o '"name":"[^"]*"' | grep -v "\"name\":\"$APP_NAME\"" || true)"
    fi
    if [[ -n "$apps" ]]; then
      warn "PM2 global preservado porque existem outros apps PM2."
      pause_enter
    else
      npm uninstall -g pm2 || true
      ok "PM2 global removido se existia"
    fi
  fi

  if yes_no "Deseja remover Node/npm do servidor se nao houver uso externo detectado?" "N"; then
    if pgrep -af 'node|npm' 2>/dev/null | grep -vE 'grep|NEXUSNVR_PORTAO|api_portao|pm2' >/tmp/nexus_iot_node_usage.$$; then
      warn "Node/npm preservados porque ha processos externos:"
      sed 's/^/  - /' /tmp/nexus_iot_node_usage.$$
      rm -f /tmp/nexus_iot_node_usage.$$
      pause_enter
    else
      rm -f /tmp/nexus_iot_node_usage.$$
      apt-get purge -y nodejs npm 2>/dev/null || true
      apt-get autoremove -y 2>/dev/null || true
      ok "Node/npm removidos se existiam"
    fi
  fi

  if yes_no "Deseja remover Docker/containerd se nao houver outros containers?" "N"; then
    if other_docker_usage; then
      warn "Docker preservado porque existem containers externos:"
      docker ps -a --format '{{.Names}}' | grep -Ev "^($MOSQ_CONTAINER|$LEGACY_MOSQ_CONTAINER)$" | sed 's/^/  - /'
      pause_enter
    else
      systemctl stop docker >/dev/null 2>&1 || true
      systemctl stop containerd >/dev/null 2>&1 || true
      apt-get purge -y docker.io docker-doc docker-compose docker-compose-v2 podman-docker containerd runc 2>/dev/null || true
      apt-get autoremove -y 2>/dev/null || true
      rm -rf /var/lib/docker /var/lib/containerd /etc/docker 2>/dev/null || true
      ok "Docker/containerd removidos se existiam"
    fi
  fi
}

uninstall_standard(){
  title "REMOVER NEXUS IOT PORTAO"
  load_config
  show_status
  confirm_text "Confirma remover Nexus IoT Portao mantendo Docker/Node/PM2 globais?" "REMOVER PORTAO" || {
    warn "Remocao cancelada."
    return 0
  }

  remove_pm2_app "$APP_USER"
  remove_mosquitto
  remove_firewall_rule "$API_PORT"
  remove_firewall_rule "$MQTT_PORT"
  save_firewall_rules
  remove_iot_files
  ok "Remocao padrao concluida"
}

uninstall_complete(){
  title "LIMPEZA COMPLETA NEXUS IOT PORTAO"
  load_config
  show_status
  confirm_text "Confirma limpeza completa do Nexus IoT Portao?" "LIMPEZA PORTAO" || {
    warn "Limpeza cancelada."
    return 0
  }

  remove_pm2_app "$APP_USER"
  remove_mosquitto
  remove_firewall_rule "$API_PORT"
  remove_firewall_rule "$MQTT_PORT"
  save_firewall_rules
  remove_iot_files
  remove_globals_if_safe
  ok "Limpeza completa concluida"
}

summary(){
  title "RESUMO"
  kv "OK" "$OK"
  kv "Avisos" "$WARN"
  kv "Falhas" "$FAIL"
  kv "Alteracoes" "$CHANGED"
  kv "Log" "$LOG_FILE"
}

main_menu(){
  while true; do
    title "NEXUS IOT PORTAO"
    echo "0) Ver status / diagnostico"
    echo "1) Instalar Nexus IoT Portao"
    echo "2) Remover Portao mantendo Docker/Node/PM2"
    echo "3) Limpeza completa"
    echo "4) Sair"
    echo
    echo "As rotas do APK e os topicos MQTT padrao sao mantidos."
    read -r -p "Escolha uma opcao: " opt || true

    case "${opt:-}" in
      0) show_status ;;
      1) install_system; summary; break ;;
      2) uninstall_standard; summary; break ;;
      3) uninstall_complete; summary; break ;;
      4) exit 0 ;;
      *) warn "Opcao invalida." ;;
    esac

    echo
    pause_enter "Pressione Enter para voltar ao menu..."
  done
}

need_root
main_menu
