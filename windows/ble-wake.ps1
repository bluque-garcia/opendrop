<#
.SYNOPSIS
  Broadcast the Apple Continuity "AirDrop" BLE advertisement from Windows.

.DESCRIPTION
  An iPhone keeps AWDL asleep until a sender nearby advertises AirDrop over
  Bluetooth LE. With AirDrop set to "Everyone" any well-formed advertisement
  wakes it; the contact hashes do not have to match. WSL has no Bluetooth, so
  this runs on the Windows side for the duration of a send.

  Wire format (furiousMAC/continuity, type 0x05), manufacturer data for
  company 0x004C:  05 12 | 00 x8 | 01 | 4 x 2-byte hash prefixes | 00
  Same payload as tools/blewake.sh in airdrop-mt7921.

.PARAMETER Seconds
  How long to advertise. 0 = until the process is stopped.
#>
param(
    [int]$Seconds = 120
)
$ErrorActionPreference = 'Stop'

$null = [Windows.Devices.Bluetooth.Advertisement.BluetoothLEAdvertisementPublisher, Windows.Devices.Bluetooth, ContentType = WindowsRuntime]
# Windows PowerShell cannot hand a DataWriter's IBuffer back to WinRT (it
# arrives as a bare __ComObject); the .NET projection's AsBuffer() can.
Add-Type -AssemblyName System.Runtime.WindowsRuntime

[byte[]]$payload = @(0x05, 0x12) + (, 0x00 * 8) + @(0x01) + (, 0x00 * 8) + @(0x00)

$md = New-Object Windows.Devices.Bluetooth.Advertisement.BluetoothLEManufacturerData
$md.CompanyId = 0x004C
$md.Data = [System.Runtime.InteropServices.WindowsRuntime.WindowsRuntimeBufferExtensions]::AsBuffer($payload)

$pub = New-Object Windows.Devices.Bluetooth.Advertisement.BluetoothLEAdvertisementPublisher
# Same projection gap for the IVector: call Add through the generic interface.
$list = $pub.Advertisement.ManufacturerData
$icoll = [System.Collections.Generic.ICollection[Windows.Devices.Bluetooth.Advertisement.BluetoothLEManufacturerData]]
$null = $icoll.GetMethod('Add').Invoke($list.psobject.BaseObject, [object[]]@($md.psobject.BaseObject))
$pub.Start()

# Status goes Created -> Waiting -> Started; Aborted means the radio refused.
$deadline = (Get-Date).AddSeconds(5)
while ($pub.Status -ne 'Started' -and $pub.Status -ne 'Aborted' -and (Get-Date) -lt $deadline) {
    Start-Sleep -Milliseconds 100
}
if ($pub.Status -ne 'Started') {
    Write-Error "BLE advertisement did not start (status $($pub.Status)). Is Bluetooth on?"
    exit 1
}
Write-Output "BLE AirDrop advertisement started"
try {
    if ($Seconds -gt 0) { Start-Sleep -Seconds $Seconds }
    else { while ($true) { Start-Sleep -Seconds 3600 } }
}
finally {
    $pub.Stop()
    Write-Output "BLE AirDrop advertisement stopped"
}
