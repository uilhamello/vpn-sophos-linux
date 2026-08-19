# VPN Sophos para Linux

> Setup automatizado para conectar à VPN Sophos SSL com autenticação 2FA (TOTP) no Ubuntu/GNOME.

---

## Por que esse projeto existe?

O **Sophos Connect** — cliente oficial da Sophos — **não tem versão para Linux**. As alternativas nativas (NetworkManager + plugin OpenVPN) não funcionam com a autenticação de dois fatores concatenada usada pelo Sophos SSL VPN.

Este projeto resolve exatamente esse gap: um setup com interface gráfica que configura tudo automaticamente e permite conectar/desconectar com um clique.

---

## Compatibilidade

| Requisito | Detalhe |
|---|---|
| **Sistema operacional** | Ubuntu 22.04+ (ou derivados) com GNOME |
| **VPN** | Sophos SSL VPN com TOTP (2FA) |
| **Shell** | zsh ou bash |

> Não funciona em: Windows, macOS, outras distros (Arch, Fedora), outras VPNs (Fortinet, GlobalProtect, WireGuard).

---

## Pré-requisitos

Antes de rodar o setup, tenha em mãos:

1. **Arquivo `.ovpn`** — baixe no portal Sophos da sua empresa:
   `https://vpn.suaempresa.com → VPN → SSL VPN configuration → Download for Linux`

2. **Chave TOTP BASE32** — disponível no mesmo portal:
   `https://vpn.suaempresa.com → OTP tokens → Secret (BASE32)`

3. **Usuário e senha VPN** — suas credenciais de domínio

4. **Senha sudo** — senha do seu usuário Linux

---

## Instalação

```bash
# 1. Clone o repositório
git clone https://github.com/sua-empresa/vpn-sophos.git
cd vpn-sophos

# 2. Coloque o arquivo .ovpn na sua home (opcional — pode selecionar na tela)
cp sslvpn-*.ovpn ~/

# 3. Dê permissão e rode o setup
chmod +x scripts/setup-vpn.sh
./scripts/setup-vpn.sh
```

O instalador abrirá uma interface gráfica pedindo as informações passo a passo.

## Informações solicitadas:

1. - Senha SUDO — pedida pelo próprio `sudo`, **não é armazenada em lugar nenhum**
2. - Usuário da VPN
3. - Senha da VPN — vai para o keyring
4. - Secret Base32 - [opcional]  Caso queira que o sistema leia o token automaticamente.
---
Onde obter o secret base32:
<img width="1245" height="449" alt="imagem (3)" src="https://github.com/user-attachments/assets/47b6e7ad-91d1-4b88-8377-0c14d20964d5" />

---

## Uso

Depois do setup aparece um **ícone da VPN na barra do sistema**. Clique nele para
conectar, desconectar, copiar o IP do túnel ou ver o diagnóstico da última
conexão. Nenhuma dessas ações pede senha.

| Ação | Bandeja | Terminal |
|---|---|---|
| Conectar | **Conectar** | `vpn-on` |
| Desconectar | **Desconectar** | `vpn-off` |
| Ver estado | ícone + primeira linha do menu | `vpn-status` |
| Diagnóstico da conexão | **Diagnóstico...** | `vpn-log` |

Os atalhos de terminal valem em novos terminais (o setup os grava no `.zshrc` e
no `.bashrc`).

---

## Como funciona

1. O setup coleta os dados numa interface gráfica. A **senha do sudo** é pedida
   pelo próprio `sudo` (ou por uma janela do `zenity` que entrega a senha direto
   a ele) e **nunca passa por variável, ambiente ou arquivo nosso**.
2. **Senha VPN** e **secret TOTP** vão para o **GNOME keyring**, criptografados
   em repouso. Em disco ficam apenas dados não sensíveis — usuário e modo do OTP
   — em `~/.config/vpn-sophos/config` (`600`).
3. O `.ovpn` é copiado para `/etc/vpn-sophos/client.ovpn` (`root:root 0644`) e
   **sanitizado**: toda diretiva capaz de executar código (`up`, `down`,
   `route-up`, `plugin`, `script-security`…) é comentada. O setup mostra quantas
   foram neutralizadas. Seu arquivo original não é alterado.
4. O setup instala três comandos privilegiados em `/usr/local/sbin`
   (`vpn-sophos-up`, `-down`, `-log`) e uma regra `sudoers` que libera **somente
   eles, sem senha e sem argumento algum**.
5. Ao conectar, o script do usuário busca a senha no keyring e gera o OTP com o
   `vpn-sophos-otp` — o segredo vai do keyring direto para o **stdin** do
   gerador, nunca para a linha de comando. Usuário e `senha+OTP` seguem também
   pelo **stdin** do `vpn-sophos-up`, que grava a credencial em tmpfs root-only,
   sobe o OpenVPN endurecido, espera a interface subir e apaga a credencial antes
   de retornar.
6. Não há terminal preso nem processo pai morto: os scripts podem ser chamados
   pela bandeja, pelo terminal ou por automação.

---

