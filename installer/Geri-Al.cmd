@echo off
chcp 65001 >nul
powershell.exe -NoProfile -ExecutionPolicy Bypass -File "%~dp0Yama.ps1" -Restore %*
set "YAMA_SONUC=%ERRORLEVEL%"
pause
exit /b %YAMA_SONUC%
