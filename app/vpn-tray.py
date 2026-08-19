#!/usr/bin/env python3
# =============================================================================
# VPN Sophos — ícone de bandeja
# =============================================================================
# Mostra o estado da VPN na barra do sistema e conecta/desconecta pelo menu.
#
# Esta camada é SÓ interface: não lê credencial, não pede senha e não fala com o
# OpenVPN. Tudo passa por ~/vpn-connect.sh e ~/vpn-disconnect.sh, que buscam o
# segredo no keyring e chamam os comandos privilegiados. Nenhuma lógica sensível
# é duplicada aqui — este processo roda sem privilégio nenhum.
# =============================================================================
import os
import subprocess

import gi

gi.require_version("Gtk", "3.0")
try:  # Ubuntu atual
    gi.require_version("AyatanaAppIndicator3", "0.1")
    from gi.repository import AyatanaAppIndicator3 as AppIndicator
except (ValueError, ImportError):  # fallback legado
    gi.require_version("AppIndicator3", "0.1")
    from gi.repository import AppIndicator3 as AppIndicator

from gi.repository import Gdk, GLib, Gtk

APP_ID = "vpn-sophos-tray"
HOME = os.path.expanduser("~")
CONNECT = os.path.join(HOME, "vpn-connect.sh")
DISCONNECT = os.path.join(HOME, "vpn-disconnect.sh")
LOG_CMD = ["sudo", "-n", "/usr/local/sbin/vpn-sophos-log"]

ICON_ON = "network-vpn"
ICON_OFF = "network-offline"
ICON_BUSY = "network-transmit-receive"

POLL_NORMAL = 5
POLL_OCUPADO = 2


def interface_vpn():
    """Nome e IP da interface da VPN, ou (None, None). Barato: sysfs + ip."""
    try:
        devs = [d for d in os.listdir("/sys/class/net") if d.startswith("tun")]
    except OSError:
        return None, None
    for dev in sorted(devs):
        try:
            saida = subprocess.run(
                ["ip", "-4", "-o", "addr", "show", dev],
                capture_output=True, text=True, timeout=3,
            ).stdout
        except (OSError, subprocess.SubprocessError):
            continue
        for token in saida.split():
            if "/" in token and token[0].isdigit():
                return dev, token.split("/")[0]
    return None, None


def notificar(texto, icone="network-vpn"):
    try:
        subprocess.Popen(["notify-send", "VPN", texto, "--icon=" + icone])
    except OSError:
        pass


class VpnTray:
    def __init__(self):
        self.ocupado = False
        self.ip = None

        self.indicator = AppIndicator.Indicator.new(
            APP_ID, ICON_OFF, AppIndicator.IndicatorCategory.SYSTEM_SERVICES
        )
        self.indicator.set_status(AppIndicator.IndicatorStatus.ACTIVE)
        self.indicator.set_title("VPN Sophos")

        menu = Gtk.Menu()

        self.item_status = Gtk.MenuItem(label="Verificando...")
        self.item_status.set_sensitive(False)
        menu.append(self.item_status)
        menu.append(Gtk.SeparatorMenuItem())

        self.item_conectar = Gtk.MenuItem(label="Conectar")
        self.item_conectar.connect("activate", self.ao_conectar)
        menu.append(self.item_conectar)

        self.item_desconectar = Gtk.MenuItem(label="Desconectar")
        self.item_desconectar.connect("activate", self.ao_desconectar)
        menu.append(self.item_desconectar)

        menu.append(Gtk.SeparatorMenuItem())

        self.item_copiar = Gtk.MenuItem(label="Copiar IP")
        self.item_copiar.connect("activate", self.ao_copiar_ip)
        menu.append(self.item_copiar)

        item_log = Gtk.MenuItem(label="Diagnóstico...")
        item_log.connect("activate", self.ao_diagnostico)
        menu.append(item_log)

        menu.append(Gtk.SeparatorMenuItem())
        item_sair = Gtk.MenuItem(label="Sair")
        item_sair.connect("activate", lambda _i: Gtk.main_quit())
        menu.append(item_sair)

        menu.show_all()
        self.indicator.set_menu(menu)

        self.atualizar()
        self.timer = GLib.timeout_add_seconds(POLL_NORMAL, self.atualizar)

    # ── Estado ────────────────────────────────────────────────────────────────

    def atualizar(self):
        dev, ip = interface_vpn()
        self.ip = ip

        if self.ocupado:
            self.indicator.set_icon_full(ICON_BUSY, "VPN mudando de estado")
            self.item_status.set_label("• Aguarde...")
        elif dev:
            self.indicator.set_icon_full(ICON_ON, "VPN conectada")
            self.item_status.set_label("● Conectada — %s (%s)" % (ip, dev) if ip else "● Conectada")
        else:
            self.indicator.set_icon_full(ICON_OFF, "VPN desconectada")
            self.item_status.set_label("○ Desconectada")

        conectada = bool(dev)
        self.item_conectar.set_sensitive(not conectada and not self.ocupado)
        self.item_desconectar.set_sensitive(conectada and not self.ocupado)
        self.item_copiar.set_sensitive(bool(ip))
        return True  # mantém o timer

    def _reagendar(self, segundos):
        if self.timer:
            GLib.source_remove(self.timer)
        self.timer = GLib.timeout_add_seconds(segundos, self.atualizar)

    # ── Ações ─────────────────────────────────────────────────────────────────

    def _executar(self, script, rotulo):
        if not os.path.exists(script):
            notificar("Script não encontrado. Rode o setup novamente.", "network-error")
            return

        self.ocupado = True
        self.atualizar()
        self._reagendar(POLL_OCUPADO)

        try:
            proc = subprocess.Popen(
                ["bash", script],
                stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL,
            )
        except OSError as exc:
            self.ocupado = False
            notificar("Falha ao executar %s: %s" % (rotulo, exc), "network-error")
            self.atualizar()
            return

        GLib.timeout_add_seconds(1, self._aguardar, proc)

    def _aguardar(self, proc):
        """Espera o script terminar sem travar a interface."""
        if proc.poll() is None:
            return True  # continua verificando
        self.ocupado = False
        self.atualizar()
        self._reagendar(POLL_NORMAL)
        return False

    def ao_conectar(self, _item):
        self._executar(CONNECT, "conexão")

    def ao_desconectar(self, _item):
        self._executar(DISCONNECT, "desconexão")

    def ao_copiar_ip(self, _item):
        if not self.ip:
            return
        clipboard = Gtk.Clipboard.get(Gdk.SELECTION_CLIPBOARD)
        clipboard.set_text(self.ip, -1)
        clipboard.store()
        notificar("IP %s copiado." % self.ip)

    def ao_diagnostico(self, _item):
        try:
            resultado = subprocess.run(LOG_CMD, capture_output=True, text=True, timeout=8)
            texto = resultado.stdout or resultado.stderr or "Sem log disponível."
        except (OSError, subprocess.SubprocessError) as exc:
            texto = "Não foi possível ler o log: %s" % exc
        try:
            zenity = subprocess.Popen(
                ["zenity", "--text-info", "--title=VPN Sophos — diagnóstico",
                 "--width=760", "--height=460"],
                stdin=subprocess.PIPE, text=True,
            )
            zenity.communicate(texto)
        except OSError:
            notificar("zenity não disponível para mostrar o diagnóstico.", "network-error")


def main():
    VpnTray()
    try:
        Gtk.main()
    except KeyboardInterrupt:
        pass


if __name__ == "__main__":
    main()
