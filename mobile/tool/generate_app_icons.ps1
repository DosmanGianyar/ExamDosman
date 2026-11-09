# Generator ikon launcher Android & iOS untuk Exam Dosman.
# Gaya: latar navy gradasi + cincin gold + logo sekolah di tengah.
#
# Pemakaian (dari folder mobile/):
#   powershell -ExecutionPolicy Bypass -File tool\generate_app_icons.ps1
#
# Sumber logo: assets/logo_sekolah_original.png (PNG transparan).
# Ubah warna/ukuran lewat parameter di bawah bila perlu.

param(
    [string]$Logo        = "assets/logo_sekolah_original.png",
    [string]$ColorCenter = "#1E4C93",   # navy terang (tengah)
    [string]$ColorEdge   = "#0A1633",   # navy gelap (tepi)
    [double]$LogoScale   = 0.60,        # tinggi logo vs sisi ikon (iOS & legacy Android)
    [double]$RingDiam    = 0.86,        # diameter cincin gold vs sisi ikon (iOS & legacy)
    [double]$FgRingDiam  = 0.60,        # diameter cincin gold vs kanvas adaptive (108dp)
    [double]$RingStroke  = 0.045,       # tebal cincin vs diameter cincin
    [double]$FgScale     = 0.42         # tinggi logo vs kanvas adaptive foreground (108dp)
)

$ErrorActionPreference = "Stop"
Add-Type -AssemblyName System.Drawing
$root = Split-Path -Parent $PSScriptRoot   # folder mobile/
Set-Location $root

$logoImg = [System.Drawing.Image]::FromFile((Resolve-Path $Logo))
$cCenter = [System.Drawing.ColorTranslator]::FromHtml($ColorCenter)
$cEdge   = [System.Drawing.ColorTranslator]::FromHtml($ColorEdge)

function New-Canvas([int]$size, [bool]$alpha) {
    $fmt = if ($alpha) { [System.Drawing.Imaging.PixelFormat]::Format32bppArgb } else { [System.Drawing.Imaging.PixelFormat]::Format24bppRgb }
    $bmp = New-Object System.Drawing.Bitmap $size, $size, $fmt
    $g = [System.Drawing.Graphics]::FromImage($bmp)
    $g.SmoothingMode      = "AntiAlias"
    $g.InterpolationMode  = "HighQualityBicubic"
    $g.PixelOffsetMode    = "HighQuality"
    $g.CompositingQuality = "HighQuality"
    return @($bmp, $g)
}

function Fill-Background($g, [int]$size, $clipPath) {
    if ($clipPath) { $g.SetClip($clipPath) }
    $g.FillRectangle((New-Object System.Drawing.SolidBrush $cEdge), 0, 0, $size, $size)
    # Gradasi radial: terang di tengah-atas, gelap di tepi.
    $ell = New-Object System.Drawing.Drawing2D.GraphicsPath
    $pad = [int]($size * 0.35)
    $ell.AddEllipse(-$pad, -$pad - [int]($size * 0.08), $size + 2 * $pad, $size + 2 * $pad)
    $pgb = New-Object System.Drawing.Drawing2D.PathGradientBrush $ell
    $pgb.CenterColor    = $cCenter
    $pgb.SurroundColors = @($cEdge)
    $pgb.CenterPoint    = New-Object System.Drawing.PointF ($size / 2), ($size * 0.42)
    $g.FillRectangle($pgb, 0, 0, $size, $size)
    if ($clipPath) { $g.ResetClip() }
}

function Draw-Logo($g, [int]$size, [double]$scale) {
    $h = $size * $scale
    $w = $h * $logoImg.Width / $logoImg.Height
    $x = ($size - $w) / 2
    $y = ($size - $h) / 2
    # Bayangan lembut agar logo "terangkat" dari latar.
    $shadow = New-Object System.Drawing.Imaging.ColorMatrix
    $shadow.Matrix00 = 0; $shadow.Matrix11 = 0; $shadow.Matrix22 = 0; $shadow.Matrix33 = 0.35
    $ia = New-Object System.Drawing.Imaging.ImageAttributes
    $ia.SetColorMatrix($shadow)
    $off = $size * 0.012
    $g.DrawImage($logoImg, (New-Object System.Drawing.Rectangle ([int]($x + $off)), ([int]($y + $off * 1.5)), ([int]$w), ([int]$h)), 0, 0, $logoImg.Width, $logoImg.Height, "Pixel", $ia)
    $g.DrawImage($logoImg, [single]$x, [single]$y, [single]$w, [single]$h)
}

