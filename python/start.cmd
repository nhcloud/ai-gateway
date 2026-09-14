@echo off
rem ─────────────────────────────────────────────────────────────────────
rem  Runs the Python / FastAPI app - backend and UI, self-contained.
rem
rem  Call it as  .\start.cmd  (a bare "start" is cmd's built-in command).
rem
rem    .\start.cmd                http://localhost:8080
rem    .\start.cmd --port 8090    a different port
rem    .\start.cmd --mock         against the offline mock, no Azure needed
rem    .\start.cmd --reload       uvicorn auto-reload
rem    .\start.cmd --no-browser   do not open a browser
rem
rem  Configuration comes from ..\.env (shared with the .NET stack), or from
rem  python\.env if you want this app pointed somewhere the other one is not.
rem ─────────────────────────────────────────────────────────────────────
setlocal EnableExtensions EnableDelayedExpansion

set "HERE=%~dp0"
if "%HERE:~-1%"=="\" set "HERE=%HERE:~0,-1%"
for %%I in ("%HERE%\..") do set "ROOT=%%~fI"

set "PORT=8080"
set "MOCK_PORT=5290"
set "FORCE_MOCK=0"
set "NO_BROWSER=0"
set "RELOAD="

:parse
if "%~1"=="" goto parsed
if /i "%~1"=="--mock"       set "FORCE_MOCK=1"    & shift & goto parse
if /i "%~1"=="--no-browser" set "NO_BROWSER=1"    & shift & goto parse
if /i "%~1"=="--reload"     set "RELOAD=--reload" & shift & goto parse
if /i "%~1"=="--port"       set "PORT=%~2"        & shift & shift & goto parse
if /i "%~1"=="-h"           goto usage
if /i "%~1"=="--help"       goto usage
echo.
echo   unknown argument: %~1
goto usage

:parsed
where python >nul 2>&1 || (
    echo.
    echo   error: Python was not found. Install Python 3.10+ from https://python.org
    echo.
    exit /b 1
)

set "VPY=%HERE%\.venv\Scripts\python.exe"
if not exist "%VPY%" (
    echo.
    echo   Creating python\.venv
    python -m venv "%HERE%\.venv" || exit /b 1
)

echo   Installing requirements
"%VPY%" -m pip install --quiet --disable-pip-version-check -r "%HERE%\requirements.txt" || exit /b 1

rem ── fall back to the mock when nothing is configured ─────────────────
if "%FORCE_MOCK%"=="0" (
    if not exist "%ROOT%\.env" if not exist "%HERE%\.env" if "%AI_ENDPOINT%"=="" (
        echo.
        echo   ! No AI_ENDPOINT in .env or the environment - falling back to the offline mock.
        echo   ! Run scripts\03-set-local-env.ps1 to point the demo at real Azure resources.
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
        echo   Configuration: python\.env ^(overrides the shared one^)
    ) else (
        echo   Configuration: .env at the repo root
    )
)

if "%NO_BROWSER%"=="0" start "" /b cmd /c "timeout /t 3 /nobreak >nul & start http://localhost:%PORT%"

echo.
echo   FastAPI app on http://localhost:%PORT%
echo   The .NET stack runs separately, on its own port - see dotnet\start.cmd
echo.
pushd "%HERE%"
"%VPY%" -m uvicorn app:app --port %PORT% %RELOAD%
popd
exit /b %ERRORLEVEL%

:usage
echo.
echo   Runs the Python / FastAPI app (backend + UI).
echo.
echo     .\start.cmd                http://localhost:8080
echo     .\start.cmd --port 8090    a different port
echo     .\start.cmd --mock         against the offline mock
echo     .\start.cmd --reload       uvicorn auto-reload
echo     .\start.cmd --no-browser   do not open a browser
echo.
exit /b 1
