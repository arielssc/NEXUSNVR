#!/usr/bin/env bash
set -Eeuo pipefail

# ============================================================
# Nexus NVR - Configurar camera externa testada
# Camera XMEI/A28B sub stream externo via RTSP TCP
# Execute no servidor NVR:
#   sudo bash configurar_camera_rua_externa.sh
# ============================================================

CAM_ID="1"
CAM_NAME="Rua"

CAM_IP="177.75.60.137"
CAM_PORT="48904"
CAM_USER="ariel"
CAM_PASS="ariel193"
CAM_STREAM="1"

RTSP_URL="rtsp://${CAM_USER}:${CAM_PASS}@${CAM_IP}:${CAM_PORT}/user=${CAM_USER}_password=${CAM_PASS}_channel=0_stream=${CAM_STREAM}&onvif=0.sdp?real_stream"

API_URL="http://127.0.0.1:3000/maestro/save-cam"
CONFIG_FILE="/home/nexus/api/nvr_config.json"
GO2RTC_FILE="/home/nexus/go2rtc/go2rtc.yaml"

echo "============================================================"
echo " Nexus NVR - Configurando camera externa"
echo "============================================================"
echo "Camera ID: $CAM_ID"
echo "Nome: $CAM_NAME"
echo "RTSP: $RTSP_URL"
echo

if ! command -v python3 >/dev/null 2>&1; then
  echo "ERRO: python3 nao encontrado."
  exit 1
fi

echo "===== Verificando containers ====="
sudo docker ps --format "table {{.Names}}\t{{.Status}}\t{{.Ports}}" | grep -E "NAMES|nexus_api|go2rtc|nvr_proxy|visualizador_videos|nvr-frontend" || true
echo

echo "===== Fazendo backup das configuracoes atuais ====="
TS="$(date +%Y%m%d_%H%M%S)"
BK_DIR="/home/nexus/backup_camera_${TS}"
sudo mkdir -p "$BK_DIR"

[ -f "$CONFIG_FILE" ] && sudo cp -a "$CONFIG_FILE" "$BK_DIR/nvr_config.json" || true
[ -f "$GO2RTC_FILE" ] && sudo cp -a "$GO2RTC_FILE" "$BK_DIR/go2rtc.yaml" || true

echo "Backup: $BK_DIR"
echo

echo "===== Enviando configuracao para API Nexus ====="
sudo python3 - <<PY
import json
import urllib.request
import urllib.error
from pathlib import Path

cam_id = "${CAM_ID}"
config_path = Path("${CONFIG_FILE}")

old_name = None
if config_path.exists():
    try:
        db = json.loads(config_path.read_text())
        old = db.get(cam_id) or db.get(int(cam_id))
        if isinstance(old, dict):
            old_name = old.get("name")
    except Exception:
        pass

cam = {
    "active": True,
    "name": "${CAM_NAME}",
    "ip": "${CAM_IP}",
    "port": "${CAM_PORT}",
    "user": "${CAM_USER}",
    "pass": "${CAM_PASS}",
    "stream": "${CAM_STREAM}",

    "manual": True,
    "url": "${RTSP_URL}",
    "recurl": "${RTSP_URL}",

    "rec_active": True,
    "proto": "tcp",
    "segtime": "10",
    "format": "mkv",
    "vcodec": "copy",
    "acodec": "copy",

    "nameformat": "%H-%M-%S",
    "tz": "America/Sao_Paulo",
    "restart": "unless-stopped",
    "genpts": True,
    "delay": "5000000",
    "timeout": "5000000",
    "analyzeduration": "10000000",
    "probe": "10000000"
}

payload = {
    "id": cam_id,
    "oldName": old_name,
    "config": cam
}

data = json.dumps(payload).encode("utf-8")
req = urllib.request.Request(
    "${API_URL}",
    data=data,
    headers={"Content-Type": "application/json"},
    method="POST"
)

try:
    with urllib.request.urlopen(req, timeout=60) as resp:
        body = resp.read().decode("utf-8", errors="replace")
        print("HTTP", resp.status)
        print(body)
        if resp.status < 200 or resp.status >= 300:
            raise SystemExit(1)
except urllib.error.HTTPError as e:
    print("ERRO HTTP", e.code)
    print(e.read().decode("utf-8", errors="replace"))
    raise SystemExit(1)
except Exception as e:
    print("ERRO:", e)
    raise SystemExit(1)
PY

echo
echo "===== Configuracao atual da API ====="
curl -s http://127.0.0.1:3000/maestro/config | python3 -m json.tool || true

echo
echo "===== Go2RTC YAML ====="
sudo cat "$GO2RTC_FILE" || true

echo
echo "===== Testando proxy local ====="
curl -s -o /dev/null -w "Painel: %{http_code}\n" http://127.0.0.1:48902/
curl -s -o /dev/null -w "API: %{http_code}\n" http://127.0.0.1:48902/maestro/config
curl -s -o /dev/null -w "Go2RTC: %{http_code}\n" http://127.0.0.1:48902/stream.html

echo
echo "===== Verificando gravador ====="
sleep 3
sudo docker ps --format "table {{.Names}}\t{{.Status}}\t{{.Ports}}" | grep -E "NAMES|gravador_${CAM_NAME}|go2rtc|nexus_api" || true

echo
echo "===== Logs recentes do gravador ====="
sudo docker logs --tail 40 "gravador_${CAM_NAME}" 2>&1 || true

echo
echo "===== Pastas de gravacao ====="
sudo find "/home/nexus/gravacoes/${CAM_NAME}" -maxdepth 3 -type f 2>/dev/null | tail -20 || true

echo
echo "============================================================"
echo " Camera configurada."
echo " Acesse:"
echo "   http://127.0.0.1:48902"
echo "   http://164.152.43.21:48902"
echo
echo " Configuracao usada:"
echo "   RTSP TCP"
echo "   MKV"
echo "   video copy"
echo "   audio copy"
echo "   segmento 10 minutos"
echo "============================================================"