## Segurança

O modelo de ameaça é explícito: **assume-se que um processo qualquer da sua
sessão pode tentar abusar do que roda sem senha.** Daí cada decisão abaixo.

| Defesa | Ataque que ela fecha |
|---|---|
| Senha do sudo nunca em variável/ambiente | leitura de `/proc/<pid>/environ` por outro processo seu |
| Senha VPN e TOTP no keyring | segredo em texto plano legível por qualquer coisa que leia seu `$HOME` |
| Comandos privilegiados fixos, **sem argumentos** (`""` no sudoers) | passar parâmetro extra para o comando que roda como root |
| Config root-owned em `/etc` + `.ovpn` sanitizado + `--script-security 1` | `.ovpn` adulterado executando script/`plugin` **como root** |
| Credencial pelo **stdin**, nunca por caminho que o usuário controle | trocar o arquivo de auth por symlink para `/etc/shadow` e fazer o root enviá-lo ao servidor VPN |
| Runtime em tmpfs `root:root 0700`, credencial apagada antes do retorno | leitura da credencial em disco por outro processo da sessão |
| `--user nobody --group nogroup --persist-tun --persist-key` | um OpenVPN comprometido seguir como root depois de subir o túnel |
| Encerramento pelo pidfile/cmdline desta VPN | `killall openvpn` derrubando a VPN de outro usuário ou serviço |
| Credencial e segredo TOTP nunca em `argv` | qualquer usuário da máquina lendo a senha ou o segundo fator num `ps` (é assim que o `oathtool` expõe o segredo) |
| `sudo -n` nos scripts | prompt de senha travando automação silenciosamente |

Também: os scripts gerados **não contêm senha**, o `.ovpn` original não é
modificado e o `.gitignore` cobre `.ovpn` e `.credentials` — **nunca commite**
esses arquivos.

> **Trade-off do modo TOTP automático:** guardar o secret TOTP (mesmo no keyring,
> que destrava no login) coloca o segundo fator ao alcance de processos da sua
> sessão logada. Se você quer 2FA "puro" — o código existindo só no momento em
> que você o digita — escolha **Manual** no setup. O preço é que nenhuma
> automação consegue conectar sozinha.

---

## Reinstalar do zero

```bash
chmod +x scripts/cleanup-vpn.sh
./scripts/cleanup-vpn.sh
# depois rode o setup novamente
./scripts/setup-vpn.sh
```

---

## Estrutura do projeto

```
vpn-sophos/
├── README.md
├── .gitignore
├── app/                     # Componentes instalados na máquina
│   ├── vpn-sophos-up        # (root) sobe a VPN — credencial pelo stdin
│   ├── vpn-sophos-down      # (root) encerra só esta VPN
│   ├── vpn-sophos-log       # (root) devolve o fim do log do OpenVPN
│   ├── vpn-sophos-otp       # gerador TOTP — segredo pelo stdin, nunca em argv
│   └── vpn-tray.py          # ícone de bandeja (sem privilégio, sem segredo)
├── scripts/
│   ├── setup-vpn.sh         # Instala e configura tudo
│   └── cleanup-vpn.sh       # Remove tudo
├── mcp/                     # Servidor MCP para o Claude Code (opcional)
│   ├── install.sh
│   ├── servidor_vpn.py
│   └── README.md
└── docs/
    └── guia-completo.md     # Passo a passo detalhado
```

Os três comandos `vpn-sophos-{up,down,log}` são instalados em `/usr/local/sbin`
como `root:root 0755` — o usuário não pode alterar o que roda como root. O
`vpn-sophos-otp` e a bandeja ficam em `~/.local/share/vpn-sophos/` e rodam sem
privilégio nenhum. Todo o código vive versionado aqui, para poder ser revisado.

O `oathtool` deixou de ser usado: ele recebe o segredo TOTP como argumento de
linha de comando, e `argv` é legível por qualquer usuário da máquina.

---

## Automação (opcional)

Quem usa o **Claude Code** pode instalar o servidor MCP em `mcp/` e passar a
ligar/desligar a VPN por ele — útil quando um acesso a banco falha por timeout e
a VPN precisa subir sozinha:

```bash
mcp/install.sh
```

Detalhes em [`mcp/README.md`](mcp/README.md). Funciona apenas no modo TOTP
automático (no modo manual, alguém precisa digitar o código).

---

## Dependências instaladas automaticamente

- `openvpn`
- `libsecret-tools` (acesso ao GNOME keyring via `secret-tool`)
- `python3` (gerador de TOTP e ícone de bandeja)
- `zenity`
- `libnotify-bin`
- `python3-gi`, `gir1.2-gtk-3.0` e `gir1.2-ayatanaappindicator3-0.1` (ícone de bandeja)

---

## Contribuindo

Pull requests são bem-vindos! Antes de abrir um PR:

- Teste em Ubuntu 22.04+ com GNOME
- Nunca inclua credenciais, arquivos `.ovpn` ou `.credentials` no repositório
- Siga o `.gitignore` existente

---

## Licença

MIT
