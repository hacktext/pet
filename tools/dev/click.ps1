# DPI-safe click in physical pixels (the same space as shot.ps1).
# -Expect "r,g,b": the pixel AT the click point must match (+-6) or no click is sent.
# Usage: click.ps1 -X <px> -Y <px> [-Button left|right] [-Expect "r,g,b"]
param([Parameter(Mandatory)][int]$X, [Parameter(Mandatory)][int]$Y,
      [ValidateSet('left', 'right')][string]$Button = 'left', [string]$Expect)
Add-Type -AssemblyName System.Drawing
Add-Type @"
using System; using System.Runtime.InteropServices;
public static class Mouse {
  [DllImport("user32.dll")] public static extern bool SetProcessDPIAware();
  [DllImport("user32.dll")] public static extern bool SetCursorPos(int x, int y);
  [DllImport("user32.dll")] public static extern void mouse_event(uint f, uint dx, uint dy, uint d, UIntPtr e);
}
"@
[void][Mouse]::SetProcessDPIAware()
if ($Expect) {
  $want = $Expect.Split(',') | ForEach-Object { [int]$_ }
  $bmp = New-Object System.Drawing.Bitmap 1, 1
  $g = [System.Drawing.Graphics]::FromImage($bmp)
  $g.CopyFromScreen($X, $Y, 0, 0, $bmp.Size)
  $c = $bmp.GetPixel(0, 0); $g.Dispose(); $bmp.Dispose()
  if ([math]::Abs($c.R - $want[0]) -gt 6 -or [math]::Abs($c.G - $want[1]) -gt 6 -or [math]::Abs($c.B - $want[2]) -gt 6) {
    "GUARD FAILED at ($X,$Y): saw $($c.R),$($c.G),$($c.B), expected $Expect -- no click sent"; exit 1
  }
}
[void][Mouse]::SetCursorPos($X, $Y)
Start-Sleep -Milliseconds 80
if ($Button -eq 'right') { $down = 0x0008; $up = 0x0010 } else { $down = 0x0002; $up = 0x0004 }
[Mouse]::mouse_event($down, 0, 0, 0, [UIntPtr]::Zero)
Start-Sleep -Milliseconds 40
[Mouse]::mouse_event($up, 0, 0, 0, [UIntPtr]::Zero)
"$Button click at physical ($X,$Y)"
