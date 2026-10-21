<#
.SYNOPSIS
    Atualiza o Zabbix Agent (agentd e/ou agent2) em Windows para a versao 7.0.x LTS.

.DESCRIPTION
    CCM Tecnologia - campanha "Atualizar Zabbix Agent".
    Compativel com Windows PowerShell 5.1 (Windows Server 2016+); em 4.0 degrada sem quebrar.

    Etapas:
      Iniciar  -> roda como filha do proprio agente: so detecta, loga e agenda a tarefa SYSTEM.
                  NUNCA para servico nesta etapa.
      Upgrade  -> roda na tarefa agendada (SYSTEM, independente do agente): para cada servico
                  de agente baixa o zip, faz backup, testa o conf (-T), troca o exe, sobe,
                  valida e faz rollback se algo falhar.

    Log (append, rotacao 5 MB): C:\CCM\Logs\atualizar_zabbix_agent.log
    Linha: yyyy-MM-ddTHH:mm:ssZ | NIVEL | EXEC_ID | ETAPA | MENSAGEM

.PARAMETER Etapa
    Iniciar | Upgrade
.PARAMETER VersaoAlvo
    Versao 7.0.x exata (ex.: 7.0.32). Vem da macro {$ZBXAGENT.VERSAO.ALVO}.
.PARAMETER ExecId
    Identificador da execucao (default: $env:CCM_EXEC_ID, senao yyyyMMddHHmmss).
.PARAMETER Arquitetura
    manter (default: preserva 32/64 bits do exe atual, evita mudar o comportamento WOW64 dos
    itens da frota) | amd64 | i386.
.PARAMETER SomenteDetectar
    So grava INICIO/DETECCAO/FIM e sai (nao agenda nada).
#>
[CmdletBinding()]
param(
    [Parameter(Mandatory = $true)]
    [ValidateSet('Iniciar', 'Upgrade')]
    [string]$Etapa,

    [string]$VersaoAlvo = '7.0.32',

    [string]$ExecId,

    [ValidateSet('manter', 'amd64', 'i386')]
    [string]$Arquitetura = 'manter',

    [switch]$SomenteDetectar
)

$ErrorActionPreference = 'Stop'
$script:ScriptVersao = '1.0.3'
$script:VersaoPadrao = '7.0.32'

# ---------------------------------------------------------------- constantes
$script:DirTrabalho = 'C:\CCM\atualizarZabbix'
$script:DirLog      = 'C:\CCM\Logs'
$script:ArqLog      = 'C:\CCM\Logs\atualizar_zabbix_agent.log'
$script:LogMaxBytes = 5MB
$script:NomeTarefa  = 'CCM-AtualizarZabbixAgent'
$script:BaseCdn     = 'https://cdn.zabbix.com/zabbix/binaries/stable'

# SHA256 dos zips oficiais (cdn.zabbix.com NAO publica arquivo de hash para binarios Windows;
# estes valores foram calculados baixando do proprio CDN via HTTPS e ficam fixados aqui).
$script:HashesZip = @{
    'zabbix_agent-7.0.32-windows-amd64-openssl.zip'           = '20de464a8dd9cd21a073fc540f6d227f075c0d2bfabebb5dfec443ceaa616039'
    'zabbix_agent-7.0.32-windows-i386-openssl.zip'            = '0b34e5c418fd80c78b75fa6b77b022f09c058ff04ef6191aff717c3f70bc3585'
    'zabbix_agent2-7.0.32-windows-amd64-openssl-static.zip'   = '7cdfa06cefae58d5e7a8dc859192a9629077d4dde80706a1396db20cf2e404bc'
    'zabbix_agent2-7.0.32-windows-i386-openssl-static.zip'    = 'd01fceebc1f51896b82ccd436802a4d65d82458d00d1d722616cb3d3298637bc'
}

# ---------------------------------------------------------------- log
function Limpar-Texto {
    param([string]$Texto)
    if ($null -eq $Texto) { return '' }
    $t = $Texto -replace '[\r\n]+', ' / '
    # log em ASCII puro: o item de leitura passa pelo console (codepage OEM)
    return [regex]::Replace($t, '[^\x20-\x7E]', '?').Trim()
}

function Escrever-Log {
    param(
        [ValidateSet('INFO', 'AVISO', 'ERRO')][string]$Nivel,
        [string]$EtapaLog,
        [string]$Mensagem
    )
    try {
        if (-not (Test-Path -LiteralPath $script:DirLog)) {
            New-Item -ItemType Directory -Path $script:DirLog -Force | Out-Null
        }
        if (Test-Path -LiteralPath $script:ArqLog) {
            $fi = Get-Item -LiteralPath $script:ArqLog
            if ($fi.Length -gt $script:LogMaxBytes) {
                Move-Item -LiteralPath $script:ArqLog -Destination ($script:ArqLog + '.1') -Force
            }
        }
        $ts = (Get-Date).ToUniversalTime().ToString('yyyy-MM-ddTHH:mm:ssZ', [Globalization.CultureInfo]::InvariantCulture)
        $linha = '{0} | {1} | {2} | {3} | {4}' -f $ts, $Nivel, $script:ExecId, $EtapaLog, (Limpar-Texto $Mensagem)
        Add-Content -LiteralPath $script:ArqLog -Value $linha -Encoding ASCII
    }
    catch {
        # log nunca pode derrubar a execucao
    }
}

# ---------------------------------------------------------------- utilitarios
function Comparar-Versao {
    # retorna $true se $A >= $B (x.y.z)
    param([string]$A, [string]$B)
    try { return ([version]$A -ge [version]$B) } catch { return $false }
}

function Obter-ArquiteturaPE {
    # le o cabecalho PE do exe: amd64 | i386 | desconhecida
    param([string]$Exe)
    try {
        $fs = [IO.File]::Open($Exe, 'Open', 'Read', 'ReadWrite')
        try {
            $br = New-Object IO.BinaryReader($fs)
            $fs.Seek(0x3C, 'Begin') | Out-Null
            $pe = $br.ReadInt32()
            $fs.Seek($pe + 4, 'Begin') | Out-Null
            $m = $br.ReadUInt16()
            if ($m -eq 0x8664) { return 'amd64' }
            if ($m -eq 0x14c) { return 'i386' }
        }
        finally { $fs.Close() }
    }
    catch { }
    return 'desconhecida'
}

