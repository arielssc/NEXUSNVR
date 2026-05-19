# Nexus NVR

Nexus NVR e um instalador para servidor de monitoramento com painel web, live via Go2RTC, gravacao por FFmpeg, visualizador de videos e retencao automatica.

O pacote pode ser usado em servidor local, VPS ou em ambiente misto com acesso local e externo.

## Requisitos

- Ubuntu Server 22.04 ou superior
- Usuario com permissao `sudo`
- Acesso a internet durante a instalacao
- Docker e Docker Compose podem ja existir; se nao existirem, o instalador pode preparar o ambiente
- Uma porta TCP livre para o painel/API
- A mesma porta em UDP liberada quando for usar RTC/WebRTC pela internet

## Instalacao

Entre na pasta do pacote e execute:

```bash
sudo bash NEXUSNVR_INSTALADOR.sh
```

O instalador vai perguntar:

- IP local final do servidor
- porta do painel/API
- fuso horario
- modo de rede
- IP publico ou dominio, quando necessario
- disco/pasta onde as gravacoes serao salvas

No final, ele mostra um resumo com os acessos, credenciais iniciais e local das gravacoes.

## Modos de Rede

### Apenas local

Use quando o servidor sera acessado somente dentro da mesma rede local.

Exemplo:

```text
http://IP_LOCAL:PORTA
```

Neste modo, o RTC anuncia apenas o IP local.

### Apenas VPS/internet

Use quando o servidor ficara em VPS ou sera acessado apenas por IP publico ou dominio.

Exemplo:

```text
http://IP_PUBLICO_OU_DOMINIO:PORTA
```

Neste modo, o RTC anuncia apenas o endereco externo.

### Local + internet

Use quando o mesmo servidor precisa funcionar dentro do Wi-Fi local e tambem fora da rede.

Neste modo, o RTC anuncia:

- IP publico ou dominio externo
- IP local do servidor

Isso reduz conflito quando o celular esta no mesmo Wi-Fi do servidor e tambem permite acesso externo.

## Porta do Sistema

A porta nao e fixa. Ela e escolhida durante a instalacao.

O instalador usa essa porta para:

- TCP: painel/API pelo Nginx
- UDP: RTC/WebRTC pelo Go2RTC

Se escolher a porta `48902`, por exemplo:

- liberar TCP `48902` para acesso ao painel/API
- liberar UDP `48902` para RTC/WebRTC

Nao e necessario abrir TCP `8555` publicamente.

## Acessos Padrao

Depois da instalacao, use os enderecos mostrados no resumo final do instalador.

Servicos principais:

- Painel Nexus NVR: `http://IP_OU_DOMINIO:PORTA`
- Go2RTC direto: `http://IP_DO_SERVIDOR:1984`
- Visualizador de videos: `http://IP_DO_SERVIDOR:8085`
- Nginx Proxy Manager: `http://IP_DO_SERVIDOR:81`

Credenciais iniciais:

```text
Nginx Proxy Manager
Usuario: admin@nexusnvr.local
Senha: nexusnvr1234

Filebrowser
Usuario: nexusnvr
Senha: nexusnvr1234
```

Altere as senhas padrao apos o primeiro acesso.

## Gravacoes

O sistema sempre usa este caminho interno:

```text
/home/nexus/gravacoes
```

Se outro disco for escolhido, o instalador cria um link para a pasta real.

Exemplo:

```text
/home/nexus/gravacoes -> /dados/nexus/gravacoes
```

Nao apague a pasta real de gravacoes. Ela contem os videos do NVR.

## Retencao de Videos

O pacote inclui retencao automatica profissional:

```bash
sudo bash NEXUSNVR_RETENCAO.sh
```

Comandos uteis:

```bash
sudo bash NEXUSNVR_RETENCAO.sh --status
sudo bash NEXUSNVR_RETENCAO.sh --simulate
sudo bash NEXUSNVR_RETENCAO.sh --clean
```

O modo automatico e instalado no cron:

```text
*/10 * * * * /home/ubuntu/NVR/NEXUSNVR_RETENCAO.sh --auto
```

A retencao so apaga arquivos dentro da pasta segura de gravacoes e respeita protecao para arquivos recentes.

## Backup e Restauracao

O backup salva apenas configuracoes do Nexus NVR. Ele nao inclui videos, Docker inteiro, imagens, programas do Ubuntu, APK ou a pasta `/DADOS`.

Criar backup:

```bash
sudo bash NEXUSNVR_BACKUP.sh
```

Os arquivos sao salvos em:

```text
backups/
```

Restaurar backup:

```bash
sudo bash NEXUSNVR_RESTAURAR.sh backups/arquivo.tar.gz
```

O backup inclui:

- cameras configuradas
- modo de rede
- porta escolhida
- IP externo/dominio
- candidates WebRTC
- retencao
- cron do Nexus NVR
- proxy interno

Antes de restaurar, o restaurador cria outro backup automatico em:

```text
backups/pre_restore/
```

Depois da restauracao, ele reinicia API/Go2RTC, recarrega o Nginx e recria os motores de gravacao das cameras ativas.

## Cameras

As cameras sao configuradas pelo painel/app do Nexus NVR.

Para evitar problemas em containers, nomes de camera devem usar apenas:

- letras
- numeros
- `_`
- `-`

Exemplos validos:

```text
Rua
Garagem_1
Portao-Frente
```

## Arquivos Principais

```text
NEXUSNVR_INSTALADOR.sh       Instalador principal
NEXUSNVR_DIAGNOSTICO.sh      Diagnostico do servidor
NEXUSNVR_BACKUP.sh           Backup de configuracoes
NEXUSNVR_RESTAURAR.sh        Restauracao de configuracoes
NEXUSNVR_RETENCAO.sh         Retencao de gravacoes
NEXUSNVR_PORTAO.sh           Instalador separado para IoT/portao
NEXUSNVR_LIMPEZA.sh          Limpeza/remocao exclusiva do Nexus NVR
nexus_nvr_pacote/            Arquivos copiados para /home/nexus
```

## Limpeza e Remocao

Para remover o Nexus NVR ou analisar residuos:

```bash
sudo bash NEXUSNVR_LIMPEZA.sh
```

Modos disponiveis:

- ver status/analisar
- limpeza completa
- remover NVR mantendo videos e Docker
- remover residuos sem mexer nos videos
- remover apenas state/continuacao

No modo `Limpeza completa`, o script pergunta se deve apagar os videos e tambem pergunta se deve remover Docker/Node do servidor.

Docker/Node so sao removidos quando o script nao detecta uso por outros servicos. Se houver algo fora do Nexus NVR, como outro container ou servico, ele bloqueia a remocao global e pede Enter para continuar.

Nenhum modo remove Ubuntu, APK ou `/DADOS`.

## Validacao Rapida

Apos instalar, confira:

```bash
sudo bash NEXUSNVR_DIAGNOSTICO.sh
sudo docker ps
curl -I http://127.0.0.1:PORTA
curl http://127.0.0.1:1984/api/streams
sudo bash NEXUSNVR_RETENCAO.sh --simulate
```

Substitua `PORTA` pela porta escolhida na instalacao.

## Observacoes Importantes

- O APK/app nao e alterado por este pacote.
- A porta do sistema e escolhida pelo usuario.
- Para acesso externo com RTC, libere TCP e UDP da porta escolhida.
- Para servidor local com acesso interno e externo, use o modo `Local + internet`.
- Antes de publicar um servidor para uso real, altere as senhas padrao.
