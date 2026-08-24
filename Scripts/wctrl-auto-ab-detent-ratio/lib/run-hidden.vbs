' run-hidden.vbs - start a PowerShell script with no console window.
'
' Not something to double-click: it is the shim the DCS hook and
' launch-config-manager.cmd use. Named so it does not sit next to
' launch-config-manager.cmd looking like an alternative to it.
' Defaults to helper.ps1; pass a filename to launch something else.
' DCS's os.execute() would otherwise flash a cmd window on every mission start.
Option Explicit
Dim shell, fso, here, ps1, cmd, target
Set shell = CreateObject("WScript.Shell")
Set fso = CreateObject("Scripting.FileSystemObject")
here = fso.GetParentFolderName(WScript.ScriptFullName)
target = "helper.ps1"
If WScript.Arguments.Count > 0 Then target = WScript.Arguments(0)
ps1 = here & "\" & target
If Not fso.FileExists(ps1) Then WScript.Quit 1
cmd = "powershell.exe -NoProfile -NonInteractive -ExecutionPolicy Bypass -WindowStyle Hidden -File """ & ps1 & """"
' 0 = hidden window, False = do not wait
shell.Run cmd, 0, False