function Executar-Exe {
    # executa e captura saida com timeout. Retorna @{ Codigo; Saida; TimeOut }
    param([string]$Exe, [string]$Argumentos, [int]$TimeoutSeg = 30)
    $psi = New-Object Diagnostics.ProcessStartInfo
    $psi.FileName = $Exe
    $psi.Arguments = $Argumentos
    $psi.UseShellExecute = $false
    $psi.RedirectStandardOutput = $true
    $psi.RedirectStandardError = $true
    $psi.CreateNoWindow = $true
    $p = New-Object Diagnostics.Process
    $p.StartInfo = $psi
    [void]$p.Start()
    $so = $p.StandardOutput.ReadToEndAsync()
    $se = $p.StandardError.ReadToEndAsync()
    if (-not $p.WaitForExit($TimeoutSeg * 1000)) {
        try { $p.Kill() } catch { }
        return @{ Codigo = -1; Saida = 'timeout'; TimeOut = $true }
    }
    $p.WaitForExit()
    $txt = ($so.Result + "`n" + $se.Result).Trim()
    return @{ Codigo = $p.ExitCode; Saida = $txt; TimeOut = $false }
}

function Obter-VersaoExe {
    param([string]$Exe)
    try {
        $r = Executar-Exe -Exe $Exe -Argumentos '-V' -TimeoutSeg 20
        if ($r.Saida -match '(\d+\.\d+\.\d+)') { return $Matches[1] }
    }
    catch { }
    try {
        $pv = (Get-Item -LiteralPath $Exe).VersionInfo.ProductVersion
        if ($pv -match '(\d+\.\d+\.\d+)') { return $Matches[1] }
    }
    catch { }
    return $null
}

function Interpretar-ImagePath {
    # separa exe e arquivo de conf da linha de comando do servico
    param([string]$PathName)
    $r = @{ Exe = $null; Conf = $null }
    if ($PathName -match '^\s*"?(.+?zabbix_agent(?:d|2)\.exe)"?(?:\s+(.*))?$') {
        $r.Exe = $Matches[1]
        $resto = $Matches[2]
        if ($resto -match '(?:^|\s)(?:-c|--config)[\s=]+(?:"([^"]+)"|(\S+))') {
            if ($Matches[1]) { $r.Conf = $Matches[1] } else { $r.Conf = $Matches[2] }
        }
    }
    return $r
}

