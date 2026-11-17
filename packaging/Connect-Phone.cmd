@echo off
chcp 65001 >nul
"%~dp0KeyboardControl.exe" --lan
if errorlevel 1 pause
