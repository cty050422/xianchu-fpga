@echo off
setlocal
set "XC_NODE=%ProgramFiles%\nodejs\node.exe"
if not exist "%XC_NODE%" set "XC_NODE=%LOCALAPPDATA%\Programs\nodejs\node.exe"
if not exist "%XC_NODE%" (
  set "XC_NODE="
  for /f "delims=" %%N in ('where node.exe 2^>nul') do if not defined XC_NODE set "XC_NODE=%%N"
)
if not defined XC_NODE (
  echo ERROR: Node.js was not found. Install Node.js 24 LTS with npm.
  exit /b 1
)
"%XC_NODE%" %*
exit /b %ERRORLEVEL%
