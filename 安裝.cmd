@echo off
rem Double-click to install: asks for Administrator (UAC), then runs install.ps1 in a window that stays open.
powershell -NoProfile -Command "Start-Process powershell -Verb RunAs -ArgumentList '-NoProfile -NoExit -ExecutionPolicy Bypass -File \"%~dp0install.ps1\"'"
