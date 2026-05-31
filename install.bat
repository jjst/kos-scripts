@echo off
setlocal enabledelayedexpansion

set SCRIPT_DIR=%~dp0

if not "%~1"=="" (
    set KSP_DIR=%~1
    goto :check
)

set KSP_CANDIDATES=^
    "%ProgramFiles(x86)%\Steam\steamapps\common\Kerbal Space Program" ^
    "%ProgramFiles%\Steam\steamapps\common\Kerbal Space Program" ^
    "%LOCALAPPDATA%\Programs\Kerbal Space Program"

for %%C in (%KSP_CANDIDATES%) do (
    if exist "%%~C\Ships\Script" (
        set KSP_DIR=%%~C
        goto :check
    )
)

echo Error: KSP install not found. Pass the KSP directory as an argument:
echo   install.bat "C:\path\to\Kerbal Space Program"
exit /b 1

:check
if not exist "%KSP_DIR%\Ships\Script" (
    echo Error: Ships\Script not found in: %KSP_DIR%
    exit /b 1
)

set DEST=%KSP_DIR%\Ships\Script

if not exist "%DEST%\boot" mkdir "%DEST%\boot"

copy /y "%SCRIPT_DIR%*.ks" "%DEST%\" >nul
copy /y "%SCRIPT_DIR%boot\*.ks" "%DEST%\boot\" >nul

echo Installed kOS scripts to: %DEST%
