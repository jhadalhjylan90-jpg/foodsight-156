@echo off
cd /d "%~dp0"
if not exist .env copy .env.example .env >nul
node --env-file-if-exists=.env server.mjs
pause
