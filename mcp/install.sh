#!/usr/bin/env bash
# Instala o MCP "vpn-sophos" no Claude Code desta máquina.
#
# O que faz:
#   1. checa os pré-requisitos (scripts do app, credenciais, python, setsid, claude)
#   2. blinda o `kill $(ps -o ppid= -p $$)` dos scripts da VPN com um guard de TTY
#   3. cria a venv própria e instala a dependência (pacote mcp)
#   4. registra o servidor no escopo user (vale em qualquer projeto)
#   5. valida o registro e as tools
#
# Idempotente: rodar de novo não duplica nada.

set -euo pipefail

DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
NOME_MCP="vpn-sophos"
CONNECT="$HOME/vpn-connect.sh"
DISCONNECT="$HOME/vpn-disconnect.sh"
CREDENCIAIS="$HOME/.config/vpn-sophos/.credentials"
STAMP="$(date +%Y%m%d%H%M%S)"

erro() { printf '\n\033[31m✘ %s\033[0m\n' "$1" >&2; exit 1; }
ok()   { printf '\033[32m✔\033[0m %s\n' "$1"; }
info() { printf '\033[36m·\033[0m %s\n' "$1"; }

# ── 1. Pré-requisitos ─────────────────────────────────────────────────────────

for bin in python3 setsid ip pgrep claude; do
  command -v "$bin" >/dev/null 2>&1 || erro "'$bin' não encontrado no PATH."
done

python3 - <<'PY' || erro "Python 3.10+ é necessário."
import sys
sys.exit(0 if sys.version_info >= (3, 10) else 1)
PY

[ -f "$CONNECT" ]     || erro "$CONNECT não existe. Rode scripts/setup-vpn.sh primeiro."
[ -f "$DISCONNECT" ]  || erro "$DISCONNECT não existe. Rode scripts/setup-vpn.sh primeiro."
[ -f "$CREDENCIAIS" ] || erro "$CREDENCIAIS não existe. Rode scripts/setup-vpn.sh primeiro."
ok "Pré-requisitos presentes."

# ── 2. Guard no kill do ppid ──────────────────────────────────────────────────
# Os scripts terminam com `kill $(ps -o ppid= -p $$)` para fechar a janela do
# lançador GUI. Isso mata o processo PAI — e derruba qualquer chamador
# programático (uma sessão do Claude Code, por exemplo). O guard faz o kill
# disparar somente quando há terminal interativo.

blindar() {
  local arquivo="$1"
  grep -q 'ps -o ppid= -p \$\$' "$arquivo" 2>/dev/null || { info "$(basename "$arquivo"): sem kill de ppid, nada a fazer."; return 0; }
  if grep -q '\[ -t 1 \].*kill \$(ps -o ppid= -p \$\$)' "$arquivo"; then
    info "$(basename "$arquivo"): já blindado."
    return 0
  fi
  cp -a "$arquivo" "$arquivo.bak-$STAMP"
  sed -i -E '/\[ -t 1 \]/! s|^([[:space:]]*)kill \$\(ps -o ppid= -p \$\$\).*$|\1[ -t 1 ] \&\& kill $(ps -o ppid= -p $$) 2>/dev/null \|\| true|' "$arquivo"
  bash -n "$arquivo" || { mv "$arquivo.bak-$STAMP" "$arquivo"; erro "$arquivo ficou com erro de sintaxe; revertido."; }
  ok "$(basename "$arquivo") blindado (backup em $(basename "$arquivo").bak-$STAMP)."
}

blindar "$CONNECT"
blindar "$DISCONNECT"

# O gerador também, para um próximo setup não reintroduzir o problema.
if [ -f "$DIR/../scripts/setup-vpn.sh" ]; then
  GERADOR="$DIR/../scripts/setup-vpn.sh"
  if grep -q 'ps -o ppid= -p' "$GERADOR" && ! grep -q '\[ -t 1 \].*ps -o ppid= -p' "$GERADOR"; then
    cp -a "$GERADOR" "$GERADOR.bak-$STAMP"
    sed -i -E '/\[ -t 1 \]/! s|^([[:space:]]*)kill (\\?)\$\((ps -o ppid= -p )(\\?)\$(\\?)\$\).*$|\1[ -t 1 ] \&\& kill \2$(\3\4$\5$) 2>/dev/null \|\| true|' "$GERADOR"
    bash -n "$GERADOR" && ok "setup-vpn.sh blindado." || { mv "$GERADOR.bak-$STAMP" "$GERADOR"; info "setup-vpn.sh não pôde ser blindado automaticamente; revertido (não impede a instalação)."; }
  else
    info "setup-vpn.sh: já blindado ou sem o padrão."
  fi
fi

# ── 3. Venv própria ───────────────────────────────────────────────────────────

if [ ! -x "$DIR/.venv/bin/python" ]; then
  info "Criando venv em $DIR/.venv ..."
  python3 -m venv "$DIR/.venv"
fi
"$DIR/.venv/bin/pip" install --quiet --upgrade pip
"$DIR/.venv/bin/pip" install --quiet -r "$DIR/requirements.txt"
ok "Dependências instaladas."

# ── 4. Registro no Claude Code ────────────────────────────────────────────────

claude mcp remove "$NOME_MCP" -s user >/dev/null 2>&1 || true
claude mcp add-json -s user "$NOME_MCP" \
  "{\"type\":\"stdio\",\"command\":\"$DIR/.venv/bin/python\",\"args\":[\"$DIR/servidor_vpn.py\"],\"env\":{}}" >/dev/null
ok "MCP '$NOME_MCP' registrado no escopo user."

# ── 5. Validação ──────────────────────────────────────────────────────────────

cd "$DIR"
"$DIR/.venv/bin/python" - <<'PY'
import asyncio
import servidor_vpn as s

tools = asyncio.run(s.mcp.list_tools())
print("  tools:  " + ", ".join(t.name for t in tools))
print("  status: " + s.vpn_status())
PY

claude mcp list 2>/dev/null | grep -F "$NOME_MCP" || true

cat <<EOF

$(ok "Instalado.")

  As tools só aparecem na PRÓXIMA sessão do Claude Code — MCPs são carregados
  na inicialização. Abra uma sessão nova e peça "qual o status da vpn?".

  Tools:  vpn_status · vpn_connect · vpn_disconnect · vpn_logs
EOF
