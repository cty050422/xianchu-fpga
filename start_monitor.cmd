@echo off
setlocal
cd /d "%~dp0"
call "%~dp0src\tools\run_node.cmd" "%~dp0src\tools\start_ui.mjs"
pause
