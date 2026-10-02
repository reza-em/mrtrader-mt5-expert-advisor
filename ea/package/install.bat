@echo off
chcp 65001 >nul
title MRTRADER installer
echo.
echo  MRTRADER  -  نصب ربات روی متاتریدر ۵
echo  =====================================
echo.

set "SRC=%~dp0MRTRADER.mq5"
if not exist "%SRC%" (
  echo فایل MRTRADER.mq5 کنار این نصب‌کننده نیست.
  pause
  exit /b 1
)

set "BASE=%APPDATA%\MetaQuotes\Terminal"
if not exist "%BASE%" (
  echo متاتریدر ۵ پیدا نشد.
  echo اول متاتریدر آلپاری را نصب و یک‌بار باز کن، بعد دوباره install.bat را بزن.
  echo دانلود: https://alpari.com
  pause
  exit /b 1
)

set FOUND=0
for /d %%D in ("%BASE%\*") do (
  if exist "%%D\MQL5\Experts" (
    copy /Y "%SRC%" "%%D\MQL5\Experts\MRTRADER.mq5" >nul
    echo کپی شد: %%D\MQL5\Experts\MRTRADER.mq5
    set FOUND=1
  )
)

if "%FOUND%"=="0" (
  echo پوشه Experts پیدا نشد. یک‌بار متاتریدر را باز کن و ببند، بعد دوباره نصب کن.
  pause
  exit /b 1
)

echo.
echo تمام.
echo.
echo مراحل داخل متاتریدر:
echo  1. MetaEditor را باز کن  ^(F4^)
echo  2. Experts \ MRTRADER.mq5 را Compile کن  ^(F7^)
echo  3. Tools - Options - Expert Advisors
echo     Allow algorithmic trading
echo     Allow WebRequest و این آدرس را اضافه کن:
echo     https://nfs.faireconomy.media
echo  4. AutoTrading را روشن کن
echo  5. ربات را روی چارت XAUUSD H1 بکش
echo.
pause
