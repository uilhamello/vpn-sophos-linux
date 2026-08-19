#!/usr/bin/env python3
"""MCP da VPN Sophos — liga, desliga e inspeciona a VPN de trabalho.

Os scripts `~/vpn-connect.sh` e `~/vpn-disconnect.sh` fazem o trabalho; este
servidor só os invoca e traduz o resultado. Eles são chamados através de um shell
descartável:

    bash -c 'bash "$1"; codigo=$?; exit $codigo' -- <script>

O shell do meio existe por duas razões. A primeira é histórica e ainda vale como
proteção: até 18/08/2026 os scripts terminavam com `kill $(ps -o ppid= -p $$)`,
que mata o processo PAI — numa instalação antiga isso derrubaria este servidor.
Com o shell descartável no meio, o kill acerta ele. A segunda é que o `codigo=$?`
impede o bash de fazer exec-optimization, garantindo que o descartável exista de
fato, e ainda devolve o código de saída real do script.

Os códigos de saída dos scripts são traduzidos em mensagens: 2 sem configuração,
3 credencial indisponível (keyring travado, TOTP), 4 autorização sudo ausente,
5 falha ao conectar.

Nenhuma credencial passa por aqui: quem fala com o keyring é o script, e a senha
do sudo não existe no fluxo (a regra sudoers libera os comandos da VPN sem
senha). Ainda assim, todo texto devolvido passa por um mascarador.
"""

import os
import json
import shlex
import subprocess
import time

try:  # SDK mcp 2.x
    from mcp.server import MCPServer as _Servidor
except ImportError:  # SDK mcp 1.x
    from mcp.server.fastmcp import FastMCP as _Servidor

mcp = _Servidor("VPN Sophos")

HOME = os.path.expanduser("~")
SCRIPT_CONNECT = os.path.join(HOME, "vpn-connect.sh")
SCRIPT_DISCONNECT = os.path.join(HOME, "vpn-disconnect.sh")
CONFIG_FILE = os.path.join(HOME, ".config", "vpn-sophos", "config")
# Instalações antigas guardavam segredo em texto plano neste arquivo. Ele não é
# mais usado, mas segue alimentando o mascarador enquanto existir na máquina.
CREDENCIAL_LEGADA = os.path.join(HOME, ".config", "vpn-sophos", ".credentials")
LOG_DIR = os.path.join(HOME, ".local", "state", "vpn-mcp")
LOG_FILE = os.path.join(LOG_DIR, "connect.log")

IFACE = "tun0"
CHAVES_SENSIVEIS = ("SUDO_PASS", "VPN_PASS", "TOTP_SECRET", "VPN_USER")


# ── Helpers ───────────────────────────────────────────────────────────────────

def _run(cmd, **kwargs):
    """Executa um comando e devolve (returncode, stdout+stderr)."""
    proc = subprocess.run(
        cmd, capture_output=True, text=True, timeout=kwargs.pop("timeout", 30), **kwargs
    )
    return proc.returncode, (proc.stdout or "") + (proc.stderr or "")


def _credenciais():
    """Lê os arquivos de configuração (KEY=VALUE de shell). Nunca é retornado.

    Serve apenas para alimentar o mascarador de saída.
    """
    dados = {}
    for caminho in (CONFIG_FILE, CREDENCIAL_LEGADA):
        if os.path.isfile(caminho):
            dados.update(_ler_pares(caminho))
    return dados


def _ler_pares(caminho):
    dados = {}
    with open(caminho, "r", encoding="utf-8", errors="replace") as fh:
        for linha in fh:
            linha = linha.strip()
            if not linha or linha.startswith("#") or "=" not in linha:
                continue
            chave, _, valor = linha.partition("=")
            chave = chave.replace("export ", "").strip()
            try:
                partes = shlex.split(valor)
            except ValueError:
                partes = [valor]
            dados[chave] = partes[0] if partes else ""
    return dados


def _mascarar(texto):
    """Substitui qualquer valor sensível que tenha vazado para um output."""
    if not texto:
        return texto
    for chave, valor in _credenciais().items():
        if chave in CHAVES_SENSIVEIS and valor and len(valor) > 2:
            texto = texto.replace(valor, "***")
    linhas = [ln for ln in texto.splitlines() if "[sudo]" not in ln and "password for" not in ln]
    return "\n".join(linhas)


def _ip_tun():
    """Devolve o IPv4 da interface da VPN, ou None se estiver caída."""
    rc, out = _run(["ip", "-j", "addr", "show", IFACE], timeout=10)
    if rc != 0:
        return None
    try:
        ifaces = json.loads(out or "[]")
    except json.JSONDecodeError:
        return None
    for iface in ifaces:
        for addr in iface.get("addr_info", []):
            if addr.get("family") == "inet":
                return addr.get("local")
    return None


def _pids_openvpn():
    rc, out = _run(["pgrep", "-x", "openvpn"], timeout=10)
    return [int(p) for p in out.split()] if rc == 0 else []


def _executar_script(script, timeout):
    """Roda um dos scripts da VPN e devolve (codigo, saida).

    O shell descartável no meio protege este servidor do `kill` de processo pai
    que as instalações antigas do vpn-sophos deixavam no fim dos scripts, e o
    `codigo=$?` preserva o código de saída real (ver o cabeçalho do módulo).
    """
    os.makedirs(LOG_DIR, mode=0o700, exist_ok=True)
    try:
        proc = subprocess.run(
            ["bash", "-c", 'bash "$1"; codigo=$?; exit $codigo', "--", script],
            stdin=subprocess.DEVNULL,
            capture_output=True,
            text=True,
            timeout=timeout,
            start_new_session=True,
        )
    except subprocess.TimeoutExpired:
        return 124, "o script não terminou em %ds" % timeout

    saida = ((proc.stdout or "") + (proc.stderr or "")).strip()
    try:
        with open(LOG_FILE, "w", encoding="utf-8") as log:
            os.chmod(LOG_FILE, 0o600)
            log.write("$ %s\n(codigo %s)\n%s\n" % (script, proc.returncode, saida))
    except OSError:
        pass
    return proc.returncode, saida


