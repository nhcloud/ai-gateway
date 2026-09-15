@echo off
rem ─────────────────────────────────────────────────────────────────────
rem  Convenience dispatcher. Each stack is self-contained and can be run on
rem  its own - this just saves you a cd:
rem
rem    .\start_all.cmd              both stacks at once, side by side
rem    .\start_all.cmd dotnet       -> dotnet\start.cmd   http://localhost:5080
rem    .\start_all.cmd python       -> python\start.cmd   http://localhost:8080
rem    .\start_all.cmd verify       run both against the mock and compare them
rem    .\start_all.cmd mock         the offline mock only
rem
rem  Any other flags (--port, --mock, --no-browser, ...) pass straight through.
rem  The name is start_all, not start, for two reasons: it launches both stacks, and
rem  "start" is one of cmd's built-in commands - internal commands beat files of the
rem  same name, so a bare "start" would run START instead of a file called start.cmd.
rem  The .\ prefix is still needed either way: PowerShell never searches the current
rem  directory, and cmd does not either where NoDefaultCurrentDirectoryInExePath is set.
rem ─────────────────────────────────────────────────────────────────────
setlocal EnableExtensions

set "ROOT=%~dp0"
if "%ROOT:~-1%"=="\" set "ROOT=%ROOT:~0,-1%"

rem With no argument - or with a leading flag, which means no target was named -
rem run both stacks. That is the demo: one page and one JSON contract served by two
rem back ends on their own ports. Double-clicking this file in Explorer lands here.
set "TARGET=%~1"
if "%TARGET%"=="" set "TARGET=both" & goto dispatch
if "%TARGET:~0,1%"=="-" set "TARGET=both" & goto dispatch
shift

:dispatch

if /i "%TARGET%"=="dotnet"  call "%ROOT%\dotnet\start.cmd" %1 %2 %3 %4 %5 & exit /b %ERRORLEVEL%
if /i "%TARGET%"=="net"     call "%ROOT%\dotnet\start.cmd" %1 %2 %3 %4 %5 & exit /b %ERRORLEVEL%
if /i "%TARGET%"=="razor"   call "%ROOT%\dotnet\start.cmd" %1 %2 %3 %4 %5 & exit /b %ERRORLEVEL%
if /i "%TARGET%"=="python"  call "%ROOT%\python\start.cmd" %1 %2 %3 %4 %5 & exit /b %ERRORLEVEL%
if /i "%TARGET%"=="py"      call "%ROOT%\python\start.cmd" %1 %2 %3 %4 %5 & exit /b %ERRORLEVEL%
if /i "%TARGET%"=="fastapi" call "%ROOT%\python\start.cmd" %1 %2 %3 %4 %5 & exit /b %ERRORLEVEL%
if /i "%TARGET%"=="both"    goto both
if /i "%TARGET%"=="verify"  goto verify
if /i "%TARGET%"=="mock"    goto mock
goto usage

:both
rem Different ports by design, so both run at once and can be compared.
echo.
echo   Starting both stacks in separate windows.
echo     .NET 10 Razor    http://localhost:5080
echo     Python FastAPI   http://localhost:8080
echo   Same page, same contract, two stacks. Close either window to stop it.
echo.
start "AI Gateway - .NET 10 Razor" cmd /k "%ROOT%\dotnet\start.cmd" %1 %2 %3
timeout /t 3 /nobreak >nul
start "AI Gateway - Python FastAPI" cmd /k "%ROOT%\python\start.cmd" --no-browser %1 %2 %3
exit /b 0

:verify
dotnet build "%ROOT%\dotnet\AiGatewayDemo" --nologo -v q || exit /b 1
start "AI Gateway - mock" /min python "%ROOT%\tools\mock-azure-ai.py" 5290
timeout /t 3 /nobreak >nul
python "%ROOT%\tests\verify-apps.py"
exit /b %ERRORLEVEL%

:mock
python "%ROOT%\tools\mock-azure-ai.py" 5290
exit /b %ERRORLEVEL%

:usage
echo.
echo   AI Gateway demo - each stack is self-contained.
echo.
echo     .\start_all.cmd              both stacks at once  :5080 and :8080
echo     .\start_all.cmd dotnet       .NET app     http://localhost:5080
echo     .\start_all.cmd python       Python app   http://localhost:8080
echo     .\start_all.cmd verify       compare the two against the mock
echo     .\start_all.cmd mock         the offline mock only
echo.
echo   Or run a stack directly:  cd dotnet ^&^& .\start.cmd
echo.
exit /b 1
