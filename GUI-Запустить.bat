@echo off
REM CI-3-fix: раньше указывал на несуществующий GUI-demo.py (который ещё и в .gitignore).
REM Теперь запускает реальный python -m xrayebator_gui.
cd /d "%~dp0"
if not exist gui\.venv\Scripts\python.exe (
  echo Python venv not found: gui\.venv 1>&2
  echo Run: python -m venv gui\.venv ^&^& gui\.venv\Scripts\pip install -e gui
  exit /b 1
)
echo === Xrayebator GUI ===
echo.
.\gui\.venv\Scripts\python.exe -m xrayebator_gui
exit /b %ERRORLEVEL%
