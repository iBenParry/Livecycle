; Livecycle NSIS Installer Script
; Created by Ben Parry

!include "MUI2.nsh"
!include "FileFunc.nsh"

; App info
Name "Livecycle"
OutFile "E:\Livecycle\Installer\Livecycle-Setup-v1.0.0.exe"
InstallDir "$PROGRAMFILES64\Livecycle"
InstallDirRegKey HKLM "Software\Livecycle" "Install_Dir"
RequestExecutionLevel admin

; Version info
VIProductVersion "1.0.0.0"
VIAddVersionKey "ProductName" "Livecycle"
VIAddVersionKey "ProductVersion" "1.0.0"
VIAddVersionKey "CompanyName" "Ben Parry"
VIAddVersionKey "FileDescription" "Livecycle - Automated Wallpaper Manager"
VIAddVersionKey "FileVersion" "1.0.0"
VIAddVersionKey "LegalCopyright" "Ben Parry"

; MUI Settings
!define MUI_ABORTWARNING
!define MUI_ICON "${NSISDIR}\Contrib\Graphics\Icons\modern-install.ico"
!define MUI_UNICON "${NSISDIR}\Contrib\Graphics\Icons\modern-uninstall.ico"
!define MUI_WELCOMEPAGE_TITLE "Welcome to Livecycle Setup"
!define MUI_WELCOMEPAGE_TEXT "This will install Livecycle v1.0.0 on your computer.$\r$\n$\r$\nLivecycle is an Automated Wallpaper Manager that changes your desktop wallpaper based on time of day or weather.$\r$\n$\r$\nClick Next to continue."
!define MUI_FINISHPAGE_RUN "$INSTDIR\Livecycle.exe"
!define MUI_FINISHPAGE_RUN_TEXT "Launch Livecycle"

; Pages
!insertmacro MUI_PAGE_WELCOME
!insertmacro MUI_PAGE_DIRECTORY
!insertmacro MUI_PAGE_INSTFILES
!insertmacro MUI_PAGE_FINISH

!insertmacro MUI_UNPAGE_CONFIRM
!insertmacro MUI_UNPAGE_INSTFILES

!insertmacro MUI_LANGUAGE "English"

; Installer
Section "Livecycle" SecMain
    SectionIn RO
    SetOutPath "$INSTDIR"
    File "E:\Livecycle\Livecycle\Livecycle.exe"

    ; Write registry keys
    WriteRegStr HKLM "Software\Livecycle" "Install_Dir" "$INSTDIR"
    WriteRegStr HKLM "Software\Microsoft\Windows\CurrentVersion\Uninstall\Livecycle" "DisplayName" "Livecycle"
    WriteRegStr HKLM "Software\Microsoft\Windows\CurrentVersion\Uninstall\Livecycle" "DisplayVersion" "1.0.0"
    WriteRegStr HKLM "Software\Microsoft\Windows\CurrentVersion\Uninstall\Livecycle" "Publisher" "Ben Parry"
    WriteRegStr HKLM "Software\Microsoft\Windows\CurrentVersion\Uninstall\Livecycle" "UninstallString" '"$INSTDIR\Uninstall.exe"'
    WriteRegStr HKLM "Software\Microsoft\Windows\CurrentVersion\Uninstall\Livecycle" "DisplayIcon" "$INSTDIR\Livecycle.exe"
    WriteRegStr HKLM "Software\Microsoft\Windows\CurrentVersion\Uninstall\Livecycle" "URLInfoAbout" "https://github.com/b3npa/Livecycle"
    WriteRegDWORD HKLM "Software\Microsoft\Windows\CurrentVersion\Uninstall\Livecycle" "NoModify" 1
    WriteRegDWORD HKLM "Software\Microsoft\Windows\CurrentVersion\Uninstall\Livecycle" "NoRepair" 1

    ; Create uninstaller
    WriteUninstaller "$INSTDIR\Uninstall.exe"

    ; Start Menu shortcut
    CreateDirectory "$SMPROGRAMS\Livecycle"
    CreateShortcut "$SMPROGRAMS\Livecycle\Livecycle.lnk" "$INSTDIR\Livecycle.exe"
    CreateShortcut "$SMPROGRAMS\Livecycle\Uninstall Livecycle.lnk" "$INSTDIR\Uninstall.exe"

    ; Desktop shortcut (optional - ask user)
    MessageBox MB_YESNO "Would you like a desktop shortcut?" IDNO NoDesktop
        CreateShortcut "$DESKTOP\Livecycle.lnk" "$INSTDIR\Livecycle.exe"
    NoDesktop:

SectionEnd

; Check for Lively after install
Section -Post
    IfFileExists "$LOCALAPPDATA\Programs\Lively Wallpaper\Lively.exe" LivelyFound
    IfFileExists "$PROGRAMFILES64\Lively Wallpaper\Lively.exe" LivelyFound
        MessageBox MB_YESNO "Livecycle requires Lively Wallpaper to display wallpapers.$\r$\n$\r$\nWould you like to open the Lively download page now?" IDNO NoLively
            ExecShell "open" "https://rocksdanister.github.io/lively/"
        NoLively:
        Goto LivelyDone
    LivelyFound:
    LivelyDone:
SectionEnd

; Uninstaller
Section "Uninstall"
    Delete "$INSTDIR\Livecycle.exe"
    Delete "$INSTDIR\Uninstall.exe"
    RMDir "$INSTDIR"

    Delete "$SMPROGRAMS\Livecycle\Livecycle.lnk"
    Delete "$SMPROGRAMS\Livecycle\Uninstall Livecycle.lnk"
    RMDir "$SMPROGRAMS\Livecycle"
    Delete "$DESKTOP\Livecycle.lnk"

    DeleteRegKey HKLM "Software\Microsoft\Windows\CurrentVersion\Uninstall\Livecycle"
    DeleteRegKey HKLM "Software\Livecycle"

    MessageBox MB_YESNO "Would you like to remove your Livecycle data (wallpapers, config, saved settings)?" IDNO NoData
        RMDir /r "$APPDATA\Livecycle"
    NoData:
SectionEnd
