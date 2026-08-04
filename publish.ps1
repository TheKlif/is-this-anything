# Publish script (markdown + auto index + dark styling)
$source = "D:\Obsidian\Klif-Create\Is This Anything\Publish"
$site   = "D:\Is This Anything\TheKlif.github.io\Is-This-Anything"
$backup = "D:\Is This Anything\Backups"
$published = "D:\Obsidian\Klif-Create\Is This Anything\Published"
$COMMITMSG = $env:COMMITMSG

# Backup before doing anything
$timestamp = Get-Date -Format "yyyy-MM-dd_HH-mm-ss"
$backupDest = Join-Path $backup $timestamp
Copy-Item -Path $site -Destination $backupDest -Recurse -Force
Write-Host "Backup created: $backupDest"

# Clean up old backups: keep last 30 days and last 30 pushes
$allBackups = Get-ChildItem -Path $backup -Directory | Sort-Object CreationTime
$cutoffDate = (Get-Date).AddDays(-30)
$recentBackups = $allBackups | Where-Object { $_.CreationTime -ge $cutoffDate }
$oldBackups = $allBackups | Where-Object { $_.CreationTime -lt $cutoffDate }
# Keep at least 30 most recent regardless of age
$keepCount = 30
if ($allBackups.Count -gt $keepCount) {
    $toDelete = $allBackups | Select-Object -First ($allBackups.Count - $keepCount)
    foreach ($dir in $toDelete) {
        if ($dir.CreationTime -lt $cutoffDate) {
            Remove-Item -Path $dir.FullName -Recurse -Force
            Write-Host "Deleted old backup: $($dir.Name)"
        }
    }
}

# Track conversion errors
$publishErrors = @()

# add the Publish folder if it doesn't already exist, so errors don't happen
if (-not (Test-Path $source)) {
    New-Item -ItemType Directory -Path $source | Out-Null
}

# Convert markdown to HTML (slugified, lowercase)
Get-ChildItem -Path $source -Recurse -Include "*.md" | ForEach-Object {
    $relative = $_.FullName.Substring($source.Length + 1)
    $dir      = Split-Path $relative
    $targetDir = Join-Path $site ($dir.ToLower())
    if (!(Test-Path $targetDir)) { New-Item -ItemType Directory -Path $targetDir }
    $slug  = $_.BaseName -replace ' ', '-'
    $slug  = $slug.ToLower()
    $title = "$($_.BaseName) - Is This Anything?"
    $output = Join-Path $targetDir ($slug + ".html")

    # Read markdown (do not modify source)
    $content = Get-Content $_.FullName -Raw
    # force blank line before headings that follow content
    $content = $content -replace "(.*)\r?\n(#)", "$1`n`n#"

    Write-Host "Processing file: $($_.FullName)"

    # Convert Obsidian [!info] callouts to Pandoc div blocks
    $pattern = '(?ms)^\s*>\s*\[!info\]\s*(.*?)\r?\n((?:\s*>\s*.*\r?\n?)*)'
    $content = [regex]::Replace($content, $pattern, {
        param($match)
        $titleText = $match.Groups[1].Value.Trim()
        $body  = $match.Groups[2].Value
        $body = $body -replace '(?m)^\s*>\s?', ''
        return "`n::: {.info}`n`n**$titleText**`n`n$body`n:::`n"
    })

    # Convert Obsidian wikilink image syntax to standard markdown, adding attachments/ prefix
    $content = $content -replace '!\[\[([^\]]+)\]\]', '![](attachments/$1)'
    # Fix image paths - strip everything before attachments/
    $content = $content -replace '!\[\]\([^)]*attachments/', '![](attachments/'
    # Add attachments/ prefix to bare filenames with no path
    $content = $content -replace '!\[\]\((?!attachments/)([^/\)]+\.(png|jpg|jpeg|gif|webp))\)', '![](attachments/$1)'
    # Encode spaces in image paths
    $content = [regex]::Replace($content, '!\[\]\(([^)]+)\)', {
        param($m)
        $path = $m.Groups[1].Value -replace ' ', '%20'
        return "![]($path)"
    })

    # Write converted content to temp file for pandoc
    $temp = "$env:TEMP\publish_temp.md"
    Set-Content -Path $temp -Value $content -Encoding UTF8

    Push-Location $source
    pandoc $temp -o $output `
        --standalone `
        --css="../../style.css" `
        --metadata title="$title" `
        --include-before-body="$site\_header.html" `
        --include-after-body="$site\_footer.html" `
        --from=markdown
    
    if ($LASTEXITCODE -ne 0) {
        $publishErrors += $_.FullName
        Write-Host "ERROR: Pandoc failed on $($_.FullName)"
    }
    Pop-Location
}

