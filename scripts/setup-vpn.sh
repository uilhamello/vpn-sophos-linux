#!/bin/bash

# =============================================================================
# Setup VPN Sophos - Ubuntu/GNOME
# =============================================================================

CREDENTIALS_DIR="$HOME/.config/vpn-sophos"
CREDENTIALS_FILE="$CREDENTIALS_DIR/.credentials"

# -----------------------------------------------------------------------------
# PASSO 0: Coletar senha sudo via terminal ANTES de qualquer coisa
# -----------------------------------------------------------------------------
echo "========================================"
echo "   VPN Sophos - Setup"
echo "========================================"
echo ""
read -sp "Senha sudo: " SUDO_PASS; echo
echo ""

if ! echo "$SUDO_PASS" | sudo -S true 2>/dev/null; then
  echo "❌ Senha sudo incorreta. Abortando."
  exit 1
fi

echo "✅ Senha sudo validada."

# -----------------------------------------------------------------------------
# PASSO 1: Instalar todas as dependências necessárias
# -----------------------------------------------------------------------------
echo "🔧 Instalando dependências..."
echo "$SUDO_PASS" | sudo -S apt update -qq 2>/dev/null
echo "$SUDO_PASS" | sudo -S apt install -y \
  zenity \
  openvpn \
  network-manager-openvpn \
  network-manager-openvpn-gnome \
  oathtool \
  libnotify-bin \
  gnome-terminal 2>/dev/null

echo "✅ Dependências instaladas."
echo ""

# -----------------------------------------------------------------------------
# PASSO 2: Interface gráfica via Zenity
# -----------------------------------------------------------------------------

# Tela de boas-vindas
zenity --info \
  --title="VPN Sophos - Setup" \
  --text="Bem-vindo ao setup da VPN Sophos!\n\nVocê precisará de:\n\n• Usuário e senha VPN\n• Arquivo .ovpn\n• Chave TOTP BASE32 (opcional)\n  (portal Sophos → OTP tokens)" \
  --width=420 \
  --ok-label="Começar"

[ $? -ne 0 ] && exit 0

# Usuário VPN
VPN_USER=$(zenity --entry \
  --title="VPN Sophos - Setup (1/4)" \
  --text="Usuário VPN:" \
  --entry-text="firstname.lastname" \
  --width=420)
[ -z "$VPN_USER" ] && zenity --error --text="Usuário não informado. Abortando." && exit 1

# Senha VPN
VPN_PASS=$(zenity --password \
  --title="VPN Sophos - Setup (2/4)" \
  --text="Senha VPN:")
[ -z "$VPN_PASS" ] && zenity --error --text="Senha não informada. Abortando." && exit 1

# Chave TOTP — opcional
zenity --question \
  --title="VPN Sophos - Setup (3/4)" \
  --text="Deseja configurar o código 2FA automático?\n\nSe sim, o código OTP será gerado automaticamente\na cada conexão usando sua chave TOTP BASE32.\n\nSe não, o código será solicitado manualmente\ncada vez que você conectar." \
  --width=420 \
  --ok-label="Sim, configurar automático" \
  --cancel-label="Não, digitar manualmente"

TOTP_MODE=$?  # 0 = automático, 1 = manual

if [ $TOTP_MODE -eq 0 ]; then
  TOTP_SECRET=$(zenity --entry \
    --title="VPN Sophos - Setup (3/4)" \
    --text="Chave TOTP BASE32:\n(Portal Sophos → OTP tokens)" \
    --width=420)
  [ -z "$TOTP_SECRET" ] && zenity --error --text="Chave TOTP não informada. Abortando." && exit 1
else
  TOTP_SECRET=""
fi

