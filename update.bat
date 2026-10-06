@echo off
rem Downloads the latest craftbook files from GitHub into this folder.
echo Updating craftbook from github.com/Happyfists/Craftbook ...
powershell -NoProfile -ExecutionPolicy Bypass -Command "$ErrorActionPreference='Stop'; [Net.ServicePointManager]::SecurityProtocol='Tls12'; $u='https://raw.githubusercontent.com/Happyfists/Craftbook/main/'; foreach($f in 'craftbook.lua','recipes.lua','README.md'){ Invoke-WebRequest -UseBasicParsing ($u+$f) -OutFile (Join-Path '%~dp0' ($f+'.new')); Move-Item -Force (Join-Path '%~dp0' ($f+'.new')) (Join-Path '%~dp0' $f); Write-Host ('  updated ' + $f) }"
if errorlevel 1 (
  echo Update failed. Check your internet connection and try again.
) else (
  echo Done. In game type:  /addon reload craftbook
)
pause
