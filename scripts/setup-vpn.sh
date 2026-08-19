#!/bin/bash
# =============================================================================
# Setup VPN Sophos — Ubuntu/GNOME
# =============================================================================
# Modelo de segurança
#
#   Senha sudo      nunca entra numa variável nossa nem no ambiente. O prompt é
#                   do próprio sudo (terminal) ou de um askpass que chama o
#                   zenity — em ambos os casos a senha vai direto do teclado para
#                   o sudo. Nada é gravado.
#   Senha VPN/TOTP  ficam no keyring do GNOME (criptografados em repouso). Em
#                   disco, só dados não sensíveis (usuário e modo do OTP).
#   Privilégio      confinado a três comandos fixos em /usr/local/sbin
#                   (vpn-sophos-up / -down / -log), root:root 0755, liberados
#                   pelo sudoers SEM SENHA e SEM ARGUMENTOS. É a única coisa que
#                   a sessão do usuário pode fazer como root: subir, derrubar e
#                   diagnosticar esta VPN.
#   Config          copiada para /etc/vpn-sophos/client.ovpn (root:root 0644) e
#                   SANITIZADA: toda diretiva capaz de executar código — up,
#                   down, route-up, plugin, script-security… — é comentada. Um
#                   .ovpn adulterado não vira execução de código como root.
#   Credencial      transita pelo stdin do wrapper e é gravada por ele em tmpfs
#                   root-only, apagada antes de a chamada retornar. O usuário
#                   nunca controla um caminho que o root vai ler.
# =============================================================================
set -uo pipefail

CONFIG_DIR="$HOME/.config/vpn-sophos"
CONFIG_FILE="$CONFIG_DIR/config"
CURRENT_USER="$(id -un)"

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(dirname "$SCRIPT_DIR")"
APP_SRC="$REPO_ROOT/app"
APP_DIR="$HOME/.local/share/vpn-sophos"

WRAPPERS=(vpn-sophos-up vpn-sophos-down vpn-sophos-log)

falhar() { printf '\n❌ %s\n' "$1" >&2; exit 1; }

# -----------------------------------------------------------------------------
# PASSO 0: Privilégio — sem armazenar senha em lugar nenhum
# -----------------------------------------------------------------------------
echo "========================================"
echo "   VPN Sophos — Setup"
echo "========================================"
echo ""

for arquivo in "${WRAPPERS[@]}" vpn-tray.py vpn-sophos-otp; do
  [ -f "$APP_SRC/$arquivo" ] || falhar "$APP_SRC/$arquivo não encontrado. Rode a partir da raiz do repositório: ./scripts/setup-vpn.sh"
done

for bin in zenity secret-tool; do
  command -v "$bin" >/dev/null 2>&1 || echo "· $bin ainda não está instalado — será instalado no passo 1."
done

# Askpass gráfico: o arquivo NÃO contém segredo, apenas invoca o zenity. A senha
# vai do zenity direto para o sudo, sem passar por variável nem pelo ambiente
# (que seria legível em /proc/<pid>/environ por qualquer processo do usuário).
ASKPASS_FILE="$(mktemp)"
chmod 700 "$ASKPASS_FILE"
cat > "$ASKPASS_FILE" <<'ASKPASS'
#!/bin/bash
exec zenity --password --title="VPN Sophos — Setup" --timeout=120
ASKPASS
trap 'rm -f "$ASKPASS_FILE"' EXIT INT TERM

echo "🔐 Autorização de administrador (a senha não é armazenada em nenhum momento)."
if [ -t 0 ] && [ -t 1 ]; then
  sudo -v || falhar "Autorização negada."
elif [ -n "${DISPLAY:-}${WAYLAND_DISPLAY:-}" ] && command -v zenity >/dev/null 2>&1; then
  export SUDO_ASKPASS="$ASKPASS_FILE"
  sudo -A -v || falhar "Autorização negada."
else
  falhar "Sem terminal interativo e sem interface gráfica para pedir a senha."
fi

# Nas etapas seguintes: -n para falhar de imediato caso o cache do sudo expire,
# em vez de travar num prompt dentro da barra de progresso. O askpass entra
# apenas como plano B.
export SUDO_ASKPASS="$ASKPASS_FILE"

