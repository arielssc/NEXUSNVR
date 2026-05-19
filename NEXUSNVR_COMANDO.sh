#!/usr/bin/env bash
set -Eeuo pipefail

VERSION="2026-05-19-publico-1.0"
REPO_ARCHIVE_URL="${NEXUSNVR_REPO_ARCHIVE_URL:-https://github.com/arielssc/NEXUSNVR/archive/refs/heads/main.tar.gz}"
SOURCE_DIR="${NEXUSNVR_SOURCE_DIR:-}"
INSTALL_DIR="${NEXUSNVR_INSTALL_DIR:-/opt/nexusnvr}"
COMMAND_PATH="${NEXUSNVR_COMMAND_PATH:-/usr/local/bin/nexusnvr}"
LOG_FILE="/tmp/nexusnvr_comando_$(date +%Y%m%d_%H%M%S).log"
TMP_WORK=""

OK=0
WARN=0
FAIL=0

exec > >(tee -a "$LOG_FILE") 2>&1

title(){
  echo
  echo "============================================================"
  echo " $1"
  echo "============================================================"
}

section(){
  echo
  echo "$1"
  echo "------------------------------------------------------------"
}

ok(){ echo "[OK] $*"; OK=$((OK+1)); }
warn(){ echo "[AVISO] $*"; WARN=$((WARN+1)); }
fail(){ echo "[FALHA] $*"; FAIL=$((FAIL+1)); }
die(){ fail "$*"; echo "Log: $LOG_FILE"; exit 1; }

need_root(){
  if [[ "$EUID" -ne 0 ]]; then
    echo "Rode com sudo:"
    echo "  sudo bash $0"
    exit 1
  fi
}

have_cmd(){
  command -v "$1" >/dev/null 2>&1
}

install_basic_deps(){
  section "DEPENDENCIAS"

  local missing=()
  for cmd in tar find chmod mkdir cp ln date tee; do
    have_cmd "$cmd" || missing+=("$cmd")
  done

  if ! have_cmd curl && ! have_cmd wget; then
    missing+=(curl)
  fi

  if [[ "${#missing[@]}" -gt 0 ]]; then
    if have_cmd apt-get; then
      apt-get update
      apt-get install -y ca-certificates curl tar coreutils findutils
      ok "Dependencias basicas instaladas"
    else
      die "Dependencias ausentes e apt-get nao encontrado: ${missing[*]}"
    fi
  else
    ok "Dependencias basicas encontradas"
  fi
}

download_package(){
  local dest="$1"

  if [[ -n "$SOURCE_DIR" ]]; then
    [[ -d "$SOURCE_DIR" ]] || die "Diretorio local nao encontrado: $SOURCE_DIR"
    cp -a "$SOURCE_DIR/." "$dest/package/"
    ok "Pacote copiado de $SOURCE_DIR"
    return 0
  fi

  local archive="$dest/nexusnvr.tar.gz"
  section "DOWNLOAD"
  echo "Origem: $REPO_ARCHIVE_URL"

  if have_cmd curl; then
    curl -fL --retry 3 --connect-timeout 15 -o "$archive" "$REPO_ARCHIVE_URL"
  elif have_cmd wget; then
    wget -O "$archive" "$REPO_ARCHIVE_URL"
  else
    die "curl/wget nao encontrado"
  fi

  tar -xzf "$archive" -C "$dest"
  local root
  root="$(find "$dest" -mindepth 1 -maxdepth 1 -type d -name 'NEXUSNVR-*' | head -n 1)"
  [[ -n "$root" ]] || die "Pacote baixado nao contem diretorio NEXUSNVR-*"

  cp -a "$root/." "$dest/package/"
  ok "Pacote baixado e extraido"
}

validate_package(){
  local dir="$1"
  section "VALIDACAO DO PACOTE"

  local required=(
    NEXUSNVR_MENU.sh
    NEXUSNVR_COMANDO.sh
    NEXUSNVR_INSTALADOR.sh
    NEXUSNVR_DIAGNOSTICO.sh
    NEXUSNVR_BACKUP.sh
    NEXUSNVR_RESTAURAR.sh
    NEXUSNVR_RETENCAO.sh
    NEXUSNVR_LIMPEZA.sh
    NEXUSNVR_PORTAO.sh
    nexus_nvr_pacote/api/api.js
    nexus_nvr_pacote/frontend/index.html
    nexus_nvr_pacote/go2rtc/go2rtc.yaml
  )

  local item
  for item in "${required[@]}"; do
    [[ -e "$dir/$item" ]] || die "Arquivo obrigatorio ausente: $item"
  done

  local sh
  for sh in "$dir"/*.sh; do
    bash -n "$sh" || die "Falha de sintaxe em $(basename "$sh")"
  done

  ok "Arquivos obrigatorios encontrados"
  ok "Sintaxe dos scripts validada"
}

install_package(){
  local src="$1"
  section "INSTALACAO DO PAINEL"

  mkdir -p "$INSTALL_DIR"

  if [[ -d "$INSTALL_DIR/backups" ]]; then
    mkdir -p "$src/backups"
    cp -a "$INSTALL_DIR/backups/." "$src/backups/" 2>/dev/null || true
    warn "Backups existentes preservados"
  fi

  find "$INSTALL_DIR" -mindepth 1 -maxdepth 1 ! -name backups -exec rm -rf {} +
  cp -a "$src/." "$INSTALL_DIR/"
  rm -rf "$INSTALL_DIR/.git"
  find "$INSTALL_DIR" -maxdepth 1 -type f -name '*.sh' -exec chmod +x {} +

  ok "Pacote instalado em $INSTALL_DIR"
}

install_command(){
  section "COMANDO GLOBAL"

  mkdir -p "$(dirname "$COMMAND_PATH")"
  cat > "$COMMAND_PATH" <<EOF
#!/usr/bin/env bash
if [[ "\$EUID" -eq 0 ]]; then
  exec bash "$INSTALL_DIR/NEXUSNVR_MENU.sh" "\$@"
fi
exec sudo bash "$INSTALL_DIR/NEXUSNVR_MENU.sh" "\$@"
EOF
  chmod +x "$COMMAND_PATH"

  ok "Comando criado: $COMMAND_PATH"
}

show_summary(){
  title "NEXUS NVR PRONTO"
  echo "Versao do bootstrap : $VERSION"
  echo "Pacote instalado   : $INSTALL_DIR"
  echo "Comando            : $COMMAND_PATH"
  echo "Log                : $LOG_FILE"
  echo
  echo "Agora use:"
  echo "  nexusnvr"
  echo
  echo "Para instalar ou gerenciar o sistema, escolha as opcoes no menu."
  echo
  echo "Resumo: OK=$OK Avisos=$WARN Falhas=$FAIL"
}

main(){
  need_root
  title "NEXUS NVR - INSTALADOR DO COMANDO"
  install_basic_deps

  TMP_WORK="$(mktemp -d)"
  trap '[[ -n "$TMP_WORK" ]] && rm -rf "$TMP_WORK"' EXIT
  mkdir -p "$TMP_WORK/package"

  download_package "$TMP_WORK"
  validate_package "$TMP_WORK/package"
  install_package "$TMP_WORK/package"
  install_command
  show_summary
}

main "$@"
