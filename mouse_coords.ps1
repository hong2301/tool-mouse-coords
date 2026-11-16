<#
.SYNOPSIS
    鼠标坐标悬浮窗 · 像素调试风格
    5x7 点阵字自绘 + CRT 扫描线 + 荧光青，实时显示鼠标物理像素坐标

.DESCRIPTION
    为屏幕点位配置场景设计的调试小工具。悬浮窗跟随鼠标右下方，实时显示 X / Y。
    坐标取物理像素（已置 DPI 感知），与点位表口径一致，可直接抄录。

    交互：
      双击      复制 "X,Y" 到剪贴板（数字闪黄反馈）
      右键      退出
      拖动      固定到拖到的位置（跟随模式自动解除）

.PARAMETER Offset
    相对鼠标的偏移像素，默认 22

.PARAMETER Opacity
    不透明度 0~1，默认 0.92

.PARAMETER Scale
    像素点放大倍数（1=5x7 原始大小，2=10x14，3=15x21），默认 3

.PARAMETER Green
    荧光绿配色（默认青色）

.EXAMPLE
    start.vbs
    powershell -ExecutionPolicy Bypass -File mouse_coords.ps1 -Scale 4 -Green
#>
param(
    [int]$Offset = 22,
    [double]$Opacity = 0.92,
    [int]$Scale = 3,
    [switch]$Green,
    [switch]$Follow
)

$ErrorActionPreference = 'Stop'

# ---------------- 单实例保护 ----------------
# 重复双击 start.vbs 时，后来的实例直接静默退出，避免多个悬浮窗叠在一起
$script:mutex = New-Object System.Threading.Mutex($false, 'Global\MouseCoordsPixelHUD')
$gotMutex = $false
try { $gotMutex = $script:mutex.WaitOne(0, $false) } catch { $gotMutex = $false }
if (-not $gotMutex) { return }

Add-Type -AssemblyName System.Windows.Forms
Add-Type -AssemblyName System.Drawing

Add-Type @'
using System;
using System.Runtime.InteropServices;
public class DpiUtil {
    [DllImport("user32.dll")] public static extern bool SetProcessDPIAware();
}
'@
[DpiUtil]::SetProcessDPIAware() | Out-Null

# 与采集器 computer.py 的 mouse_click 完全等价的原语：SetCursorPos + mouse_event
Add-Type @'
using System;
using System.Runtime.InteropServices;
public class InputSim {
    [DllImport("user32.dll")] public static extern bool SetCursorPos(int x, int y);
    [DllImport("user32.dll")] public static extern void mouse_event(uint dwFlags, uint dx, uint dy, uint dwData, IntPtr dwExtraInfo);
    [DllImport("user32.dll")] public static extern short GetAsyncKeyState(int vKey);
    public const uint LEFTDOWN = 0x0002;
    public const uint LEFTUP   = 0x0004;
}
'@

# ---------------- 5x7 点阵字库 ----------------
$GLYPHS = @{
    '0' = @('01110','10001','10011','10101','11001','10001','01110')
    '1' = @('00100','01100','00100','00100','00100','00100','01110')
    '2' = @('01110','10001','00001','00110','01000','10000','11111')
    '3' = @('11111','00010','00100','00010','00001','10001','01110')
    '4' = @('00010','00110','01010','10010','11111','00010','00010')
    '5' = @('11111','10000','11110','00001','00001','10001','01110')
    '6' = @('00110','01000','10000','11110','10001','10001','01110')
    '7' = @('11111','00001','00010','00100','01000','01000','01000')
    '8' = @('01110','10001','10001','01110','10001','10001','01110')
    '9' = @('01110','10001','10001','01111','00001','00010','01100')
    'X' = @('10001','10001','01010','00100','01010','10001','10001')
    'Y' = @('10001','10001','01010','00100','00100','00100','00100')
    ',' = @('00000','00000','00000','00000','00110','00100','01000')
    ' ' = @('00000','00000','00000','00000','00000','00000','00000')
    '-' = @('00000','00000','00000','11111','00000','00000','00000')
    'O' = @('01110','10001','10001','10001','10001','10001','01110')
    'K' = @('10001','10010','10100','11000','10100','10010','10001')
}

