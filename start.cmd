@echo off
rem ─────────────────────────────────────────────────────────────────────
rem  Convenience dispatcher. Each stack is self-contained and can be run on
rem  its own - this just saves you a cd:
rem
rem    .\start.cmd              -> dotnet\start.cmd   http://localhost:5080
rem    .\start.cmd python       -> python\start.cmd   http://localhost:8080
rem    .\start.cmd both         both at once, side by side
rem    .\start.cmd verify       run both against the mock and compare them
rem    .\start.cmd mock         the offline mock only
rem
rem  Any other flags (--port, --mock, --no-browser, ...) pass straight through.
rem  Call it as .\start.cmd - a bare "start" is cmd's built-in command.
rem ─────────────────────────────────────────────────────────────────────
setlocal EnableExtensions

set "ROOT=%~dp0"
if "%ROOT:~-1%"=="\" set "ROOT=%ROOT:~0,-1%"

set "TARGET=%~1"
if "%TARGET%"=="" set "TARGET=dotnet"
if not "%~1"=="" shift

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
start "AI Gateway - mock" /min python "%ROOT%\scripts\mock-azure-ai.py" 5290
timeout /t 3 /nobreak >nul
python "%ROOT%\scripts\verify-apps.py"
exit /b %ERRORLEVEL%

:mock
python "%ROOT%\scripts\mock-azure-ai.py" 5290
exit /b %ERRORLEVEL%

:usage
echo.
echo   AI Gateway demo - each stack is self-contained.
echo.
echo     .\start.cmd              .NET app     http://localhost:5080
echo     .\start.cmd python       Python app   http://localhost:8080
echo     .\start.cmd both         both at once
echo     .\start.cmd verify       compare the two against the mock
echo     .\start.cmd mock         the offline mock only
echo.
echo   Or run a stack directly:  cd dotnet ^&^& .\start.cmd
echo.
exit /b 1
