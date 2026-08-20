@echo off
setlocal

:: Version: 2026.08.19.3   (date-based, stamped automatically by tools\Update-Version.ps1 on commit)

:: Check for administrative privileges
NET SESSION >NUL 2>&1
IF %ERRORLEVEL% NEQ 0 (
    ECHO Requesting administrative privileges...
    :: Relaunch the script with admin rights, passing along any arguments.
    :: We check if arguments exist. If not, we call Start-Process without -ArgumentList.
    :: If they do, we pass them all using %*. This is the most reliable way.
    IF [%1]==[] (
        powershell -Command "Start-Process -FilePath '%~dpnx0' -Verb RunAs"
    ) ELSE (
        powershell -Command "Start-Process -FilePath '%~dpnx0' -Verb RunAs -ArgumentList '%*'"
    )
    EXIT /B
)

:: If we reach here, the script is running with administrative privileges.
ECHO Running with administrative privileges.

:: This batch file is a simple wrapper to execute the Windows-ISO-Updater.ps1 PowerShell script.
:: It ensures that the script is run with an execution policy that allows it to execute,
:: and it passes along any arguments provided to this batch file.

:: Get the directory where this batch file is located.
set "SCRIPT_DIR=%~dp0"

:: Construct the full path to the PowerShell script.
set "PS_SCRIPT=%SCRIPT_DIR%Windows-ISO-Updater.ps1"

IF NOT EXIST "%PS_SCRIPT%" (
    ECHO Windows-ISO-Updater.ps1 was not found in the same folder as this batch file.
    ECHO Place Windows-ISO-Updater.ps1 next to Run-Windows-ISO-Updater.bat and run again.
    PAUSE
    EXIT /B 1
)

:: Execute the PowerShell script.
:: -ExecutionPolicy Bypass: Allows the script to run without changing the system-wide policy.
:: -File: Specifies the script to run.
:: %*: Passes all arguments from this batch file to the PowerShell script.
powershell.exe -ExecutionPolicy Bypass -File "%PS_SCRIPT%" %*
