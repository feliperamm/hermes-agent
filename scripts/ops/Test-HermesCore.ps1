param()

$ErrorActionPreference = "Continue"
Set-StrictMode -Version Latest

$HostAlias = "hermes-core"
$RemoteHermes = "/home/hermes/.local/bin/hermes"
$Results = [ordered]@{}

function Report([string]$Name, [bool]$Ok, [string]$Detail) {
    $symbol = if ($Ok) { "OK" } else { "FALHA" }
    $color = if ($Ok) { "Green" } else { "Yellow" }
    Write-Host ("[{0}] {1}: {2}" -f $symbol, $Name, $Detail) -ForegroundColor $color
}

Write-Host "Diagnóstico somente leitura: Hermes Desktop → hermes-core" -ForegroundColor Cyan
Write-Host "Nenhuma configuração, serviço, VPN ou arquivo será alterado.`n"

$protonProcesses = @(Get-Process -ErrorAction SilentlyContinue | Where-Object {
    $_.ProcessName -match "Proton.*VPN|ProtonVPN"
})
$protonAdapters = @()
try {
    $protonAdapters = @(Get-NetAdapter -ErrorAction SilentlyContinue | Where-Object {
        ($_.Name -match "Proton|WireGuard") -or ($_.InterfaceDescription -match "Proton")
    } | Where-Object { $_.Status -eq "Up" })
} catch {}
$ProtonActive = ($protonProcesses.Count -gt 0) -or ($protonAdapters.Count -gt 0)
$Results.ProtonActive = $ProtonActive
Report "Proton VPN detectado" (-not $ProtonActive) $(if ($ProtonActive) { "processo/adaptador ativo; pode interferir no Tailscale" } else { "nenhum indício ativo" })

$tailscaleCandidates = @(
    (Join-Path $env:ProgramFiles "Tailscale\tailscale.exe"),
    "tailscale.exe"
)
$Tailscale = $null
foreach ($candidate in $tailscaleCandidates) {
    if ($candidate -eq "tailscale.exe") {
        $command = Get-Command $candidate -ErrorAction SilentlyContinue
        if ($command) { $Tailscale = $command.Source; break }
    } elseif (Test-Path -LiteralPath $candidate -PathType Leaf) {
        $Tailscale = $candidate; break
    }
}
$Results.TailscaleInstalled = [bool]$Tailscale
Report "Tailscale instalado" ([bool]$Tailscale) $(if ($Tailscale) { "binário localizado" } else { "tailscale.exe não encontrado" })

$tailscaleService = Get-Service -Name "Tailscale" -ErrorAction SilentlyContinue
$tailscaleRunning = [bool]($tailscaleService -and $tailscaleService.Status -eq "Running")
$Results.TailscaleRunning = $tailscaleRunning
Report "Serviço Tailscale" $tailscaleRunning $(if ($tailscaleService) { [string]$tailscaleService.Status } else { "não encontrado" })

$tailscalePing = $false
if ($Tailscale) {
    $null = & $Tailscale ping --timeout=5s --c=1 $HostAlias 2>&1
    $tailscalePing = ($LASTEXITCODE -eq 0)
}
$Results.TailscalePing = $tailscalePing
Report "Tailscale ping" $tailscalePing $(if ($tailscalePing) { "$HostAlias respondeu" } else { "$HostAlias não respondeu" })

$sshCandidates = @(
    (Join-Path $env:WINDIR "System32\OpenSSH\ssh.exe"),
    "ssh.exe"
)
$Ssh = $null
foreach ($candidate in $sshCandidates) {
    if ($candidate -eq "ssh.exe") {
        $command = Get-Command $candidate -ErrorAction SilentlyContinue
        if ($command) { $Ssh = $command.Source; break }
    } elseif (Test-Path -LiteralPath $candidate -PathType Leaf) {
        $Ssh = $candidate; break
    }
}
$Results.OpenSshInstalled = [bool]$Ssh
Report "OpenSSH" ([bool]$Ssh) $(if ($Ssh) { "cliente localizado" } else { "ssh.exe não encontrado" })

$sshAlias = $false
if ($Ssh) {
    $null = & $Ssh -G $HostAlias 2>&1
    $sshAlias = ($LASTEXITCODE -eq 0)
}
$Results.SshAlias = $sshAlias
Report "Alias SSH" $sshAlias $(if ($sshAlias) { "$HostAlias é resolvido pela configuração SSH" } else { "$HostAlias não foi resolvido" })

$sshReachable = $false
if ($Ssh -and $sshAlias) {
    $sshOutput = & $Ssh -o BatchMode=yes -o ConnectTimeout=8 -o ConnectionAttempts=1 -o StrictHostKeyChecking=yes $HostAlias "printf HERMES_CORE_OK" 2>&1
    $sshReachable = (($LASTEXITCODE -eq 0) -and (($sshOutput | Out-String) -match "HERMES_CORE_OK"))
}
$Results.SshReachable = $sshReachable
Report "SSH hermes-core" $sshReachable $(if ($sshReachable) { "acesso não interativo confirmado" } else { "falhou ou exigiu interação" })

$remoteHermesOk = $false
if ($sshReachable) {
    $null = & $Ssh -o BatchMode=yes -o ConnectTimeout=8 -o ConnectionAttempts=1 -o StrictHostKeyChecking=yes $HostAlias "test -x '$RemoteHermes' && '$RemoteHermes' --version >/dev/null" 2>&1
    $remoteHermesOk = ($LASTEXITCODE -eq 0)
}
$Results.RemoteHermes = $remoteHermesOk
Report "Hermes remoto" $remoteHermesOk $(if ($remoteHermesOk) { "$RemoteHermes está executável" } else { "não confirmado" })

Write-Host "`nConclusão" -ForegroundColor Cyan
if ($sshReachable -and $remoteHermesOk) {
    Write-Host "A rota até o Core está saudável." -ForegroundColor Green
    Write-Host "No Desktop: Settings → Gateways → Test (exigir Reachable), confirme Primary e selecione hermes-core em Sessions."
    Write-Host "Se já estiver selecionado mas desconectado, use Reconnect gateway."
    exit 0
}

if ($ProtonActive -and (-not $tailscalePing)) {
    Write-Host "Forte indício de que o Proton VPN está bloqueando o Tailscale." -ForegroundColor Yellow
    Write-Host "Desconecte temporariamente o Proton, execute este diagnóstico novamente e depois configure Split tunneling em Exclude mode."
} elseif (-not $tailscaleRunning) {
    Write-Host "O Tailscale não está em execução. Corrija esse estado antes de alterar o Hermes Desktop." -ForegroundColor Yellow
} elseif ($tailscalePing -and (-not $sshReachable)) {
    Write-Host "Tailscale funciona, mas o SSH falhou. Verifique o alias/cliente OpenSSH; não recrie o Core." -ForegroundColor Yellow
} else {
    Write-Host "A conectividade até o Core não foi confirmada. Não reconstrua nem restaure o ambiente ainda." -ForegroundColor Yellow
}
Write-Host "Depois da rede: Settings → Gateways → Test; só então selecione hermes-core em Sessions."
exit 2
