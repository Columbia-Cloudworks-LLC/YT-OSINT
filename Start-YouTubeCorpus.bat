@echo off
setlocal
set COMPlus_gcConcurrent=1
"%SystemRoot%\System32\WindowsPowerShell\v1.0\powershell.exe" -NoLogo -NoProfile -STA -ExecutionPolicy Bypass -File "%~dp0YouTubeCorpus.ps1"
if errorlevel 1 pause
