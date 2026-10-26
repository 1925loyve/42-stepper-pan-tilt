# Windows PowerShell 5.1+; no extra software or modules required.
# Examples:
#   .\add_watermark.ps1
#   .\add_watermark.ps1 -Text '1925loyve-roze-n' -Opacity 0.75 -Overwrite
#   .\add_watermark.ps1 -InputPath '.\assets\_MG_0887.JPG' -Position BottomLeft
# Original JPG/PNG files and camera RAW files are never overwritten.
[CmdletBinding()]
param(
    [string]$InputPath = '',
    [string]$OutputDirectory = '',
    [string]$Text = '',
    [ValidateSet('BottomRight', 'BottomLeft', 'TopRight', 'TopLeft', 'Center')]
    [string]$Position = 'BottomRight',
    [ValidateRange(0.01, 1.0)]
    [double]$Opacity = 0.65,
    [ValidateRange(0.05, 0.8)]
    [double]$WidthRatio = 0.24,
    [ValidateRange(0.0, 0.1)]
    [double]$MarginRatio = 0.03,
    [ValidateRange(0, 20000)]
    [int]$MaxEdge = 0,
    [ValidateRange(1, 100)]
    [int]$JpegQuality = 92,
    [switch]$Overwrite
)

$ErrorActionPreference = 'Stop'
Add-Type -AssemblyName System.Drawing
$watermarkScriptDirectory = Split-Path -Parent $MyInvocation.MyCommand.Path
if ([string]::IsNullOrWhiteSpace($InputPath)) {
    $InputPath = Join-Path $watermarkScriptDirectory 'assets'
}
if ([string]::IsNullOrWhiteSpace($OutputDirectory)) {
    $OutputDirectory = Join-Path $watermarkScriptDirectory 'watermarked'
}

# ASCII source keeps this script compatible with Windows PowerShell's
# legacy script encoding. Change -Text to use a different watermark.
if ([string]::IsNullOrWhiteSpace($Text)) {
    $Text = '1925loyve-roze-n'
}

$source = Get-Item -LiteralPath $InputPath
$extensions = @('.jpg', '.jpeg', '.png')
if ($source.PSIsContainer) {
    $sourceDirectory = $source.FullName
    $allFiles = @(Get-ChildItem -LiteralPath $sourceDirectory -File)
} else {
    $sourceDirectory = $source.DirectoryName
    $allFiles = @($source)
}
$files = @($allFiles | Where-Object { $extensions -contains $_.Extension.ToLowerInvariant() })
if ($files.Count -eq 0) {
    throw 'No JPG, JPEG or PNG files found. Export camera RAW files to JPG first.'
}

