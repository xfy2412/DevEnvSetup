@echo off
rem ===========================================================================
rem  WindowsLayout.bat - one-click dev desktop launcher.
rem
rem  Opens the home Windows Terminal window (as a NAMED window, so it can be
rem  addressed again afterwards) and lays out the dev desktop:
rem
rem    tab 1 : D:\git-repo                  - layout first, then dsh web
rem    tab 2 : D:\git-repo\ServerPluginCore - plain pwsh
rem
rem  The layout script runs INSIDE the home window, so it recognises that
rem  window as its own host and positions it - it does NOT open a second
rem  terminal beside the one you already have.
rem
rem  Hard-won Windows Terminal facts behind this design:
rem    * wt.exe has no way to inject a command into an already-running tab
rem      (only new-tab / split-pane / focus-tab exist), so tab 1's shell has to
rem      do the remaining work itself.
rem    * wt.exe splits its command line on ';' EVEN INSIDE QUOTES, so the
rem      command handed to wt must not contain a single semicolon.
rem    * wt.exe returns before the window has started, so files the new tab
rem      still has to read must not be deleted here.
rem  Therefore tab 1 starts a generated wrapper script (fixed name in %TEMP%,
rem  overwritten on every run) which runs the layout and then hands over to an
rem  interactive pwsh that starts dsh web.
rem
rem  Edge windows, geometry and z-order come from WindowsLayout.json.
rem ===========================================================================
setlocal

set "HERE=%~dp0"
if "%HERE:~-1%"=="\" set "HERE=%HERE:~0,-1%"
set "WORKSPACE=D:\git-repo"
set "PLUGINCORE=%WORKSPACE%\ServerPluginCore"
set "WINNAME=WindowsLayoutHome"
set "WRAP=%TEMP%\WindowsLayout.wrap.ps1"

where pwsh.exe >nul 2>nul
if errorlevel 1 (
    echo [WindowsLayout] pwsh ^(PowerShell 7^) was not found on PATH.
    echo                 Install PowerShell 7, or edit this file to use powershell.exe.
    pause
    exit /b 1
)

if not exist "%HERE%\WindowsLayout.ps1" (
    echo [WindowsLayout] WindowsLayout.ps1 not found next to this file:
    echo                 %HERE%
    pause
    exit /b 1
)

rem tab 2 starts in the ServerPluginCore working tree, which lives in the
rem workspace next to this folder - NOT inside it.  A missing directory makes
rem wt.exe fail to start that tab (error 0x8007010b, "cannot access the start
rem directory"), so check it up front instead of failing silently later.
if not exist "%PLUGINCORE%" (
    echo [WindowsLayout] ServerPluginCore not found:
    echo                 %PLUGINCORE%
    echo                 Edit WORKSPACE at the top of this file if the workspace moved.
    pause
    exit /b 1
)

rem ---------------------------------------------------------------------------
rem What happens, in order (tab 1 runs a small generated wrapper):
rem
rem   1. WindowsLayout.ps1 -WeatherView -Refresh -ZoomPercent 150 -ScrollTicks 4
rem        a. finds / opens the three windows
rem        b. moves them into the layout rectangles from WindowsLayout.json
rem        c. weather page: F5 -> zoom 150% -> Down x4
rem           (F5 first because a reload resets both scroll and zoom)
rem        d. applies the z-order: terminal > right Edge > weather
rem        e. makes the right Edge window the active one and stops
rem   2. "dsh web" runs in the FOREGROUND in this tab.  It is the dev server, so
rem      it is expected to occupy the tab.  It opens the 3080 page itself.
rem      Running it after step 1 is required: it grabs focus, and the weather
rem      keystrokes in 1c are real keyboard input.
rem
rem   tab 2 = pwsh in ServerPluginCore (plain shell, no command).
rem
rem The layout script runs INSIDE the home window, so it recognises that window
rem as its own host and positions it instead of opening another terminal.
rem ---------------------------------------------------------------------------
>"%WRAP%" echo ^& '%HERE%\WindowsLayout.ps1' -WeatherView -Refresh -ZoomPercent 150 -ScrollTicks 4
>>"%WRAP%" echo dsh web

wt.exe -w "%WINNAME%" ^
  new-tab -d "%HERE%" pwsh -NoProfile -ExecutionPolicy Bypass -NoExit -File "%WRAP%" ; ^
  new-tab -d "%PLUGINCORE%"

endlocal
