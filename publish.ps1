# Publish script (markdown + auto index + dark styling)
param(
    # When set, regenerates HTML for every already-published page (read
    # from $published) instead of just new content in $publish_folder,
    # to pick up template/header/footer/OG-tag changes on old pages.
    # Skips the move/copy steps below, since that content already lives
    # in Published - there's nothing to move.
    [switch]$RepublishAll
)

$publish_folder = "D:\Obsidian\Klif-Create\Is This Anything\Publish"
$published = "D:\Obsidian\Klif-Create\Is This Anything\Published"
$source = if ($RepublishAll) { $published } else { $publish_folder }
$site = Join-Path $PSScriptRoot "docs"
$backup = "E:\VibeCoding\itaBackups"
$COMMITMSG = $env:COMMITMSG
$enable_table_roller = $true

# Logging (Category D - timestamp + level, color-coded console, persistent log file)
$log_file = Join-Path $PSScriptRoot "publish_log.txt"

function Write-Log {
    param(
        [string]$Message,
        [ValidateSet("INFO", "WARN", "ERROR")]
        [string]$Level = "INFO"
    )
    if ([string]::IsNullOrWhiteSpace($Message)) { return }
    $timestamp = Get-Date -Format "yyyy-MM-dd HH:mm:ss"
    $line = "$timestamp [$Level] $Message"

    $color = switch ($Level) {
        "INFO"  { "Green" }
        "WARN"  { "Yellow" }
        "ERROR" { "Red" }
    }
    Write-Host $line -ForegroundColor $color
    Add-Content -Path $log_file -Value $line
}

function Html-Encode($s) {
    return $s -replace '&','&amp;' -replace '"','&quot;' -replace '<','&lt;' -replace '>','&gt;'
}

# Returns the article's first git-commit date for RSS pubDate. Falls back
# to "now" when the file has no history yet (e.g. this is the same run
# that's about to commit it for the first time) - by the time git commit
# actually runs a few steps later, that timestamp will be seconds off
# from this fallback at most.
function Get-FirstCommitDate($repo_relative_path) {
    $log = git log --follow --diff-filter=A --format=%aI --reverse -- "$repo_relative_path" 2>$null
    if ($log) {
        $oldest = ($log -split "`r?`n")[0]
        return Get-Date $oldest
    }
    return Get-Date
}

# Trim log file: 30-day retention, age-based
if (Test-Path $log_file) {
    $cutoff = (Get-Date).AddDays(-30)
    $lines = Get-Content $log_file
    $kept = $lines | Where-Object {
        try {
            $ts = [datetime]::ParseExact($_.Substring(0, 19), "yyyy-MM-dd HH:mm:ss", $null)
            $ts -ge $cutoff
        } catch { $true }  # keep malformed lines rather than silently drop them
    }
    Set-Content -Path $log_file -Value $kept
}

# Backup before doing anything
$timestamp = Get-Date -Format "yyyy-MM-dd_HH-mm-ss"
$backup_dest = Join-Path $backup $timestamp
Copy-Item -Path $site -Destination $backup_dest -Recurse -Force
Write-Log "Backup created: $backup_dest"

# Clean up old backups: keep last 30 days and last 30 pushes
$all_backups = Get-ChildItem -Path $backup -Directory | Sort-Object CreationTime
$cutoff_date = (Get-Date).AddDays(-30)
$old_backups = $all_backups | Where-Object { $_.CreationTime -lt $cutoff_date }
# Keep at least 30 most recent regardless of age
$keep_count = 30
if ($all_backups.Count -gt $keep_count) {
    $to_delete = $all_backups | Select-Object -First ($all_backups.Count - $keep_count)
    foreach ($dir in $to_delete) {
        if ($dir.CreationTime -lt $cutoff_date) {
            Remove-Item -Path $dir.FullName -Recurse -Force
            Write-Log "Deleted old backup: $($dir.Name)"
        }
    }
}

$publish_errors = @()

# add the Publish folder if it doesn't already exist, so errors don't happen
if (-not (Test-Path $publish_folder)) {
    New-Item -ItemType Directory -Path $publish_folder | Out-Null
}

