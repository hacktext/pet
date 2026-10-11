@echo off
rem 双击启动 AI 桌宠（release 版）。
rem 源码比已编译的 aipet.exe 新（或还没编译过）就先 flutter build windows --release，再启动。
rem 想连本地服务端调试：在下面 AIPET_API_BASE 那行去掉 rem，改成本地地址。
chcp 65001 >nul
setlocal

set "ROOT=%~dp0"
set "APP=%ROOT%apps\aipet"
set "EXE=%APP%\build\windows\x64\runner\Release\aipet.exe"
set "FLUTTER=C:\Users\Administrator\code\envs\flutter\bin\flutter.bat"
rem set "AIPET_API_BASE=http://aipet.localhost:8089"

if not exist "%FLUTTER%" set "FLUTTER=flutter"

rem 软件没有防多开，两个进程会同时写 settings.json，所以已在运行就不再开
tasklist /FI "IMAGENAME eq aipet.exe" 2>nul | find /I "aipet.exe" >nul
if not errorlevel 1 (
    echo 桌宠已经在运行了，看看桌面或任务栏托盘。
    timeout /t 4 >nul
    exit /b 0
)

rem 比较源码最新修改时间和 aipet.exe 的时间
for /f %%R in ('powershell -NoProfile -ExecutionPolicy Bypass -Command ^
    "$exe = $env:EXE; if (-not (Test-Path $exe)) { 'build'; exit }" ^
    "$t = (Get-Item $exe).LastWriteTime;" ^
    "$dirs = 'apps\aipet\lib','apps\aipet\assets','apps\aipet\windows\runner','packages','native' | ForEach-Object { Join-Path $env:ROOT $_ };" ^
    "$skip = '\\(build|\.dart_tool|testdata|ephemeral)\\';" ^
    "$files = @(Get-Item (Join-Path $env:APP 'pubspec.yaml')) + @(Get-ChildItem $dirs -Recurse -File -ErrorAction SilentlyContinue | Where-Object { $_.FullName -notmatch $skip });" ^
    "if ($files | Where-Object { $_.LastWriteTime -gt $t } | Select-Object -First 1) { 'build' } else { 'ok' }"') do set "STATE=%%R"

if /I "%STATE%"=="build" (
    echo 源码有更新，正在编译 release 版，第一次大约要几分钟……
    pushd "%APP%"
    call "%FLUTTER%" build windows --release
    if errorlevel 1 (
        popd
        echo.
        echo 编译失败，错误信息见上面。
        pause
        exit /b 1
    )
    popd
)

if not exist "%EXE%" (
    echo 找不到 %EXE%
    pause
    exit /b 1
)

echo 正在启动桌宠……
start "" /D "%APP%\build\windows\x64\runner\Release" "%EXE%"
exit /b 0
