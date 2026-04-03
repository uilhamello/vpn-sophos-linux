#!/bin/bash

# =============================================================================
# Cleanup VPN Sophos - Remove toda a configuração
# =============================================================================

if ! command -v zenity &>/dev/null; then
  sudo apt install -y zenity
fi

zenity --question \
  --title="VPN Sophos - Cleanup" \
  --text="Isso irá remover toda a configuração da VPN Sophos.\n\nDeseja continuar?" \
  --width=400 \
  --ok-label="Sim, remover tudo" \
  --cancel-label="Cancelar"

[ $? -ne 0 ] && exit 0

SUDO_PASS=$(zenity --password \
  --title="VPN Sophos - Cleanup" \
  --text="Senha sudo:")

[ -z "$SUDO_PASS" ] && zenity --error --text="Senha sudo não informada. Abortando." && exit 1

(
  echo "10"; echo "# Encerrando processos openvpn..."
  echo "$SUDO_PASS" | sudo -S killall -9 openvpn 2>/dev/null

  echo "25"; echo "# Removendo conexão do NetworkManager..."
  VPN_NAME=$(nmcli -t -f NAME connection show | grep sslvpn | head -1)
  if [ -n "$VPN_NAME" ]; then
    nmcli connection delete "$VPN_NAME" 2>/dev/null
  fi

  echo "40"; echo "# Removendo credenciais..."
  rm -rf "$HOME/.config/vpn-sophos"

  echo "55"; echo "# Removendo scripts..."
  rm -f ~/vpn-connect.sh
  rm -f ~/vpn-disconnect.sh

  echo "70"; echo "# Removendo atalhos do menu..."
  rm -f ~/.local/share/applications/vpn-connect.desktop
  rm -f ~/.local/share/applications/vpn-disconnect.desktop

  echo "82"; echo "# Removendo aliases..."
  for RC in ~/.zshrc ~/.bashrc; do
    if [ -f "$RC" ]; then
      sed -i '/alias vpn-on/d' "$RC"
      sed -i '/alias vpn-off/d' "$RC"
      sed -i '/alias vpn-status/d' "$RC"
    fi
  done

  echo "93"; echo "# Removendo pacotes..."
  echo "$SUDO_PASS" | sudo -S apt remove -y \
    network-manager-openvpn \
    network-manager-openvpn-gnome \
    oathtool 2>/dev/null

  echo "100"; echo "# Concluido!"

) | zenity --progress \
  --title="VPN Sophos - Removendo..." \
  --text="Iniciando..." \
  --percentage=0 \
  --auto-close \
  --width=420

zenity --info \
  --title="VPN Sophos - Cleanup concluido" \
  --text="Tudo removido com sucesso!\n\nPara instalar novamente:\n  ./scripts/setup-vpn.sh" \
  --width=400
