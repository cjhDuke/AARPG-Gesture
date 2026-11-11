@echo off
rem 单独运行识别端（带调试窗口）。优先用装了 OpenCV 的 conda 环境，找不到再用 PATH 里的 python。
set "PY=C:\Users\DukeChen\miniconda3\envs\ai312\python.exe"
if not exist "%PY%" set "PY=python"
"%PY%" "%~dp0main.py" %*
if errorlevel 1 pause
