# post-social.ps1 — social posting functions for #iTA publish pipeline
# Dot-sourced by publish.ps1. Requires config.ps1 variables in scope.

# ── UTILITIES ────────────────────────────────────────────────────────────────

function Get-PostTitle {
    param($Markdown, $Fallback)
    $m = [regex]::Match($Markdown, '(?m)^#\s+(.+)$')
    if ($m.Success) { return $m.Groups[1].Value.Trim() }
    return $Fallback
}

function Get-Hashtags {
    param($Markdown)
    # Matches trailing fenced code block containing only hashtag lines
    $m = [regex]::Match($Markdown, '(?ms)^```\s*\r?\n((?:#\w+\s*)+)\r?\n```\s*$')
    if ($m.Success) {
        return ($m.Groups[1].Value | Select-String -Pattern '#(\w+)' -AllMatches).Matches |
            ForEach-Object { $_.Groups[1].Value }
    }
    return @()
}

# ── CONTENT FORMATTERS ───────────────────────────────────────────────────────

function Format-ForMastodon {
    param($Markdown, $SiteUrl)
    $t = $Markdown
    $t = $t -replace '(?m)^#\s+.+\r?\n?', ''                             # strip H1
    $t = $t -replace '\[\[(?:[^\]|]+\|)?([^\]]+)\]\]', '$1'              # flatten wikilinks
    $t = $t -replace '!\[.*?\]\(attachments/([^)%]+)[^)]*\)', '[image: $1]'  # named images
    $t = $t -replace '!\[.*?\]\([^)]+\)', '[image]'                       # any remaining images
    $t = $t -replace '(?ms)^:::\s*\{[^}]+\}.*?^:::\s*\r?\n?', ''        # strip pandoc divs
    $t = $t.Trim()
    return "$t`n`n$SiteUrl"
}

function Format-ForReddit {
    param($Markdown, $SiteUrl)
    $t = $Markdown
    $t = $t -replace '(?m)^#\s+.+\r?\n?', ''                             # strip H1 (used as title)
    $t = $t -replace '(?ms)^```\s*\r?\n(?:#\w+\s*)+\r?\n```\s*$', ''    # strip hashtag block
    $t = $t -replace '\[\[(?:[^\]|]+\|)?([^\]]+)\]\]', '$1'
    $t = $t -replace '!\[.*?\]\(attachments/([^)%]+)[^)]*\)', '[image: $1]'
    $t = $t -replace '!\[.*?\]\([^)]+\)', '[image]'
    $t = $t -replace '(?ms)^:::\s*\{[^}]+\}.*?^:::\s*\r?\n?', ''
    $t = $t.Trim()
    return "$t`n`n[Full post on Is This Anything?]($SiteUrl)"
}

# ── OAUTH HELPER (Tumblr) ────────────────────────────────────────────────────

function New-OAuthSignature {
    param($Method, $Url, $Params, $ConsumerSecret, $TokenSecret = "")
    $paramStr = ($Params.GetEnumerator() | Sort-Object Key | ForEach-Object {
        "$([Uri]::EscapeDataString($_.Key))=$([Uri]::EscapeDataString($_.Value))"
    }) -join '&'
    $base = "$Method&$([Uri]::EscapeDataString($Url))&$([Uri]::EscapeDataString($paramStr))"
    $key  = "$([Uri]::EscapeDataString($ConsumerSecret))&$([Uri]::EscapeDataString($TokenSecret))"
    $hmac = New-Object System.Security.Cryptography.HMACSHA1
    $hmac.Key = [System.Text.Encoding]::ASCII.GetBytes($key)
    return [Convert]::ToBase64String($hmac.ComputeHash([System.Text.Encoding]::ASCII.GetBytes($base)))
}

# ── PLATFORM SENDERS ─────────────────────────────────────────────────────────

