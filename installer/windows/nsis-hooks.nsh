!macro NSIS_HOOK_POSTINSTALL
  DetailPrint "Running HyperSearch Installation Wizard..."
  ${If} ${FileExists} "$EXEDIR\hypersearch-install-automation.json"
    nsExec::ExecToLog 'powershell.exe -NoProfile -Sta -ExecutionPolicy Bypass -File "$INSTDIR\installer\windows\HyperSearchPrereqSetup.ps1" -InstallDir "$INSTDIR" -MediaDir "$EXEDIR" -Automated -ConfigPath "$EXEDIR\hypersearch-install-automation.json"'
  ${Else}
    nsExec::ExecToLog 'powershell.exe -NoProfile -Sta -ExecutionPolicy Bypass -File "$INSTDIR\installer\windows\HyperSearchPrereqSetup.ps1" -InstallDir "$INSTDIR" -MediaDir "$EXEDIR"'
  ${EndIf}
!macroend
