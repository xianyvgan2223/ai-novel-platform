$ErrorActionPreference = 'Stop'
Add-Type -AssemblyName System.Drawing

$root = "E:\flutter\deepSeekapp\android\app\src\main\res"
$srcPath = Join-Path $root "mipmap-xxxhdpi\ic_launcher.png"

Write-Host "=== Source artwork ==="
$orig = [System.Drawing.Image]::FromFile($srcPath)
Write-Host ("  " + $orig.Width + "x" + $orig.Height)
$source = New-Object System.Drawing.Bitmap($orig)
$orig.Dispose()

# Android launcher icon sizes per density
$sizes = [ordered]@{
  'mipmap-mdpi'    = 48
  'mipmap-hdpi'    = 72
  'mipmap-xhdpi'   = 96
  'mipmap-xxhdpi'  = 144
  'mipmap-xxxhdpi' = 192
}

Write-Host "=== Writing real PNGs ==="
foreach ($key in $sizes.Keys) {
  $n = $sizes[$key]
  $bmp = New-Object System.Drawing.Bitmap($n, $n, [System.Drawing.Imaging.PixelFormat]::Format32bppArgb)
  $g = [System.Drawing.Graphics]::FromImage($bmp)
  $g.InterpolationMode = [System.Drawing.Drawing2D.InterpolationMode]::HighQualityBicubic
  $g.PixelOffsetMode   = [System.Drawing.Drawing2D.PixelOffsetMode]::HighQuality
  $g.SmoothingMode     = [System.Drawing.Drawing2D.SmoothingMode]::HighQuality
  $g.Clear([System.Drawing.Color]::Transparent)

  $scale = [Math]::Min($n / $source.Width, $n / $source.Height)
  $w = [int][Math]::Round($source.Width * $scale)
  $h = [int][Math]::Round($source.Height * $scale)
  $x = [int](($n - $w) / 2)
  $y = [int](($n - $h) / 2)
  $g.DrawImage($source, $x, $y, $w, $h)
  $g.Dispose()

  $outPath = Join-Path (Join-Path $root $key) 'ic_launcher.png'
  $bmp.Save($outPath, [System.Drawing.Imaging.ImageFormat]::Png)
  $bmp.Dispose()

  $len = (Get-Item $outPath).Length
  Write-Host ("  {0,-16} {1,3}x{2,-3}  {3} bytes" -f $key, $n, $n, $len)
}
$source.Dispose()

Write-Host "=== Verify PNG signature ==="
foreach ($key in $sizes.Keys) {
  $p = Join-Path (Join-Path $root $key) 'ic_launcher.png'
  $b = [System.IO.File]::ReadAllBytes($p)
  $head = ($b[0..7] | ForEach-Object { $_.ToString('X2') }) -join ' '
  $ok = if ($head -eq '89 50 4E 47 0D 0A 1A 0A') { 'PNG-OK' } else { 'STILL-BAD' }
  Write-Host ("  {0,-16} {1}" -f $key, $ok)
}
Write-Host "ICONS-FIXED"