function Send-MastodonPost {
    param($Text, $Instance, $Token)
    if ($Text.Length -gt 11000) {
        Write-Host "  WARNING: Mastodon post is $($Text.Length) chars. Truncating." -ForegroundColor Yellow
        $Text = $Text.Substring(0, 10997) + "..."
    }
    try {
        $body   = @{ status = $Text } | ConvertTo-Json -Depth 2
        $result = Invoke-RestMethod -Uri "$Instance/api/v1/statuses" `
            -Method POST `
            -Headers @{ Authorization = "Bearer $Token"; "Content-Type" = "application/json" } `
            -Body $body
        Write-Host "  Mastodon: $($result.url)"
    } catch {
        Write-Host "  ERROR Mastodon: $($_.Exception.Message)" -ForegroundColor Red
    }
}

function Open-RedditDraft {
    param($Title, $Body, $Subreddit)
    # NOTE: very long posts may be silently truncated by Reddit's URL pre-fill.
    # Manual paste is a fallback if that happens.
    $url = "https://www.reddit.com/r/$Subreddit/submit?type=self" +
           "&title=$([Uri]::EscapeDataString($Title))" +
           "&text=$([Uri]::EscapeDataString($Body))"
    try {
        Start-Process $url
        Write-Host "  Reddit: browser opened for r/$Subreddit"
    } catch {
        Write-Host "  ERROR Reddit: $($_.Exception.Message)" -ForegroundColor Red
    }
}

function Send-TumblrPost {
    param($BlogName, $Title, $BodyHtml, $Tags, $ConsumerKey, $ConsumerSecret, $AccessToken, $AccessSecret)
    $url       = "https://api.tumblr.com/v2/blog/$BlogName/post"
    $timestamp = [DateTimeOffset]::UtcNow.ToUnixTimeSeconds().ToString()
    $nonce     = [System.Guid]::NewGuid().ToString("N")

    $oauthParams = [ordered]@{
        oauth_consumer_key     = $ConsumerKey
        oauth_nonce            = $nonce
        oauth_signature_method = "HMAC-SHA1"
        oauth_timestamp        = $timestamp
        oauth_token            = $AccessToken
        oauth_version          = "1.0"
    }
    $postBody = [ordered]@{
        body  = $BodyHtml
        tags  = ($Tags -join ',')
        title = $Title
        type  = "text"
    }

    $allParams = @{}
    $oauthParams.GetEnumerator() | ForEach-Object { $allParams[$_.Key] = $_.Value }
    $postBody.GetEnumerator()    | ForEach-Object { $allParams[$_.Key] = $_.Value }

    $sig = New-OAuthSignature "POST" $url $allParams $ConsumerSecret $AccessSecret
    $oauthParams["oauth_signature"] = $sig

    $authHeader = 'OAuth ' + (($oauthParams.GetEnumerator() | Sort-Object Key | ForEach-Object {
        "$([Uri]::EscapeDataString($_.Key))=""$([Uri]::EscapeDataString($_.Value))"""
    }) -join ', ')

    try {
        $result = Invoke-RestMethod -Uri $url `
            -Method POST `
            -Headers @{ Authorization = $authHeader } `
            -Body $postBody
        Write-Host "  Tumblr: post id $($result.response)"
    } catch {
        Write-Host "  ERROR Tumblr: $($_.Exception.Message)" -ForegroundColor Red
    }
}

function Send-ButtondownDraft {
    param($Subject, $BodyHtml, $ApiKey, $Status)
    try {
        $payload = @{ subject = $Subject; body = $BodyHtml; status = $Status } | ConvertTo-Json -Depth 2
        $result  = Invoke-RestMethod -Uri "https://api.buttondown.email/v1/emails" `
            -Method POST `
            -Headers @{ Authorization = "Token $ApiKey"; "Content-Type" = "application/json" } `
            -Body $payload
        Write-Host "  Buttondown: draft id $($result.id)"
    } catch {
        Write-Host "  ERROR Buttondown: $($_.Exception.Message)" -ForegroundColor Red
    }
}

# ── DISPATCHER ───────────────────────────────────────────────────────────────

function Publish-ToSocial {
    param($Post)
    Write-Host ""
    Write-Host "Social posting: $($Post.Title)"

    if ($POST_MASTODON -and $MASTODON_TOKEN) {
        $text = Format-ForMastodon $Post.SourceMD $Post.SiteURL
        Send-MastodonPost $text $MASTODON_INSTANCE $MASTODON_TOKEN
    }

    if ($POST_REDDIT) {
        $body = Format-ForReddit $Post.SourceMD $Post.SiteURL
        Open-RedditDraft $Post.Title $body $REDDIT_SUBREDDIT
    }

    if ($POST_TUMBLR -and $TUMBLR_ACCESS_TOKEN) {
        Send-TumblrPost $TUMBLR_BLOG_NAME $Post.Title $Post.BodyHTML $Post.Hashtags `
            $TUMBLR_CONSUMER_KEY $TUMBLR_CONSUMER_SECRET `
            $TUMBLR_ACCESS_TOKEN $TUMBLR_ACCESS_SECRET
    }

    if ($POST_BUTTONDOWN -and $BUTTONDOWN_API_KEY) {
        Send-ButtondownDraft $Post.Title $Post.BodyHTML $BUTTONDOWN_API_KEY $BUTTONDOWN_EMAIL_STATUS
    }
}
