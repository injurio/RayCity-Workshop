@echo off
rem RayCity Workshop: starts the local server and opens the page. Close this window to stop it.
rem On the first start (or when a folder is gone) it asks for the client folder and the JMDReader folder.
cd /d "%~dp0"
where node >nul 2>nul || (
  echo Node.js is not installed. Install the LTS version from https://nodejs.org/ and start the Workshop again.
  pause
  exit /b 1
)
node server.js --open
pause
