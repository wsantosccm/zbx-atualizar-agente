# zbx-atualizar-agente

Script PowerShell da campanha **Atualizar Zabbix Agent** (CCM Tecnologia): atualiza o Zabbix Agent
(`zabbix_agentd.exe` e/ou `zabbix_agent2.exe`) de hosts Windows com versao anterior a 7.0 para a
**7.0.x LTS**, com backup, teste de configuracao, validacao e rollback automatico.

Arquivo unico: [`atualizar_agente.ps1`](atualizar_agente.ps1) (Windows PowerShell 5.1; em 4.0 funciona
sem recursos opcionais). O repositorio nao contem segredos: os binarios sao baixados de
`cdn.zabbix.com`.

- Versao-alvo padrao do script: **7.0.32** (parametro `-VersaoAlvo`).
- Log: `C:\CCM\Logs\atualizar_zabbix_agent.log` (append, rotacao 5 MB para `.log.1`).
- Pasta de trabalho: `C:\CCM\atualizarZabbix\` (script, `zips\`, `backup\<EXEC_ID>\<servico>\`).

## Como roda

O template Zabbix `CCM-AtualizarZabbixAgent` executa um *bootstrap* (`system.run`, `nowait`) que
cria a pasta, baixa este script do GitHub, grava a linha `DOWNLOAD` e chama
`atualizar_agente.ps1 -Etapa Iniciar -VersaoAlvo 7.0.32`. Manual:

```powershell
$env:CCM_EXEC_ID = (Get-Date).ToString('yyyyMMddHHmmss')
.\atualizar_agente.ps1 -Etapa Iniciar -VersaoAlvo 7.0.32            # detecta e agenda
.\atualizar_agente.ps1 -Etapa Iniciar -SomenteDetectar               # so detecta, nao agenda
```

Parametros: `-Etapa Iniciar|Upgrade`, `-VersaoAlvo x.y.z`, `-ExecId`, `-SomenteDetectar`,
`-Arquitetura manter|amd64|i386` (padrao `manter`: preserva 32/64 bits do exe atual, para nao mudar o
comportamento WOW64 dos itens ja existentes).

Processo 32-bit em SO 64-bit: o script se re-executa em `%WINDIR%\Sysnative\...\powershell.exe`.

## Etapas

**Iniciar** (roda como filha do agente, rapida, *nao para servico algum*)
1. `INICIO`.
2. Enumera **todos** os servicos cujo ImagePath contem `zabbix_agentd.exe` ou `zabbix_agent2.exe`
   (pode haver mais de um, inclusive de cliente) e grava uma linha `DETECCAO` por servico
   (variante, pasta, versao via `-V`, arquitetura do exe, estado, conf).
3. Se todos ja estao >= alvo: `FIM status=SUCESSO resultado=ja_atualizado`.
4. Senao cria a tarefa agendada `CCM-AtualizarZabbixAgent` (usuario SYSTEM, `executar_upgrade.cmd`),
   dispara na hora (`schtasks /Run`, gatilho de reserva em +1 min) e grava `AGENDADO`.

**Upgrade** (tarefa SYSTEM, independente do agente; um servico por vez)
1. `BAIXAR_ZIP`: zip oficial da variante certa (agent: `zabbix_agent-<v>-windows-<arq>-openssl.zip`;
   agent2: `zabbix_agent2-<v>-windows-<arq>-openssl-static.zip`) em
   `https://cdn.zabbix.com/zabbix/binaries/stable/7.0/<v>/`. Confere SHA256, tamanho, assinatura
   Authenticode (se houver) e `-V` do exe extraido.
