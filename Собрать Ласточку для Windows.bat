@echo off
chcp 65001 >nul
cd /d "%~dp0"
title Сборка Ласточки для Windows
where node >nul 2>nul
if errorlevel 1 (
  echo Не найден Node.js. Установите LTS-версию с https://nodejs.org и запустите снова.
  pause
  exit /b 1
)
rem Сначала официальные серверы (GitHub), при ошибке — зеркало npmmirror.
rem Electron в любом случае сверяется с контрольными суммами из реестра npm.
call :build
if errorlevel 1 (
  echo.
  echo Официальные серверы недоступны, пробую через зеркало npmmirror...
  set "ELECTRON_MIRROR=https://npmmirror.com/mirrors/electron/"
  set "ELECTRON_BUILDER_BINARIES_MIRROR=https://npmmirror.com/mirrors/electron-builder-binaries/"
  call :build
  if errorlevel 1 goto fail
)
echo.
echo Готово! Файлы в папке release
start "" "%~dp0release"
pause
exit /b 0
:build
echo ^> Устанавливаю зависимости...
call npm install || exit /b 1
echo ^> Обновляю Electron до версии с последними исправлениями безопасности...
call npm run harden || exit /b 1
echo ^> Собираю установщик и портативную версию...
call npm run dist:win || exit /b 1
exit /b 0
:fail
echo.
echo Ошибка сборки. Пришлите текст выше.
pause
exit /b 1
