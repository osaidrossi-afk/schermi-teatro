@echo off
title Ponte Resolume - slide sincronizzate
rem Fa cambiare le clip di Resolume insieme ai monitor dei palchetti. Si ferma chiudendo questa finestra.
rem -Sito: indirizzo dove sono pubblicate le pagine degli schermi. -Layer: layer di Resolume con le slide.
powershell -NoProfile -ExecutionPolicy Bypass -File "%~dp0ponte-resolume.ps1" -Sito "[DA COMPILARE: indirizzo delle pagine]" -Layer 1
pause
