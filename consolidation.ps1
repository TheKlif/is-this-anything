# seed-keep-files.ps1
$root = "D:\Obsidian\Klif-Create\Is This Anything"
$placeholderName = ".keep"

if (-not (Test-Path $root)) {
    Write-Error "Path not found: $root"
    exit 1
}

$dirs = Get-ChildItem -Path $root -Recurse -Directory
$added = 0

foreach ($dir in $dirs) {
    $placeholder = Join-Path $dir.FullName $placeholderName
    if (-not (Test-Path $placeholder)) {
        New-Item -Path $placeholder -ItemType File -Force | Out-Null
        Write-Host "Added: $placeholder"
        $added++
    }
}

Write-Host "`n$($dirs.Count) subfolder(s) scanned under '$root'."
Write-Host "$added placeholder file(s) added."