function Obter-ServicosAgente {
    $lista = @()
    $svcs = $null
    try { $svcs = Get-CimInstance -ClassName Win32_Service -ErrorAction Stop }
    catch { $svcs = Get-WmiObject -Class Win32_Service }
    foreach ($s in $svcs) {
        if (-not $s.PathName) { continue }
        if ($s.PathName -notmatch 'zabbix_agent(d|2)\.exe') { continue }
        $ip = Interpretar-ImagePath $s.PathName
        if (-not $ip.Exe) { continue }
        $exe = $ip.Exe
        $variante = 'agent'
        if ($exe -match 'zabbix_agent2\.exe$') { $variante = 'agent2' }
        $dir = Split-Path -Parent $exe
        $conf = $ip.Conf
        if (-not $conf) {
            $padrao = if ($variante -eq 'agent2') { 'zabbix_agent2.conf' } else { 'zabbix_agentd.conf' }
            foreach ($c in @((Join-Path $dir $padrao), ('C:\' + $padrao))) {
                if (Test-Path -LiteralPath $c) { $conf = $c; break }
            }
        }
        $lista += New-Object PSObject -Property @{
            Nome     = $s.Name
            Variante = $variante
            Exe      = $exe
            Dir      = $dir
            Conf     = $conf
            Estado   = $s.State
            ProcessId = $s.ProcessId
            ExeExiste = (Test-Path -LiteralPath $exe)
        }
    }
    return $lista
}

# ---------------------------------------------------------------- fixups de conf
# Parametros removidos/alterados no 7.0 (ver README):
#  agent2 7.0: EnableRemoteCommands e LogRemoteCommands nao existem mais
#              (-> AllowKey/DenyKey=system.run[*] e Plugins.SystemRun.LogRemoteCommands)
#  agentd 7.0: EnableRemoteCommands esta DEPRECADO mas funciona; so e convertido se -T reclamar.
function Ler-Conf {
    param([string]$Arquivo)
    $bytes = [IO.File]::ReadAllBytes($Arquivo)
    return [Text.Encoding]::GetEncoding(28591).GetString($bytes)   # latin1: round-trip byte a byte
}

function Gravar-Conf {
    param([string]$Arquivo, [string]$Texto)
    $bytes = [Text.Encoding]::GetEncoding(28591).GetBytes($Texto)
    [IO.File]::WriteAllBytes($Arquivo, $bytes)
}

function Corrigir-TextoConf {
    # aplica as regras; $Modo = 'agent2-sempre' | 'por-erro'. Retorna @{ Texto; Mudancas }
    param([string]$Texto, [string]$Variante, [string[]]$Alvos)
    $mud = @()
    $linhas = [regex]::Split($Texto, '(?<=\n)')
    $nl = "`r`n"
    $novo = New-Object Collections.Generic.List[string]

    $temAllowRun = [regex]::IsMatch($Texto, '(?m)^\s*AllowKey\s*=\s*system\.run\[\*\]')
    $temLogPlugin = [regex]::IsMatch($Texto, '(?m)^\s*Plugins\.SystemRun\.LogRemoteCommands\s*=')
    $temServerActive = $false

    foreach ($ln in $linhas) {
        if ($ln -eq '') { continue }
        $fim = ''
        if ($ln -match '(\r?\n)$') { $fim = $Matches[1] } else { $fim = '' }
        $corpo = $ln.TrimEnd("`r", "`n")
        $term = $(if ($fim) { $fim } else { $nl })
        $out = $null

        if ($corpo -match '^\s*([A-Za-z][A-Za-z0-9_.\[\]*]*)\s*=\s*(.*?)\s*$') {
            $nome = $Matches[1]; $val = $Matches[2]
            $tratar = $false
            switch -Regex ($nome) {
                '^EnableRemoteCommands$' { $tratar = ($Variante -eq 'agent2') -or ($Alvos -contains $nome) }
                '^LogRemoteCommands$'    { $tratar = ($Variante -eq 'agent2') -or ($Alvos -contains $nome) }
                '^(DisablePassive|DisableActive|LoadModule|LoadModulePath|AllowRoot|User)$' { $tratar = ($Alvos -contains $nome) }
                '^Plugins\.[A-Za-z0-9_]+\.Capacity$' { $tratar = ($Alvos -contains $nome) -or ($Variante -eq 'agent2' -and $Alvos -contains 'Capacity') }
            }
            if ($tratar) {
                $marca = '# CCM-ATL (removido/alterado no 7.0): '
                switch -Regex ($nome) {
                    '^EnableRemoteCommands$' {
                        $out = $marca + $corpo + $term
                        if ($val -eq '1' -and -not $temAllowRun) {
                            $out += 'AllowKey=system.run[*]' + $term
                            $temAllowRun = $true
                            $mud += 'EnableRemoteCommands=1 -> AllowKey=system.run[*]'
                        }
                        elseif ($val -eq '1') { $mud += 'EnableRemoteCommands=1 comentado (AllowKey ja existe)' }
                        else { $mud += 'EnableRemoteCommands=' + $val + ' comentado (padrao 7.0 = negar system.run)' }
                    }
                    '^LogRemoteCommands$' {
                        $out = $marca + $corpo + $term
                        if (-not $temLogPlugin) {
                            $out += 'Plugins.SystemRun.LogRemoteCommands=' + $val + $term
                            $temLogPlugin = $true
                            $mud += 'LogRemoteCommands=' + $val + ' -> Plugins.SystemRun.LogRemoteCommands'
                        }
                        else { $mud += 'LogRemoteCommands comentado' }
                    }
                    '^DisablePassive$' {
                        $out = $marca + $corpo + $term
                        if ($val -eq '1') {
                            $out += 'StartAgents=0' + $term
                            $mud += 'DisablePassive=1 -> StartAgents=0'
                        }
                        else { $mud += 'DisablePassive=0 comentado' }
                    }
                    '^DisableActive$' {
                        $out = $marca + $corpo + $term
                        $mud += 'DisableActive comentado (ServerActive sera comentado se existir)'
                        $temServerActive = ($val -eq '1')
                    }
                    '^Plugins\.([A-Za-z0-9_]+)\.Capacity$' {
                        $pl = $Matches[1]
                        $out = $marca + $corpo + $term
                        $out += ('Plugins.{0}.System.Capacity={1}' -f $pl, $val) + $term
                        $mud += ('Plugins.{0}.Capacity -> Plugins.{0}.System.Capacity' -f $pl)
                    }
                    default {
                        $out = $marca + $corpo + $term
                        $mud += ($nome + ' comentado')
                    }
                }
            }
        }
        if ($null -eq $out) { $out = $ln }
        $novo.Add($out)
    }
    $res = ($novo -join '')
    if ($temServerActive) {
        $res = [regex]::Replace($res, '(?m)^(\s*ServerActive\s*=.*)$', '# CCM-ATL (DisableActive=1): $1')
    }
    return @{ Texto = $res; Mudancas = $mud }
}

function Obter-ArquivosConf {
    # conf principal + arquivos Include (arquivo, diretorio ou wildcard)
    param([string]$Conf)
    $arqs = New-Object Collections.Generic.List[string]
    $arqs.Add($Conf)
    try {
        $txt = Ler-Conf $Conf
        $base = Split-Path -Parent $Conf
        foreach ($m in [regex]::Matches($txt, '(?m)^\s*Include\s*=\s*(.+?)\s*$')) {
            $p = $m.Groups[1].Value.Trim('"')
            $cands = @($p)
            if (-not [IO.Path]::IsPathRooted($p)) { $cands += (Join-Path $base $p) }
            foreach ($c in $cands) {
                try {
                    if (Test-Path -LiteralPath $c -PathType Container) {
                        foreach ($f in (Get-ChildItem -LiteralPath $c -File)) { if (-not $arqs.Contains($f.FullName)) { $arqs.Add($f.FullName) } }
                    }
                    else {
                        foreach ($f in (Get-ChildItem -Path $c -File -ErrorAction SilentlyContinue)) { if (-not $arqs.Contains($f.FullName)) { $arqs.Add($f.FullName) } }
                    }
                }
                catch { }
            }
        }
    }
    catch { }
    return $arqs
}

# ---------------------------------------------------------------- servicos
function Obter-Servico {
    # nome de servico pode ter colchetes (ex.: 'Zabbix Agent [HOST]'): -Name trata como curinga; comparar por igualdade
    param([string]$Nome)
    return (Get-Service -ErrorAction SilentlyContinue | Where-Object { $_.Name -eq $Nome } | Select-Object -First 1)
}

function Parar-ServicoComTimeout {
    param([string]$Nome, [int]$TimeoutSeg = 60)
    $svc = Obter-Servico $Nome
    if (-not $svc) { throw ('servico nao encontrado: ' + $Nome) }
    if ($svc.Status -eq 'Stopped') { return $true }
    # ServiceController.Stop() nao bloqueia (Stop-Service espera sem timeout se o servico travar em StopPending)
    try { $svc.Stop() } catch { Escrever-Log 'AVISO' 'PARAR' ('servico=' + $Nome + ' Stop-Service: ' + $_.Exception.Message) }
    $ate = (Get-Date).AddSeconds($TimeoutSeg)
    while ((Get-Date) -lt $ate) {
        $svc.Refresh()
        if ($svc.Status -eq 'Stopped') { return $true }
        Start-Sleep -Seconds 1
    }
    # estourou o timeout: mata o processo do servico
    try {
        $w = Get-WmiObject -Class Win32_Service -Filter ("Name='" + $Nome + "'")
        if ($w -and $w.ProcessId -gt 0) {
            Escrever-Log 'AVISO' 'PARAR' ('servico=' + $Nome + ' nao parou em ' + $TimeoutSeg + 's; finalizando PID ' + $w.ProcessId)
            Stop-Process -Id $w.ProcessId -Force -ErrorAction SilentlyContinue
        }
    }
    catch { }
    $ate = (Get-Date).AddSeconds(15)
    while ((Get-Date) -lt $ate) {
        $svc.Refresh()
        if ($svc.Status -eq 'Stopped') { return $true }
        Start-Sleep -Seconds 1
    }
    return $false
}

function Subir-Servico {
    param([string]$Nome, [int]$TimeoutSeg = 30)
    $svc = Obter-Servico $Nome
    if (-not $svc) { throw ('servico nao encontrado: ' + $Nome) }
    if ($svc.Status -eq 'Running') { return $true }
    try { $svc.Start() } catch { Escrever-Log 'AVISO' 'SUBIR' ('servico=' + $Nome + ' Start-Service: ' + $_.Exception.Message) }
    $ate = (Get-Date).AddSeconds($TimeoutSeg)
    while ((Get-Date) -lt $ate) {
        $svc.Refresh()
        if ($svc.Status -eq 'Running') { return $true }
        Start-Sleep -Seconds 1
    }
    return $false
}

function Copiar-ComRetry {
    param([string]$Origem, [string]$Destino, [int]$Tentativas = 6)
    for ($i = 1; $i -le $Tentativas; $i++) {
        try { Copy-Item -LiteralPath $Origem -Destination $Destino -Force -ErrorAction Stop; return }
        catch {
            if ($i -eq $Tentativas) { throw }
            Start-Sleep -Seconds 2   # exe pode estar preso por AV/handle residual
        }
    }
}

# ---------------------------------------------------------------- download
function Baixar-Zip {
    param([string]$Variante, [string]$Arq, [string]$Versao)
    $partes = $Versao.Split('.')
    $serie = $partes[0] + '.' + $partes[1]
    if ($Variante -eq 'agent2') { $nome = 'zabbix_agent2-{0}-windows-{1}-openssl-static.zip' -f $Versao, $Arq }
    else { $nome = 'zabbix_agent-{0}-windows-{1}-openssl.zip' -f $Versao, $Arq }
    $url = '{0}/{1}/{2}/{3}' -f $script:BaseCdn, $serie, $Versao, $nome
    $dirZips = Join-Path $script:DirTrabalho 'zips'
    if (-not (Test-Path -LiteralPath $dirZips)) { New-Item -ItemType Directory -Path $dirZips -Force | Out-Null }
    $destino = Join-Path $dirZips $nome

    $esperado = $script:HashesZip[$nome]
    $ok = $false
    if (Test-Path -LiteralPath $destino) {
        if ($esperado -and (Calcular-Sha256 $destino) -eq $esperado) { $ok = $true; Escrever-Log 'INFO' 'BAIXAR_ZIP' ('zip em cache com hash valido: ' + $nome) }
    }
    if (-not $ok) {
        try { [Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12 } catch { }
        $erro = $null
        for ($i = 1; $i -le 3; $i++) {
            try {
                if (Test-Path -LiteralPath $destino) { Remove-Item -LiteralPath $destino -Force }
                $wc = New-Object Net.WebClient
                $wc.DownloadFile($url, $destino)
                $erro = $null; break
            }
            catch { $erro = $_.Exception.Message; Start-Sleep -Seconds (3 * $i) }
        }
        if ($erro) { throw ('download falhou (' + $url + '): ' + $erro) }
        $tam = (Get-Item -LiteralPath $destino).Length
        if ($tam -lt 1MB) { throw ('zip com tamanho suspeito (' + $tam + ' bytes): ' + $nome) }
        $h = Calcular-Sha256 $destino
        if ($esperado) {
            if ($h -ne $esperado) { Remove-Item -LiteralPath $destino -Force; throw ('SHA256 diferente do esperado para ' + $nome + ' (obtido ' + $h + ')') }
            Escrever-Log 'INFO' 'BAIXAR_ZIP' ('baixado e SHA256 conferido: ' + $nome + ' bytes=' + $tam)
        }
        else {
            Escrever-Log 'AVISO' 'BAIXAR_ZIP' ('sem hash fixado para ' + $nome + ' (versao fora da tabela do script); conferidos so HTTPS, tamanho=' + $tam + ' e -V pos-troca. sha256=' + $h)
        }
    }
    return $destino
}

function Calcular-Sha256 {
    param([string]$Arquivo)
    $sha = [Security.Cryptography.SHA256]::Create()
    $fs = [IO.File]::OpenRead($Arquivo)
    try { return ([BitConverter]::ToString($sha.ComputeHash($fs)) -replace '-', '').ToLower() }
    finally { $fs.Close() }
}

function Extrair-ExeDoZip {
    param([string]$Zip, [string]$NomeExe, [string]$DestinoDir)
    Add-Type -AssemblyName System.IO.Compression.FileSystem
    if (-not (Test-Path -LiteralPath $DestinoDir)) { New-Item -ItemType Directory -Path $DestinoDir -Force | Out-Null }
    $z = [IO.Compression.ZipFile]::OpenRead($Zip)
    try {
        $achou = $null
        foreach ($e in $z.Entries) {
            $fn = $e.FullName -replace '\\', '/'
            if ($fn -match ('(^|/)bin/' + [regex]::Escape($NomeExe) + '$')) { $achou = $e; break }
        }
        if (-not $achou) { throw ('exe ' + $NomeExe + ' nao encontrado no zip') }
        $dest = Join-Path $DestinoDir $NomeExe
        [IO.Compression.ZipFileExtensions]::ExtractToFile($achou, $dest, $true)
        return $dest
    }
    finally { $z.Dispose() }
}

# ---------------------------------------------------------------- upgrade de UM servico
function Atualizar-Servico {
    param($Svc, [string]$Alvo)

    $res = @{ Resultado = 'FALHA'; Antes = $null; Depois = $null; Detalhe = ''; Etapa = '' }
    $nome = $Svc.Nome
    $nomeExe = Split-Path -Leaf $Svc.Exe
    $ctx = @{ Parou = $false; Trocou = $false; Validado = $false; ExeBak = $null; Arquivos = @{} }
    $script:Contextos[$nome] = $ctx

    try {
        $res.Antes = Obter-VersaoExe $Svc.Exe
        if ($res.Antes -and (Comparar-Versao $res.Antes $Alvo)) {
            $res.Resultado = 'JA_ATUALIZADO'; $res.Depois = $res.Antes; $res.Detalhe = 'versao ja >= alvo'
            return $res
        }
        if (-not $Svc.ExeExiste) { $res.Etapa = 'DETECCAO'; throw ('exe nao encontrado: ' + $Svc.Exe) }
        if (-not $Svc.Conf -or -not (Test-Path -LiteralPath $Svc.Conf)) { $res.Etapa = 'CONF'; throw 'arquivo de configuracao nao localizado (ImagePath sem -c e sem conf padrao)' }

        # --- arquitetura
        $arq = $Arquitetura
        if ($arq -eq 'manter') {
            $arq = Obter-ArquiteturaPE $Svc.Exe
            if ($arq -eq 'desconhecida') { if ([Environment]::Is64BitOperatingSystem) { $arq = 'amd64' } else { $arq = 'i386' } }
        }
        if ($arq -eq 'amd64' -and -not [Environment]::Is64BitOperatingSystem) { Escrever-Log 'AVISO' 'BAIXAR_ZIP' ('servico=' + $nome + ' SO 32-bit: usando i386'); $arq = 'i386' }

        # --- zip
        $res.Etapa = 'BAIXAR_ZIP'
        $zip = Baixar-Zip -Variante $Svc.Variante -Arq $arq -Versao $Alvo
        $stage = Join-Path $script:DirTrabalho ('stage\' + $script:ExecId + '\' + $nome)
        $exeNovo = Extrair-ExeDoZip -Zip $zip -NomeExe $nomeExe -DestinoDir $stage
        $sig = $null
        try { $sig = Get-AuthenticodeSignature -FilePath $exeNovo } catch { }
        if ($sig -and $sig.Status -eq 'HashMismatch') { throw 'assinatura Authenticode do exe novo invalida (HashMismatch)' }
        $verNovo = Obter-VersaoExe $exeNovo
        if (-not $verNovo -or -not (Comparar-Versao $verNovo $Alvo)) { throw ('exe do zip reporta versao ' + $verNovo + ' (esperado ' + $Alvo + ')') }
        Escrever-Log 'INFO' 'BAIXAR_ZIP' ('servico=' + $nome + ' exe novo ok versao=' + $verNovo + ' arq=' + $arq + ' authenticode=' + $(if ($sig) { $sig.Status } else { 'n/a' }))

        # --- backup
        $res.Etapa = 'BACKUP'
        $bak = Join-Path $script:DirTrabalho ('backup\' + $script:ExecId + '\' + $nome)
        New-Item -ItemType Directory -Path $bak -Force | Out-Null
        $ctx.ExeBak = Join-Path $bak $nomeExe
        Copy-Item -LiteralPath $Svc.Exe -Destination $ctx.ExeBak -Force
        $ctx.ExePath = $Svc.Exe
        $ctx.ConfPath = $Svc.Conf
        $arquivosConf = @(Obter-ArquivosConf $Svc.Conf)
        $i = 0
        foreach ($a in $arquivosConf) {
            $i++
            $dst = Join-Path $bak ('conf{0}_{1}' -f $i, (Split-Path -Leaf $a))
            Copy-Item -LiteralPath $a -Destination $dst -Force
            $ctx.Arquivos[$a] = $dst
        }
        Escrever-Log 'INFO' 'BACKUP' ('servico=' + $nome + ' backup em ' + $bak + ' (exe + ' + $arquivosConf.Count + ' arquivo(s) de conf)')

        # --- conf: agent2 sempre converte o que o 7.0 removeu; depois testa com -T
        $res.Etapa = 'CONF'
        $mudancas = @()
        if ($Svc.Variante -eq 'agent2') {
            foreach ($a in $arquivosConf) {
                $r = Corrigir-TextoConf -Texto (Ler-Conf $a) -Variante 'agent2' -Alvos @()
                if ($r.Mudancas.Count -gt 0) { Gravar-Conf $a $r.Texto; $mudancas += $r.Mudancas }
            }
        }
        $teste = $null
        for ($it = 0; $it -le 5; $it++) {
            $teste = Executar-Exe -Exe $exeNovo -Argumentos ('-c "' + $Svc.Conf + '" -T') -TimeoutSeg 60
            if ($teste.Codigo -eq 0) { break }
            # -T falhou: tenta corrigir apenas parametros conhecidos citados no erro e presentes no conf
            $citados = @([regex]::Matches($teste.Saida, '[A-Za-z][A-Za-z0-9_.]*') | ForEach-Object { $_.Value.TrimEnd('.') } | Select-Object -Unique)
            $alvos = @()
            foreach ($c in $citados) { if ($c -match '^(EnableRemoteCommands|LogRemoteCommands|DisablePassive|DisableActive|LoadModule|LoadModulePath|AllowRoot|User)$' -or $c -match '^Plugins\.[A-Za-z0-9_]+\.Capacity$') { $alvos += $c } }
            if ($teste.Saida -match 'Capacity') { $alvos += 'Capacity' }
            $mexeu = $false
            if ($alvos.Count -gt 0) {
                foreach ($a in $arquivosConf) {
                    $r = Corrigir-TextoConf -Texto (Ler-Conf $a) -Variante $Svc.Variante -Alvos $alvos
                    if ($r.Mudancas.Count -gt 0) { Gravar-Conf $a $r.Texto; $mudancas += $r.Mudancas; $mexeu = $true }
                }
            }
            if (-not $mexeu) { break }
        }
        if ($mudancas.Count -gt 0) { Escrever-Log 'AVISO' 'CONF' ('servico=' + $nome + ' fixups aplicados: ' + ($mudancas -join '; ')) }
        if ($teste.Codigo -ne 0) {
            Restaurar-Conf $ctx
            throw ('conf nao passa em -T no exe ' + $verNovo + ' (exit=' + $teste.Codigo + '): ' + $teste.Saida)
        }
        Escrever-Log 'INFO' 'CONF' ('servico=' + $nome + ' -T OK no exe novo' + $(if ($mudancas.Count -eq 0) { ' (sem alteracao de conf)' } else { '' }))
        if ($Svc.Variante -eq 'agent2') {
            $txt = Ler-Conf $Svc.Conf
            if ($txt -match '(?m)^\s*Plugins\.[A-Za-z0-9_]+\.System\.Path\s*=') { Escrever-Log 'AVISO' 'CONF' ('servico=' + $nome + ' usa plugin carregavel (System.Path); plugin precisa ser compativel com ' + $Alvo) }
        }

        # --- parar / trocar / subir
        $res.Etapa = 'PARAR'
        $ctx.Parou = $true
        if (-not (Parar-ServicoComTimeout -Nome $nome -TimeoutSeg 60)) { throw 'servico nao parou' }
        Escrever-Log 'INFO' 'PARAR' ('servico=' + $nome + ' parado')

        $res.Etapa = 'TROCAR'
        $ctx.Trocou = $true
        Copiar-ComRetry -Origem $exeNovo -Destino $Svc.Exe
        Escrever-Log 'INFO' 'TROCAR' ('servico=' + $nome + ' exe substituido: ' + $Svc.Exe)

        $res.Etapa = 'SUBIR'
        if (-not (Subir-Servico -Nome $nome -TimeoutSeg 30)) { throw 'servico nao subiu apos a troca' }
        Escrever-Log 'INFO' 'SUBIR' ('servico=' + $nome + ' em execucao; aguardando 30s para validar')

        # --- validar
        $res.Etapa = 'VALIDAR'
        Start-Sleep -Seconds 30
        $sv = Obter-Servico $nome
        $res.Depois = Obter-VersaoExe $Svc.Exe
        if ($sv.Status -ne 'Running') { throw ('servico nao esta Running apos 30s (estado ' + $sv.Status + ')') }
        if (-not $res.Depois -or -not (Comparar-Versao $res.Depois $Alvo)) { throw ('versao apos troca = ' + $res.Depois + ' (esperado >= ' + $Alvo + ')') }
        $ctx.Validado = $true
        Escrever-Log 'INFO' 'VALIDAR' ('servico=' + $nome + ' Running e versao ' + $res.Depois)
        $res.Resultado = 'OK'
        $res.Detalhe = 'atualizado' + $(if ($mudancas.Count -gt 0) { '; conf ajustada: ' + ($mudancas -join ', ') } else { '' })
        return $res
    }
    catch {
        $msg = $_.Exception.Message
        $res.Detalhe = 'etapa=' + $res.Etapa + '; ' + $msg
        Escrever-Log 'ERRO' $(if ($res.Etapa) { $res.Etapa } else { 'AGENTE' }) ('servico=' + $nome + ' ' + $msg)
        if ($ctx.Arquivos.Count -gt 0 -and -not $ctx.Trocou -and -not $ctx.Parou) { Restaurar-Conf $ctx }
        if ($ctx.Trocou -or $ctx.Parou) {
            $rb = Reverter-Servico -Nome $nome -Ctx $ctx
            if ($rb) { $res.Resultado = 'ROLLBACK'; $res.Depois = Obter-VersaoExe $Svc.Exe }
            else { $res.Resultado = 'FALHA'; $res.Detalhe += '; rollback falhou' }
        }
        else { $res.Resultado = 'FALHA' }
        return $res
    }
}

function Restaurar-Conf {
    param($Ctx)
    foreach ($orig in @($Ctx.Arquivos.Keys)) {
        try { Copy-Item -LiteralPath $Ctx.Arquivos[$orig] -Destination $orig -Force } catch { Escrever-Log 'ERRO' 'ROLLBACK' ('falha restaurando conf ' + $orig + ': ' + $_.Exception.Message) }
    }
}

function Reverter-Servico {
    # restaura exe e conf do backup e sobe o servico. Retorna $true se terminou Running.
    param([string]$Nome, $Ctx)
    Escrever-Log 'AVISO' 'ROLLBACK' ('servico=' + $Nome + ' iniciando rollback')
    try {
        Restaurar-Conf $Ctx
        if ($Ctx.Trocou -and $Ctx.ExeBak -and (Test-Path -LiteralPath $Ctx.ExeBak)) {
            [void](Parar-ServicoComTimeout -Nome $Nome -TimeoutSeg 60)
            Copiar-ComRetry -Origem $Ctx.ExeBak -Destino $Ctx.ExePath
        }
        $ok = Subir-Servico -Nome $Nome -TimeoutSeg 30
        if ($ok) { $Ctx.Validado = $true; Escrever-Log 'INFO' 'ROLLBACK' ('servico=' + $Nome + ' restaurado e Running') }
        else { Escrever-Log 'ERRO' 'ROLLBACK' ('servico=' + $Nome + ' restaurado mas NAO subiu') }
        return $ok
    }
    catch {
        Escrever-Log 'ERRO' 'ROLLBACK' ('servico=' + $Nome + ' erro no rollback: ' + $_.Exception.Message)
        return $false
    }
}

# ---------------------------------------------------------------- tarefa agendada
function Remover-Tarefa {
    $ea = $ErrorActionPreference
    $ErrorActionPreference = 'Continue'   # stderr de exe nativo vira excecao com 'Stop' no PS 5.1
    try { & schtasks.exe /Delete /TN $script:NomeTarefa /F 2>&1 | Out-Null } catch { }
    $ErrorActionPreference = $ea
}

function Agendar-Upgrade {
    param([string]$Alvo, [string]$ScriptPath)
    $cmd = Join-Path $script:DirTrabalho 'executar_upgrade.cmd'
    $psexe = Join-Path $env:WINDIR 'System32\WindowsPowerShell\v1.0\powershell.exe'
    $linhas = @(
        '@echo off',
        ('set CCM_EXEC_ID=' + $script:ExecId),
        ('"' + $psexe + '" -NoProfile -ExecutionPolicy Bypass -File "' + $ScriptPath + '" -Etapa Upgrade -VersaoAlvo ' + $Alvo + ' -ExecId ' + $script:ExecId + ' -Arquitetura ' + $Arquitetura)
    )
    Set-Content -LiteralPath $cmd -Value $linhas -Encoding ASCII
    Remover-Tarefa
    $hora = (Get-Date).AddMinutes(1).ToString('HH:mm', [Globalization.CultureInfo]::InvariantCulture)
    $ea = $ErrorActionPreference
    $ErrorActionPreference = 'Continue'
    try {
        $out = & schtasks.exe /Create /TN $script:NomeTarefa /TR $cmd /SC ONCE /ST $hora /RU SYSTEM /RL HIGHEST /F 2>&1
        $rc1 = $LASTEXITCODE
        $out2 = $null; $rc2 = 0
        if ($rc1 -eq 0) { $out2 = & schtasks.exe /Run /TN $script:NomeTarefa 2>&1; $rc2 = $LASTEXITCODE }
    }
    finally { $ErrorActionPreference = $ea }
    if ($rc1 -ne 0) { throw ('schtasks /Create falhou (' + $rc1 + '): ' + ($out -join ' ')) }
    if ($rc2 -ne 0) { Escrever-Log 'AVISO' 'AGENDADO' ('schtasks /Run falhou; ficara para o gatilho das ' + $hora + ': ' + ($out2 -join ' ')) }
    return $hora
}

function Limpar-Antigos {
    try {
        $lim = (Get-Date).AddDays(-60)
        foreach ($sub in @('backup', 'stage')) {
            $d = Join-Path $script:DirTrabalho $sub
            if (Test-Path -LiteralPath $d) {
                Get-ChildItem -LiteralPath $d -Directory | Where-Object { $_.LastWriteTime -lt $lim } | Remove-Item -Recurse -Force -ErrorAction SilentlyContinue
            }
        }
        $stage = Join-Path $script:DirTrabalho ('stage\' + $script:ExecId)
        if (Test-Path -LiteralPath $stage) { Remove-Item -LiteralPath $stage -Recurse -Force -ErrorAction SilentlyContinue }
    }
    catch { }
}

# ---------------------------------------------------------------- etapas
function Executar-Iniciar {
    $codigo = 1
    try {
        Escrever-Log 'INFO' 'INICIO' ('etapa=Iniciar versao_alvo=' + $VersaoAlvo + ' script=' + $script:ScriptVersao + ' ps=' + $PSVersionTable.PSVersion + ' so64=' + [Environment]::Is64BitOperatingSystem + ' proc64=' + [Environment]::Is64BitProcess + ' usuario=' + [Environment]::UserName + ' host=' + $env:COMPUTERNAME)
        if (-not (Test-Path -LiteralPath $script:DirTrabalho)) { New-Item -ItemType Directory -Path $script:DirTrabalho -Force | Out-Null }

        $servicos = @(Obter-ServicosAgente)
        if ($servicos.Count -eq 0) {
            Escrever-Log 'ERRO' 'DETECCAO' 'nenhum servico com zabbix_agentd.exe/zabbix_agent2.exe no ImagePath'
            Escrever-Log 'ERRO' 'FIM' 'status=FALHA resultado=sem_servico'
            return 1
        }
        $pendentes = 0
        foreach ($s in $servicos) {
            $ver = $null
            if ($s.ExeExiste) { $ver = Obter-VersaoExe $s.Exe }
            $arq = if ($s.ExeExiste) { Obter-ArquiteturaPE $s.Exe } else { 'n/a' }
            $precisa = $true
            if ($ver -and (Comparar-Versao $ver $VersaoAlvo)) { $precisa = $false }
            if ($precisa) { $pendentes++ }
            Escrever-Log 'INFO' 'DETECCAO' ('servico=' + $s.Nome + ' variante=' + $s.Variante + ' caminho=' + $s.Dir + ' versao=' + $(if ($ver) { $ver } else { 'desconhecida' }) + ' arq=' + $arq + ' estado=' + $s.Estado + ' conf=' + $(if ($s.Conf) { $s.Conf } else { 'nao_localizado' }) + ' atualizar=' + $precisa)
        }
        if ($pendentes -eq 0) {
            Escrever-Log 'INFO' 'FIM' ('status=SUCESSO resultado=ja_atualizado servicos=' + $servicos.Count)
            return 0
        }
        if ($SomenteDetectar) {
            Escrever-Log 'INFO' 'FIM' ('status=SUCESSO resultado=somente_detectar pendentes=' + $pendentes)
            return 0
        }
        # garante o script em local estavel para a tarefa agendada
        $alvoScript = Join-Path $script:DirTrabalho 'atualizar_agente.ps1'
        # GetFullPath normaliza '/' x '\' (o bootstrap chama com C:/CCM/...): evita copiar o arquivo sobre ele mesmo
        if ($PSCommandPath -and ([IO.Path]::GetFullPath($PSCommandPath) -ne [IO.Path]::GetFullPath($alvoScript))) { Copy-Item -LiteralPath $PSCommandPath -Destination $alvoScript -Force }
        $hora = Agendar-Upgrade -Alvo $VersaoAlvo -ScriptPath $alvoScript
        Escrever-Log 'INFO' 'AGENDADO' ('tarefa=' + $script:NomeTarefa + ' usuario=SYSTEM pendentes=' + $pendentes + ' gatilho=' + $hora + ' (servico NAO foi parado nesta etapa)')
        return 0
    }
    catch {
        Escrever-Log 'ERRO' 'AGENDADO' ('excecao na etapa Iniciar: ' + $_.Exception.Message)
        Escrever-Log 'ERRO' 'FIM' 'status=FALHA resultado=erro_iniciar'
        return 1
    }
}

function Executar-Upgrade {
    $codigo = 1
    $mutex = $null
    $temMutex = $false
    $fimGravado = $false
    $script:Contextos = @{}
    try {
        $mutex = New-Object Threading.Mutex($false, 'Global\CCM-AtualizarZabbixAgent')
        $temMutex = $mutex.WaitOne(0)
        if (-not $temMutex) {
            Escrever-Log 'AVISO' 'AGENDADO' 'etapa=Upgrade ja em execucao em outra instancia; saindo'
            return 0
        }
        Escrever-Log 'INFO' 'INICIO' ('etapa=Upgrade versao_alvo=' + $VersaoAlvo + ' script=' + $script:ScriptVersao + ' ps=' + $PSVersionTable.PSVersion + ' usuario=' + [Environment]::UserName + ' arquitetura=' + $Arquitetura)

        $servicos = @(Obter-ServicosAgente)
        if ($servicos.Count -eq 0) {
            Escrever-Log 'ERRO' 'DETECCAO' 'nenhum servico de agente encontrado'
            Escrever-Log 'ERRO' 'FIM' 'status=FALHA resultado=sem_servico'
            $fimGravado = $true
            return 1
        }
        $resultados = @()
        foreach ($s in $servicos) {
            $r = $null
            try { $r = Atualizar-Servico -Svc $s -Alvo $VersaoAlvo }
            catch { $r = @{ Resultado = 'FALHA'; Antes = $null; Depois = $null; Detalhe = ('excecao: ' + $_.Exception.Message) } }
            $resultados += $r
            $nivel = if ($r.Resultado -in @('OK', 'JA_ATUALIZADO')) { 'INFO' } else { 'ERRO' }
            Escrever-Log $nivel 'AGENTE' ('servico=' + $s.Nome + ' variante=' + $s.Variante + ' caminho=' + $s.Dir + ' versao_antes=' + $(if ($r.Antes) { $r.Antes } else { 'desconhecida' }) + ' versao_depois=' + $(if ($r.Depois) { $r.Depois } else { 'desconhecida' }) + ' resultado=' + $r.Resultado + ' detalhe=' + $r.Detalhe)
        }
        $ok = @($resultados | Where-Object { $_.Resultado -in @('OK', 'JA_ATUALIZADO') }).Count
        $falha = $resultados.Count - $ok
        if ($falha -eq 0) { $status = 'SUCESSO'; $codigo = 0 }
        elseif ($ok -gt 0) { $status = 'PARCIAL'; $codigo = 1 }
        else { $status = 'FALHA'; $codigo = 1 }
        $nivelFim = if ($status -eq 'SUCESSO') { 'INFO' } else { 'ERRO' }
        Escrever-Log $nivelFim 'FIM' ('status=' + $status + ' servicos=' + $resultados.Count + ' ok=' + $ok + ' falha=' + $falha + ' versao_alvo=' + $VersaoAlvo)
        $fimGravado = $true
        return $codigo
    }
    catch {
        Escrever-Log 'ERRO' 'AGENTE' ('excecao nao tratada: ' + $_.Exception.Message)
        $codigo = 1
        return 1
    }
    finally {
        # nunca deixar servico parado
        try {
            foreach ($nome in @($script:Contextos.Keys)) {
                $c = $script:Contextos[$nome]
                $sv = Obter-Servico $nome
                if ($sv -and $sv.Status -ne 'Running' -and ($c.Parou -or $c.Trocou)) {
                    Escrever-Log 'AVISO' 'ROLLBACK' ('finally: servico=' + $nome + ' fora de Running; tentando restaurar/subir')
                    if (-not $c.Validado) { [void](Reverter-Servico -Nome $nome -Ctx $c) }
                    else { [void](Subir-Servico -Nome $nome -TimeoutSeg 30) }
                }
            }
        }
        catch { Escrever-Log 'ERRO' 'ROLLBACK' ('finally: ' + $_.Exception.Message) }
        if ($temMutex -and -not $fimGravado) { Escrever-Log 'ERRO' 'FIM' 'status=FALHA resultado=excecao_nao_tratada' }
        if ($temMutex) { Limpar-Antigos; Remover-Tarefa }
        if ($mutex) { try { if ($temMutex) { $mutex.ReleaseMutex() } } catch { } ; $mutex.Dispose() }
    }
}

# ---------------------------------------------------------------- main
function Main {
    if (-not $ExecId) { $ExecId = $env:CCM_EXEC_ID }
    if (-not $ExecId) { $ExecId = (Get-Date).ToString('yyyyMMddHHmmss', [Globalization.CultureInfo]::InvariantCulture) }
    $script:ExecId = $ExecId
    $env:CCM_EXEC_ID = $ExecId

    if ($VersaoAlvo -notmatch '^\d+\.\d+\.\d+$') {
        Escrever-Log 'AVISO' 'INICIO' ('VersaoAlvo invalida/vazia (' + $VersaoAlvo + '); usando padrao ' + $script:VersaoPadrao)
        Set-Variable -Name VersaoAlvo -Value $script:VersaoPadrao -Scope Script
    }

    # processo 32-bit em SO 64-bit: re-executa no PowerShell 64-bit (WOW64 distorce registro e System32)
    if ([Environment]::Is64BitOperatingSystem -and -not [Environment]::Is64BitProcess) {
        $ps64 = Join-Path $env:WINDIR 'Sysnative\WindowsPowerShell\v1.0\powershell.exe'
        if (Test-Path -LiteralPath $ps64) {
            $a = @('-NoProfile', '-ExecutionPolicy', 'Bypass', '-File', $PSCommandPath, '-Etapa', $Etapa, '-VersaoAlvo', $VersaoAlvo, '-ExecId', $ExecId, '-Arquitetura', $Arquitetura)
            if ($SomenteDetectar) { $a += '-SomenteDetectar' }
            & $ps64 @a
            return $LASTEXITCODE
        }
    }

    if ($Etapa -eq 'Iniciar') { return (Executar-Iniciar) }
    return (Executar-Upgrade)
}

if ($MyInvocation.InvocationName -ne '.') {
    $codigoSaida = Main
    exit ([int]$codigoSaida)
}