function Draw-Ring($g, [int]$size, [double]$diamRatio) {
    # Cincin gold metalik di tengah ikon.
    $d  = $size * $diamRatio
    $t  = [math]::Max(1.0, $d * $RingStroke)
    $x  = ($size - $d) / 2 + $t / 2
    $dd = $d - $t
    $rect = New-Object System.Drawing.RectangleF ([single]$x), ([single]$x), ([single]$dd), ([single]$dd)
    # bayangan tipis
    $sh = New-Object System.Drawing.Pen ([System.Drawing.Color]::FromArgb(90, 0, 0, 0)), ([single]$t)
    $rs = New-Object System.Drawing.RectangleF ([single]$x), ([single]($x + $t * 0.35)), ([single]$dd), ([single]$dd)
    $g.DrawEllipse($sh, $rs)
    # gradasi gold
    $br = New-Object System.Drawing.Drawing2D.LinearGradientBrush (New-Object System.Drawing.PointF 0, 0), (New-Object System.Drawing.PointF $size, $size), ([System.Drawing.Color]::Black), ([System.Drawing.Color]::Black)
    $blend = New-Object System.Drawing.Drawing2D.ColorBlend 5
    $blend.Colors = @(
        [System.Drawing.ColorTranslator]::FromHtml("#FFE9A3"),
        [System.Drawing.ColorTranslator]::FromHtml("#D4A537"),
        [System.Drawing.ColorTranslator]::FromHtml("#F6D77A"),
        [System.Drawing.ColorTranslator]::FromHtml("#B8862B"),
        [System.Drawing.ColorTranslator]::FromHtml("#F2CF6B"))
    $blend.Positions = @(0.0, 0.3, 0.5, 0.75, 1.0)
    $br.InterpolationColors = $blend
    $pen = New-Object System.Drawing.Pen $br, ([single]$t)
    $g.DrawEllipse($pen, $rect)
}

function RoundedRect([int]$size, [double]$radiusRatio) {
    $r = $size * $radiusRatio; $d = $r * 2
    $p = New-Object System.Drawing.Drawing2D.GraphicsPath
    $p.AddArc(0, 0, $d, $d, 180, 90)
    $p.AddArc($size - $d, 0, $d, $d, 270, 90)
    $p.AddArc($size - $d, $size - $d, $d, $d, 0, 90)
    $p.AddArc(0, $size - $d, $d, $d, 90, 90)
    $p.CloseFigure()
    return $p
}

function Save($bmp, $path) {
    New-Item -ItemType Directory -Force (Split-Path $path) | Out-Null
    $bmp.Save($path, [System.Drawing.Imaging.ImageFormat]::Png)
    Write-Host "  $path"
}

