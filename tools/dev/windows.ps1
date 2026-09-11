# List the top-level windows of a process, optionally post WM_CLOSE to one by
# exact title (same effect as clicking its X). ASCII only (PowerShell 5.1).
# DPI-aware: W/H are physical pixels, the same space as shot.ps1 / click.ps1.
# Usage: windows.ps1 [-Name aipet] [-CloseTitle "aipet"]
param([string]$Name = 'aipet', [string]$CloseTitle)

Add-Type @"
using System; using System.Runtime.InteropServices; using System.Text;
public static class TopWin {
  public delegate bool EnumProc(IntPtr h, IntPtr l);
  [StructLayout(LayoutKind.Sequential)] public struct RECT { public int L, T, R, B; }
  [DllImport("user32.dll")] public static extern bool EnumWindows(EnumProc f, IntPtr l);
  [DllImport("user32.dll")] public static extern uint GetWindowThreadProcessId(IntPtr h, out uint pid);
  [DllImport("user32.dll", CharSet = CharSet.Unicode)] public static extern int GetWindowText(IntPtr h, StringBuilder s, int n);
  [DllImport("user32.dll")] public static extern bool IsWindowVisible(IntPtr h);
  [DllImport("user32.dll")] public static extern bool GetWindowRect(IntPtr h, out RECT r);
  [DllImport("user32.dll")] public static extern bool PostMessage(IntPtr h, uint m, IntPtr w, IntPtr l);
  [DllImport("user32.dll")] public static extern bool SetProcessDPIAware();
}
"@
[void][TopWin]::SetProcessDPIAware()

$procIds = @(Get-Process $Name -ErrorAction SilentlyContinue | ForEach-Object { [uint32]$_.Id })
if ($procIds.Count -eq 0) { "no $Name process"; exit 0 }
$script:rows = @()
[void][TopWin]::EnumWindows({ param($h, $l)
  $p = [uint32]0
  [void][TopWin]::GetWindowThreadProcessId($h, [ref]$p)
  if ($procIds -contains $p) {
    $sb = New-Object System.Text.StringBuilder 256
    [void][TopWin]::GetWindowText($h, $sb, 256)
    $r = New-Object TopWin+RECT
    [void][TopWin]::GetWindowRect($h, [ref]$r)
    $script:rows += [pscustomobject]@{ Handle = $h; Title = $sb.ToString(); Visible = [TopWin]::IsWindowVisible($h); W = $r.R - $r.L; H = $r.B - $r.T }
  }
  return $true }, [IntPtr]::Zero)
$script:rows | Where-Object { $_.Title -ne '' } | ForEach-Object {
  $r = New-Object TopWin+RECT; [void][TopWin]::GetWindowRect($_.Handle, [ref]$r)
  $_ | Add-Member -NotePropertyName Rect -NotePropertyValue "$($r.L),$($r.T),$($r.R),$($r.B)" -PassThru
} | Format-Table Title, Visible, W, H, Rect -AutoSize | Out-String
if ($CloseTitle) {
  $t = $script:rows | Where-Object { $_.Title -eq $CloseTitle } | Select-Object -First 1
  if ($t) { [void][TopWin]::PostMessage($t.Handle, 0x0010, [IntPtr]::Zero, [IntPtr]::Zero); "posted WM_CLOSE to '$CloseTitle'" }
  else { "no window titled '$CloseTitle'" }
}
