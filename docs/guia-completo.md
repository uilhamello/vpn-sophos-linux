# Guia Completo — VPN Sophos no Linux

## Contexto

O cliente oficial da Sophos (**Sophos Connect**) não tem versão para Linux. O NetworkManager com plugin OpenVPN não suporta autenticação 2FA concatenada usada pelo Sophos SSL VPN. Este guia documenta a solução desenvolvida para contornar essas limitações.

---

## Como a autenticação funciona

O Sophos SSL VPN com TOTP usa autenticação concatenada:

```
senha_enviada = senha_do_domínio + código_otp_6_digitos
```

Por exemplo, se sua senha é `minhasenha` e o OTP do momento é `123456`, o campo de senha enviado ao servidor é `minhasenha123456`.

O NetworkManager não consegue lidar com isso nativamente porque pede a senha uma única vez e não tem como compor senha + OTP dinâmico.

---

## O que o setup instala

| Componente | Finalidade |
|---|---|
| `openvpn` | Cliente OpenVPN |
| `python3` | Gerador de TOTP (`vpn-sophos-otp`) e ícone de bandeja |
| `libsecret-tools` | Acesso ao GNOME keyring via `secret-tool` |
| `zenity` | Interface gráfica para os scripts |
| `libnotify-bin` | Notificações de desktop (`notify-send`) |
| `python3-gi`, `gir1.2-gtk-3.0`, AppIndicator | Ícone de bandeja |

Além dos pacotes, o setup cria:

| Artefato | Local | Finalidade |
|---|---|---|
| Comando de conexão | `/usr/local/sbin/vpn-sophos-up` | Sobe a VPN (root). Credencial pelo stdin |
| Comando de desconexão | `/usr/local/sbin/vpn-sophos-down` | Encerra só esta VPN (root) |
| Comando de diagnóstico | `/usr/local/sbin/vpn-sophos-log` | Devolve o fim do log do OpenVPN (root) |
| Regra sudoers | `/etc/sudoers.d/vpn-sophos` | Libera os três comandos, sem senha e **sem argumentos** |
| Config sanitizada | `/etc/vpn-sophos/client.ovpn` | `.ovpn` do sistema, `root:root 0644` (original intacto) |
| Runtime | `/run/vpn-sophos/` | tmpfs `root:root 0700` — credencial, pidfile, log e interface |
| Gerador de TOTP | `~/.local/share/vpn-sophos/vpn-sophos-otp` | Segredo pelo stdin, sem privilégio |
| Ícone de bandeja | `~/.local/share/vpn-sophos/vpn-tray.py` | UI sem privilégio, com autostart |
---

## Onde ficam os segredos

| Item | Onde | Proteção |
|---|---|---|
| Senha sudo | **não é armazenada** | pedida pelo `sudo`/`zenity`; nunca em variável nossa nem no ambiente |
| Senha VPN | GNOME keyring (`service vpn-sophos key password`) | criptografado em repouso |
| Secret TOTP (modo auto) | GNOME keyring (`service vpn-sophos key totp`) | criptografado em repouso |
| Usuário VPN + modo OTP | `~/.config/vpn-sophos/config` | 600 (não é segredo) |
| Auth de conexão | `/run/vpn-sophos/auth` | tmpfs `root:root 0700`; escrito pelo root e apagado antes de a chamada retornar |
---

## Fluxo de conexão (passo a passo interno)

1. `~/vpn-connect.sh` verifica se já existe túnel — se sim, sai com 0 (idempotente)
2. Lê `VPN_USER` de `~/.config/vpn-sophos/config`
3. Confere que `/usr/local/sbin/vpn-sophos-up` é root e não gravável por outros — se não for, aborta: o ambiente foi adulterado
4. Busca a senha VPN no keyring (`secret-tool lookup`)
5. Gera o OTP com `vpn-sophos-otp`, passando o segredo do keyring pelo stdin — nunca por `argv`, que é legível por outros usuários em `/proc`. No modo manual, pede o código via Zenity
6. Entrega usuário e `senha+OTP` pelo **stdin** de `sudo -n vpn-sophos-up` — nada em `argv`, nada em arquivo que o usuário controle
7. O wrapper (root) valida a config, grava a credencial em `/run/vpn-sophos/auth`, encerra **apenas** a instância desta VPN e sobe o `openvpn --daemon` com `--script-security 1`, `--user nobody`, `--group nogroup`, `--persist-tun` e `--persist-key`
8. O wrapper espera até 20s pela interface, apaga a credencial e retorna o nome da interface
9. O script notifica o resultado. Códigos de saída: `0` conectado, `2` sem configuração, `3` credencial indisponível, `4` autorização sudo ausente, `5` falha ao conectar
---

