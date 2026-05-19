#!/usr/bin/env bash
set -Eeuo pipefail

VERSION="2026-05-19-agendamentos-1.0"
NVR_ROOT="${NVR_ROOT:-/home/nexus}"
CRON_DIR="${NVR_ROOT}/cron"
RETENTION_SCRIPT="${CRON_DIR}/retencao_nvr.sh"
FOLDER_SCRIPT="${CRON_DIR}/cria_pasta_camera.sh"
RETENTION_CONFIG="${NVR_ROOT}/retencao_nvr.conf"
RETENTION_MARKER="NEXUS_NVR_RETENCAO"
FOLDER_MARKER="NEXUS_NVR_CRIAR_PASTAS"

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

kv(){ printf "  %-30s: %s\n" "$1" "$2"; }
ok(){ echo "[OK] $*"; }
warn(){ echo "[AVISO] $*"; }

need_root(){
  if [[ "$EUID" -ne 0 ]]; then
    echo "Execute com sudo: sudo bash $0"
    exit 1
  fi
}

pause(){
  read -r -p "Pressione Enter para continuar..." _ || true
}

ensure_cron_dir(){
  mkdir -p "$CRON_DIR"
  chmod 755 "$CRON_DIR" 2>/dev/null || true
}

current_cron(){
  crontab -l -u root 2>/dev/null || true
}

write_cron_lines(){
  local retention_line="$1"
  local folder_line="$2"
  local tmp
  tmp="$(mktemp)"

  current_cron \
    | grep -v "$RETENTION_MARKER" \
    | grep -v "$FOLDER_MARKER" \
    | grep -v '/home/nexus/cria_pasta_camera.sh' \
    | grep -v '/home/nexus/cron/retencao_nvr.sh' \
    | grep -v '/home/nexus/cron/cria_pasta_camera.sh' \
    > "$tmp" || true

  echo "$retention_line" >> "$tmp"
  echo "$folder_line" >> "$tmp"
  crontab -u root "$tmp"
  rm -f "$tmp"
}

get_retention_interval(){
  local value="30"
  if [[ -f "$RETENTION_CONFIG" ]]; then
    value="$(awk -F= '/^AUTO_INTERVAL_MINUTES=/{gsub(/"/,"",$2); print $2}' "$RETENTION_CONFIG" | tail -1)"
  fi
  [[ "$value" =~ ^[0-9]+$ ]] || value="30"
  echo "$value"
}

set_retention_interval(){
  local minutes="$1"
  if [[ -f "$RETENTION_CONFIG" ]]; then
    if grep -q '^AUTO_INTERVAL_MINUTES=' "$RETENTION_CONFIG"; then
      sed -i "s/^AUTO_INTERVAL_MINUTES=.*/AUTO_INTERVAL_MINUTES=\"$minutes\"/" "$RETENTION_CONFIG"
    else
      echo "AUTO_INTERVAL_MINUTES=\"$minutes\"" >> "$RETENTION_CONFIG"
    fi
  else
    cat > "$RETENTION_CONFIG" <<EOF
# Nexus NVR - Configuracao de retencao
RET_MODE="disabled"
GB_LIMIT="100"
GB_ACTION="gb"
GB_DELETE="10"
GB_DELETE_DAYS="7"
KEEP_DAYS="15"
DELETE_DAYS="30"
PROTECT_MINUTES="10"
AUTO_INTERVAL_MINUTES="$minutes"
VIDEO_EXTENSIONS="mkv,mp4,ts,avi,mov,m4v"
EOF
  fi
}

get_folder_time(){
  local line minute hour
  line="$(current_cron | grep "$FOLDER_MARKER" | tail -1 || true)"
  if [[ -n "$line" ]]; then
    minute="$(awk '{print $1}' <<< "$line")"
    hour="$(awk '{print $2}' <<< "$line")"
    echo "${hour}:${minute}"
  else
    echo "23:49"
  fi
}

