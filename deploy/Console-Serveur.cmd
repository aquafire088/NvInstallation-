@echo off
rem Console graphique du serveur (configuration, deploiement, administration).
rem Double-cliquez : Windows demande les droits administrateur.
start "" powershell.exe -NoProfile -ExecutionPolicy Bypass -STA -WindowStyle Hidden -File "%~dp0Console.ps1"
