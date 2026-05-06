!macro NSIS_HOOK_POSTINSTALL
  DetailPrint "Running HyperSearch prerequisite setup..."
  nsExec::ExecToLog 'powershell.exe -NoProfile -ExecutionPolicy Bypass -File "$INSTDIR\installer\windows\HyperSearchPrereqSetup.ps1" -InstallDir "$INSTDIR" -MediaDir "$EXEDIR"'
!macroend