$PX     = [Math]::Max(1, $Scale)
$CELL_W = 5 * $PX
$CELL_H = 7 * $PX
$GAP    = 1 * $PX        # 字距
$PADX   = 14
$PADY   = 13

$CLR_BG     = [System.Drawing.Color]::FromArgb(8, 9, 12)
$CLR_MAIN   = if ($Green) { [System.Drawing.Color]::FromArgb(57, 255, 136) } else { [System.Drawing.Color]::FromArgb(53, 240, 255) }
$CLR_DIM    = [System.Drawing.Color]::FromArgb(28, 62, 74)
$CLR_FLASH  = [System.Drawing.Color]::FromArgb(255, 224, 102)
$CLR_FRAME  = [System.Drawing.Color]::FromArgb(38, 48, 66)
$CLR_FRAME2 = [System.Drawing.Color]::FromArgb(90, 130, 170)

$W = $PADX * 2 + (14 * ($CELL_W + $GAP)) + 6   # 预留 14 字符宽
$H = $PADY * 2 + $CELL_H + 6

$form = New-Object System.Windows.Forms.Form
$form.FormBorderStyle = [System.Windows.Forms.FormBorderStyle]::None
$form.StartPosition = 'Manual'
$form.TopMost = $true
$form.ShowInTaskbar = $false
$form.BackColor = $CLR_BG
$form.Opacity = $Opacity
$form.Width = $W
$form.Height = $H
$form.Cursor = [System.Windows.Forms.Cursors]::Cross
# DoubleBuffered 是 protected 成员，用反射设置避免闪烁
$bf = [System.Reflection.BindingFlags]'Instance,NonPublic'
$dp = [System.Windows.Forms.Control].GetProperty('DoubleBuffered', $bf)
if ($dp) { $dp.SetValue($form, $true, $null) }

$script:txt = 'X 0  Y 0'
$script:flashUntil = [DateTime]::MinValue
$script:lastX = $null
$script:lastY = $null
$script:fixedMode = $false

function Draw-Text($g, $text, $x, $y, $brush) {
    $cx = $x
    foreach ($ch in $text.ToCharArray()) {
        $rows = $GLYPHS[[string]$ch]
        if ($rows) {
            for ($r = 0; $r -lt 7; $r++) {
                $row = $rows[$r]
                for ($c = 0; $c -lt 5; $c++) {
                    if ($row[$c] -eq '1') {
                        $g.FillRectangle($brush, ($cx + $c * $PX), ($y + $r * $PX), $PX, $PX)
                    }
                }
            }
        }
        $cx += $CELL_W + $GAP
    }
}

$brushMain  = New-Object System.Drawing.SolidBrush($CLR_MAIN)
$brushDim   = New-Object System.Drawing.SolidBrush($CLR_DIM)
$brushFlash = New-Object System.Drawing.SolidBrush($CLR_FLASH)
$penFrame   = New-Object System.Drawing.Pen($CLR_FRAME, 1)
$penFrame2  = New-Object System.Drawing.Pen($CLR_FRAME2, 1)

