@echo off
rem Jonction graphique du poste au domaine. Copiez tout le dossier poste sur le PC.
rem Double-cliquez : Windows demande les droits administrateur.
start "" powershell.exe -NoProfile -ExecutionPolicy Bypass -STA -WindowStyle Hidden -File "%~dp0Join-Domain-GUI.ps1"
