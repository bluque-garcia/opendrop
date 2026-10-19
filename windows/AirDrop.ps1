<#
.SYNOPSIS
  AirDrop on Windows: OpenDrop + OWL in WSL2 on a USB Wi-Fi adapter.

.EXAMPLE
  .\AirDrop.ps1 setup                  # once, and after every `wsl --update`
  .\AirDrop.ps1                        # receive into Downloads\AirDrop
  .\AirDrop.ps1 send foto.jpg doc.pdf  # send to an iPhone
  .\AirDrop.ps1 find
  .\AirDrop.ps1 doctor                 # check adapter, driver and AWDL channels

.DESCRIPTION
  The internal Wi-Fi cannot do AWDL (no active monitor mode with injection,
  and a PCIe card cannot be handed to WSL anyway). A USB adapter is shared
  with WSL through usbipd-win and used only for AirDrop, so Windows keeps its
  network on the internal card the whole time.

  The phone must have AirDrop set to "Everyone for 10 Minutes".
#>
param(
    [ValidateSet('receive', 'send', 'find', 'doctor', 'setup', 'detach')]
    [string]$Mode = 'receive',
    [Parameter(ValueFromRemainingArguments = $true)]
    [string[]]$Files = @(),
    [string]$BusId,
    [string]$Name = $env:COMPUTERNAME,
    [string]$ReceiveDir = (Join-Path $env:USERPROFILE 'Downloads\AirDrop'),
    [string]$Receiver,
    [ValidateSet('', '6', '44', '149')]
    [string]$Channel = '',
    [string]$Country = 'ES',
    [string]$Distro = 'Ubuntu-24.04'
)
$ErrorActionPreference = 'Stop'

# Adapters known to do active monitor + injection with a mainline driver
# (the ones wsl/build-wifi-modules.sh builds).
$KnownAdapters = @{
    '0E8D:7961' = 'MT7921AU (Alfa AWUS036AXML)'
    '0846:9060' = 'MT7921AU (Netgear A8000)'
    '0E8D:7612' = 'MT7612U (Alfa AWUS036ACM)'
    '0846:9053' = 'MT7612U (Netgear A6210)'
    '0B05:17EB' = 'MT7612U (ASUS USB-AC55)'
    '0E8D:7610' = 'MT7610U'
    '0CF3:9271' = 'AR9271 (TP-Link TL-WN722N v1, Alfa AWUS036NHA)'
    '148F:5572' = 'RT5572'
    '148F:5370' = 'RT5370'
}

$Repo = Split-Path -Parent $PSScriptRoot

function ConvertTo-WslPath([string]$Path) {
    $full = [System.IO.Path]::GetFullPath($Path)
    $drive = $full.Substring(0, 1).ToLower()
    return "/mnt/$drive" + ($full.Substring(2) -replace '\\', '/')
}

function Invoke-Wsl([string[]]$Arguments) {
    & wsl.exe -d $Distro -u root -- @Arguments
    return $LASTEXITCODE
}

function Get-Usbipd {
    $cmd = Get-Command usbipd -ErrorAction SilentlyContinue
    if (-not $cmd) {
        $default = Join-Path $env:ProgramFiles 'usbipd-win\usbipd.exe'
        if (Test-Path $default) { return $default }
        throw "usbipd-win no está instalado: winget install dorssel.usbipd-win"
    }
    return $cmd.Source
}

function Find-Adapter([string]$Usbipd) {
    $state = (& $Usbipd state) | ConvertFrom-Json
    $devices = @($state.Devices | Where-Object { $_.BusId })
    if ($BusId) {
        $dev = $devices | Where-Object { $_.BusId -eq $BusId } | Select-Object -First 1
        if (-not $dev) { throw "No hay ningún dispositivo USB en el bus $BusId" }
        if ($dev.Description -match 'Bluetooth|entrada|input|almacenamiento|storage|audio|Blackwire') {
            throw "El bus $BusId es '$($dev.Description)', no un adaptador Wi-Fi; no lo paso a WSL."
        }
        return $dev
    }
    foreach ($dev in $devices) {
        if ($dev.InstanceId -match 'VID_([0-9A-F]{4})&PID_([0-9A-F]{4})') {
            $id = "$($Matches[1]):$($Matches[2])"
            if ($KnownAdapters.ContainsKey($id)) {
                Write-Host "Adaptador: $($KnownAdapters[$id]) en el bus $($dev.BusId)"
                return $dev
            }
        }
    }
    # Never pick an unknown device by its description: "Intel(R) Wireless
    # Bluetooth(R)" matches any Wi-Fi-ish pattern, and handing the machine's
    # Bluetooth (or a keyboard) to WSL takes it away from Windows.
    Write-Host "Dispositivos USB:"
    & $Usbipd list
    throw "No encuentro un adaptador Wi-Fi USB compatible. Conéctalo, o indica su bus con -BusId si es otro modelo."
}

