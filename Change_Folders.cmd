@echo off
rem Choose the client folder and the JMDReader folder again (saved in workshop.config.json).
cd /d "%~dp0"
powershell -NoProfile -ExecutionPolicy Bypass -File backend\setup_paths.ps1 -Force
pause