# Convert markdown to HTML (slugified, lowercase)
Get-ChildItem -Path $source -Recurse -Include "*.md" | ForEach-Object {
    $relative = $_.FullName.Substring($source.Length + 1)
    $dir      = Split-Path $relative
    $target_dir = Join-Path $site ($dir.ToLower())
    if (!(Test-Path $target_dir)) { New-Item -ItemType Directory -Path $target_dir }
    $slug  = $_.BaseName -replace ' ', '-'
    $slug  = $slug.ToLower()
    # Strip characters Windows won't allow in a filename at all - defensive;
    # a stray one here would otherwise crash New-Item/pandoc outright rather
    # than just looking odd.
    $slug  = $slug -replace '[<>:"/\\|?*]', ''
    # Windows also silently disallows a filename ending in a period or
    # space. Without this, a title like "Bruce Tree." collides with the
    # appended ".html" into a literal double dot (bruce-tree..html) - a
    # real bug hit in production, not a hypothetical one.
    $slug  = $slug.TrimEnd('. ')
    $title = "$($_.BaseName) - Is This Anything?"
    $output = Join-Path $target_dir ($slug + ".html")

    # Read markdown (do not modify source)
    $content = Get-Content $_.FullName -Raw -Encoding UTF8
    # force blank line before headings that follow content
    $content = $content -replace "(.*)\r?\n(#)", "$1`n`n#"

    Write-Log "Processing file: $($_.FullName)"

    # Convert Obsidian [!info] callouts to Pandoc div blocks
    $pattern = '(?ms)^\s*>\s*\[!info\]\s*(.*?)\r?\n((?:\s*>\s*.*\r?\n?)*)'
    $content = [regex]::Replace($content, $pattern, {
        param($match)
        $title_text = $match.Groups[1].Value.Trim()
        $body  = $match.Groups[2].Value
        $body = $body -replace '(?m)^\s*>\s?', ''
        return "`n::: {.info}`n`n**$title_text**`n`n$body`n:::`n"
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

    # Broken-attachment check
    $attachment_dir = Join-Path $_.DirectoryName "attachments"
    $referenced = [regex]::Matches($content, '!\[\]\(attachments/([^)]+)\)') | ForEach-Object {
        [uri]::UnescapeDataString($_.Groups[1].Value)
    }
    foreach ($img in $referenced) {
        $img_path = Join-Path $attachment_dir $img
        if (-not (Test-Path $img_path)) {
            $publish_errors += "$($_.FullName): missing attachment '$img'"
            Write-Log "Missing attachment '$img' referenced in $($_.FullName)" -Level ERROR
        }
    }

    # Auto-extract an OG description from the first real paragraph.
    # Strip a leading YAML frontmatter block first - old notes still
    # carry one, and with no blank lines inside it, it otherwise reads
    # as a single paragraph that slips past the filters below.
    $content_for_excerpt = $content -replace '(?s)^\s*---\r?\n.*?\r?\n---\r?\n', ''
    $plain_paragraphs = $content_for_excerpt -split "`r?`n`r?`n" | Where-Object {
        $t = $_.Trim()
        $t -ne "" -and $t -notmatch '^#' -and $t -notmatch '^!\[' -and $t -notmatch '^:::'
    }
    $description = ""
    if ($plain_paragraphs.Count -gt 0) {
        $description = ($plain_paragraphs[0] -replace '[*_`]', '' -replace '\s+', ' ').Trim()
        if ($description.Length -gt 155) {
            $description = $description.Substring(0, 155).Trim() + "..."
        }
    }

    $rel_dir = $target_dir.Substring((Resolve-Path $site).Path.Length).TrimStart('\').Replace('\','/')
    $og_url = "https://theklif.github.io/is-this-anything/$rel_dir/$slug.html"

    $og_image = ""
    $img_match = [regex]::Match($content, '!\[\]\(attachments/([^)]+)\)')
    if ($img_match.Success) {
        $og_image = "https://theklif.github.io/is-this-anything/$rel_dir/attachments/" + $img_match.Groups[1].Value
    }

    $og_tags = "<meta property=`"og:title`" content=`"$(Html-Encode $title)`">`n"
    $og_tags += "<meta property=`"og:type`" content=`"article`">`n"
    $og_tags += "<meta property=`"og:url`" content=`"$og_url`">`n"
    if ($description -ne "") {
        $og_tags += "<meta property=`"og:description`" content=`"$(Html-Encode $description)`">`n"
    }
    if ($og_image -ne "") {
        $og_tags += "<meta property=`"og:image`" content=`"$og_image`">`n"
    }
    $og_tags += "<meta name=`"twitter:card`" content=`"summary_large_image`">"
    $og_tags += "`n<link rel=`"alternate`" type=`"application/rss+xml`" title=`"Is This Anything? Feed`" href=`"/is-this-anything/feed.xml`">"
    if ($enable_table_roller) {
        $og_tags += "`n<script src=`"/is-this-anything/roller.js`" defer></script>"
    }

    # Write converted content to temp file for pandoc
    $temp = "$env:TEMP\publish_temp.md"
    Set-Content -Path $temp -Value $content -Encoding UTF8

    # Preserve the existing page's mtime in republish mode, so
    # regenerating old pages doesn't make every one of them falsely
    # show the index's "New" badge for the next 30 days.
    $original_mtime = $null
    if ($RepublishAll -and (Test-Path $output)) {
        $original_mtime = (Get-Item $output).LastWriteTime
    }

    Push-Location $source
    pandoc $temp -o $output `
        --standalone `
        --css="../../style.css" `
        --metadata title="$title" `
        --include-before-body="$site\_header.html" `
        --include-after-body="$site\_footer.html" `
        --from=markdown+hard_line_breaks+lists_without_preceding_blankline

    if ($LASTEXITCODE -ne 0) {
        $publish_errors += $_.FullName
        Write-Log "Pandoc failed on $($_.FullName)" -Level ERROR
    } else {
        $html = Get-Content $output -Raw
        $html = $html -replace '(<title>.*?</title>)', "`$1`n$og_tags"
        Set-Content -Path $output -Value $html -Encoding UTF8
        if ($original_mtime) {
            (Get-Item $output).LastWriteTime = $original_mtime
        }
    }
    Pop-Location
}

# Abort if any conversions failed
if ($publish_errors.Count -gt 0) {
    Write-Log "Publish aborted due to errors in the following files:" -Level ERROR
    $publish_errors | ForEach-Object { Write-Log "  $_" -Level ERROR }
    Write-Log "No files were committed. Restore from backup if needed: $backup_dest" -Level WARN
    pause
    exit 1
}

# Auto index (grouped)
$index = @"
<!DOCTYPE html>
<html lang='en'>
<head>
  <meta charset='UTF-8'>
  <meta name="viewport" content="width=device-width, initial-scale=1.0">
  <title>All Musings</title>
  <link rel='stylesheet' href='/is-this-anything/style.css'>
  <link rel='alternate' type='application/rss+xml' title='Is This Anything? Feed' href='/is-this-anything/feed.xml'>
</head>
<body>
<nav class="site-nav" style="display:flex;align-items:center;">
  <button id="a11y-toggle" class="table-roll-btn" style="margin-left:auto;" aria-label="Toggle high-contrast mode">Aa</button>
</nav>
<script>
(function () {
  var root = document.documentElement;
  var btn = document.getElementById('a11y-toggle');
  if (localStorage.getItem('accessibleMode') === '1') root.classList.add('accessible-mode');
  btn.addEventListener('click', function () {
    var on = root.classList.toggle('accessible-mode');
    localStorage.setItem('accessibleMode', on ? '1' : '0');
  });
})();
</script>
<div class="main-content">
  <h1>All Musings</h1>
"@

$new_cutoff = (Get-Date).AddDays(-7)
$groups = @{}
$feed_items = @()
Get-ChildItem -Path $site -Recurse -Include "*.html" |
    Where-Object { $_.Name -notin @("index.html", "test.html", "404.html", "_header.html", "_footer.html") } |
    ForEach-Object {
        $full = $_.FullName
        $base_site = (Resolve-Path $site).Path
        $rel = $full.Substring($base_site.Length).TrimStart("\").Replace("\", "/")
        $folder = Split-Path $rel -Parent
        if ([string]::IsNullOrWhiteSpace($folder)) { $folder = "uncategorized" }
        if (-not $groups.ContainsKey($folder)) { $groups[$folder] = @() }
        $title_text = $_.BaseName -replace '-', ' '
        $title_text = (Get-Culture).TextInfo.ToTitleCase($title_text)
        $badge = ""
        if ($_.LastWriteTime -ge $new_cutoff) {
            $badge = " <span class='new-badge'>New</span>"
        }
        $groups[$folder] += "<li><a href='$rel'>$title_text</a>$badge</li>"

        # Feed item: reuse the og:description already embedded in this
        # page's <head> as the excerpt, so there's no second pass over
        # the source markdown.
        $page_html = Get-Content $full -Raw
        $desc_match = [regex]::Match($page_html, 'property="og:description" content="([^"]*)"')
        $excerpt = if ($desc_match.Success) { $desc_match.Groups[1].Value } else { "" }
        $feed_items += [pscustomobject]@{
            Title       = $title_text
            Link        = "https://theklif.github.io/is-this-anything/$rel"
            Description = $excerpt
            PubDate     = Get-FirstCommitDate "docs/$rel"
        }
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

# RSS feed - latest 20 items by first-commit date
$feed_entries = ($feed_items | Sort-Object PubDate -Descending | Select-Object -First 20 | ForEach-Object {
    $pub_rfc822 = $_.PubDate.ToUniversalTime().ToString("R")
    @"
  <item>
    <title>$(Html-Encode $_.Title)</title>
    <link>$(Html-Encode $_.Link)</link>
    <guid>$(Html-Encode $_.Link)</guid>
    <description>$($_.Description)</description>
    <pubDate>$pub_rfc822</pubDate>
  </item>
"@
}) -join "`n"

$feed_xml = @"
<?xml version="1.0" encoding="UTF-8"?>
<rss version="2.0">
<channel>
  <title>Is This Anything?</title>
  <link>https://theklif.github.io/is-this-anything/index.html</link>
  <description>Homebrew D&amp;D content from #iTA</description>
$feed_entries
</channel>
</rss>
"@
Set-Content "$site/feed.xml" $feed_xml -Encoding UTF8

# 404 page with a random attachment image, regenerated every run
$attachment_images = Get-ChildItem -Path $site -Recurse -Include "*.png","*.jpg","*.jpeg","*.gif","*.webp" -File |
    Where-Object { $_.FullName -match '\\attachments\\' } |
    ForEach-Object {
        $base_site = (Resolve-Path $site).Path
        "/is-this-anything/" + $_.FullName.Substring($base_site.Length).TrimStart("\").Replace("\", "/")
    }
$images_json = ($attachment_images | ForEach-Object { "`"$_`"" }) -join ","

$not_found = @"
<!DOCTYPE html>
<html lang='en'>
<head>
  <meta charset='UTF-8'>
  <meta name="viewport" content="width=device-width, initial-scale=1.0">
  <title>Not Found - Is This Anything?</title>
  <link rel='stylesheet' href='/is-this-anything/style.css'>
</head>
<body>
<div class="main-content">
  <h1>404: Nothing here</h1>
  <p>That page doesn't exist. Maybe this does:</p>
  <img id="random-attachment" alt="" style="display:none;">
  <p><a href="/is-this-anything/index.html">Back to All Musings</a></p>
</div>
<script>
  var images = [$images_json];
  if (images.length > 0) {
    var pick = images[Math.floor(Math.random() * images.length)];
    var el = document.getElementById('random-attachment');
    el.src = pick;
    el.style.display = 'block';
  }
</script>
</body>
</html>
"@
Set-Content "$site/404.html" $not_found

# Copy attachment folders from source to site
Get-ChildItem -Path $source -Recurse -Directory -Filter "attachments" | ForEach-Object {
    $relative = $_.FullName.Substring($source.Length + 1)
    $dest = Join-Path $site $relative
    if (!(Test-Path $dest)) {
        New-Item -ItemType Directory -Path $dest -Force
    }
    Copy-Item -Path (Join-Path $_.FullName '*') -Destination $dest -Recurse -Force
}

# Move attachment folders from Publish to Published (skipped in
# republish mode - content already lives in Published, nowhere to move it)
if (-not $RepublishAll) {
    Get-ChildItem -Path $source -Recurse -Directory -Filter "attachments" | ForEach-Object {
        $relative = $_.FullName.Substring($source.Length + 1)
        $dest = Join-Path $published $relative
        if (!(Test-Path $dest)) {
            New-Item -ItemType Directory -Path $dest -Force
        }
        Move-Item -Path (Join-Path $_.FullName '*') -Destination $dest -Force
    }
}

# Move published source files to Published folder (skipped in
# republish mode - same reason as above)
if (-not $RepublishAll) {
    Get-ChildItem -Path $source -Recurse -Include "*.md" | ForEach-Object {
        $relative = $_.FullName.Substring($source.Length + 1)
        $dest_file = Join-Path $published $relative
        $dest_dir = Split-Path $dest_file
        if (!(Test-Path $dest_dir)) { New-Item -ItemType Directory -Path $dest_dir -Force }
        Move-Item -Path $_.FullName -Destination $dest_file -Force
    }
}

Get-ChildItem $draftsPath -Recurse -Directory | Where-Object {
    (Get-ChildItem $_.FullName -Force | Measure-Object).Count -eq 0
} | ForEach-Object {
    New-Item -Path (Join-Path $_.FullName "_keep.md") -ItemType File -Force | Out-Null
}

# Commit and push
git add .
git commit -m $COMMITMSG
if ($LASTEXITCODE -ne 0) {
    Write-Log "git commit failed." -Level ERROR
    exit 1
}
git push
if ($LASTEXITCODE -ne 0) {
    Write-Log "git push failed." -Level ERROR
    exit 1
}

Write-Log "Publish complete. Reason: $COMMITMSG"

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