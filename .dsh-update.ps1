$adb    = "D:\tools\Android\Sdk\platform-tools\adb.exe"
$serial = "AQQB9X1526W02408"
$apk    = "E:\flutter\deepSeekapp\build\app\outputs\flutter-apk\app-release.apk"

Write-Host "=== wait for APK ==="
$w = 0
while (-not (Test-Path $apk) -and $w -lt 1800) { Start-Sleep -Seconds 10; $w += 10 }
if (-not (Test-Path $apk)) { Write-Host "APK-NOT-FOUND"; exit 2 }
$mb = [math]::Round((Get-Item $apk).Length / 1MB, 1)
Write-Host ("  APK " + $mb + " MB  (built at " + (Get-Item $apk).LastWriteTime + ")")

function Ensure-Device {
  for ($i = 1; $i -le 30; $i++) {
    $l = (& $adb devices 2>&1 | Select-String -Pattern $serial | Select-Object -First 1)
    if ($l -and ($l.Line -match '\sdevice\s*$')) { return $true }
    & $adb reconnect offline 2>&1 | Out-Null
    Start-Sleep -Seconds 4
  }
  return $false
}

Write-Host ""
Write-Host "=== step 1: push to /data/local/tmp (retry on drop) ==="
$pushed = $false
for ($try = 1; $try -le 5; $try++) {
  if (-not (Ensure-Device)) { Write-Host ("  attempt " + $try + ": device not ready"); continue }
  Write-Host ("  attempt " + $try + ": pushing...")
  $p = (& $adb -s $serial push $apk /data/local/tmp/dsupdate.apk 2>&1 | Out-String)
  Write-Host ("    " + $p.Trim())
  if ($p -match '1 file pushed') { $pushed = $true; break }
  Start-Sleep -Seconds 5
}
if (-not $pushed) {
  Write-Host "PUSH-FAILED"
} else {
  Write-Host "  push ok"
  Write-Host ""
  Write-Host "=== step 2: pm install -r ==="
  if (-not (Ensure-Device)) { Write-Host "NO-DEVICE"; exit 4 }
  $r = (& $adb -s $serial shell pm install -r /data/local/tmp/dsupdate.apk 2>&1 | Out-String)
  Write-Host ("  " + $r.Trim())
  if ($r -match 'Success') { Write-Host "PM-INSTALL-SUCCESS" }
  elseif ($r -match 'USER_RESTRICTED') { Write-Host "NEED-USB-INSTALL-PERMISSION" }
  elseif ($r -match 'UPDATE_INCOMPATIBLE') { Write-Host "SIGNATURE-CONFLICT" }
}

Write-Host ""
Write-Host "=== step 3: always copy APK to Download as manual fallback ==="
if (Ensure-Device) {
  $c = (& $adb -s $serial push $apk /sdcard/Download/deepseekapp-update.apk 2>&1 | Out-String)
  Write-Host ("  " + $c.Trim())
}
Write-Host "DONE"