MENSAGENS = {
    2: "configuração da VPN ausente ou incompleta — rode o scripts/setup-vpn.sh",
    3: "credencial indisponível — destrave o keyring do GNOME (ou rode o setup)",
    4: "autorização sudo ausente para os comandos da VPN — rode o setup novamente",
    5: "falha ao conectar (rede, senha ou OTP)",
    124: "o script não respondeu no tempo esperado",
}


# ── Tools ─────────────────────────────────────────────────────────────────────

@mcp.tool()
def vpn_status() -> str:
    """Diz se a VPN de trabalho está conectada.

    Use ANTES de qualquer acesso ao banco da AutoAvaliar (MCP b2b-database,
    Cloud SQL, mysql, ProxySQL) — sem VPN o banco é inalcançável e a conexão
    morre em timeout. Não altera nada."""
    ip = _ip_tun()
    pids = _pids_openvpn()
    if ip:
        return f"CONECTADA — {IFACE} {ip} | openvpn pid {pids or 'não visível'}"
    if pids:
        return f"CONECTANDO/INSTÁVEL — openvpn rodando (pid {pids}) mas {IFACE} sem IPv4"
    return f"DESCONECTADA — sem interface {IFACE} e sem processo openvpn"


@mcp.tool()
def vpn_connect(espera_segundos: int = 45) -> str:
    """Liga a VPN de trabalho e espera o túnel subir.

    Idempotente: se já estiver conectada, não faz nada. No modo TOTP automático
    não pede nada a ninguém — o script busca a senha no keyring e gera o código
    2FA. Quando falha, devolve a causa (configuração, keyring, sudo ou rede)."""
    ip = _ip_tun()
    if ip:
        return f"Já estava conectada — {IFACE} {ip}. Nada a fazer."

    if not os.path.isfile(SCRIPT_CONNECT):
        return f"Erro: {SCRIPT_CONNECT} não existe. Rode o scripts/setup-vpn.sh."
    if not os.path.isfile(CONFIG_FILE):
        return f"Erro: configuração ausente em {CONFIG_FILE}. Rode o setup novamente."

    espera = max(10, min(int(espera_segundos), 180))
    codigo, saida = _executar_script(SCRIPT_CONNECT, espera)
    saida = _mascarar(saida)

    if codigo == 0:
        ip = _ip_tun()
        if ip:
            return f"Conectada — {IFACE} {ip}. Banco acessível."
        return f"O script concluiu sem erro, mas não vejo IPv4 em {IFACE}: {saida}"

    return (
        f"Falhou: {MENSAGENS.get(codigo, f'código {codigo}')}."
        + (f"\n{saida}" if saida else "")
        + "\nPara o log do OpenVPN: vpn_logs."
    )


@mcp.tool()
def vpn_disconnect() -> str:
    """Desliga a VPN de trabalho.

    Use SÓ quando o usuário pedir explicitamente — desligar no meio de um
    acesso a banco derruba consultas em andamento."""
    if not _pids_openvpn() and not _ip_tun():
        return "Já estava desconectada. Nada a fazer."

    if not os.path.isfile(SCRIPT_DISCONNECT):
        return f"Erro: {SCRIPT_DISCONNECT} não existe. Rode o scripts/setup-vpn.sh."

    codigo, saida = _executar_script(SCRIPT_DISCONNECT, 45)
    saida = _mascarar(saida)

    if codigo == 0 and not _ip_tun():
        return "Desconectada — openvpn encerrado."
    if codigo == 0:
        return f"O script concluiu, mas {IFACE} ainda tem IPv4. {saida}"
    return f"Falhou: {MENSAGENS.get(codigo, f'código {codigo}')}." + (f"\n{saida}" if saida else "")


@mcp.tool()
def vpn_logs(linhas: int = 30) -> str:
    """Diagnóstico da VPN: última execução dos scripts e fim do log do OpenVPN.

    Use quando vpn_connect falhar — é aqui que aparece AUTH_FAILED (senha ou OTP
    errado), erro de TLS ou de rede. Segredos são mascarados."""
    partes = []

    local = _ler_log(max(1, min(int(linhas), 200)))
    if local:
        partes.append("--- última execução dos scripts ---\n" + local)

    # O log do OpenVPN vive em tmpfs root-only; o wrapper privilegiado é a única
    # forma de lê-lo, e ele não aceita argumentos.
    codigo, saida = _run(["sudo", "-n", "/usr/local/sbin/vpn-sophos-log"], timeout=15)
    saida = (saida or "").strip()
    if codigo == 0 and saida:
        partes.append("--- log do OpenVPN ---\n" + saida)
    elif codigo != 0:
        partes.append(f"(log do OpenVPN indisponível: {saida or 'código %d' % codigo})")

    return _mascarar("\n\n".join(partes)) or f"Sem log ainda em {LOG_FILE}."


def _ler_log(linhas):
    if not os.path.isfile(LOG_FILE):
        return ""
    with open(LOG_FILE, "r", encoding="utf-8", errors="replace") as fh:
        return "".join(fh.readlines()[-linhas:]).strip()


if __name__ == "__main__":
    mcp.run()
