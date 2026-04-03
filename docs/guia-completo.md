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
| `network-manager-openvpn` | Plugin OpenVPN para o NetworkManager |
| `network-manager-openvpn-gnome` | Interface gráfica do plugin |
| `oathtool` | Gerador de códigos TOTP via linha de comando |
| `zenity` | Interface gráfica para os scripts |

---

## Onde ficam os arquivos

| Arquivo | Local | Permissão |
|---|---|---|
| Credenciais | `~/.config/vpn-sophos/.credentials` | 600 (só você lê) |
| Script de conexão | `~/vpn-connect.sh` | 700 |
| Script de desconexão | `~/vpn-disconnect.sh` | 700 |
| Atalho conectar | `~/.local/share/applications/vpn-connect.desktop` | — |
| Atalho desconectar | `~/.local/share/applications/vpn-disconnect.desktop` | — |

---

## Fluxo de conexão (passo a passo interno)

1. Script lê credenciais de `~/.config/vpn-sophos/.credentials`
2. Mata processos `openvpn` anteriores
3. Gera o OTP com `oathtool --totp --base32 "$TOTP_SECRET"`
4. Cria arquivo temporário (chmod 600) com usuário e `senha+OTP`
5. Chama `openvpn --daemon` passando o arquivo temporário
6. Aguarda até 10 segundos pela interface `tun0` subir
7. Remove o arquivo temporário
8. Exibe notificação de sucesso ou falha

---

## Verificar se a VPN está ativa

```bash
# Interface tun0 só existe quando VPN está conectada
ip addr show tun0 2>/dev/null && echo "VPN ATIVA" || echo "VPN DESCONECTADA"

# Ou pelo alias
vpn-status
```

---

## Processos zumbi do NetworkManager

Durante as tentativas de configuração via NetworkManager, podem acumular processos `[nm-openvpn-auth] <defunct>` — estes são zumbis inofensivos, não indicam VPN ativa. Use sempre `vpn-status` para confirmar o estado real.

Para limpar:

```bash
sudo systemctl restart NetworkManager
```

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
