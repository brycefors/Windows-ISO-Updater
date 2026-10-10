@echo off
setlocal

:: Version: 2026.10.10.2   (date-based, stamped automatically by tools\Update-Version.ps1 on commit)

:: Runs Windows-ISO-Updater.ps1 elevated, with an execution policy that lets it run, passing along every
:: argument given to this file. Dropping an ISO onto this file builds from that ISO.

NET SESSION >NUL 2>&1
IF %ERRORLEVEL% EQU 0 GOTO :Elevated

ECHO Requesting administrative privileges...
:: Handed over in environment variables so PowerShell treats them as data, never as code to run.
set "WISO_BAT=%~f0"
set "WISO_CWD=%CD%"
set "WISO_ARGS=%*"
:: An elevated cmd.exe starts in System32, so the relaunch changes back to this folder first. Without that a
:: relative path such as .\Examples\autounattend-lab-admin.xml points at the wrong place.
:: Run from a terminal it waits, so the prompt gets the script's exit code back. Double-clicked or dropped
:: onto from Explorer, nobody is reading that code, so this window closes straight away.
powershell.exe -NoProfile -ExecutionPolicy Bypass -Command "$q = [char]34; $Line = '/d /c ' + $q + 'cd /d ' + $q + $env:WISO_CWD + $q + ' && ' + $q + $env:WISO_BAT + $q + ' ' + $env:WISO_ARGS + $q; $Caller = try { $Cmd = (Get-CimInstance Win32_Process -Filter ('ProcessId=' + $PID)).ParentProcessId; $Up = (Get-CimInstance Win32_Process -Filter ('ProcessId=' + $Cmd)).ParentProcessId; (Get-Process -Id $Up -ErrorAction Stop).ProcessName } catch { '' }; try { if ($Caller -and $Caller -ne 'explorer') { $p = Start-Process -FilePath $env:ComSpec -ArgumentList $Line -Verb RunAs -Wait -PassThru -ErrorAction Stop; exit $p.ExitCode } Start-Process -FilePath $env:ComSpec -ArgumentList $Line -Verb RunAs -ErrorAction Stop; exit 0 } catch { exit 1 }"
EXIT /B %ERRORLEVEL%

:Elevated
ECHO Running with administrative privileges.

set "PS_SCRIPT=%~dp0Windows-ISO-Updater.ps1"

IF NOT EXIST "%PS_SCRIPT%" (
    ECHO Windows-ISO-Updater.ps1 was not found in the same folder as this batch file.
    ECHO Place Windows-ISO-Updater.ps1 next to Run-Windows-ISO-Updater.bat and run again.
    PAUSE
    EXIT /B 1
)

:: An ISO dropped onto this file arrives as its only argument.
set "WISO_DROP="
IF "%~2"=="" IF /I "%~x1"==".iso" IF EXIST "%~f1" set "WISO_DROP=%~f1"
IF NOT DEFINED WISO_DROP GOTO :Run
powershell.exe -NoProfile -ExecutionPolicy Bypass -File "%PS_SCRIPT%" -IsoPath "%WISO_DROP%"
EXIT /B %ERRORLEVEL%

:Run
powershell.exe -NoProfile -ExecutionPolicy Bypass -File "%PS_SCRIPT%" %*
:: Passed on so a caller can read -CheckOnly's 0 or 10.
EXIT /B %ERRORLEVEL%
