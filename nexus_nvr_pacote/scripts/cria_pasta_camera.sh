#!/usr/bin/env bash
set -Eeuo pipefail

DATA_HOJE=$(TZ="America/Sao_Paulo" date +%d-%m-%Y)
DATA_AMANHA=$(TZ="America/Sao_Paulo" date -d "tomorrow" +%d-%m-%Y)
BASE_DIR="/home/nexus/gravacoes"
CONFIG_FILE="/home/nexus/api/nvr_config.json"

mkdir -p "$BASE_DIR"

if [ ! -f "$CONFIG_FILE" ]; then
  echo "[AVISO] Config nao encontrada: $CONFIG_FILE"
  exit 0
fi

CAMERAS=$(python3 - <<'PY'
import json
from pathlib import Path

cfg = Path("/home/nexus/api/nvr_config.json")

try:
    db = json.loads(cfg.read_text(encoding="utf-8"))
except Exception:
    raise SystemExit(0)

for key in sorted(db.keys(), key=lambda x: int(x) if str(x).isdigit() else str(x)):
    c = db.get(key) or {}
    name = str(c.get("name") or "").strip()
    active = bool(c.get("active"))
    rec_active = bool(c.get("rec_active"))

    if active and rec_active and name:
        if "/" in name or name in (".", ".."):
            continue
        print(name)
PY
)

if [ -z "${CAMERAS:-}" ]; then
  echo "[INFO] Nenhuma camera ativa com gravacao ligada."
  exit 0
fi

while IFS= read -r CAMERA; do
  [ -z "$CAMERA" ] && continue

  PASTA_HOJE="$BASE_DIR/$CAMERA/$DATA_HOJE"
  PASTA_AMANHA="$BASE_DIR/$CAMERA/$DATA_AMANHA"

  if [ ! -d "$PASTA_HOJE" ]; then
    mkdir -p "$PASTA_HOJE"
    chown -R nexus:nexus "$BASE_DIR/$CAMERA" 2>/dev/null || true
    chmod -R 775 "$BASE_DIR/$CAMERA" 2>/dev/null || true
    echo "[LOG] Criado hoje: $PASTA_HOJE"
  fi

  if [ ! -d "$PASTA_AMANHA" ]; then
    mkdir -p "$PASTA_AMANHA"
    chown -R nexus:nexus "$PASTA_AMANHA" 2>/dev/null || true
    chmod -R 775 "$PASTA_AMANHA" 2>/dev/null || true
    echo "[LOG] Criado amanha: $PASTA_AMANHA"
  fi
done <<< "$CAMERAS"