2. `BACKUP`: exe + conf (e arquivos `Include`) em `C:\CCM\atualizarZabbix\backup\<EXEC_ID>\<servico>\`.
3. `CONF`: testa o conf real com o exe novo (`-c <conf> -T`). No **agent2** converte sempre o que o 7.0
   removeu; se o `-T` falhar tenta os fixups conhecidos e testa de novo; se ainda falhar nao mexe no
   servico (`resultado=FALHA`, `detalhe=etapa=CONF; ...`) e restaura o conf.
4. `PARAR` (timeout 60 s, depois finaliza o processo), `TROCAR` (exe), `SUBIR`.
5. `VALIDAR`: apos 30 s o servico precisa estar Running e `exe -V` >= alvo. Senao `ROLLBACK`
   (restaura exe + conf, sobe) e `resultado=ROLLBACK`.
6. `finally`: se algum servico ficou fora de Running, restaura/sobe. Ao final `FIM`
   (`SUCESSO` | `PARCIAL` | `FALHA`), remove a tarefa agendada, exit 0 (sucesso) ou 1.

Idempotente: rodar de novo em host ja atualizado grava `FIM status=SUCESSO resultado=ja_atualizado`
sem tocar no servico.

### Parametros de configuracao tratados

| Parametro antigo | Onde | O que o script faz |
|---|---|---|
| `EnableRemoteCommands=1` | agent2 7.0 (removido) | comenta e coloca `AllowKey=system.run[*]` |
| `EnableRemoteCommands=0` | agent2 7.0 | comenta (padrao 7.0 e negar `system.run`) |
| `LogRemoteCommands=N` | agent2 7.0 (removido) | vira `Plugins.SystemRun.LogRemoteCommands=N` |
| `EnableRemoteCommands` | agentd 7.0 (deprecado, ainda funciona) | nao altera; so converte se o `-T` reclamar |
| `Plugins.<X>.Capacity` | agent2 | vira `Plugins.<X>.System.Capacity` (so se o `-T` reclamar) |
| `DisablePassive=1` / `DisableActive=1` | obsoletos | `StartAgents=0` / comenta `ServerActive` (so se o `-T` reclamar) |
| `LoadModule`, `LoadModulePath`, `AllowRoot`, `User` | nao existem no Windows | comenta (so se o `-T` reclamar) |

Linhas alteradas ficam como `# CCM-ATL (removido/alterado no 7.0): <linha original>`.

## Formato do log

```
yyyy-MM-ddTHH:mm:ssZ | NIVEL | EXEC_ID | ETAPA | MENSAGEM
```

- `NIVEL`: `INFO` | `AVISO` | `ERRO`. Mensagens em ASCII puro (a leitura passa pelo console OEM).
- `EXEC_ID`: `yyyyMMddHHmmss` (UTC), o mesmo da etapa Iniciar e da Upgrade.
- `ETAPA`: `DOWNLOAD INICIO DETECCAO AGENDADO BAIXAR_ZIP BACKUP CONF PARAR TROCAR SUBIR VALIDAR ROLLBACK AGENTE FIM`
- A linha final sempre contem `| FIM | status=SUCESSO|PARCIAL|FALHA`.
- Uma linha `AGENTE` por servico:
  `servico=<nome> variante=agent|agent2 caminho=<dir> versao_antes=<x> versao_depois=<y> resultado=OK|FALHA|ROLLBACK|JA_ATUALIZADO detalhe=<...>`
  (em falha, `detalhe` comeca com `etapa=<ETAPA>; ...`).

## Integridade dos binarios

O CDN da Zabbix **nao publica arquivo de hash** para os zips Windows (so para o codigo-fonte) e os
`.exe` do 7.0.32 **nao sao assinados com Authenticode**. Por isso o script traz uma tabela com os
SHA256 dos 4 zips da versao padrao (calculados baixando do CDN via HTTPS). Para outra versao-alvo nao
ha hash fixado: o script segue com `AVISO` e confere HTTPS, tamanho e `-V` do exe. Ao mudar a versao
padrao, atualize `$script:HashesZip` e `$script:VersaoPadrao`.

## Rollback manual

Os backups ficam em `C:\CCM\atualizarZabbix\backup\<EXEC_ID>\<servico>\` (`zabbix_agent*.exe` e
`conf<N>_<arquivo>`). Para voltar:

```powershell
Stop-Service '<servico>'
Copy-Item 'C:\CCM\atualizarZabbix\backup\<EXEC_ID>\<servico>\zabbix_agentd.exe' '<caminho>\zabbix_agentd.exe' -Force
Copy-Item 'C:\CCM\atualizarZabbix\backup\<EXEC_ID>\<servico>\conf1_zabbix_agentd.conf' '<caminho do conf>' -Force
Start-Service '<servico>'
```

O script ja faz esse rollback sozinho quando a validacao falha. Backups com mais de 60 dias sao
apagados automaticamente.

## Limitacoes conhecidas

- `zabbix_get.exe` / `zabbix_sender.exe` ao lado do agente nao sao atualizados.
- Plugins carregaveis do agent2 (`Plugins.*.System.Path`) nao sao trocados; o script avisa no log.
- O agente precisa rodar com privilegio de administrador (LocalSystem) para criar a tarefa agendada.
