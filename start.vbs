' ============================================================
'  鼠标坐标悬浮窗 - 静默启动器（不弹任何终端窗口）
'  双击本文件即可启动；退出请右键悬浮窗
' ============================================================
Option Explicit

Dim oShell, sDir, sScript, sCmd
Set oShell = CreateObject("WScript.Shell")

sDir = Left(WScript.ScriptFullName, InStrRev(WScript.ScriptFullName, "\"))
sScript = sDir & "mouse_coords.ps1"

sCmd = "powershell.exe -NoProfile -NonInteractive -ExecutionPolicy Bypass -WindowStyle Hidden -File """ & sScript & """"

' 0 = 隐藏窗口, False = 不等待返回
oShell.Run sCmd, 0, False

Set oShell = Nothing
