# Screenshot of a desktop tool's window (ModelSim, Quartus...) for lesson slides: start it, wait, capture one window.
#
#   powershell -NoProfile -ExecutionPolicy Bypass -File scripts\gui_shot.ps1 -Exe <tool.exe> [-Args "a b"]
#       -WorkDir <dir> -Out <file.png> [-Title "ModelSim*"] [-Wait 25] [-W 1500 -H 900] [-Settle 3]
#
# -Title picks the window by its title (wildcards); -W 0 keeps the window's own size (let the tool size itself:
# ModelSim is Tk, a do-file can run "wm geometry [winfo toplevel [view wave]] 1300x430+0+0").
# PrintWindow captures the window even when other windows cover it. The tool is closed afterwards.
# ModelSim example (the do-file runs the commands, then sizes and zooms the wave window):
#   -Exe C:\intelFPGA_lite\17.1\modelsim_ase\win32aloem\vsim.exe -Args "-do C:\tmp\shot.do" -Title "Wave*" -W 0
param(
  [string]$Exe = "C:\intelFPGA_lite\17.1\modelsim_ase\win32aloem\vsim.exe",
  [string]$Args = "",
  [string]$WorkDir = ".",
  [string]$Out,
  [string]$Title = "ModelSim*",
  [int]$Wait = 25,
  [int]$W = 1500, [int]$H = 900,
  [int]$Settle = 3
)
Add-Type -AssemblyName System.Drawing
Add-Type @"
using System; using System.Text; using System.Runtime.InteropServices;
public class GuiShot {
  public delegate bool Cb(IntPtr h, IntPtr l);
  [DllImport("user32.dll")] public static extern bool EnumWindows(Cb cb, IntPtr l);
  [DllImport("user32.dll")] public static extern int GetWindowText(IntPtr h, StringBuilder s, int n);
  [DllImport("user32.dll")] public static extern bool IsWindowVisible(IntPtr h);
  [DllImport("user32.dll")] public static extern bool SetForegroundWindow(IntPtr h);
  [DllImport("user32.dll")] public static extern bool ShowWindow(IntPtr h, int c);
  [DllImport("user32.dll")] public static extern bool MoveWindow(IntPtr h, int x, int y, int w, int hh, bool r);
  [DllImport("user32.dll")] public static extern bool GetWindowRect(IntPtr h, out RECT r);
  [DllImport("user32.dll")] public static extern bool PrintWindow(IntPtr h, IntPtr dc, uint f);
  public struct RECT { public int Left, Top, Right, Bottom; }
}
"@
function Find-Window($pattern) {
  $script:found = [IntPtr]::Zero
  [GuiShot]::EnumWindows({ param($hw, $l)
    $sb = New-Object System.Text.StringBuilder 256
    [GuiShot]::GetWindowText($hw, $sb, 256) | Out-Null
    if ([GuiShot]::IsWindowVisible($hw) -and $sb.ToString() -like $pattern) { $script:found = $hw; return $false }
    return $true }, [IntPtr]::Zero) | Out-Null
  return $script:found
}
if ($Args) { $p = Start-Process -FilePath $Exe -ArgumentList $Args -WorkingDirectory $WorkDir -PassThru }
else       { $p = Start-Process -FilePath $Exe -WorkingDirectory $WorkDir -PassThru }
Start-Sleep -Seconds $Wait
$h = Find-Window $Title
if ($h -eq [IntPtr]::Zero) { Write-Output "FAIL: no window like '$Title'"; Stop-Process -Id $p.Id -Force -ErrorAction SilentlyContinue; exit 1 }
[GuiShot]::ShowWindow($h, 9) | Out-Null
if ($W -gt 0) { [GuiShot]::MoveWindow($h, 0, 0, $W, $H, $true) | Out-Null }
[GuiShot]::SetForegroundWindow($h) | Out-Null
Start-Sleep -Seconds $Settle
$r = New-Object GuiShot+RECT
[GuiShot]::GetWindowRect($h, [ref]$r) | Out-Null
$bmp = New-Object System.Drawing.Bitmap ($r.Right - $r.Left), ($r.Bottom - $r.Top)
$g = [System.Drawing.Graphics]::FromImage($bmp)
$dc = $g.GetHdc()
[GuiShot]::PrintWindow($h, $dc, 2) | Out-Null       # PW_RENDERFULLCONTENT
$g.ReleaseHdc($dc)
$bmp.Save($Out, [System.Drawing.Imaging.ImageFormat]::Png)
Write-Output "OK: $Out $($bmp.Width)x$($bmp.Height)"
Stop-Process -Id $p.Id -Force -ErrorAction SilentlyContinue
Get-Process vish, vsimk -ErrorAction SilentlyContinue | Stop-Process -Force
