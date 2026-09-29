@echo off
REM ===========================================================================
REM run.bat - one-command setup + launch for the Lyrics app on Windows.
REM
REM On a fresh Windows machine this will, as needed:
REM   1. Install Python 3.12 and ffmpeg via winget (built into Windows 10/11).
REM   2. Create/refresh a virtual environment and install app dependencies.
REM   3. Launch the Lyrics app.
REM
REM Safe to run repeatedly. Override the interpreter with:
REM   set PYTHON=C:\path\to\python.exe && run.bat
REM ===========================================================================
setlocal EnableDelayedExpansion
cd /d "%~dp0"

REM --- Locate winget (used to install prerequisites) ------------------------
where winget >nul 2>nul
if errorlevel 1 (
  echo WARNING: winget was not found. Cannot auto-install prerequisites.
  echo   Install "App Installer" from the Microsoft Store, or install manually:
  echo     Python 3.12: https://www.python.org/downloads/
  echo     ffmpeg:      https://www.gyan.dev/ffmpeg/builds/
  set HAVE_WINGET=0
) else (
  set HAVE_WINGET=1
)

REM --- Ensure Python -------------------------------------------------------
set PY=%PYTHON%
if "%PY%"=="" set PY=python

%PY% --version >nul 2>nul
if errorlevel 1 (
  if "%HAVE_WINGET%"=="1" (
    echo ==^> Installing Python 3.12 via winget...
    winget install -e --id Python.Python.3.12 --accept-source-agreements --accept-package-agreements
    set PY=python
  ) else (
    echo ERROR: Python is not installed and winget is unavailable. Please install Python 3.12 manually.
    exit /b 1
  )
) else (
  echo ==^> Python found.
)

REM --- Ensure ffmpeg -------------------------------------------------------
where ffmpeg >nul 2>nul
if errorlevel 1 (
  if "%HAVE_WINGET%"=="1" (
    echo ==^> Installing ffmpeg via winget...
    winget install -e --id Gyan.FFmpeg --accept-source-agreements --accept-package-agreements
    echo NOTE: You may need to open a NEW terminal so ffmpeg is on PATH, then re-run.
  ) else (
    echo WARNING: ffmpeg not found and winget unavailable. Transcription will fail until installed.
  )
) else (
  echo ==^> ffmpeg found.
)

REM --- Virtual environment + dependencies ----------------------------------
if not exist ".venv" (
  echo ==^> Creating virtual environment (.venv)...
  %PY% -m venv .venv
)

call .venv\Scripts\activate.bat

echo ==^> Installing/upgrading Python dependencies...
python -m pip install --upgrade pip >nul
REM openai-whisper's build imports pkg_resources, which setuptools^>=81 removed.
python -m pip install --upgrade "setuptools>=68,<81" wheel >nul
python -m pip install --upgrade --no-build-isolation -r requirements.txt

echo ==^> Launching Lyrics...
python app.py

endlocal