# Arquivo .ovpn
OVPN_DEFAULT=$(ls ~/*.ovpn 2>/dev/null | head -1)

if [ -n "$OVPN_DEFAULT" ]; then
  zenity --question \
    --title="VPN Sophos - Setup (4/4)" \
    --text="Arquivo .ovpn encontrado:\n\n$OVPN_DEFAULT\n\nDeseja usar este arquivo?" \
    --width=420 \
    --ok-label="Sim" \
    --cancel-label="Escolher outro"

  if [ $? -eq 0 ]; then
    OVPN_FILE="$OVPN_DEFAULT"
  else
    OVPN_FILE=$(zenity --file-selection \
      --title="Selecione o arquivo .ovpn" \
      --file-filter="OpenVPN Config | *.ovpn")
  fi
else
  OVPN_FILE=$(zenity --file-selection \
    --title="VPN Sophos - Setup (4/4) — Selecione o arquivo .ovpn" \
    --file-filter="OpenVPN Config | *.ovpn")
fi

[ -z "$OVPN_FILE" ] && zenity --error --text="Arquivo .ovpn não selecionado. Abortando." && exit 1

# Detecta terminal disponível
if command -v gnome-terminal &>/dev/null; then
  TERMINAL="gnome-terminal --"
elif command -v xterm &>/dev/null; then
  TERMINAL="xterm -e"
elif command -v konsole &>/dev/null; then
  TERMINAL="konsole -e"
else
  zenity --error --text="Nenhum terminal compatível encontrado.\nInstale o gnome-terminal e tente novamente."
  exit 1
fi

# -----------------------------------------------------------------------------
# PASSO 3: Instalação com barra de progresso
# -----------------------------------------------------------------------------
(
  echo "10"; echo "# Importando conexão VPN..."
  sed -i 's/^route /#route /' "$OVPN_FILE"
  nmcli connection import type openvpn file "$OVPN_FILE" 2>/dev/null

  VPN_NAME=$(nmcli -t -f NAME connection show | grep sslvpn | head -1)
  nmcli connection modify "$VPN_NAME" vpn.user-name "$VPN_USER"
  nmcli connection modify "$VPN_NAME" vpn.secrets "password=${VPN_PASS}"
  nmcli connection modify "$VPN_NAME" +vpn.data "password-flags=0"

  echo "30"; echo "# Salvando credenciais com segurança..."
  mkdir -p "$CREDENTIALS_DIR"
  chmod 700 "$CREDENTIALS_DIR"

  printf 'VPN_USER=%q\nVPN_PASS=%q\nTOTP_SECRET=%q\nSUDO_PASS=%q\nOVPN_FILE=%q\n' \
    "$VPN_USER" "$VPN_PASS" "$TOTP_SECRET" "$SUDO_PASS" "$OVPN_FILE" \
    > "$CREDENTIALS_FILE"

  chmod 600 "$CREDENTIALS_FILE"

  echo "50"; echo "# Criando script de conexão..."

  # Bloco OTP: automático ou manual, dependendo do modo escolhido
  if [ $TOTP_MODE -eq 0 ]; then
    OTP_BLOCK='OTP=$(oathtool --totp --base32 "$TOTP_SECRET")'
  else
    OTP_BLOCK='OTP=$(zenity --entry \
  --title="VPN - Código 2FA" \
  --text="Digite o código OTP do Sophos:" \
  --width=320)
[ -z "$OTP" ] && notify-send "VPN" "Código OTP não informado. Abortando." --icon=network-error && exit 1'
  fi

  cat > ~/vpn-connect.sh << ENDOFSCRIPT
#!/bin/bash
CREDENTIALS_FILE="\$HOME/.config/vpn-sophos/.credentials"

if [ ! -f "\$CREDENTIALS_FILE" ]; then
  notify-send "VPN" "Credenciais não encontradas. Rode o setup novamente." --icon=network-error
  exit 1
fi

source "\$CREDENTIALS_FILE"

echo "\$SUDO_PASS" | sudo -S killall -9 openvpn 2>/dev/null

$OTP_BLOCK

TMPFILE=\$(mktemp)
chmod 600 "\$TMPFILE"
echo "\$VPN_USER" > "\$TMPFILE"
echo "\${VPN_PASS}\${OTP}" >> "\$TMPFILE"

echo "\$SUDO_PASS" | sudo -S openvpn --daemon \\
  --config "\$OVPN_FILE" \\
  --auth-user-pass "\$TMPFILE" \\
  --auth-nocache

for i in {1..10}; do
  sleep 1
  if ip addr show tun0 &>/dev/null; then
    rm -f "\$TMPFILE"
    notify-send "VPN" "Conectado com sucesso!" --icon=network-vpn
    sleep 2
    kill \$(ps -o ppid= -p \$\$)
    exit 0
  fi
done

rm -f "\$TMPFILE"
notify-send "VPN" "Falha ao conectar. Verifique as credenciais." --icon=network-error
sleep 3
kill \$(ps -o ppid= -p \$\$)
ENDOFSCRIPT

  echo "65"; echo "# Criando script de desconexão..."
  cat > ~/vpn-disconnect.sh << 'ENDOFSCRIPT'
#!/bin/bash
CREDENTIALS_FILE="$HOME/.config/vpn-sophos/.credentials"

if [ ! -f "$CREDENTIALS_FILE" ]; then
  notify-send "VPN" "Credenciais não encontradas. Rode o setup novamente." --icon=network-error
  exit 1
fi

source "$CREDENTIALS_FILE"

echo "$SUDO_PASS" | sudo -S kill -9 $(pgrep -f openvpn) 2>/dev/null

sleep 1

if ip addr show tun0 &>/dev/null; then
  notify-send "VPN" "Falha ao desconectar!" --icon=network-error
else
  notify-send "VPN" "VPN desconectada!" --icon=network-offline
fi

sleep 1
kill $(ps -o ppid= -p $$)
ENDOFSCRIPT

  chmod 700 ~/vpn-connect.sh ~/vpn-disconnect.sh

  echo "78"; echo "# Criando atalhos no menu..."
  mkdir -p ~/.local/share/applications

  cat > ~/.local/share/applications/vpn-connect.desktop << DESKEOF
[Desktop Entry]
Name=VPN Conectar
Comment=Conectar VPN do trabalho
Exec=$TERMINAL bash -c '~/vpn-connect.sh; exec bash'
Icon=network-vpn
Terminal=false
Type=Application
Categories=Network;
DESKEOF

  cat > ~/.local/share/applications/vpn-disconnect.desktop << DESKEOF
[Desktop Entry]
Name=VPN Desconectar
Comment=Desconectar VPN do trabalho
Exec=$TERMINAL bash -c '~/vpn-disconnect.sh; exec bash'
Icon=network-error
Terminal=false
Type=Application
Categories=Network;
DESKEOF

  echo "90"; echo "# Configurando aliases..."
  for SHELL_RC in "$HOME/.zshrc" "$HOME/.bashrc"; do
    if [ -f "$SHELL_RC" ]; then
      grep -qxF "alias vpn-on='~/vpn-connect.sh'" "$SHELL_RC" || echo "alias vpn-on='~/vpn-connect.sh'" >> "$SHELL_RC"
      grep -qxF "alias vpn-off='sudo kill -9 \$(pgrep -f openvpn)'" "$SHELL_RC" || echo "alias vpn-off='sudo kill -9 \$(pgrep -f openvpn)'" >> "$SHELL_RC"
      grep -qxF "alias vpn-status='ip addr show tun0 2>/dev/null && echo VPN ATIVA || echo VPN DESCONECTADA'" "$SHELL_RC" || echo "alias vpn-status='ip addr show tun0 2>/dev/null && echo VPN ATIVA || echo VPN DESCONECTADA'" >> "$SHELL_RC"
    fi
  done

  echo "100"; echo "# Concluido!"

) | zenity --progress \
  --title="VPN Sophos - Instalando..." \
  --text="Iniciando..." \
  --percentage=0 \
  --auto-close \
  --width=420

# Modo escolhido
if [ $TOTP_MODE -eq 0 ]; then
  OTP_INFO="Modo: OTP automatico"
else
  OTP_INFO="Modo: OTP manual (solicitado ao conectar)"
fi

zenity --info \
  --title="VPN Sophos - Pronto!" \
  --text="Setup concluido!\n\n$OTP_INFO\n\nAtalhos no menu de aplicativos:\n  VPN Conectar\n  VPN Desconectar\n\nOu no terminal:\n  vpn-on     → conectar\n  vpn-off    → desconectar\n  vpn-status → verificar status" \
  --width=420