# Decide a forma de autenticar ANTES de rodar o comando — nunca executa duas
# vezes. (`sudo -n cmd || sudo -A cmd` repetiria um comando que falhou por
# motivo próprio, não por falta de senha.)
su_do() {
  if sudo -n true 2>/dev/null; then
    sudo -n "$@"
  else
    sudo -A "$@"
  fi
}

echo "✅ Autorizado."
echo ""

# -----------------------------------------------------------------------------
# PASSO 1: Dependências
# -----------------------------------------------------------------------------
echo "🔧 Instalando dependências..."
su_do apt update -qq >/dev/null 2>&1
su_do apt install -y \
  zenity \
  openvpn \
  libsecret-tools \
  libnotify-bin \
  python3-gi \
  gir1.2-gtk-3.0 >/dev/null 2>&1 || falhar "Falha ao instalar dependências. Rode 'sudo apt update' e tente de novo."

# Ícone de bandeja: Ayatana no Ubuntu atual, com fallback para o AppIndicator legado.
su_do apt install -y gir1.2-ayatanaappindicator3-0.1 >/dev/null 2>&1 \
  || su_do apt install -y gir1.2-appindicator3-0.1 >/dev/null 2>&1 \
  || echo "⚠️  AppIndicator não disponível — o ícone de bandeja pode não aparecer."

for bin in openvpn secret-tool zenity python3; do
  command -v "$bin" >/dev/null 2>&1 || falhar "$bin não ficou disponível após a instalação."
done

echo "✅ Dependências instaladas."
echo ""

# -----------------------------------------------------------------------------
# PASSO 2: Coleta de dados (interface gráfica)
# -----------------------------------------------------------------------------
zenity --info \
  --title="VPN Sophos — Setup" \
  --text="Bem-vindo ao setup da VPN Sophos!\n\nVocê precisará de:\n\n• Usuário e senha VPN\n• Arquivo .ovpn\n• Chave TOTP BASE32 (opcional)\n  (portal Sophos → OTP tokens)\n\n<b>Atenção:</b> se a VPN estiver conectada, ela será desconectada durante a instalação." \
  --width=420 \
  --ok-label="Começar" || exit 0

VPN_USER=$(zenity --entry \
  --title="VPN Sophos — Setup (1/4)" \
  --text="Usuário VPN:" \
  --entry-text="firstname.lastname" \
  --width=420)
[ -z "$VPN_USER" ] && { zenity --error --text="Usuário não informado. Abortando." --width=320; falhar "Usuário não informado."; }

VPN_PASS=$(zenity --password \
  --title="VPN Sophos — Setup (2/4)" \
  --text="Senha VPN:")
[ -z "$VPN_PASS" ] && { zenity --error --text="Senha não informada. Abortando." --width=320; falhar "Senha não informada."; }

zenity --question \
  --title="VPN Sophos — Setup (3/4)" \
  --text="Deseja configurar o código 2FA automático?\n\n<b>Automático:</b> o OTP é gerado a cada conexão a partir da sua chave TOTP, que fica guardada no keyring. Permite conectar sem digitar nada — inclusive por automação.\n\n<b>Manual:</b> o código é pedido numa janela a cada conexão. O segundo fator nunca fica guardado, mas nenhuma automação consegue conectar sozinha." \
  --width=460 \
  --ok-label="Automático" \
  --cancel-label="Manual"

if [ $? -eq 0 ]; then
  TOTP_MODE="auto"
  TOTP_SECRET=$(zenity --entry \
    --title="VPN Sophos — Setup (3/4)" \
    --text="Chave TOTP BASE32:\n(Portal Sophos → OTP tokens)" \
    --width=420)
  [ -z "$TOTP_SECRET" ] && { zenity --error --text="Chave TOTP não informada. Abortando." --width=320; falhar "Chave TOTP não informada."; }
  if ! printf '%s\n' "$TOTP_SECRET" | python3 "$APP_SRC/vpn-sophos-otp" >/dev/null 2>&1; then
    zenity --error --text="A chave TOTP informada não é um BASE32 válido." --width=380
    falhar "Chave TOTP inválida."
  fi
else
  TOTP_MODE="manual"
  TOTP_SECRET=""
fi

