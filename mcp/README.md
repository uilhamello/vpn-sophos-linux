# MCP da VPN Sophos

Servidor MCP (stdio) que deixa o **Claude Code** ligar, desligar e inspecionar a
VPN configurada por este app — sem risco de derrubar a sessão de quem chamou.

## Instalação

Depois de já ter rodado o `scripts/setup-vpn.sh` (o MCP usa os scripts que ele
gera, não reimplementa a conexão):

```bash
mcp/install.sh
```

O instalador checa os pré-requisitos, blinda o `kill` dos scripts (ver abaixo),
cria a `.venv` própria, instala o pacote `mcp` e registra o servidor no escopo
**user** do Claude Code — vale em qualquer projeto. É idempotente: rodar de novo
não duplica nada.

As tools só aparecem na **próxima** sessão do Claude Code — servidores MCP são
carregados na inicialização.

## Tools

| Tool | O que faz |
|---|---|
| `vpn_status` | interface up/down, IP e PID do openvpn. Não altera nada. |
| `vpn_connect(espera_segundos=45, codigo_2fa="")` | Idempotente. Roda o `~/vpn-connect.sh` e traduz o código de saída em causa: configuração, keyring/2FA, sudo ou rede. |
| `vpn_disconnect` | Roda o `~/vpn-disconnect.sh` e confirma o encerramento. |
| `vpn_logs(linhas=30)` | Última execução dos scripts **e** o fim do log do OpenVPN (via `vpn-sophos-log`), com segredos mascarados. |

Uso típico: pedir "liga a vpn" / "qual o status da vpn?" numa sessão, ou deixar
o próprio agente ligar sozinho quando um acesso a banco falhar por timeout.

### Modo 2FA manual

No modo automático o `vpn_connect` não pede nada a ninguém. No modo **manual** o
segundo fator não fica guardado, então alguém precisa informá-lo:

- **com `codigo_2fa`** (6 a 8 dígitos): o código é injetado no script pela variável
  `VPN_OTP`, que o script consome e descarta — nenhuma janela é aberta, e funciona
  até em sessão sem interface gráfica;
- **sem `codigo_2fa`**: o script abre uma janela pedindo o código e espera (90s).
  Só serve se o usuário estiver na frente da tela; passado o tempo, o servidor
  encerra o **grupo** de processos, então a janela não fica órfã.

O `codigo_2fa` também resolve o modo automático com o keyring travado. O código é
de uso único e expira em ~30s; enquanto o processo vive, ele fica visível em
`/proc/<pid>/environ` para processos do mesmo usuário.

## Por que este MCP existe

Duas razões práticas: o agente descobre as tools sozinho, sem depender de lembrar
comandos, e o resultado vem traduzido — `vpn_connect` devolve *por que* falhou,
não só que falhou.

Há também uma proteção embutida. Até 18/08/2026 os scripts terminavam com:

```bash
kill $(ps -o ppid= -p $$)
```

Isso mata o processo **pai** (servia para fechar a janela do lançador) e derrubou
uma sessão de terminal. O setup atual não gera mais esse `kill`, mas o servidor
segue invocando os scripts através de um shell descartável, para o caso de uma
instalação antiga:

```bash
bash -c 'bash "$1"; codigo=$?; exit $codigo' -- ~/vpn-connect.sh
```

O shell do meio é quem levaria o `kill`. O `codigo=$?` impede o bash de fazer
exec-optimization — garantindo que esse shell exista de fato — e devolve o código
de saída real do script.

## Segredos

Nada de credencial passa por aqui: quem fala com o keyring é o script, e não
existe senha de sudo no fluxo — a regra `sudoers` libera os comandos da VPN sem
senha. O log é criado com permissão `600` e todo texto
devolvido passa por um mascarador que troca valores de `SUDO_PASS`, `VPN_PASS`,
`TOTP_SECRET` e `VPN_USER` por `***` e remove linhas de prompt do `sudo`.

Cada pessoa usa as próprias credenciais, geradas localmente pelo
`scripts/setup-vpn.sh` — não há segredo neste diretório.

## Requisitos

- Linux com o app já configurado (`~/vpn-connect.sh`, `~/vpn-disconnect.sh`,
  `~/.config/vpn-sophos/.credentials`)
- Python 3.10+, `setsid` (util-linux), `ip`, `pgrep`
- CLI `claude` no PATH
- Pacote `mcp` 1.x ou 2.x (o servidor detecta qual está instalado)

## Verificar / remover

```bash
claude mcp list | grep vpn-sophos
```

```bash
claude mcp remove vpn-sophos -s user
```

Se a interface da VPN não for `tun0` na sua máquina, ajuste a constante `IFACE`
no `servidor_vpn.py`.