# ---------- iOS (persegi penuh, tanpa alpha; iOS membulatkan sudut sendiri) ----------
Write-Host "iOS:"
$ios = "ios/Runner/Assets.xcassets/AppIcon.appiconset"
$iosSizes = @{
  "Icon-App-20x20@1x.png"=20; "Icon-App-20x20@2x.png"=40; "Icon-App-20x20@3x.png"=60;
  "Icon-App-29x29@1x.png"=29; "Icon-App-29x29@2x.png"=58; "Icon-App-29x29@3x.png"=87;
  "Icon-App-40x40@1x.png"=40; "Icon-App-40x40@2x.png"=80; "Icon-App-40x40@3x.png"=120;
  "Icon-App-50x50@1x.png"=50; "Icon-App-50x50@2x.png"=100;
  "Icon-App-57x57@1x.png"=57; "Icon-App-57x57@2x.png"=114;
  "Icon-App-60x60@2x.png"=120; "Icon-App-60x60@3x.png"=180;
  "Icon-App-72x72@1x.png"=72; "Icon-App-72x72@2x.png"=144;
  "Icon-App-76x76@1x.png"=76; "Icon-App-76x76@2x.png"=152;
  "Icon-App-83.5x83.5@2x.png"=167; "Icon-App-1024x1024@1x.png"=1024
}
foreach ($k in $iosSizes.Keys) {
    $s = $iosSizes[$k]; $bmp, $g = New-Canvas $s $false
    Fill-Background $g $s $null; Draw-Ring $g $s $RingDiam; Draw-Logo $g $s $LogoScale
    Save $bmp "$ios/$k"; $g.Dispose(); $bmp.Dispose()
}
# Master untuk store listing / referensi
$bmp, $g = New-Canvas 1024 $false; Fill-Background $g 1024 $null; Draw-Ring $g 1024 $RingDiam; Draw-Logo $g 1024 $LogoScale
Save $bmp "assets/icon/app_icon_1024.png"; $g.Dispose(); $bmp.Dispose()
# Sumber untuk flutter_launcher_icons (jika dijalankan di PC yang ada Flutter)
$bmp, $g = New-Canvas 1024 $true; $g.Clear([System.Drawing.Color]::Transparent); Draw-Ring $g 1024 $FgRingDiam; Draw-Logo $g 1024 $FgScale
Save $bmp "assets/icon/app_icon_foreground.png"; $g.Dispose(); $bmp.Dispose()
$bmp, $g = New-Canvas 1024 $false; Fill-Background $g 1024 $null
Save $bmp "assets/icon/app_icon_background.png"; $g.Dispose(); $bmp.Dispose()
# Play Store icon 512
$bmp, $g = New-Canvas 512 $false; Fill-Background $g 512 $null; Draw-Ring $g 512 $RingDiam; Draw-Logo $g 512 $LogoScale
Save $bmp "assets/icon/play_store_512.png"; $g.Dispose(); $bmp.Dispose()

# ---------- Android ----------
Write-Host "Android:"
$res = "android/app/src/main/res"
$dens = [ordered]@{ mdpi = 1.0; hdpi = 1.5; xhdpi = 2.0; xxhdpi = 3.0; xxxhdpi = 4.0 }
foreach ($d in $dens.Keys) {
    $m = $dens[$d]
    # Legacy (Android < 8): kotak sudut bulat 48dp
    $s = [int](48 * $m); $bmp, $g = New-Canvas $s $true
    $g.Clear([System.Drawing.Color]::Transparent)
    $rr = RoundedRect $s 0.20
    Fill-Background $g $s $rr; Draw-Ring $g $s $RingDiam; Draw-Logo $g $s $LogoScale
    Save $bmp "$res/mipmap-$d/ic_launcher.png"; $g.Dispose(); $bmp.Dispose()

    # Adaptive (Android 8+): kanvas 108dp, logo dalam safe zone
    $s = [int](108 * $m)
    $bmp, $g = New-Canvas $s $true; $g.Clear([System.Drawing.Color]::Transparent)
    Draw-Ring $g $s $FgRingDiam; Draw-Logo $g $s $FgScale
    Save $bmp "$res/drawable-$d/ic_launcher_foreground.png"; $g.Dispose(); $bmp.Dispose()

    $bmp, $g = New-Canvas $s $true; Fill-Background $g $s $null
    Save $bmp "$res/drawable-$d/ic_launcher_bg.png"; $g.Dispose(); $bmp.Dispose()
}

$xml = @'
<?xml version="1.0" encoding="utf-8"?>
<adaptive-icon xmlns:android="http://schemas.android.com/apk/res/android">
  <background android:drawable="@drawable/ic_launcher_bg"/>
  <foreground android:drawable="@drawable/ic_launcher_foreground"/>
</adaptive-icon>
'@
Set-Content -Path "$res/mipmap-anydpi-v26/ic_launcher.xml" -Value $xml -Encoding UTF8
Write-Host "  $res/mipmap-anydpi-v26/ic_launcher.xml"

$logoImg.Dispose()
Write-Host "Selesai."

