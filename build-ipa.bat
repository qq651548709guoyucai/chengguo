@echo off
title Build IPA
echo.
echo  ============================================
echo   Build IPA - cloud macOS build
echo  ============================================
echo.
echo  Step 1: open this URL and login GitHub:
echo  https://github.com/settings/tokens/new
echo.
echo  Step 2: check these 3 scopes:
echo    Contents (read and write)
echo    Actions (read and write)
echo    Metadata (read)
echo  Then click "Generate token" at the bottom.
echo.
set /p PAT=Paste your GitHub token here and press Enter: 
echo.
echo  Building... cloud compile takes 5-10 min. Keep this window open.
echo.
"C:\Users\Administrator\.workbuddy\binaries\python\versions\3.13.12\python.exe" "%~dp0build_ipa.py" %PAT%
echo.
pause
