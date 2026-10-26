@echo off
setlocal
powershell.exe -NoLogo -NoProfile -ExecutionPolicy Bypass -File "%~dp0add_watermark.ps1" %*
if errorlevel 1 (
    echo Watermark processing failed. Check the messages above.
) else (
    echo Done. Open the watermarked folder next to this script.
)
pause
