@echo off
rem AirDrop launcher: double-click to receive, or "AirDrop.cmd send file.jpg".
powershell.exe -NoProfile -ExecutionPolicy Bypass -File "%~dp0AirDrop.ps1" %*
if errorlevel 1 pause