# Abort if any conversions failed
if ($publishErrors.Count -gt 0) {
    Write-Host "Publish aborted due to errors in the following files:"
    $publishErrors | ForEach-Object { Write-Host "  $_" }
    Write-Host "No files were committed. Restore from backup if needed: $backupDest"
    pause
    exit 1
}

# Auto index (grouped)
$index = @"
<!DOCTYPE html>
<html lang='en'>
<head>
  <meta charset='UTF-8'>
  <title>All Musings</title>
  <link rel='stylesheet' href='/Is-This-Anything/style.css'>
</head>
<body>
<div class="main-content">
  <h1>All Musings</h1>
"@

$groups = @{}
Get-ChildItem -Path $site -Recurse -Include "*.html" |
    Where-Object { $_.Name -notin @("index.html", "test.html", "_header.html", "_footer.html") } |
    ForEach-Object {
        $full = $_.FullName
        $baseSite = (Resolve-Path $site).Path
        $rel = $full.Substring($baseSite.Length).TrimStart("\").Replace("\", "/")
        $folder = Split-Path $rel -Parent
        if ([string]::IsNullOrWhiteSpace($folder)) { $folder = "uncategorized" }
        if (-not $groups.ContainsKey($folder)) { $groups[$folder] = @() }
        $titleText = $_.BaseName -replace '-', ' '
        $titleText = (Get-Culture).TextInfo.ToTitleCase($titleText)
        $groups[$folder] += "<li><a href='$rel'>$titleText</a></li>"
    }

foreach ($group in ($groups.GetEnumerator() | Sort-Object Name)) {
    if ($group.Key -eq "uncategorized") {
        continue
    }
    $parts = $group.Key.Split("\")
    $parent = (Get-Culture).TextInfo.ToTitleCase($parts[0])
    $child = if ($parts.Length -gt 1) { (Get-Culture).TextInfo.ToTitleCase($parts[1]) } else { $parent }
    $index += "<p class='category-parent'>$parent</p><h2 class='category-child'>$child</h2><ul>`n"
    $index += ($group.Value -join "`n")
    $index += "`n</ul>`n"
}

$timestamp = Get-Date -Format "yyyy.MM.dd.HH.mm.ss"
$index += @"
<p class='last-updated'>Last updated: $timestamp</p>
</div>
</body>
</html>
"@

Set-Content "$site/index.html" $index

# Copy attachment folders from source to site
Get-ChildItem -Path $source -Recurse -Directory -Filter "attachments" | ForEach-Object {
    $relative = $_.FullName.Substring($source.Length + 1)
    $dest = Join-Path $site $relative
    if (!(Test-Path $dest)) {
        New-Item -ItemType Directory -Path $dest -Force
    }
    Copy-Item -Path (Join-Path $_.FullName '*') -Destination $dest -Recurse -Force
}

# Move attachment folders from Publish to Published
Get-ChildItem -Path $source -Recurse -Directory -Filter "attachments" | ForEach-Object {
    $relative = $_.FullName.Substring($source.Length + 1)
    $dest = Join-Path $published $relative
    if (!(Test-Path $dest)) {
        New-Item -ItemType Directory -Path $dest -Force
    }
    Move-Item -Path (Join-Path $_.FullName '*') -Destination $dest -Force
}

# Move published source files to Published folder
Get-ChildItem -Path $source -Recurse -Include "*.md" | ForEach-Object {
    $relative = $_.FullName.Substring($source.Length + 1)
    $destFile = Join-Path $published $relative
    $destDir = Split-Path $destFile
    if (!(Test-Path $destDir)) { New-Item -ItemType Directory -Path $destDir -Force }
    Move-Item -Path $_.FullName -Destination $destFile -Force
}

# Commit and push
git add .
git commit -m $COMMITMSG
git push

Write-Host ""
Write-Host ""
Write-Host ""
Write-Host "==============================="
Write-Host ""
Write-Host "Publish complete."
Write-Host ""
Write-Host "Reason:"
Write-Host $COMMITMSG
Write-Host ""
Write-Host "==============================="
Write-Host ""
Write-Host ""
Write-Host ""