function Connect-Adapter {
    $usbipd = Get-Usbipd
    $dev = Find-Adapter $usbipd
    # Stage firmware and load the drivers BEFORE attaching: the driver asks
    # for its firmware the moment the device appears in WSL. This also
    # starts the WSL VM, which attach needs.
    if ((Invoke-Wsl @('env', "REG=$Country", 'bash', $script, 'prepare')) -ne 0) {
        throw "No se pudo preparar WSL (¿falta 'AirDrop.cmd setup'?)"
    }
    if ($dev.ClientIPAddress) { return $dev }      # already attached to WSL
    if (-not $dev.PersistedGuid) {
        # Sharing a device is the one step that needs admin, and it persists.
        Write-Host "Compartiendo el adaptador con WSL (pide permisos de administrador una vez)..."
        $p = Start-Process -FilePath $usbipd -ArgumentList 'bind', '--busid', $dev.BusId -Verb RunAs -Wait -PassThru
        if ($p.ExitCode -ne 0) { throw "usbipd bind falló ($($p.ExitCode))" }
    }
    & $usbipd attach --wsl --busid $dev.BusId
    if ($LASTEXITCODE -ne 0) { throw "usbipd attach falló" }
    return $dev
}

$script = ConvertTo-WslPath (Join-Path $Repo 'wsl\airdrop-wsl.sh')

switch ($Mode) {
    'setup' {
        exit (Invoke-Wsl @('bash', (ConvertTo-WslPath (Join-Path $Repo 'wsl\setup-wsl.sh'))))
    }
    'detach' {
        $usbipd = Get-Usbipd
        $dev = Find-Adapter $usbipd
        & $usbipd detach --busid $dev.BusId
        exit $LASTEXITCODE
    }
}

$null = Connect-Adapter

$envArgs = @(
    "AIRDROP_NAME=$Name",
    "RECV_DIR=$(ConvertTo-WslPath $ReceiveDir)",
    "REG=$Country"
)
if ($Channel) { $envArgs += "CHAN=$Channel" }
if ($Receiver) { $envArgs += "RECEIVER=$Receiver" }

$wslFiles = @()
if ($Mode -eq 'send') {
    if (-not $Files) { throw "Indica qué enviar: .\AirDrop.ps1 send foto.jpg" }
    foreach ($f in $Files) {
        if (-not (Test-Path -LiteralPath $f -PathType Leaf)) { throw "No existe: $f" }
        $wslFiles += ConvertTo-WslPath (Resolve-Path -LiteralPath $f).Path
    }
}
if ($Mode -eq 'receive') { $null = New-Item -ItemType Directory -Force -Path $ReceiveDir }

$ble = $null
if ($Mode -in 'send', 'find') {
    # Wakes the phone's AWDL; must run for the whole discovery + transfer.
    $ble = Start-Process powershell.exe -WindowStyle Hidden -PassThru -ArgumentList @(
        '-NoProfile', '-ExecutionPolicy', 'Bypass',
        '-File', (Join-Path $PSScriptRoot 'ble-wake.ps1'), '-Seconds', '0')
}
try {
    $rc = Invoke-Wsl (@('env') + $envArgs + @('bash', $script, $Mode) + $wslFiles)
}
finally {
    if ($ble -and -not $ble.HasExited) { Stop-Process -Id $ble.Id -Force }
}
if ($Mode -eq 'receive') { Write-Host "Archivos recibidos en $ReceiveDir" }
exit $rc
