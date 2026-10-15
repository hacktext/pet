; Aipet Windows 安装包（Inno Setup 6）。
; 先 flutter build windows --release，再：
;   "C:\Program Files (x86)\Inno Setup 6\ISCC.exe" installer\aipet.iss
; 产物：仓库根目录 dist\AipetSetup-<版本>.exe
;
; 按用户安装（不要管理员权限）：程序在 %LOCALAPPDATA%\Programs\Aipet，
; 用户数据在 %APPDATA%\com.aipet\aipet，卸载不删数据（重装后宠物、账号还在）。

#define AppName "Aipet 桌宠"
#define AppVersion "1.0.0"
#define AppExe "aipet.exe"
#define Release "..\build\windows\x64\runner\Release"
#define VcRedist "C:\Program Files (x86)\Microsoft Visual Studio\18\BuildTools\VC\Redist\MSVC\14.50.35710\x64\Microsoft.VC145.CRT"

[Setup]
; 固定不变：升级安装靠它认出是同一个软件。
AppId={{C8CB70F7-CA24-4B4C-84B8-B03A1360E83C}
AppName={#AppName}
AppVersion={#AppVersion}
AppVerName={#AppName} {#AppVersion}
AppPublisher=Aipet
VersionInfoVersion={#AppVersion}
DefaultDirName={localappdata}\Programs\Aipet
DefaultGroupName={#AppName}
DisableProgramGroupPage=yes
PrivilegesRequired=lowest
ArchitecturesAllowed=x64compatible
ArchitecturesInstallIn64BitMode=x64compatible
OutputDir=..\..\..\dist
OutputBaseFilename=AipetSetup-{#AppVersion}
SetupIconFile=..\windows\runner\resources\app_icon.ico
UninstallDisplayIcon={app}\{#AppExe}
Compression=lzma2/max
SolidCompression=yes
WizardStyle=modern
; 升级、卸载时桌宠在运行：用 Restart Manager 关掉它。
CloseApplications=yes
RestartApplications=no

[Languages]
Name: "chs"; MessagesFile: "compiler:Languages\ChineseSimplified.isl"

[Tasks]
Name: "desktopicon"; Description: "创建桌面快捷方式"; GroupDescription: "附加快捷方式："

[Files]
Source: "{#Release}\*"; DestDir: "{app}"; Excludes: ".built,native_assets.json"; Flags: ignoreversion recursesubdirs createallsubdirs
; VC++ 运行库放在程序旁边：没装过 VC++ 运行库的电脑也能直接运行。
Source: "{#VcRedist}\msvcp140.dll"; DestDir: "{app}"; Flags: ignoreversion
Source: "{#VcRedist}\msvcp140_1.dll"; DestDir: "{app}"; Flags: ignoreversion
Source: "{#VcRedist}\msvcp140_2.dll"; DestDir: "{app}"; Flags: ignoreversion
Source: "{#VcRedist}\vcruntime140.dll"; DestDir: "{app}"; Flags: ignoreversion
Source: "{#VcRedist}\vcruntime140_1.dll"; DestDir: "{app}"; Flags: ignoreversion
Source: "{#VcRedist}\concrt140.dll"; DestDir: "{app}"; Flags: ignoreversion

[Icons]
Name: "{group}\{#AppName}"; Filename: "{app}\{#AppExe}"
Name: "{group}\卸载 {#AppName}"; Filename: "{uninstallexe}"
Name: "{userdesktop}\{#AppName}"; Filename: "{app}\{#AppExe}"; Tasks: desktopicon

[Run]
Filename: "{app}\{#AppExe}"; Description: "立即启动 {#AppName}"; Flags: nowait postinstall skipifsilent