$form.Add_Paint({
    param($s, $e)
    $g = $e.Graphics
    $g.SmoothingMode = [System.Drawing.Drawing2D.SmoothingMode]::None
    $g.InterpolationMode = [System.Drawing.Drawing2D.InterpolationMode]::NearestNeighbor
    $g.PixelOffsetMode = [System.Drawing.Drawing2D.PixelOffsetMode]::Half
    $g.Clear($CLR_BG)

    # 外框：双层（暗边 + 亮内线），营造 CRT 边缘
    $g.DrawRectangle($penFrame, 0, 0, $W - 1, $H - 1)
    $g.DrawRectangle($penFrame2, 2, 2, $W - 5, $H - 5)
    # 四角刻度
    $g.DrawLine($penFrame2, 2, 2, 8, 2)
    $g.DrawLine($penFrame2, 2, 2, 2, 8)
    $g.DrawLine($penFrame2, $W - 9, 2, $W - 3, 2)
    $g.DrawLine($penFrame2, $W - 3, 2, $W - 3, 8)
    $g.DrawLine($penFrame2, 2, $H - 9, 2, $H - 3)
    $g.DrawLine($penFrame2, 2, $H - 3, 8, $H - 3)
    $g.DrawLine($penFrame2, $W - 9, $H - 3, $W - 3, $H - 3)
    $g.DrawLine($penFrame2, $W - 3, $H - 9, $W - 3, $H - 3)

    # 点阵文字（闪烁期用黄色）
    $brush = if ([DateTime]::Now -lt $script:flashUntil) { $brushFlash } else { $brushMain }
    Draw-Text $g $script:txt ($PADX + 4) ($PADY + 3) $brush

    # CRT 扫描线（每 3px 一条淡暗线）
    $scan = New-Object System.Drawing.SolidBrush([System.Drawing.Color]::FromArgb(26, 0, 0, 0))
    for ($y = 4; $y -lt ($H - 4); $y += 3) {
        $g.FillRectangle($scan, 4, $y, $W - 8, 1)
    }
    $scan.Dispose()

    # 左上运行指示方块（呼吸）
    $blinkOn = ([DateTime]::Now.Millisecond % 1000) -lt 700
    if ($blinkOn) {
        $g.FillRectangle($brushMain, 6, 6, 3, 3)
    }
})

$script:f8prev = $false
$script:f9prev = $false

# 用采集器 computer.mouse_click 的同款实现点一下当前鼠标位置
function Try-ClickHere {
    $p = [System.Windows.Forms.Cursor]::Position
    [InputSim]::SetCursorPos($p.X, $p.Y) | Out-Null
    Start-Sleep -Milliseconds 50
    [InputSim]::mouse_event([InputSim]::LEFTDOWN, 0, 0, 0, [IntPtr]::Zero)
    Start-Sleep -Milliseconds 80                      # 同项目 hold_ms 默认 80
    [InputSim]::mouse_event([InputSim]::LEFTUP, 0, 0, 0, [IntPtr]::Zero)
    $script:flashUntil = [DateTime]::Now.AddMilliseconds(420)
    $form.Invalidate()
}

function Copy-Coords {
    $p = [System.Windows.Forms.Cursor]::Position
    [System.Windows.Forms.Clipboard]::SetText("$($p.X),$($p.Y)")
    $script:flashUntil = [DateTime]::Now.AddMilliseconds(320)
    $form.Invalidate()
}

# 静止判定：鼠标停下 160ms 后窗口才跟随过去。
# 跟随中的窗口移动会干扰 SetCursorPos 的连续调用（实测会让采集器点击落点跑偏），
# 所以「移动时不跟随、停下才跟随」，既满足看坐标的需求，也不干扰点击。
$script:stillTicks = 0
$script:STILL_NEED = 8        # 8 x 40ms = 320ms 静止（仅 -Follow 模式使用）
$script:followMode = [bool]$Follow

