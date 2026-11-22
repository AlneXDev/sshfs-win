<#
.SYNOPSIS
    Mount/unmount smoke test for a locally built SSHFS-Win.

.DESCRIPTION
    `net use` goes through WinFsp's launcher service, whose Executable comes
    from the registry, NOT from PATH. Install the built MSI (or register a
    service pointing at -BinDir) before running this. -BinDir is only checked
    for the presence of the launcher, and PATH is extended so `cmd` mode would
    work. Mounts the remote via `net use`, lists the drive root, then disconnects.
#>
param(
    [Parameter(Mandatory=$true)] [string] $HostName,
    [Parameter(Mandatory=$true)] [string] $RemoteUser,
    [string] $RemotePath = '',
    [string] $Drive = 'X',
    [string] $BinDir = 'C:\Program Files\SSHFS-Win\bin'
)

$ErrorActionPreference = 'Stop'
$Drive = $Drive.TrimEnd(':')

if (-not (Test-Path (Join-Path $BinDir 'sshfs-win.exe'))) {
    throw "sshfs-win.exe not found in '$BinDir'. Install the build or pass -BinDir."
}
foreach ($cls in 'sshfs','sshfs.r','sshfs.k','sshfs.kr') {
    $svcExe = (Get-ItemProperty "HKLM:\SOFTWARE\WOW6432Node\WinFsp\Services\$cls" -ErrorAction SilentlyContinue).Executable
    if (-not $svcExe) {
        $svcExe = (Get-ItemProperty "HKLM:\SOFTWARE\WinFsp\Services\$cls" -ErrorAction SilentlyContinue).Executable
    }
    if ($svcExe -and ((Split-Path $svcExe) -ine $BinDir)) {
        Write-Warning "WinFsp '$cls' service uses '$svcExe', not '$BinDir'; net use will test the installed build."
    }
}

$env:PATH = "$BinDir;$env:PATH"
$unc = "\\sshfs\$RemoteUser@$HostName"
if ($RemotePath) {
    $unc += '\' + $RemotePath.TrimStart('\', '/').Replace('/', '\')
}
$dev = "${Drive}:"

Write-Host "Mounting $unc -> $dev"
& net use $dev $unc
if ($LASTEXITCODE -ne 0) { throw "net use failed with exit code $LASTEXITCODE" }

try {
    $items = @(Get-ChildItem -Force "$dev\")
    Write-Host "Mount OK. Top-level entries: $($items.Count)"
    $items | Select-Object -First 20 Name, Mode, Length | Format-Table -AutoSize
}
finally {
    Write-Host "Disconnecting $dev"
    & net use $dev /delete /y | Out-Null
}