OVPN_DEFAULT=$(ls ~/*.ovpn 2>/dev/null | head -1)
if [ -n "$OVPN_DEFAULT" ] && zenity --question \
    --title="VPN Sophos — Setup (4/4)" \
    --text="Arquivo .ovpn encontrado:\n\n$OVPN_DEFAULT\n\nDeseja usar este arquivo?" \
    --width=420 --ok-label="Sim" --cancel-label="Escolher outro"; then
  OVPN_FILE="$OVPN_DEFAULT"
else
  OVPN_FILE=$(zenity --file-selection \
    --title="VPN Sophos — Selecione o arquivo .ovpn" \
    --file-filter="OpenVPN Config | *.ovpn")
fi
[ -z "$OVPN_FILE" ] && { zenity --error --text="Arquivo .ovpn não selecionado. Abortando." --width=320; falhar "Arquivo .ovpn não selecionado."; }
[ -r "$OVPN_FILE" ] || falhar "Não consigo ler $OVPN_FILE."

# -----------------------------------------------------------------------------
# PASSO 3: Sanitização da config
# -----------------------------------------------------------------------------
# O OpenVPN roda como root. Uma config pode pedir a execução de programas
# externos (up/down/route-up/plugin…) — e essas diretivas rodariam como root. O
# wrapper já força --script-security 1, mas `plugin` carrega uma biblioteca e não
# é coberto por ele. Neutralizar na fonte é a defesa que não depende de flag.
PERIGOSAS='up|down|up-restart|up-delay|route-up|route-pre-down|ipchange|tls-verify|tls-export-cert|auth-user-pass-verify|client-connect|client-disconnect|learn-address|plugin|script-security|cd|chroot|daemon|log|log-append|writepid|user|group|askpass|auth-user-pass|management|management-client|status|setenv-safe'

OVPN_TMP="$(mktemp)"
chmod 600 "$OVPN_TMP"
trap 'rm -f "$ASKPASS_FILE" "$OVPN_TMP"' EXIT INT TERM

tr -d '\r' < "$OVPN_FILE" | sed -E \
  -e "s/^[[:space:]]*(route)([[:space:]])/#[vpn-sophos] \1\2/" \
  -e "s/^[[:space:]]*($PERIGOSAS)([[:space:]]|\$)/#[vpn-sophos BLOQUEADO] \1\2/" \
  > "$OVPN_TMP"

BLOQUEADAS=$(grep -c 'vpn-sophos BLOQUEADO' "$OVPN_TMP" 2>/dev/null || true)
BLOQUEADAS=${BLOQUEADAS:-0}
if [ "$BLOQUEADAS" -gt 0 ]; then
  echo "🛡️  $BLOQUEADAS diretiva(s) de execução de código neutralizada(s) no .ovpn:"
  grep -n 'vpn-sophos BLOQUEADO' "$OVPN_TMP" | sed 's/^/     /' | head -10
  if grep -qE '^#\[vpn-sophos BLOQUEADO\] (plugin|up|down|route-up|auth-user-pass-verify)' "$OVPN_TMP"; then
    zenity --warning \
      --title="VPN Sophos — atenção" \
      --text="O arquivo .ovpn continha diretivas que executariam programas como root.\n\nElas foram <b>neutralizadas</b> na cópia usada pela VPN — o seu arquivo original não foi alterado.\n\nSe você não baixou este .ovpn do portal oficial da empresa, confirme a origem antes de conectar." \
      --width=460
  fi
  echo ""
fi

# -----------------------------------------------------------------------------
# PASSO 4: Segredos no keyring (antes de mexer no sistema)
# -----------------------------------------------------------------------------
if ! printf '%s' "$VPN_PASS" | secret-tool store --label="VPN Sophos — senha" service vpn-sophos key password; then
  zenity --error --text="Falha ao gravar a senha no keyring.\nVerifique se o GNOME Keyring está ativo e desbloqueado." --width=420
  falhar "Keyring indisponível."
fi
unset VPN_PASS

if [ "$TOTP_MODE" = "auto" ]; then
  if ! printf '%s' "$TOTP_SECRET" | secret-tool store --label="VPN Sophos — TOTP" service vpn-sophos key totp; then
    zenity --error --text="Falha ao gravar o segredo TOTP no keyring." --width=420
    falhar "Keyring indisponível."
  fi
  unset TOTP_SECRET
fi

# -----------------------------------------------------------------------------
# PASSO 5: Instalação
# -----------------------------------------------------------------------------
INSTALL_LOG="$(mktemp)"
chmod 600 "$INSTALL_LOG"
trap 'rm -f "$ASKPASS_FILE" "$OVPN_TMP" "$INSTALL_LOG"' EXIT INT TERM

instalar() {
  set -o pipefail

  echo "5"; echo "# Encerrando conexões de versões anteriores..."
  # As versões antigas subiam o openvpn com --config apontando para um .ovpn na
  # home, então o novo comando não as reconheceria como "nossas" e a máquina
  # ficaria com dois túneis. Aqui o encerramento é por origem: processos openvpn
  # cuja linha de comando aponta para a home do usuário, para /etc/vpn-sophos,
  # para /run/vpn-sophos ou para um arquivo temporário de auth. VPN de outro
  # usuário ou de outro serviço não entra nesse critério.
  legados=""
  for d in /proc/[0-9]*; do
    [ -r "$d/comm" ] || continue
    [ "$(cat "$d/comm" 2>/dev/null || true)" = openvpn ] || continue
    linha=$(tr '\0' ' ' < "$d/cmdline" 2>/dev/null || true)
    case "$linha" in
      *"$HOME"*|*/etc/vpn-sophos/*|*/run/vpn-sophos/*|*/tmp/tmp.*)
        legados="$legados ${d#/proc/}" ;;
    esac
  done
  if [ -n "$legados" ]; then
    # shellcheck disable=SC2086
    su_do kill -TERM $legados 2>/dev/null || true
    sleep 2
  fi

  echo "10"; echo "# Removendo resquícios de versões anteriores..."
  su_do rm -f /etc/tmpfiles.d/vpn-sophos.conf
  su_do rm -rf /run/vpn-sophos
  su_do rm -f /etc/sudoers.d/vpn-sophos
  su_do rm -f /usr/local/sbin/vpn-sophos-helper
  rm -f ~/.local/share/applications/vpn-connect.desktop \
        ~/.local/share/applications/vpn-disconnect.desktop

  echo "20"; echo "# Instalando a configuração da VPN..."
  su_do mkdir -p /etc/vpn-sophos
  su_do install -m 644 -o root -g root "$OVPN_TMP" /etc/vpn-sophos/client.ovpn
  su_do chmod 755 /etc/vpn-sophos

  echo "35"; echo "# Instalando os comandos privilegiados..."
  for arquivo in "${WRAPPERS[@]}"; do
    su_do install -m 755 -o root -g root "$APP_SRC/$arquivo" "/usr/local/sbin/$arquivo"
  done

  echo "50"; echo "# Configurando a permissão sudo restrita..."
  # As duas aspas no fim de cada comando são o ponto central: liberam o comando
  # SEM ARGUMENTO ALGUM. Sem elas, o sudoers aceitaria qualquer parâmetro extra.
  SUDOERS_TMP="$(mktemp)"
  {
    printf 'Defaults:%s env_reset\n' "$CURRENT_USER"
    printf '%s ALL=(root) NOPASSWD: /usr/local/sbin/vpn-sophos-up "", /usr/local/sbin/vpn-sophos-down "", /usr/local/sbin/vpn-sophos-log ""\n' "$CURRENT_USER"
  } > "$SUDOERS_TMP"

  if su_do visudo -cf "$SUDOERS_TMP" >/dev/null 2>&1; then
    su_do install -m 440 -o root -g root "$SUDOERS_TMP" /etc/sudoers.d/vpn-sophos
    rm -f "$SUDOERS_TMP"
  else
    rm -f "$SUDOERS_TMP"
    echo "SUDOERS_INVALIDO" >> "$INSTALL_LOG"
  fi

  echo "62"; echo "# Salvando a configuração local..."
  mkdir -p "$CONFIG_DIR"
  chmod 700 "$CONFIG_DIR"
  printf 'VPN_USER=%q\nTOTP_MODE=%q\n' "$VPN_USER" "$TOTP_MODE" > "$CONFIG_FILE"
  chmod 600 "$CONFIG_FILE"

  echo "72"; echo "# Criando os scripts de conexão..."
  gerar_scripts

  echo "85"; echo "# Instalando o ícone de bandeja..."
  mkdir -p "$APP_DIR" ~/.local/share/applications ~/.config/autostart
  install -m 755 "$APP_SRC/vpn-tray.py" "$APP_DIR/vpn-tray.py"
  install -m 755 "$APP_SRC/vpn-sophos-otp" "$APP_DIR/vpn-sophos-otp"

  cat > ~/.config/autostart/vpn-sophos-tray.desktop <<DESKEOF