valid_time(){
  local t="$1" h m
  [[ "$t" =~ ^([0-9]{1,2}):([0-9]{1,2})$ ]] || return 1
  h="${BASH_REMATCH[1]}"
  m="${BASH_REMATCH[2]}"
  [[ "$h" -ge 0 && "$h" -le 23 && "$m" -ge 0 && "$m" -le 59 ]]
}

apply_schedule(){
  local folder_time="${1:-$(get_folder_time)}"
  local h="${folder_time%:*}"
  local m="${folder_time#*:}"

  h="$((10#$h))"
  m="$((10#$m))"

  ensure_cron_dir
  chmod +x "$RETENTION_SCRIPT" "$FOLDER_SCRIPT" 2>/dev/null || true

  write_cron_lines \
    "*/10 * * * * $RETENTION_SCRIPT --auto # $RETENTION_MARKER" \
    "$m $h * * * $FOLDER_SCRIPT # $FOLDER_MARKER"

  ok "Agendamentos aplicados"
}

show_status(){
  title "AGENDAMENTOS NEXUS NVR"
  kv "Versao" "$VERSION"
  kv "Diretorio" "$CRON_DIR"
  kv "Retencao" "$RETENTION_SCRIPT"
  kv "Criar pastas" "$FOLDER_SCRIPT"
  kv "Intervalo logico retencao" "$(get_retention_interval) minuto(s)"
  kv "Horario criar pastas" "$(get_folder_time)"

  section "CRON"
  current_cron | grep -E "$RETENTION_MARKER|$FOLDER_MARKER|/home/nexus/cron/" || warn "Nenhum agendamento do Nexus NVR encontrado."
}

change_retention_interval(){
  local minutes
  title "ALTERAR INTERVALO DA RETENCAO"
  echo "O cron acorda a cada 10 minutos, mas a retencao so executa no intervalo configurado."
  echo
  read -r -p "Novo intervalo em minutos [$(get_retention_interval)]: " minutes || true
  minutes="${minutes:-$(get_retention_interval)}"

  if ! [[ "$minutes" =~ ^[0-9]+$ ]] || [[ "$minutes" -lt 10 || "$minutes" -gt 1440 ]]; then
    warn "Intervalo invalido. Use numero entre 10 e 1440."
    return 1
  fi

  set_retention_interval "$minutes"
  apply_schedule "$(get_folder_time)"
  ok "Intervalo da retencao ajustado para ${minutes} minuto(s)"
}

change_folder_time(){
  local t
  title "ALTERAR HORARIO DE CRIACAO DAS PASTAS"
  read -r -p "Horario no formato HH:MM [$(get_folder_time)]: " t || true
  t="${t:-$(get_folder_time)}"

  if ! valid_time "$t"; then
    warn "Horario invalido. Exemplo valido: 23:49"
    return 1
  fi

  apply_schedule "$t"
  ok "Horario de criacao das pastas ajustado para $t"
}

restore_default(){
  title "RESTAURAR PADRAO"
  set_retention_interval "30"
  apply_schedule "23:49"
  ok "Padrao restaurado: retencao 30 min; criar pastas 23:49"
}

menu(){
  while true; do
    title "NEXUS NVR - AGENDAMENTOS AUTOMATICOS"
    echo "1) Ver agendamentos atuais"
    echo "2) Alterar intervalo da retencao"
    echo "3) Alterar horario de criacao das pastas"
    echo "4) Restaurar padrao"
    echo "0) Sair"
    echo
    read -r -p "Escolha uma opcao: " opt || true

    case "${opt:-}" in
      1) show_status; pause ;;
      2) change_retention_interval; pause ;;
      3) change_folder_time; pause ;;
      4) restore_default; pause ;;
      0) exit 0 ;;
      *) warn "Opcao invalida."; sleep 1 ;;
    esac
  done
}

need_root
menu