$outputFullPath = [IO.Path]::GetFullPath($OutputDirectory).TrimEnd('\', '/')
$sourceFullPath = [IO.Path]::GetFullPath($sourceDirectory).TrimEnd('\', '/')
if ([string]::Equals($outputFullPath, $sourceFullPath, [StringComparison]::OrdinalIgnoreCase)) {
    throw 'OutputDirectory must differ from the source folder. Originals must be preserved.'
}
[void][IO.Directory]::CreateDirectory($outputFullPath)
$outputItem = Get-Item -LiteralPath $outputFullPath
if (($outputItem.Attributes -band [IO.FileAttributes]::ReparsePoint) -ne 0) {
    throw 'Use a normal output directory, not a symbolic link or junction.'
}

$fontFamily = $null
foreach ($fontName in @('Microsoft YaHei UI', 'Microsoft YaHei', 'Segoe UI')) {
    try {
        $fontFamily = [Drawing.FontFamily]::new($fontName)
        break
    } catch { }
}
if ($null -eq $fontFamily) { throw 'No suitable font is installed.' }
$fontStyle = [Drawing.FontStyle]::Regular
if ($fontFamily.IsStyleAvailable([Drawing.FontStyle]::Bold)) {
    $fontStyle = [Drawing.FontStyle]::Bold
}
$jpegEncoder = [Drawing.Imaging.ImageCodecInfo]::GetImageEncoders() |
    Where-Object MimeType -eq 'image/jpeg' | Select-Object -First 1
$completed = 0
$skipped = 0
$failed = 0

try {
    foreach ($file in $files) {
        $destination = Join-Path $outputFullPath $file.Name
        if (Test-Path -LiteralPath $destination) {
            if (-not $Overwrite) {
                Write-Host ('SKIP (already exists): ' + $file.Name)
                $skipped++
                continue
            }
            $existing = Get-Item -LiteralPath $destination
            if (($existing.Attributes -band [IO.FileAttributes]::ReparsePoint) -ne 0) {
                throw ('Refusing to overwrite a linked file: ' + $destination)
            }
        }

        $image = $bitmap = $graphics = $textPath = $scaleMatrix = $moveMatrix = $null
        $textBrush = $outlinePen = $encoderParameters = $null
        try {
            $image = [Drawing.Image]::FromFile($file.FullName)
            # Apply EXIF orientation before drawing pixels onto a fresh bitmap.
            if ($image.PropertyIdList -contains 274) {
                $orientation = [BitConverter]::ToUInt16($image.GetPropertyItem(274).Value, 0)
                $rotation = switch ($orientation) {
                    2 { [Drawing.RotateFlipType]::RotateNoneFlipX }
                    3 { [Drawing.RotateFlipType]::Rotate180FlipNone }
                    4 { [Drawing.RotateFlipType]::Rotate180FlipX }
                    5 { [Drawing.RotateFlipType]::Rotate90FlipX }
                    6 { [Drawing.RotateFlipType]::Rotate90FlipNone }
                    7 { [Drawing.RotateFlipType]::Rotate270FlipX }
                    8 { [Drawing.RotateFlipType]::Rotate270FlipNone }
                    default { [Drawing.RotateFlipType]::RotateNoneFlipNone }
                }
                $image.RotateFlip($rotation)
            }

            $resizeRatio = 1.0
            if ($MaxEdge -gt 0) {
                $resizeRatio = [Math]::Min(1.0, $MaxEdge / [double][Math]::Max($image.Width, $image.Height))
            }
            $width = [Math]::Max(1, [int][Math]::Round($image.Width * $resizeRatio))
            $height = [Math]::Max(1, [int][Math]::Round($image.Height * $resizeRatio))
            $bitmap = [Drawing.Bitmap]::new($width, $height, [Drawing.Imaging.PixelFormat]::Format32bppArgb)
            $graphics = [Drawing.Graphics]::FromImage($bitmap)
            $graphics.SmoothingMode = [Drawing.Drawing2D.SmoothingMode]::AntiAlias
            $graphics.InterpolationMode = [Drawing.Drawing2D.InterpolationMode]::HighQualityBicubic
            $graphics.PixelOffsetMode = [Drawing.Drawing2D.PixelOffsetMode]::HighQuality
            $graphics.DrawImage($image, [Drawing.Rectangle]::new(0, 0, $width, $height))

            $textPath = [Drawing.Drawing2D.GraphicsPath]::new()
            $textPath.AddString($Text, $fontFamily, [int]$fontStyle, [single]100,
                [Drawing.PointF]::Empty, [Drawing.StringFormat]::GenericDefault)
            $bounds = $textPath.GetBounds()
            if ($bounds.Width -le 0 -or $bounds.Height -le 0) { throw 'Watermark text has no visible characters.' }
            $scale = [Math]::Min(($width * $WidthRatio) / $bounds.Width, ($height * 0.08) / $bounds.Height)
            $scaleMatrix = [Drawing.Drawing2D.Matrix]::new()
            $scaleMatrix.Scale([single]$scale, [single]$scale)
            $textPath.Transform($scaleMatrix)
            $bounds = $textPath.GetBounds()
            $marginX = $width * $MarginRatio
            $marginY = $height * $MarginRatio
            $x = $width - $bounds.Width - $marginX
            $y = $height - $bounds.Height - $marginY
            switch ($Position) {
                'BottomLeft' { $x = $marginX }
                'TopRight' { $y = $marginY }
                'TopLeft' { $x = $marginX; $y = $marginY }
                'Center' { $x = ($width - $bounds.Width) / 2; $y = ($height - $bounds.Height) / 2 }
            }
            $moveMatrix = [Drawing.Drawing2D.Matrix]::new()
            $moveMatrix.Translate([single]($x - $bounds.X), [single]($y - $bounds.Y))
            $textPath.Transform($moveMatrix)
            $textBrush = [Drawing.SolidBrush]::new([Drawing.Color]::FromArgb([int][Math]::Round(255 * $Opacity), 255, 255, 255))
            $outlinePen = [Drawing.Pen]::new([Drawing.Color]::FromArgb([int][Math]::Round(255 * $Opacity * 0.7), 20, 20, 20),
                [single][Math]::Max(1.0, $bounds.Height * 0.04))
            $outlinePen.LineJoin = [Drawing.Drawing2D.LineJoin]::Round
            $graphics.DrawPath($outlinePen, $textPath)
            $graphics.FillPath($textBrush, $textPath)

            if ($file.Extension.ToLowerInvariant() -eq '.png') {
                $bitmap.Save($destination, [Drawing.Imaging.ImageFormat]::Png)
            } else {
                $encoderParameters = [Drawing.Imaging.EncoderParameters]::new(1)
                $encoderParameters.Param[0] = [Drawing.Imaging.EncoderParameter]::new([Drawing.Imaging.Encoder]::Quality, [long]$JpegQuality)
                $bitmap.Save($destination, $jpegEncoder, $encoderParameters)
            }
            $completed++
            Write-Host ('OK: ' + $file.Name + ' (' + $width + ' x ' + $height + ')')
        } catch {
            $failed++
            Write-Warning ($file.Name + ': ' + $_.Exception.Message)
        } finally {
            foreach ($resource in @($encoderParameters, $outlinePen, $textBrush, $moveMatrix,
                $scaleMatrix, $textPath, $graphics, $bitmap, $image)) {
                if ($null -ne $resource) { $resource.Dispose() }
            }
        }
    }
} finally {
    $fontFamily.Dispose()
}

Write-Host ('Saved: ' + $completed + '; existing skipped: ' + $skipped + '; failed: ' + $failed)
Write-Host ('Unsupported files (including RAW) skipped: ' + ($allFiles.Count - $files.Count))
Write-Host ('Output folder: ' + $outputFullPath)
Write-Host 'Originals are unchanged. Nothing has been uploaded to GitHub.'
if ($failed -gt 0) { throw 'Some images failed; see the warnings above.' }
