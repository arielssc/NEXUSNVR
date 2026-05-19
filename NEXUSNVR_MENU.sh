#!/usr/bin/env bash
set -Eeuo pipefail

# Nexus NVR - Menu principal
# Execute na pasta do projeto:
#   sudo bash NEXUSNVR_MENU.sh

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

run_script(){
  local script="$1"
  shift || true

  if [[ ! -f "${SCRIPT_DIR}/${script}" ]]; then
    echo
    echo "ERRO: script nao encontrado: ${SCRIPT_DIR}/${script}"
    pause
    return 1
  fi

  echo
  echo "Executando: ${script} $*"
  echo
  bash "${SCRIPT_DIR}/${script}" "$@"
  echo
  pause
}

pause(){
  echo
  read -r -p "Pressione ENTER para voltar ao menu..." _
}

need_root(){
  if [[ "$EUID" -ne 0 ]]; then
    echo "Rode com sudo:"
    echo "  sudo bash ${0}"
    exit 1
  fi
}

show_header(){
  clear || true
  echo "============================================================"
  echo " Nexus NVR - Menu Principal"
  echo "============================================================"
  echo
}

restore_backup(){
  local backup_file=""

  echo
  echo "Backups encontrados:"
  if compgen -G "${SCRIPT_DIR}/backups/"'*.tar.gz' >/dev/null; then
    find "${SCRIPT_DIR}/backups" -maxdepth 1 -type f -name '*.tar.gz' -printf '  %p\n' | sort
  else
    echo "  Nenhum backup .tar.gz encontrado em ${SCRIPT_DIR}/backups"
  fi

  echo
  read -r -p "Informe o caminho do backup .tar.gz: " backup_file
  [[ -n "$backup_file" ]] || {
    echo "Restauracao cancelada."
    pause
    return 0
  }

  run_script "NEXUSNVR_RESTAURAR.sh" "$backup_file"
}

retention_menu(){
  local opt=""

  while true; do
    show_header
    echo "Retencao de videos"
    echo
    echo "1) Configurar retencao"
    echo "2) Ver status"
    echo "3) Simular limpeza"
    echo "4) Executar limpeza agora"
    echo "0) Voltar"
    echo
    read -r -p "Escolha uma opcao: " opt

    case "$opt" in
      1) run_script "NEXUSNVR_RETENCAO.sh" ;;
      2) run_script "NEXUSNVR_RETENCAO.sh" "--status" ;;
      3) run_script "NEXUSNVR_RETENCAO.sh" "--simulate" ;;
      4) run_script "NEXUSNVR_RETENCAO.sh" "--clean" ;;
      0) return 0 ;;
      *) echo "Opcao invalida."; sleep 1 ;;
    esac
  done
}

main_menu(){
  local opt=""

  while true; do
    show_header
    echo "1) Instalar / verificar / reparar Nexus NVR"
    echo "2) Diagnostico"
    echo "3) Backup das configuracoes"
    echo "4) Restaurar backup"
    echo "5) Retencao de videos"
    echo "6) Configurar portao"
    echo "7) Limpeza / manutencao"
    echo "0) Sair"
    echo
    read -r -p "Escolha uma opcao: " opt

    case "$opt" in
      1) run_script "NEXUSNVR_INSTALADOR.sh" ;;
      2) run_script "NEXUSNVR_DIAGNOSTICO.sh" ;;
      3) run_script "NEXUSNVR_BACKUP.sh" ;;
      4) restore_backup ;;
      5) retention_menu ;;
      6) run_script "NEXUSNVR_PORTAO.sh" ;;
      7) run_script "NEXUSNVR_LIMPEZA.sh" ;;
      0) echo "Saindo."; exit 0 ;;
      *) echo "Opcao invalida."; sleep 1 ;;
    esac
  done
}

need_root
main_menu
