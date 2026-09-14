@echo off
rem ─────────────────────────────────────────────────────────────────────
rem  Runs the .NET 10 Razor app - backend and UI, self-contained.
rem
rem  Call it as  .\start.cmd  (a bare "start" is cmd's built-in command).
rem
rem    .\start.cmd                http://localhost:5080
rem    .\start.cmd --port 5090    a different port
rem    .\start.cmd --mock         against the offline mock, no Azure needed
rem    .\start.cmd --no-browser   do not open a browser
rem
rem  Configuration comes from ..\.env (shared with the Python stack), or from
rem  dotnet\.env if you want this app pointed somewhere the other one is not.
rem ─────────────────────────────────────────────────────────────────────
setlocal EnableExtensions EnableDelayedExpansion

set "HERE=%~dp0"
if "%HERE:~-1%"=="\" set "HERE=%HERE:~0,-1%"
for %%I in ("%HERE%\..") do set "ROOT=%%~fI"

set "PORT=5080"
set "MOCK_PORT=5290"
set "FORCE_MOCK=0"
set "NO_BROWSER=0"

:parse
if "%~1"=="" goto parsed
if /i "%~1"=="--mock"       set "FORCE_MOCK=1"  & shift & goto parse
if /i "%~1"=="--no-browser" set "NO_BROWSER=1"  & shift & goto parse
if /i "%~1"=="--port"       set "PORT=%~2"      & shift & shift & goto parse
if /i "%~1"=="-h"           goto usage
if /i "%~1"=="--help"       goto usage
echo.
echo   unknown argument: %~1
goto usage

:parsed
where dotnet >nul 2>&1 || (
    echo.
    echo   error: the .NET SDK was not found. Install .NET 10 from https://dot.net
    echo.
    exit /b 1
)

rem ── fall back to the mock only when nothing at all is configured ─────
rem The .NET app also reads appsettings.json, appsettings.Development.json and
rem user-secrets. The mock fallback works by setting environment variables, and
rem those outrank appsettings - so guessing wrong would silently replace real
rem configuration with the mock.
if "%FORCE_MOCK%"=="0" (
    set "CONFIGURED="
    if not "%AI_ENDPOINT%"=="" set "CONFIGURED=1"
    if exist "%ROOT%\.env" set "CONFIGURED=1"
    if exist "%HERE%\.env" set "CONFIGURED=1"
    for %%F in ("%HERE%\AiGatewayDemo\appsettings.Development.json" "%HERE%\AiGatewayDemo\appsettings.json") do (
        if exist %%F findstr /R /C:"\"AI_ENDPOINT\"[ ]*:[ ]*\"..*\"" %%F >nul 2>&1 && set "CONFIGURED=1"
    )
    for /f "tokens=2 delims=<>" %%I in ('findstr /I "UserSecretsId" "%HERE%\AiGatewayDemo\AiGatewayDemo.csproj" 2^>nul') do (
        if exist "%APPDATA%\Microsoft\UserSecrets\%%I\secrets.json" (
            findstr /R /C:"\"AI_ENDPOINT\"[ ]*:[ ]*\"..*\"" "%APPDATA%\Microsoft\UserSecrets\%%I\secrets.json" >nul 2>&1 && set "CONFIGURED=1"
        )
    )
    if not defined CONFIGURED (
        echo.
        echo   ! No AI_ENDPOINT in .env, appsettings, user-secrets or the environment.
        echo   ! Falling back to the offline mock. Run scripts\03-set-local-env.ps1 for real resources.
        set "FORCE_MOCK=1"
    )
)

if "%FORCE_MOCK%"=="1" (
    echo.
    echo   Starting the mock Azure AI stack on :%MOCK_PORT%
    echo   'bomb', 'attack', 'kill' or 'weapon' in a prompt trips the guardrail.
    echo   The mock is not an Azure host, so the page reports a "custom" connection.
    rem The other stack may already be running one - reuse it rather than starting
    rem a second that cannot bind.
    python -c "import socket,sys; s=socket.socket(); s.settimeout(0.5); sys.exit(0 if s.connect_ex(('127.0.0.1',%MOCK_PORT%))==0 else 1)" >nul 2>&1
    if errorlevel 1 (
        start "AI Gateway - mock" /min python "%ROOT%\scripts\mock-azure-ai.py" %MOCK_PORT%
        timeout /t 3 /nobreak >nul
    ) else (
        echo   Reusing the mock already listening on :%MOCK_PORT%
    )

    set "AI_ENDPOINT=http://127.0.0.1:%MOCK_PORT%"
    set "AI_KEY=mock-gateway-key"
    set "AI_KEY_HEADER=api-key"
    set "AI_CHAT_MODEL=gpt-4o"
    set "AI_EMBEDDING_MODEL=text-embedding-3-small"
    set "CONTENT_SAFETY_ENDPOINT=http://127.0.0.1:%MOCK_PORT%"
    set "CONTENT_SAFETY_KEY=mock-safety-key"
    set "DOC_INTEL_ENDPOINT=http://127.0.0.1:%MOCK_PORT%"
    set "DOC_INTEL_KEY=mock-docintel-key"
) else (
    if not "%AI_ENDPOINT%"=="" (
        echo   Configuration: AI_ENDPOINT from the environment
    ) else if exist "%HERE%\.env" (
        echo   Configuration: dotnet\.env ^(overrides the shared one^)
    ) else if exist "%ROOT%\.env" (
        echo   Configuration: .env at the repo root
    ) else (
        echo   Configuration: appsettings / user-secrets - the app reports which on the page
    )
)

set "ASPNETCORE_URLS=http://localhost:%PORT%"
if "%NO_BROWSER%"=="0" start "" /b cmd /c "timeout /t 4 /nobreak >nul & start http://localhost:%PORT%"

echo.
echo   .NET 10 Razor app on http://localhost:%PORT%
echo   The Python stack runs separately, on its own port - see python\start.cmd
echo.
dotnet run --project "%HERE%\AiGatewayDemo"
exit /b %ERRORLEVEL%

:usage
echo.
echo   Runs the .NET 10 Razor app (backend + UI).
echo.
echo     .\start.cmd                http://localhost:5080
echo     .\start.cmd --port 5090    a different port
echo     .\start.cmd --mock         against the offline mock
echo     .\start.cmd --no-browser   do not open a browser
echo.
exit /b 1