$timer = New-Object System.Windows.Forms.Timer
$timer.Interval = 40
$timer.Add_Tick({
    $p = [System.Windows.Forms.Cursor]::Position
    $changed = $false
    if ($p.X -ne $script:lastX -or $p.Y -ne $script:lastY) {
        $script:lastX = $p.X
        $script:lastY = $p.Y
        $script:txt = "X $($p.X)  Y $($p.Y)"
        $changed = $true
        $script:stillTicks = 0
    } else {
        if ($script:stillTicks -lt 1000) { $script:stillTicks++ }
    }
    # 跟随仅在 -Follow 显式开启时生效（默认不跟随：窗口移动实测会干扰外部程序的光标定位）
    if ($script:followMode -and -not $script:fixedMode -and $script:stillTicks -ge $script:STILL_NEED) {
        $wa = [System.Windows.Forms.Screen]::FromPoint($p).WorkingArea
        $nx = $p.X + $Offset
        $ny = $p.Y + $Offset
        if (($nx + $W) -gt ($wa.X + $wa.Width))  { $nx = $p.X - $W - $Offset }
        if (($ny + $H) -gt ($wa.Y + $wa.Height)) { $ny = $p.Y - $H - $Offset }
        $np = New-Object System.Drawing.Point($nx, $ny)
        if ($form.Location -ne $np) { $form.Location = $np }
    }
    # ---- F8: 用采集器同款 API 在「当前坐标」真实点一次（验证点位是否点得准） ----
    $f8 = ([InputSim]::GetAsyncKeyState(0x77) -band 0x8000) -ne 0
    if ($f8 -and -not $script:f8prev) {
        Try-ClickHere
    }
    $script:f8prev = $f8

    # ---- F9: 复制当前坐标 ----
    $f9 = ([InputSim]::GetAsyncKeyState(0x78) -band 0x8000) -ne 0
    if ($f9 -and -not $script:f9prev) {
        Copy-Coords
    }
    $script:f9prev = $f9

    if ($changed -or [DateTime]::Now -lt $script:flashUntil) { $form.Invalidate() }
})

# 双击复制
$form.Add_MouseDoubleClick({
    $p = [System.Windows.Forms.Cursor]::Position
    [System.Windows.Forms.Clipboard]::SetText("$($p.X),$($p.Y)")
    $script:flashUntil = [DateTime]::Now.AddMilliseconds(320)
    $form.Invalidate()
})

# 右键退出
$form.Add_MouseUp({
    param($s, $e)
    if ($e.Button -eq [System.Windows.Forms.MouseButtons]::Right) {
        $timer.Stop()
        $form.Close()
    }
})

# 拖动 -> 固定
$drag = @{ on = $false; ox = 0; oy = 0 }
$form.Add_MouseDown({
    param($s, $e)
    if ($e.Button -eq [System.Windows.Forms.MouseButtons]::Left) {
        $drag.on = $true; $drag.ox = $e.X; $drag.oy = $e.Y
    }
})
$form.Add_MouseMove({
    param($s, $e)
    if ($drag.on) {
        $script:fixedMode = $true
        $mp = [System.Windows.Forms.Cursor]::Position
        $form.Location = New-Object System.Drawing.Point(($mp.X - $drag.ox), ($mp.Y - $drag.oy))
    }
})
$form.Add_MouseUp({
    param($s, $e)
    if ($e.Button -eq [System.Windows.Forms.MouseButtons]::Left) { $drag.on = $false }
})

$form.Add_Shown({
    $p = [System.Windows.Forms.Cursor]::Position
    $script:lastX = $p.X
    $script:lastY = $p.Y
    $script:txt = "X $($p.X)  Y $($p.Y)"
    # 启动时放到鼠标右下方（贴边自动翻转），之后窗口位置固定，只更新数字
    $wa = [System.Windows.Forms.Screen]::FromPoint($p).WorkingArea
    $px = $p.X + $Offset
    $py = $p.Y + $Offset
    if (($px + $W) -gt ($wa.X + $wa.Width))  { $px = $p.X - $W - $Offset }
    if (($py + $H) -gt ($wa.Y + $wa.Height)) { $py = $p.Y - $H - $Offset }
    $form.Location = New-Object System.Drawing.Point($px, $py)
    $timer.Start()
})

[System.Windows.Forms.Application]::Run($form)
