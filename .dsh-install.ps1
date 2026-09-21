$ErrorActionPreference = 'Continue'
$adb    = "D:\tools\Android\Sdk\platform-tools\adb.exe"
$serial = "AQQB9X1526W02408"
$apk    = "E:\flutter\deepSeekapp\build\app\outputs\flutter-apk\app-release.apk"

Write-Host "=== Waiting for APK ==="
$waited = 0
while (-not (Test-Path $apk) -and $waited -lt 2400) {
  Start-Sleep -Seconds 10
  $waited += 10
  if ($waited % 60 -eq 0) { Write-Host ("  elapsed " + $waited + "s") }
}
if (-not (Test-Path $apk)) { Write-Host "APK-NOT-FOUND"; exit 2 }
$size = [math]::Round((Get-Item $apk).Length / 1MB, 1)
Write-Host ("APK ready: " + $size + " MB")
Write-Host ""

Write-Host "=== Waiting for device, then installing ==="
for ($i = 1; $i -le 150; $i++) {
  $line = (& $adb devices 2>&1 | Select-String -Pattern $serial | Select-Object -First 1)
  $online = $false
  if ($line -and ($line.Line -match '\sdevice\s*$')) { $online = $true }

  if (-not $online) {
    if ($i % 6 -eq 1) { Write-Host ("[" + $i + "] device not ready, reconnecting...") }
    & $adb reconnect offline 2>&1 | Out-Null
    Start-Sleep -Seconds 5
    continue
  }

  Write-Host ("[" + $i + "] device online, installing...")
  $out = (& $adb -s $serial install -r $apk 2>&1 | Out-String)
  Write-Host ("      " + $out.Trim())

  if ($out -match 'Success') {
    Write-Host "INSTALL-SUCCESS"
    $ver = (& $adb -s $serial shell dumpsys package com.deepseek.deepseekapp 2>&1 | Select-String -Pattern 'versionName' | Select-Object -First 1)
    if ($ver) { Write-Host ("installed: " + $ver.Line.Trim()) }
    exit 0
  }
  if ($out -match 'INSTALL_FAILED_UPDATE_INCOMPATIBLE') { Write-Host "SIGNATURE-CONFLICT"; exit 3 }
  Start-Sleep -Seconds 6
}
Write-Host "INSTALL-TIMEOUT"
exit 4
