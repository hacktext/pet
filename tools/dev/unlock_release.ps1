# Before a release build: a file in the Release folder that some aipet.exe
# still holds open -- the running pet, or the 0-thread leftover that
# Stop-Process cannot end (HANDOFF 0.5) -- makes the linker fail with LNK1104
# or the install step with "Permission denied". Windows lets a mapped exe or
# dll be renamed, so move each locked one aside as <name>.locked-<time>; the
# build then writes a fresh copy and the installer skips *.locked-* files.
# Old moved-aside files that nothing holds any more are deleted.
param([Parameter(Mandatory)] [string] $Release)

if (-not (Test-Path $Release)) { exit 0 }

Get-ChildItem $Release -Filter '*.locked-*' -File -ErrorAction SilentlyContinue |
    ForEach-Object { Remove-Item $_.FullName -Force -ErrorAction SilentlyContinue }

$stamp = Get-Date -Format 'yyyyMMdd-HHmmss'
foreach ($f in Get-ChildItem $Release -File | Where-Object { $_.Extension -in '.exe', '.dll' }) {
    try {
        [IO.File]::Open($f.FullName, 'Open', 'ReadWrite', 'None').Close()
    } catch {
        Rename-Item $f.FullName -NewName "$($f.Name).locked-$stamp"
        Write-Output "占用中，已挪开：$($f.Name)"
    }
}
