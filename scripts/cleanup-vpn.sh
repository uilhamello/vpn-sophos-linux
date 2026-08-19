#!/bin/bash
# =============================================================================
# Cleanup VPN Sophos — remove tudo o que o setup instalou
# =============================================================================
# Mesma postura do setup: a senha do sudo nunca entra numa variável nossa nem no
# ambiente — vai do teclado (terminal ou zenity) direto para o sudo.
#
# Remove também o que versões anteriores deixavam para trás (o wrapper único, a
# regra tmpfiles, as credenciais em texto plano e as chaves de keyring com os
# nomes antigos), para que a máquina fique realmente limpa.
# =============================================================================
set -uo pipefail

CURRENT_USER="$(id -un)"

command -v zenity >/dev/null 2>&1 || { echo "zenity não instalado — abortando."; exit 1; }

zenity --question \
  --title="VPN Sophos — Cleanup" \
  --text="Isso remove <b>toda</b> a configuração da VPN Sophos desta máquina:\n\n• comandos privilegiados e a regra sudo\n• configuração do sistema (/etc/vpn-sophos)\n• senha e segredo TOTP do keyring\n• scripts, ícone de bandeja e atalhos\n\nSeu arquivo .ovpn original não é tocado.\n\nDeseja continuar?" \
  --width=440 \
  --ok-label="Sim, remover tudo" \
  --cancel-label="Cancelar" || exit 0

# Askpass gráfico: o arquivo não contém segredo, apenas chama o zenity.
ASKPASS_FILE="$(mktemp)"
chmod 700 "$ASKPASS_FILE"
cat > "$ASKPASS_FILE" <<'ASKPASS'
#!/bin/bash
exec zenity --password --title="VPN Sophos — Cleanup" --timeout=120
ASKPASS
trap 'rm -f "$ASKPASS_FILE"' EXIT INT TERM
export SUDO_ASKPASS="$ASKPASS_FILE"

if [ -t 0 ] && [ -t 1 ]; then
  sudo -v || { echo "Autorização negada."; exit 1; }
else
  sudo -A -v || { zenity --error --text="Autorização negada." --width=320; exit 1; }
fi

su_do() { sudo -n "$@" 2>/dev/null || sudo -A "$@"; }

(
  echo "8"; echo "# Encerrando o ícone de bandeja..."
  pkill -f "vpn-sophos/vpn-tray.py" 2>/dev/null || true

  echo "18"; echo "# Encerrando a VPN..."
  if [ -x /usr/local/sbin/vpn-sophos-down ]; then
    su_do /usr/local/sbin/vpn-sophos-down >/dev/null 2>&1 || true
  else
    # Legado: instalações antigas não tinham wrapper com encerramento cirúrgico.
    su_do pkill -x openvpn >/dev/null 2>&1 || true
  fi

  echo "30"; echo "# Removendo a permissão sudo..."
  su_do rm -f /etc/sudoers.d/vpn-sophos

  echo "40"; echo "# Removendo os comandos privilegiados..."
  su_do rm -f /usr/local/sbin/vpn-sophos-up \
              /usr/local/sbin/vpn-sophos-down \
              /usr/local/sbin/vpn-sophos-log \
              /usr/local/sbin/vpn-sophos-helper

  echo "50"; echo "# Removendo a configuração do sistema..."
  su_do rm -rf /etc/vpn-sophos
  su_do rm -f /etc/tmpfiles.d/vpn-sophos.conf
  su_do rm -rf /run/vpn-sophos

  echo "60"; echo "# Removendo os segredos do keyring..."
  for chave in password totp vpn-pass totp-secret; do
    secret-tool clear service vpn-sophos key "$chave" 2>/dev/null || true
  done

  echo "70"; echo "# Removendo a configuração local..."
  rm -rf "$HOME/.config/vpn-sophos"
  rm -f "$HOME/vpn-connect.sh" "$HOME/vpn-disconnect.sh"
  rm -f "$HOME"/vpn-connect.sh.bak-* "$HOME"/vpn-disconnect.sh.bak-*

  echo "80"; echo "# Removendo a bandeja e os atalhos..."
  rm -rf "$HOME/.local/share/vpn-sophos"
  rm -f "$HOME/.config/autostart/vpn-sophos-tray.desktop"
  rm -f "$HOME/.local/share/applications/vpn-sophos.desktop" \
        "$HOME/.local/share/applications/vpn-connect.desktop" \
        "$HOME/.local/share/applications/vpn-disconnect.desktop"

  echo "88"; echo "# Removendo os atalhos de terminal..."
  for RC in "$HOME/.zshrc" "$HOME/.bashrc"; do
    [ -f "$RC" ] || continue
    sed -i "/^alias vpn-\(on\|off\|status\|log\)=/d" "$RC"
  done

  echo "94"; echo "# Removendo o servidor MCP, se estiver registrado..."
  if command -v claude >/dev/null 2>&1; then
    claude mcp remove vpn-sophos -s user >/dev/null 2>&1 || true
  fi

  echo "100"; echo "# Concluído!"

) | zenity --progress \
  --title="VPN Sophos — removendo..." \
  --text="Iniciando..." \
  --percentage=0 \
  --auto-close \
  --width=420

# Os pacotes (openvpn, oathtool, zenity…) NÃO são removidos: outras coisas na
# máquina podem depender deles. Remover manualmente, se for o caso.
zenity --info \
  --title="VPN Sophos — cleanup concluído" \
  --text="Configuração removida.\n\nOs pacotes do sistema (openvpn, oathtool, zenity) foram mantidos — outros programas podem usá-los.\n\nPara instalar de novo:\n  <tt>./scripts/setup-vpn.sh</tt>" \
  --width=420

echo "✅ Cleanup concluído."