[Desktop Entry]
Type=Application
Name=VPN Sophos (bandeja)
Comment=Status da VPN na barra do sistema
Exec=python3 $APP_DIR/vpn-tray.py
Icon=network-vpn
Terminal=false
Categories=Network;
X-GNOME-Autostart-enabled=true
DESKEOF

  cat > ~/.local/share/applications/vpn-sophos.desktop <<DESKEOF
[Desktop Entry]
Type=Application
Name=VPN Sophos
Comment=Conectar e desconectar a VPN do trabalho
Exec=python3 $APP_DIR/vpn-tray.py
Icon=network-vpn
Terminal=false
Categories=Network;
DESKEOF

  echo "95"; echo "# Configurando os atalhos de terminal..."
  configurar_aliases

  echo "100"; echo "# Concluído!"
}

# -----------------------------------------------------------------------------
# Scripts do usuário
# -----------------------------------------------------------------------------
gerar_scripts() {
  if [ "$TOTP_MODE" = "auto" ]; then
    # O segredo vai do keyring direto para o stdin do gerador: não passa por
    # variável de ambiente nem por argv (legível em /proc por outros usuários).
    OTP_BLOCK="OTP=\$(secret-tool lookup service vpn-sophos key totp | python3 '$APP_DIR/vpn-sophos-otp')
if [ -z \"\${OTP:-}\" ]; then
  encerrar 3 'Não foi possível gerar o código OTP. Destrave o keyring ou rode o setup novamente.'
fi"
  else
    OTP_BLOCK='OTP=$(zenity --entry --title="VPN — código 2FA" --text="Digite o código OTP do Sophos:" --width=320 || true)
if [ -z "${OTP:-}" ]; then
  encerrar 3 "Código OTP não informado."
fi'
  fi

  cat > ~/vpn-connect.sh <<ENDOFSCRIPT
#!/bin/bash
# Gerado pelo setup do vpn-sophos. Não editar à mão.
#
# Sem \`kill\` de processo pai: este script pode ser chamado por um lançador
# gráfico, pelo ícone de bandeja, pelo terminal ou por automação, e não deve
# derrubar quem o chamou.
#
# Saída: 0 conectado · 2 sem configuração · 3 credencial indisponível
#        4 autorização sudo ausente · 5 falha ao conectar
set -uo pipefail

CONFIG_FILE="\$HOME/.config/vpn-sophos/config"
UP=/usr/local/sbin/vpn-sophos-up

avisar() { notify-send "VPN" "\$1" --icon="\${2:-network-vpn}" 2>/dev/null || true; }
encerrar() { local c=\$1; shift; printf '%s\\n' "\$*" >&2; avisar "\$*" network-error; exit "\$c"; }

vpn_ativa() {
  local dev
  for dev in /sys/class/net/tun*; do
    [ -e "\$dev" ] || continue
    [ -n "\$(ip -4 -o addr show "\${dev##*/}" 2>/dev/null)" ] && return 0
  done
  return 1
}

if vpn_ativa; then
  echo "VPN já está conectada."
  exit 0
fi

[ -f "\$CONFIG_FILE" ] || encerrar 2 "Configuração não encontrada. Rode o setup novamente."
# shellcheck source=/dev/null
source "\$CONFIG_FILE"
[ -n "\${VPN_USER:-}" ] || encerrar 2 "Configuração incompleta. Rode o setup novamente."

# O comando privilegiado tem de ser exatamente o que o setup instalou: root e
# não gravável por mais ninguém. Se não for, algo adulterou o ambiente.
[ -f "\$UP" ] && [ ! -L "\$UP" ] || encerrar 2 "\$UP ausente. Rode o setup novamente."
leitura=\$(stat -c '%u %a' "\$UP")
if [ "\${leitura%% *}" != 0 ] || (( 0\${leitura##* } & 022 )); then
  encerrar 2 "\$UP não é root-only — ambiente comprometido. Rode o setup novamente."
fi

VPN_PASS=\$(secret-tool lookup service vpn-sophos key password || true)
[ -n "\${VPN_PASS:-}" ] || encerrar 3 "Senha não encontrada no keyring. Destrave o keyring ou rode o setup."

$OTP_BLOCK

# Credenciais pelo stdin: não aparecem em \`ps\`, não passam por arquivo que o
# usuário controle, e o wrapper as apaga antes de retornar. (Um here-string
# seria mais simples, mas o bash o materializa em arquivo temporário — a senha
# tocaria o disco.)
#
# pipefail é desligado só aqui: se o wrapper recusar antes de ler o stdin, o
# printf morre de SIGPIPE e o pipeline devolveria 141, escondendo o código real
# do wrapper. Sem pipefail, o status é o do último comando — o que queremos.
set +o pipefail
saida=\$(printf '%s\\n%s\\n' "\$VPN_USER" "\${VPN_PASS}\${OTP}" | sudo -n "\$UP" 2>&1)
codigo=\$?
set -o pipefail
unset VPN_PASS OTP

if [ \$codigo -eq 0 ]; then
  avisar "Conectado (\${saida##*: })" network-vpn
  echo "\$saida"
  exit 0
fi

case \$codigo in
  1|64|77) encerrar 4 "Autorização sudo ausente para a VPN. Rode o setup novamente." ;;
  66)      encerrar 5 "Configuração da VPN inválida no sistema. Rode o setup novamente." ;;
  *)       encerrar 5 "Falha ao conectar: \${saida:-erro \$codigo}. Diagnóstico: vpn-log" ;;
esac
ENDOFSCRIPT

  cat > ~/vpn-disconnect.sh <<'ENDOFSCRIPT'
#!/bin/bash
# Gerado pelo setup do vpn-sophos. Não editar à mão.
# Saída: 0 desconectado · 4 autorização sudo ausente · 5 falha ao desconectar
set -uo pipefail

DOWN=/usr/local/sbin/vpn-sophos-down

avisar() { notify-send "VPN" "$1" --icon="${2:-network-offline}" 2>/dev/null || true; }

if ! saida=$(sudo -n "$DOWN" 2>&1); then
  codigo=$?
  if [ $codigo -eq 1 ] || [ $codigo -eq 64 ]; then
    printf 'Autorização sudo ausente para a VPN. Rode o setup novamente.\n' >&2
    avisar "Autorização sudo ausente. Rode o setup novamente." network-error
    exit 4
  fi
  printf 'Falha ao desconectar: %s\n' "${saida:-erro $codigo}" >&2
  avisar "Falha ao desconectar." network-error
  exit 5
fi

avisar "VPN desconectada." network-offline
echo "$saida"
ENDOFSCRIPT

  chmod 700 ~/vpn-connect.sh ~/vpn-disconnect.sh
}

configurar_aliases() {
  local rc linha
  for rc in "$HOME/.zshrc" "$HOME/.bashrc"; do
    [ -f "$rc" ] || continue
    # Remove as versões antigas dos aliases antes de reescrever.
    sed -i "/^alias vpn-\(on\|off\|status\|log\)=/d" "$rc"
    {
      echo "alias vpn-on='~/vpn-connect.sh'"
      echo "alias vpn-off='~/vpn-disconnect.sh'"
      echo "alias vpn-status='ip -4 -o addr show | grep \" tun\" || echo \"VPN DESCONECTADA\"'"
      echo "alias vpn-log='sudo -n /usr/local/sbin/vpn-sophos-log'"
    } >> "$rc"
  done
}

instalar | zenity --progress \
  --title="VPN Sophos — instalando..." \
  --text="Iniciando..." \
  --percentage=0 \
  --auto-close \
  --width=420

if grep -q SUDOERS_INVALIDO "$INSTALL_LOG" 2>/dev/null; then
  zenity --error \
    --title="VPN Sophos — atenção" \
    --text="A regra sudo não passou na validação e <b>não foi instalada</b>.\n\nA VPN só vai conectar depois que isso for resolvido. Rode o setup novamente ou verifique /etc/sudoers.d/." \
    --width=460
  falhar "Regra sudoers inválida — instalação incompleta."
fi

# -----------------------------------------------------------------------------
# PASSO 6: Verificação — a instalação corre num subshell (barra de progresso),
# então em vez de confiar no caminho feliz, validamos o resultado no final.
# -----------------------------------------------------------------------------
problemas=()

for arquivo in "${WRAPPERS[@]}"; do
  destino="/usr/local/sbin/$arquivo"
  if [ ! -f "$destino" ] || [ -L "$destino" ]; then
    problemas+=("$destino não foi instalado")
    continue
  fi
  leitura=$(stat -c '%u %a' "$destino")
  if [ "${leitura%% *}" != 0 ] || (( 0${leitura##* } & 022 )); then
    problemas+=("$destino não está root-only")
  fi
done

if [ ! -f /etc/vpn-sophos/client.ovpn ]; then
  problemas+=("/etc/vpn-sophos/client.ovpn não foi instalado")
elif [ "$(stat -c '%u' /etc/vpn-sophos/client.ovpn)" != 0 ]; then
  problemas+=("/etc/vpn-sophos/client.ovpn não pertence ao root")
fi

# A regra sudoers está ativa? vpn-sophos-log devolve 0 (com log) ou 66 (sem log
# ainda). Qualquer outro código aqui significa que o sudo pediu senha ou negou.
sudo -n /usr/local/sbin/vpn-sophos-log >/dev/null 2>&1
codigo_teste=$?
case $codigo_teste in
  0|66) : ;;
  *) problemas+=("a regra sudo não está ativa (o comando privilegiado pediu senha)") ;;
esac

if [ ! -x "$APP_DIR/vpn-sophos-otp" ]; then
  problemas+=("$APP_DIR/vpn-sophos-otp não foi instalado")
elif ! printf 'JBSWY3DPEHPK3PXP\n' | python3 "$APP_DIR/vpn-sophos-otp" >/dev/null 2>&1; then
  problemas+=("o gerador de OTP não executou (python3 quebrado?)")
fi

for script in "$HOME/vpn-connect.sh" "$HOME/vpn-disconnect.sh"; do
  [ -x "$script" ] || problemas+=("$script não foi criado")
done
[ -f "$CONFIG_FILE" ] || problemas+=("$CONFIG_FILE não foi criado")

if [ ${#problemas[@]} -gt 0 ]; then
  printf '\n❌ Instalação incompleta:\n' >&2
  printf '   • %s\n' "${problemas[@]}" >&2
  zenity --error \
    --title="VPN Sophos — instalação incompleta" \
    --text="A instalação terminou com problemas:\n\n$(printf '• %s\n' "${problemas[@]}")\n\nRode o setup novamente." \
    --width=480
  exit 1
fi

echo "✅ Verificação pós-instalação: tudo no lugar."

# -----------------------------------------------------------------------------
# PASSO 7: Sobe o ícone de bandeja e conclui
# -----------------------------------------------------------------------------
if ! pgrep -f "$APP_DIR/vpn-tray.py" >/dev/null 2>&1; then
  nohup python3 "$APP_DIR/vpn-tray.py" >/dev/null 2>&1 &
  disown 2>/dev/null || true
fi

if [ "$TOTP_MODE" = "auto" ]; then
  OTP_INFO="Modo 2FA: automático (o OTP é gerado a cada conexão)"
else
  OTP_INFO="Modo 2FA: manual (o código é pedido ao conectar)"
fi

zenity --info \
  --title="VPN Sophos — pronto!" \
  --text="Setup concluído.\n\n$OTP_INFO\n\nO ícone da VPN aparece na barra do sistema — clique para conectar ou desconectar, sem senha.\n\nNo terminal:\n  <tt>vpn-on</tt>      conectar\n  <tt>vpn-off</tt>     desconectar\n  <tt>vpn-status</tt>  ver o estado\n  <tt>vpn-log</tt>     diagnóstico da última conexão\n\nAbra um novo terminal para os atalhos valerem." \
  --width=460

echo ""
echo "✅ Setup concluído."
echo "   Atalhos: vpn-on · vpn-off · vpn-status · vpn-log (abra um novo terminal)"