## Verificar se a VPN está ativa

```bash
# Interface tun0 só existe quando VPN está conectada
ip addr show tun0 2>/dev/null && echo "VPN ATIVA" || echo "VPN DESCONECTADA"

# Ou pelo alias
vpn-status
```

---

## Segurança do privilégio de root

A conexão precisa de root (o `openvpn` cria a interface `tun`), mas a senha sudo
**não é guardada**. O setup instala uma regra em `/etc/sudoers.d/vpn-sophos`:

```
<usuario> ALL=(root) NOPASSWD: /usr/local/sbin/vpn-sophos-up "", /usr/local/sbin/vpn-sophos-down "", /usr/local/sbin/vpn-sophos-log ""
```

As duas aspas no fim de cada comando são essenciais: liberam o comando **sem
argumento algum**. Sem elas, o sudoers aceitaria qualquer parâmetro extra.

Liberar esses três comandos sem senha não dá acesso irrestrito, porque cada um
deles é fechado por construção:

- pertencem ao root (`root:root 0755`) — o usuário não altera o que roda como root;
- não recebem caminho de config nem de credencial: a config é fixa em `/etc` e as
  credenciais chegam pelo stdin. Assim ninguém aponta o OpenVPN para um `.ovpn`
  adulterado, nem faz o root ler um arquivo arbitrário (como `/etc/shadow`) e
  enviá-lo ao servidor VPN como se fosse senha;
- verificam a integridade da config antes de usar (dono root, não gravável por
  outros, não é symlink);
- forçam `--script-security 1` **depois** do `--config`, vencendo qualquer
  diretiva do arquivo, e o `.ovpn` já foi sanitizado na instalação — inclusive
  contra `plugin`, que carrega biblioteca como root e não é coberto pela flag;
- descartam privilégio para `nobody:nogroup` depois de subir o túnel;
- encerram apenas o processo desta VPN (pidfile ou linha de comando apontando
  para a nossa config), nunca `killall openvpn`, que derrubaria a VPN de outro
  usuário ou serviço da mesma máquina.
---

## Limitações conhecidas

- **Reautenticação no meio da sessão.** A conexão usa `--auth-nocache` e a
  credencial é apagada assim que o túnel sobe. Se o servidor Sophos exigir
  reautenticação durante a sessão, o OpenVPN não tem como responder e a conexão
  cai — é preciso reconectar. É o preço de não manter senha e OTP em memória nem
  em disco enquanto a VPN está de pé.
- **DNS e rotas empurrados pelo servidor não são aplicados.** Com
  `--script-security 1` nenhum script externo roda, e as diretivas `route` do
  `.ovpn` são comentadas na instalação. O acesso funciona pela rota do túnel; se
  você precisar resolver nomes internos, use IP ou configure o DNS à mão.
- **Modo TOTP automático guarda o segundo fator.** Ele fica no keyring, que
  destrava no seu login — portanto ao alcance de processos da sua sessão. O modo
  manual elimina isso, ao custo de não permitir automação.
- **Uma VPN por vez.** O encerramento é cirúrgico (só a instância desta config),
  mas subir a VPN encerra a anterior desta mesma config.

---

## Obter a Chave TOTP BASE32

1. Acesse o portal VPN da sua empresa: `https://vpn.suaempresa.com:4443`
2. Faça login com suas credenciais de domínio
3. Clique em **OTP tokens** no menu lateral
4. Copie o valor de **Secret (BASE32)**

> Guarde essa chave em local seguro — ela é necessária para reinstalar o setup.

---

## Reinstalar do zero

```bash
# Remove tudo
./scripts/cleanup-vpn.sh

# Instala novamente
./scripts/setup-vpn.sh
```

---

## Aliases disponíveis após o setup

```bash
vpn-on      # conectar
vpn-off     # desconectar
vpn-status  # verificar se está ativo
```
