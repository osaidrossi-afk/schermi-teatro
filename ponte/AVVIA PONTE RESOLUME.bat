@echo off
title Ponte Resolume - slide sincronizzate
rem Fa cambiare le clip di Resolume insieme ai monitor dei palchetti. Si ferma chiudendo questa finestra.
rem Al primo avvio chiede su quale layer di Resolume sono le slide.
powershell -NoProfile -ExecutionPolicy Bypass -File "%~dp0ponte-resolume.ps1" -Sito "https://osaidrossi-afk.github.io/schermi-teatro"
pause
