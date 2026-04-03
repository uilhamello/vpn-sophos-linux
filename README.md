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

---

## Uso

Após o setup, conecte e desconecte pela interface gráfica ou pelo terminal:

| Ação | Menu de aplicativos | Terminal |
|---|---|---|
| Conectar | **VPN Conectar** | `vpn-on` |
| Desconectar | **VPN Desconectar** | `vpn-off` |
| Verificar status | — | `vpn-status` |

---

## Como funciona

1. O setup coleta suas credenciais via interface gráfica
2. As credenciais são salvas em `~/.config/vpn-sophos/.credentials` com permissão `600` (apenas seu usuário pode ler)
3. Os scripts de conexão leem as credenciais desse arquivo — **nenhuma senha é escrita nos scripts em texto puro**
4. Na conexão, o código TOTP é gerado automaticamente via `oathtool` e concatenado à senha
5. O OpenVPN conecta em background, liberando o terminal

---

## Segurança

- Credenciais armazenadas em `~/.config/vpn-sophos/.credentials` (chmod 600)
- Scripts gerados (`~/vpn-connect.sh`, `~/vpn-disconnect.sh`) **não contêm senhas**
- Arquivo temporário com credenciais de autenticação é removido imediatamente após a conexão
- **Nunca commite** o arquivo `.credentials` ou o arquivo `.ovpn`

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
├── scripts/
│   ├── setup-vpn.sh      # Instala e configura tudo
│   └── cleanup-vpn.sh    # Remove tudo
└── docs/
    └── guia-completo.md  # Passo a passo detalhado
```

---

## Dependências instaladas automaticamente

- `network-manager-openvpn`
- `network-manager-openvpn-gnome`
- `oathtool`
- `zenity`

---

## Contribuindo

Pull requests são bem-vindos! Antes de abrir um PR:

- Teste em Ubuntu 22.04+ com GNOME
- Nunca inclua credenciais, arquivos `.ovpn` ou `.credentials` no repositório
- Siga o `.gitignore` existente

---

## Licença

MIT
