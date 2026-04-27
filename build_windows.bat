@echo off
echo Building AuthVault API for Windows...
cd /d %~dp0api
go mod tidy
go build -ldflags="-s -w" -o ..\build\authvault-api.exe .
echo.
echo Building Flutter app for Windows...
cd /d %~dp0app
flutter pub get
flutter build windows --release
xcopy /E /Y build\windows\x64\runner\Release\* ..\build\windows-app\
echo.
echo ============================================
echo  Done!
echo  API:     build\authvault-api.exe
echo  App:     build\windows-app\
echo ============================================
