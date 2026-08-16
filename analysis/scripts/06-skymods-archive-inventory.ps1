Set-StrictMode -Version Latest
$ErrorActionPreference = "Stop"

$AnalysisName = "06-skymods-archive-inventory"
$ForceRefresh = $false

$RepoRoot = (Resolve-Path (Join-Path $PSScriptRoot "..\..")).Path

$EventMatrixPath = Join-Path `
    $RepoRoot `
    "analysis\results\05-steam-git-candidate-mapping\steam-git-event-matrix.csv"

$OutputDirectory = Join-Path $RepoRoot "analysis\results\$AnalysisName"
$RawPagesDirectory = Join-Path $OutputDirectory "raw-pages"

$PackageDirectory = Join-Path $RepoRoot "analysis\packages"
$PackagePath = Join-Path $PackageDirectory "$AnalysisName.zip"

$ExpectedSteamEventCount = 1198
$ExpectedRepoCount = 13

$Sources = @(
    [pscustomobject]@{
        Repo = "Community-Flavor-Pack"
        Abbreviation = "CFP"
        WorkshopId = "2220098919"
        CatalogueUrl = "https://catalogue.smods.ru/archives/66558"
    },
    [pscustomobject]@{
        Repo = "Culture-and-Faith-Granularity"
        Abbreviation = "CFG"
        WorkshopId = "3206891770"
        CatalogueUrl = "https://catalogue.smods.ru/archives/251333"
    },
    [pscustomobject]@{
        Repo = "Culture-Expanded"
        Abbreviation = "CE"
        WorkshopId = "2829397295"
        CatalogueUrl = "https://catalogue.smods.ru/archives/102619"
    },
    [pscustomobject]@{
        Repo = "Demand-Tribute"
        Abbreviation = "DT"
        WorkshopId = "3473488611"
        CatalogueUrl = "https://catalogue.smods.ru/archives/350915"
    },
    [pscustomobject]@{
        Repo = "EPE-CFP"
        Abbreviation = "EPE-CFP"
        WorkshopId = "2996881191"
        CatalogueUrl = "https://catalogue.smods.ru/archives/188635"
    },
    [pscustomobject]@{
        Repo = "Ethnicities-and-Portraits-Expanded"
        Abbreviation = "EPE"
        WorkshopId = "2507209632"
        CatalogueUrl = "https://catalogue.smods.ru/archives/79577"
    },
    [pscustomobject]@{
        Repo = "MBP-EPE-CFP"
        Abbreviation = "MBP-EPE-CFP"
        WorkshopId = "2543865921"
        CatalogueUrl = "https://catalogue.smods.ru/archives/88794"
    },
    [pscustomobject]@{
        Repo = "MedievalImmersion"
        Abbreviation = "MI"
        WorkshopId = "3268020725"
        CatalogueUrl = "https://catalogue.smods.ru/archives/349431"
    },
    [pscustomobject]@{
        Repo = "MPE"
        Abbreviation = "MPE"
        WorkshopId = "3726274827"
        CatalogueUrl = "https://catalogue.smods.ru/archives/435984"
    },
    [pscustomobject]@{
        Repo = "RICE"
        Abbreviation = "RICE"
        WorkshopId = "2273832430"
        CatalogueUrl = "https://catalogue.smods.ru/archives/69887"
    },
    [pscustomobject]@{
        Repo = "Special-World"
        Abbreviation = "SW"
        WorkshopId = "2875587269"
        CatalogueUrl = "https://catalogue.smods.ru/archives/127297"
    },
    [pscustomobject]@{
        Repo = "Turkic-World-Expanded"
        Abbreviation = "TWE"
        WorkshopId = "3668769244"
        CatalogueUrl = "https://catalogue.smods.ru/archives/421646"
    },
    [pscustomobject]@{
        Repo = "Western-Steppe-Expanded"
        Abbreviation = "WSE"
        WorkshopId = "3490396842"
        CatalogueUrl = "https://catalogue.smods.ru/archives/360256"
    }
)

$Headers = @{
    "User-Agent" = "Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 Chrome/151 Safari/537.36"
    "Accept-Language" = "en-US,en;q=0.9"
}

function Get-Sha256 {
    param(
        [Parameter(Mandatory)]
        [string]$Path
    )

    return (Get-FileHash -LiteralPath $Path -Algorithm SHA256).Hash.ToLowerInvariant()
}

function Convert-HtmlFragmentToText {
    param(
        [AllowNull()]
        [AllowEmptyString()]
        [string]$Html
    )

    if ([string]::IsNullOrWhiteSpace($Html)) {
        return ""
    }

    $value = $Html

    $value = [regex]::Replace(
        $value,
        '(?is)<script\b[^>]*>.*?</script>',
        ' '
    )

    $value = [regex]::Replace(
        $value,
        '(?is)<style\b[^>]*>.*?</style>',
        ' '
    )

    $value = [regex]::Replace(
        $value,
        '(?i)<br\s*/?>|</p>|</div>|</li>|</h[1-6]>',
        "`n"
    )

    $value = [regex]::Replace(
        $value,
        '(?is)<[^>]+>',
        ' '
    )

    $value = [System.Net.WebUtility]::HtmlDecode($value)

    $lines = @(
        $value -split '\r?\n' |
            ForEach-Object {
                [regex]::Replace($_, '\s+', ' ').Trim()
            } |
            Where-Object {
                -not [string]::IsNullOrWhiteSpace($_)
            }
    )

    return ($lines -join "`n")
}

function Get-StatusCodeFromException {
    param(
        [Parameter(Mandatory)]
        $Exception
    )

    try {
        if ($null -ne $Exception.Response) {
            return [int]$Exception.Response.StatusCode
        }
    }
    catch {
    }

    return $null
}

function Get-CachedPage {
    param(
        [Parameter(Mandatory)]
        [string]$Url,

        [Parameter(Mandatory)]
        [string]$Path
    )

    if (
        -not $ForceRefresh -and
        (Test-Path -LiteralPath $Path)
    ) {
        return [pscustomobject]@{
            Path = $Path
            FromCache = $true
            FetchedAtUtc = (Get-Item -LiteralPath $Path).LastWriteTimeUtc
        }
    }

    $parent = Split-Path -Parent $Path

    if (-not (Test-Path -LiteralPath $parent)) {
        New-Item -ItemType Directory -Path $parent -Force | Out-Null
    }

    $lastError = $null

    for ($attempt = 1; $attempt -le 4; $attempt++) {
        if (Test-Path -LiteralPath $Path) {
            Remove-Item -LiteralPath $Path -Force
        }

        if ($attempt -eq 1) {
            Start-Sleep -Seconds (Get-Random -Minimum 2 -Maximum 5)
        }

        try {
            $response = Invoke-WebRequest `
                -Uri $Url `
                -Headers $Headers `
                -OutFile $Path `
                -PassThru `
                -MaximumRedirection 10 `
                -TimeoutSec 90

            if (
                $response.StatusCode -lt 200 -or
                $response.StatusCode -ge 300
            ) {
                throw "HTTP $($response.StatusCode)"
            }

            return [pscustomobject]@{
                Path = $Path
                FromCache = $false
                FetchedAtUtc = (Get-Item -LiteralPath $Path).LastWriteTimeUtc
            }
        }
        catch {
            $lastError = $_
            $statusCode = Get-StatusCodeFromException $_.Exception

            if (Test-Path -LiteralPath $Path) {
                Remove-Item -LiteralPath $Path -Force
            }

            if ($attempt -ge 4) {
                break
            }

            $cooldown = switch ($statusCode) {
                429 { 30 * $attempt }
                403 { 30 * $attempt }
                default { 10 * $attempt }
            }

            Write-Warning (
                "Request failed for $Url " +
                "(attempt $attempt/4, HTTP $statusCode). " +
                "Retrying in $cooldown seconds."
            )

            Start-Sleep -Seconds $cooldown
        }
    }

    throw (
        "Failed to retrieve $Url after 4 attempts. " +
        "Last error: $($lastError.Exception.Message)"
    )
}

function Get-ReferenceYear {
    param(
        [Parameter(Mandatory)]
        [string]$PageText
    )

    $updated = [regex]::Match(
        $PageText,
        '(?i)\bUpdated\s+[A-Za-z]+\s+\d{1,2},\s+(?<year>20\d{2})\b'
    )

    if ($updated.Success) {
        return [int]$updated.Groups["year"].Value
    }

    $published = [regex]::Match(
        $PageText,
        '(?i)\bPublished\s+[A-Za-z]+\s+\d{1,2},\s+(?<year>20\d{2})\b'
    )

    if ($published.Success) {
        return [int]$published.Groups["year"].Value
    }

    return (Get-Date).Year
}

function Convert-SkymodsTimestamp {
    param(
        [AllowNull()]
        [AllowEmptyString()]
        [string]$RawValue,

        [Parameter(Mandatory)]
        [int]$ReferenceYear
    )

    if ([string]::IsNullOrWhiteSpace($RawValue)) {
        return [pscustomobject]@{
            Success = $false
            Normalized = ""
            DateTime = $null
        }
    }

    $value = [regex]::Replace(
        $RawValue.Trim(),
        '\s+',
        ' '
    )

    if ($value -notmatch '\b20\d{2}\b') {
        $value = $value -replace (
            '\s+at\s+',
            ", $ReferenceYear at "
        )
    }

    $formats = @(
        "d MMM, yyyy 'at' HH:mm 'UTC'",
        "dd MMM, yyyy 'at' HH:mm 'UTC'",
        "d MMMM, yyyy 'at' HH:mm 'UTC'",
        "dd MMMM, yyyy 'at' HH:mm 'UTC'",
        "d MMM yyyy 'at' HH:mm 'UTC'",
        "dd MMM yyyy 'at' HH:mm 'UTC'"
    )

    $culture = [System.Globalization.CultureInfo]::GetCultureInfo("en-US")

    foreach ($format in $formats) {
        $parsed = [datetime]::MinValue

        if (
            [datetime]::TryParseExact(
                $value,
                $format,
                $culture,
                [System.Globalization.DateTimeStyles]::None,
                [ref]$parsed
            )
        ) {
            $parsed = [datetime]::SpecifyKind(
                $parsed,
                [System.DateTimeKind]::Unspecified
            )

            return [pscustomobject]@{
                Success = $true
                Normalized = $parsed.ToString("yyyy-MM-dd HH:mm")
                DateTime = $parsed
            }
        }
    }

    $fallbackValue = $value `
        -replace '\s+UTC$', '' `
        -replace '\s+at\s+', ' '

    $fallback = [datetime]::MinValue

    if (
        [datetime]::TryParse(
            $fallbackValue,
            $culture,
            [System.Globalization.DateTimeStyles]::None,
            [ref]$fallback
        )
    ) {
        $fallback = [datetime]::SpecifyKind(
            $fallback,
            [System.DateTimeKind]::Unspecified
        )

        return [pscustomobject]@{
            Success = $true
            Normalized = $fallback.ToString("yyyy-MM-dd HH:mm")
            DateTime = $fallback
        }
    }

    return [pscustomobject]@{
        Success = $false
        Normalized = ""
        DateTime = $null
    }
}

function Convert-SteamTimestamp {
    param(
        [AllowNull()]
        [AllowEmptyString()]
        [string]$Value
    )

    if ([string]::IsNullOrWhiteSpace($Value)) {
        return $null
    }

    $parsed = [datetime]::MinValue

    if (
        [datetime]::TryParseExact(
            $Value,
            "yyyy-MM-dd HH:mm",
            [System.Globalization.CultureInfo]::InvariantCulture,
            [System.Globalization.DateTimeStyles]::None,
            [ref]$parsed
        )
    ) {
        return [datetime]::SpecifyKind(
            $parsed,
            [System.DateTimeKind]::Unspecified
        )
    }

    return $null
}

function Get-PageTitle {
    param(
        [Parameter(Mandatory)]
        [string]$Html
    )

    $match = [regex]::Match(
        $Html,
        '(?is)<h1\b[^>]*>(?<title>.*?)</h1>'
    )

    if (-not $match.Success) {
        return ""
    }

    return Convert-HtmlFragmentToText $match.Groups["title"].Value
}

function Get-PrimaryWorkshopId {
    param(
        [Parameter(Mandatory)]
        [string]$Html
    )

    $match = [regex]::Match(
        $Html,
        '(?i)https?://steamcommunity\.com/(?:sharedfiles|workshop)/filedetails/\?[^"''<>\s]*?id=(?<id>\d+)'
    )

    if (-not $match.Success) {
        return ""
    }

    return $match.Groups["id"].Value
}

function Get-CurrentDownloadUrl {
    param(
        [Parameter(Mandatory)]
        [string]$Html
    )

    $revisionIndex = $Html.IndexOf(
        "Revisions:",
        [System.StringComparison]::OrdinalIgnoreCase
    )

    if ($revisionIndex -ge 0) {
        $section = $Html.Substring(0, $revisionIndex)
    }
    else {
        $section = $Html
    }

    $matches = [regex]::Matches(
        $section,
        '(?is)<a\b[^>]*href\s*=\s*["''](?<url>https?://(?:www\.)?modsbase\.com/[^"'']+)["''][^>]*>(?<label>.*?)</a>'
    )

    foreach ($match in $matches) {
        $label = Convert-HtmlFragmentToText $match.Groups["label"].Value

        if ($label -eq "Download") {
            return [System.Net.WebUtility]::HtmlDecode(
                $match.Groups["url"].Value
            )
        }
    }

    return ""
}

function Get-OldRevisionLinks {
    param(
        [Parameter(Mandatory)]
        [string]$Html
    )

    $revisionIndex = $Html.IndexOf(
        "Revisions:",
        [System.StringComparison]::OrdinalIgnoreCase
    )

    if ($revisionIndex -lt 0) {
        return @()
    }

    $followIndex = $Html.IndexOf(
        "Follow:",
        $revisionIndex,
        [System.StringComparison]::OrdinalIgnoreCase
    )

    if ($followIndex -gt $revisionIndex) {
        $section = $Html.Substring(
            $revisionIndex,
            $followIndex - $revisionIndex
        )
    }
    else {
        $section = $Html.Substring($revisionIndex)
    }

    $result = [System.Collections.Generic.List[object]]::new()

    $matches = [regex]::Matches(
        $section,
        '(?is)<a\b[^>]*href\s*=\s*["''](?<url>https?://(?:www\.)?modsbase\.com/[^"'']+)["''][^>]*>(?<label>.*?)</a>'
    )

    foreach ($match in $matches) {
        $label = Convert-HtmlFragmentToText $match.Groups["label"].Value

        if ($label -notmatch '(?i)\bUTC\b') {
            continue
        }

        $result.Add(
            [pscustomobject]@{
                RawTime = $label
                DownloadUrl = [System.Net.WebUtility]::HtmlDecode(
                    $match.Groups["url"].Value
                )
            }
        )
    }

    return @($result)
}

if (-not (Test-Path -LiteralPath $EventMatrixPath)) {
    throw "Required input not found: $EventMatrixPath"
}

$duplicateSourceIds = @(
    $Sources |
        Group-Object WorkshopId |
        Where-Object { $_.Count -ne 1 }
)

if ($duplicateSourceIds.Count -gt 0) {
    throw "Duplicate Workshop IDs exist in the Skymods source configuration."
}

if (Test-Path -LiteralPath $OutputDirectory) {
    Remove-Item -LiteralPath $OutputDirectory -Recurse -Force
}

New-Item -ItemType Directory -Path $OutputDirectory -Force | Out-Null
New-Item -ItemType Directory -Path $RawPagesDirectory -Force | Out-Null
New-Item -ItemType Directory -Path $PackageDirectory -Force | Out-Null

$eventMatrix = @(Import-Csv -LiteralPath $EventMatrixPath)

$warnings = [System.Collections.Generic.List[string]]::new()
$validationErrors = [System.Collections.Generic.List[string]]::new()

if ($eventMatrix.Count -ne $ExpectedSteamEventCount) {
    $validationErrors.Add(
        "Expected $ExpectedSteamEventCount Steam events from Analysis 05 but found $($eventMatrix.Count)."
    )
}

$eventRepoCount = @(
    $eventMatrix.Repo |
        Select-Object -Unique
).Count

if ($eventRepoCount -ne $ExpectedRepoCount) {
    $validationErrors.Add(
        "Expected $ExpectedRepoCount target repositories but found $eventRepoCount."
    )
}

$pageSummaries = [System.Collections.Generic.List[object]]::new()
$revisionRows = [System.Collections.Generic.List[object]]::new()
$rawPageIndex = [System.Collections.Generic.List[object]]::new()

foreach ($source in $Sources) {
    Write-Host ""
    Write-Host "============================================================"
    Write-Host "$($source.Repo) [$($source.WorkshopId)]"
    Write-Host "============================================================"

    $rawPath = Join-Path `
        $RawPagesDirectory `
        "$($source.WorkshopId).html"

    try {
        $pageResult = Get-CachedPage `
            -Url $source.CatalogueUrl `
            -Path $rawPath

        $html = [System.IO.File]::ReadAllText(
            $rawPath,
            [System.Text.UTF8Encoding]::new($false)
        )

        $pageText = Convert-HtmlFragmentToText $html
        $referenceYear = Get-ReferenceYear $pageText

        $pageTitle = Get-PageTitle $html
        $primaryWorkshopId = Get-PrimaryWorkshopId $html
        $workshopIdMatches = (
            $primaryWorkshopId -eq $source.WorkshopId
        )

        if (-not $workshopIdMatches) {
            $validationErrors.Add(
                "$($source.Repo): Skymods page primary Workshop ID '$primaryWorkshopId' does not match expected '$($source.WorkshopId)'."
            )
        }

        $archiveIdMatch = [regex]::Match(
            $source.CatalogueUrl,
            '/archives/(?<id>\d+)'
        )

        $archiveId = if ($archiveIdMatch.Success) {
            $archiveIdMatch.Groups["id"].Value
        }
        else {
            ""
        }

        $lastRevisionMatch = [regex]::Match(
            $pageText,
            '(?i)Last revision:\s*(?<time>\d{1,2}\s+[A-Za-z]+,?\s*(?:20\d{2}\s+)?at\s+\d{1,2}:\d{2}\s+UTC)(?:\s*\((?<count>\d+)\))?'
        )

        $currentRawTime = ""
        $declaredOldRevisionCount = $null

        if ($lastRevisionMatch.Success) {
            $currentRawTime = $lastRevisionMatch.Groups["time"].Value

            if ($lastRevisionMatch.Groups["count"].Success) {
                $declaredOldRevisionCount = [int]$lastRevisionMatch.Groups["count"].Value
            }
        }
        else {
            $validationErrors.Add(
                "$($source.Repo): could not parse the Skymods Last revision field."
            )
        }

        $currentTimestamp = Convert-SkymodsTimestamp `
            -RawValue $currentRawTime `
            -ReferenceYear $referenceYear

        if (
            -not [string]::IsNullOrWhiteSpace($currentRawTime) -and
            -not $currentTimestamp.Success
        ) {
            $validationErrors.Add(
                "$($source.Repo): could not normalize current Skymods revision time '$currentRawTime'."
            )
        }

        $fileSizeMatch = [regex]::Match(
            $pageText,
            '(?im)^File size:\s*(?<size>[^\r\n]+)'
        )

        $fileSize = if ($fileSizeMatch.Success) {
            $fileSizeMatch.Groups["size"].Value.Trim()
        }
        else {
            ""
        }

        $currentDownloadUrl = Get-CurrentDownloadUrl $html

        if ([string]::IsNullOrWhiteSpace($currentDownloadUrl)) {
            $warnings.Add(
                "$($source.Repo): no current Modsbase download URL was parsed."
            )
        }

        $oldRevisionLinks = @(Get-OldRevisionLinks $html)

        if (
            $null -ne $declaredOldRevisionCount -and
            $declaredOldRevisionCount -ne $oldRevisionLinks.Count
        ) {
            $validationErrors.Add(
                "$($source.Repo): Skymods declares $declaredOldRevisionCount old revisions but $($oldRevisionLinks.Count) revision links were parsed."
            )
        }

        $pageSha256 = Get-Sha256 $rawPath

        $rawPageIndex.Add(
            [pscustomobject]@{
                Repo = $source.Repo
                Abbreviation = $source.Abbreviation
                WorkshopId = $source.WorkshopId
                CatalogueUrl = $source.CatalogueUrl
                RawPath = (
                    [System.IO.Path]::GetRelativePath(
                        $RepoRoot,
                        $rawPath
                    ) -replace '\\', '/'
                )
                Sha256 = $pageSha256
                Bytes = (Get-Item -LiteralPath $rawPath).Length
                FetchedAtUtc = $pageResult.FetchedAtUtc.ToString("yyyy-MM-dd HH:mm:ss")
                FromCache = $pageResult.FromCache
            }
        )

        $currentRevisionKey = "$($source.WorkshopId)|1"

        $revisionRows.Add(
            [pscustomobject]@{
                RevisionKey = $currentRevisionKey
                Repo = $source.Repo
                Abbreviation = $source.Abbreviation
                WorkshopId = $source.WorkshopId
                CatalogueArchiveId = $archiveId
                CatalogueUrl = $source.CatalogueUrl
                SkymodsTitle = $pageTitle
                NewestOrdinal = 1
                IsCurrentRevision = $true
                RawDisplayedTime = $currentRawTime
                NormalizedUtcTime = $currentTimestamp.Normalized
                TimeParsed = $currentTimestamp.Success
                DownloadUrl = $currentDownloadUrl
                PageReferenceYear = $referenceYear
                RawPageSha256 = $pageSha256
                ContentVerified = $false
            }
        )

        $parsedOldRevisions = [System.Collections.Generic.List[object]]::new()

        foreach ($oldLink in $oldRevisionLinks) {
            $parsedTime = Convert-SkymodsTimestamp `
                -RawValue $oldLink.RawTime `
                -ReferenceYear $referenceYear

            if (-not $parsedTime.Success) {
                $warnings.Add(
                    "$($source.Repo): could not normalize old revision time '$($oldLink.RawTime)'."
                )
            }

            $parsedOldRevisions.Add(
                [pscustomobject]@{
                    RawTime = $oldLink.RawTime
                    DownloadUrl = $oldLink.DownloadUrl
                    TimeParsed = $parsedTime.Success
                    Normalized = $parsedTime.Normalized
                    DateTime = $parsedTime.DateTime
                }
            )
        }

        $nextOrdinal = 2

        for (
            $index = $parsedOldRevisions.Count - 1;
            $index -ge 0;
            $index--
        ) {
            $oldRevision = $parsedOldRevisions[$index]

            $revisionRows.Add(
                [pscustomobject]@{
                    RevisionKey = "$($source.WorkshopId)|$nextOrdinal"
                    Repo = $source.Repo
                    Abbreviation = $source.Abbreviation
                    WorkshopId = $source.WorkshopId
                    CatalogueArchiveId = $archiveId
                    CatalogueUrl = $source.CatalogueUrl
                    SkymodsTitle = $pageTitle
                    NewestOrdinal = $nextOrdinal
                    IsCurrentRevision = $false
                    RawDisplayedTime = $oldRevision.RawTime
                    NormalizedUtcTime = $oldRevision.Normalized
                    TimeParsed = $oldRevision.TimeParsed
                    DownloadUrl = $oldRevision.DownloadUrl
                    PageReferenceYear = $referenceYear
                    RawPageSha256 = $pageSha256
                    ContentVerified = $false
                }
            )

            $nextOrdinal++
        }

        $pageSummaries.Add(
            [pscustomobject]@{
                Repo = $source.Repo
                Abbreviation = $source.Abbreviation
                WorkshopId = $source.WorkshopId
                CatalogueArchiveId = $archiveId
                CatalogueUrl = $source.CatalogueUrl
                SkymodsTitle = $pageTitle
                PrimaryWorkshopId = $primaryWorkshopId
                WorkshopIdMatches = $workshopIdMatches
                PageReferenceYear = $referenceYear
                CurrentRawRevisionTime = $currentRawTime
                CurrentNormalizedUtcTime = $currentTimestamp.Normalized
                FileSize = $fileSize
                DeclaredOldRevisionCount = if (
                    $null -ne $declaredOldRevisionCount
                ) {
                    $declaredOldRevisionCount
                }
                else {
                    ""
                }
                ParsedOldRevisionCount = $oldRevisionLinks.Count
                TotalRevisionCount = $oldRevisionLinks.Count + 1
                CurrentDownloadUrlPresent = (
                    -not [string]::IsNullOrWhiteSpace($currentDownloadUrl)
                )
                RawPageSha256 = $pageSha256
                FromCache = $pageResult.FromCache
            }
        )

        Write-Host "Title: $pageTitle"
        Write-Host "Primary Workshop ID: $primaryWorkshopId"
        Write-Host "Current revision: $currentRawTime"
        Write-Host "Old revisions: $($oldRevisionLinks.Count)"
    }
    catch {
        $validationErrors.Add(
            "$($source.Repo): $($_.Exception.Message)"
        )

        Write-Warning $_.Exception.Message
    }
}

$timeCandidates = [System.Collections.Generic.List[object]]::new()

foreach ($event in $eventMatrix) {
    $steamTime = Convert-SteamTimestamp $event.SteamNormalizedFetchedTime

    if ($null -eq $steamTime) {
        $warnings.Add(
            "$($event.Repo) Steam event $($event.SteamNewestOrdinal): could not parse SteamNormalizedFetchedTime '$($event.SteamNormalizedFetchedTime)'."
        )

        continue
    }

    $sameModRevisions = @(
        $revisionRows |
            Where-Object {
                $_.WorkshopId -eq $event.WorkshopId -and
                $_.TimeParsed -eq $true
            }
    )

    foreach ($revision in $sameModRevisions) {
        $skymodsTime = Convert-SteamTimestamp $revision.NormalizedUtcTime

        if ($null -eq $skymodsTime) {
            continue
        }

        $signedDayDelta = (
            $skymodsTime.Date -
            $steamTime.Date
        ).Days

        $absoluteDayDelta = [math]::Abs($signedDayDelta)

        if ($absoluteDayDelta -gt 2) {
            continue
        }

        $unadjustedHours = (
            $skymodsTime -
            $steamTime
        ).TotalHours

        $timeCandidates.Add(
            [pscustomobject]@{
                Repo = $event.Repo
                Abbreviation = $event.Abbreviation
                WorkshopId = $event.WorkshopId

                SteamNewestOrdinal = $event.SteamNewestOrdinal
                SteamRawDisplayedTime = $event.SteamRawDisplayedTime
                SteamNormalizedFetchedTime = $event.SteamNormalizedFetchedTime
                SteamVersionText = $event.SteamVersionText

                GitAutoClassification = $event.AutoClassification
                GitCommitSha = $event.GitCommitSha
                GitSubject = $event.GitSubject

                SkymodsRevisionKey = $revision.RevisionKey
                SkymodsNewestOrdinal = $revision.NewestOrdinal
                SkymodsIsCurrentRevision = $revision.IsCurrentRevision
                SkymodsRawDisplayedTime = $revision.RawDisplayedTime
                SkymodsNormalizedUtcTime = $revision.NormalizedUtcTime
                SkymodsDownloadUrl = $revision.DownloadUrl

                SignedCalendarDayDelta = $signedDayDelta
                AbsoluteCalendarDayDelta = $absoluteDayDelta

                UnadjustedWallClockDeltaHours = [math]::Round(
                    $unadjustedHours,
                    2
                )

                ArchiveCandidateStatus = "UNVERIFIED"
                ContentVerified = $false
            }
        )
    }
}

$eventsWithArchiveCandidates = @{}

foreach ($candidate in $timeCandidates) {
    $key = "$($candidate.WorkshopId)|$($candidate.SteamNewestOrdinal)"
    $eventsWithArchiveCandidates[$key] = $true
}

$summary = [System.Collections.Generic.List[object]]::new()

foreach ($source in $Sources) {
    $repoEvents = @(
        $eventMatrix |
            Where-Object {
                $_.WorkshopId -eq $source.WorkshopId
            }
    )

    $repoRevisions = @(
        $revisionRows |
            Where-Object {
                $_.WorkshopId -eq $source.WorkshopId
            }
    )

    $repoCandidates = @(
        $timeCandidates |
            Where-Object {
                $_.WorkshopId -eq $source.WorkshopId
            }
    )

    $eventsWithCandidateCount = 0

    foreach ($event in $repoEvents) {
        $key = "$($event.WorkshopId)|$($event.SteamNewestOrdinal)"

        if ($eventsWithArchiveCandidates.ContainsKey($key)) {
            $eventsWithCandidateCount++
        }
    }

    $pageSummary = @(
        $pageSummaries |
            Where-Object {
                $_.WorkshopId -eq $source.WorkshopId
            }
    ) |
        Select-Object -First 1

    $summary.Add(
        [pscustomobject]@{
            Repo = $source.Repo
            Abbreviation = $source.Abbreviation
            WorkshopId = $source.WorkshopId
            SteamEventCount = $repoEvents.Count
            SkymodsRevisionCount = $repoRevisions.Count
            SkymodsOldRevisionCount = if ($null -ne $pageSummary) {
                $pageSummary.ParsedOldRevisionCount
            }
            else {
                ""
            }
            TimeCandidatePairCount = $repoCandidates.Count
            SteamEventsWithArchiveCandidate = $eventsWithCandidateCount
            SteamEventsWithoutArchiveCandidate = (
                $repoEvents.Count -
                $eventsWithCandidateCount
            )
            CurrentSkymodsRevisionTime = if ($null -ne $pageSummary) {
                $pageSummary.CurrentNormalizedUtcTime
            }
            else {
                ""
            }
            WorkshopIdMatches = if ($null -ne $pageSummary) {
                $pageSummary.WorkshopIdMatches
            }
            else {
                $false
            }
        }
    )
}

if ($pageSummaries.Count -ne $ExpectedRepoCount) {
    $validationErrors.Add(
        "Expected $ExpectedRepoCount parsed Skymods pages but found $($pageSummaries.Count)."
    )
}

$badWorkshopIds = @(
    $pageSummaries |
        Where-Object {
            $_.WorkshopIdMatches -ne $true
        }
)

if ($badWorkshopIds.Count -gt 0) {
    $validationErrors.Add(
        "$($badWorkshopIds.Count) Skymods page(s) failed primary Workshop ID validation."
    )
}

$duplicateRevisionKeys = @(
    $revisionRows |
        Group-Object RevisionKey |
        Where-Object {
            $_.Count -ne 1
        }
)

if ($duplicateRevisionKeys.Count -gt 0) {
    $validationErrors.Add(
        "Duplicate Skymods revision keys were produced."
    )
}

$unparsedRevisionTimes = @(
    $revisionRows |
        Where-Object {
            $_.TimeParsed -ne $true
        }
)

if ($unparsedRevisionTimes.Count -gt 0) {
    $validationErrors.Add(
        "$($unparsedRevisionTimes.Count) Skymods revision timestamp(s) could not be normalized."
    )
}

$sourceConfigPath = Join-Path $OutputDirectory "source-config.csv"
$pageSummaryPath = Join-Path $OutputDirectory "skymods-mod-summary.csv"
$revisionsPath = Join-Path $OutputDirectory "skymods-revisions.csv"
$timeCandidatesPath = Join-Path $OutputDirectory "steam-skymods-time-candidates.csv"
$summaryPath = Join-Path $OutputDirectory "summary.csv"
$rawPageIndexPath = Join-Path $OutputDirectory "raw-page-index.csv"
$warningsPath = Join-Path $OutputDirectory "warnings.txt"
$readmePath = Join-Path $OutputDirectory "README.md"

$Sources |
    Export-Csv `
        -LiteralPath $sourceConfigPath `
        -NoTypeInformation `
        -Encoding utf8

$pageSummaries |
    Sort-Object Repo |
    Export-Csv `
        -LiteralPath $pageSummaryPath `
        -NoTypeInformation `
        -Encoding utf8

$revisionRows |
    Sort-Object -Property @(
        @{
            Expression = { $_.Repo }
            Ascending = $true
        },
        @{
            Expression = { [int]$_.NewestOrdinal }
            Ascending = $true
        }
    ) |
    Export-Csv `
        -LiteralPath $revisionsPath `
        -NoTypeInformation `
        -Encoding utf8

$timeCandidates |
    Sort-Object -Property @(
        @{
            Expression = { $_.Repo }
            Ascending = $true
        },
        @{
            Expression = { [int]$_.SteamNewestOrdinal }
            Ascending = $true
        },
        @{
            Expression = { [int]$_.AbsoluteCalendarDayDelta }
            Ascending = $true
        },
        @{
            Expression = {
                [math]::Abs(
                    [double]$_.UnadjustedWallClockDeltaHours
                )
            }
            Ascending = $true
        }
    ) |
    Export-Csv `
        -LiteralPath $timeCandidatesPath `
        -NoTypeInformation `
        -Encoding utf8

$summary |
    Export-Csv `
        -LiteralPath $summaryPath `
        -NoTypeInformation `
        -Encoding utf8

$rawPageIndex |
    Sort-Object Repo |
    Export-Csv `
        -LiteralPath $rawPageIndexPath `
        -NoTypeInformation `
        -Encoding utf8

if ($warnings.Count -gt 0) {
    $warnings |
        Set-Content `
            -LiteralPath $warningsPath `
            -Encoding utf8
}
else {
    [System.IO.File]::WriteAllText(
        $warningsPath,
        "",
        [System.Text.UTF8Encoding]::new($false)
    )
}

$generatedAt = Get-Date -Format "yyyy-MM-dd HH:mm:ss zzz"

$readme = @"
# Analysis 06 - Skymods Archive Inventory

Generated: $generatedAt

This analysis inventories Skymods catalogue pages and revision links for the
selected CK3 Workshop targets.

It does not download or validate the contents of any Modsbase archive.

## Inputs

- analysis/results/05-steam-git-candidate-mapping/steam-git-event-matrix.csv

## Outputs

### source-config.csv

The exact Skymods catalogue page assigned to each selected Workshop item.

### skymods-mod-summary.csv

One row per selected mod containing:

- catalogue page identity
- primary Workshop ID validation
- current Skymods revision timestamp
- declared and parsed old-revision counts
- current file-size metadata
- raw-page SHA-256 provenance

### skymods-revisions.csv

One row for every current or historical revision exposed by Skymods.

Revision timestamps are retained as displayed by Skymods and additionally
normalized without timezone conversion.

ContentVerified remains False because no archive bytes are inspected here.

### steam-skymods-time-candidates.csv

Potential Steam-event / Skymods-revision relationships based only on calendar
proximity of up to two days.

Steam's displayed timestamp and Skymods' UTC timestamp are not assumed to use
the same time basis.

UnadjustedWallClockDeltaHours is diagnostic only and must not be interpreted as
a canonical timezone conversion.

Every archive candidate remains UNVERIFIED.

### raw-page-index.csv

SHA-256 provenance for the retained Skymods catalogue HTML pages.

### raw-pages/

Exact downloaded catalogue pages used by this analysis.

### summary.csv

Per-mod Steam event, Skymods revision, and archive-candidate counts.

## Evidence policy

A Skymods revision link proves only that an archive candidate is exposed by
Skymods for the displayed revision time.

It does not prove that:

- the archive belongs to the expected Workshop item
- the archive contents match a historical Git snapshot
- the archive corresponds to a specific Steam Change Notes event
- the archive timestamp is an exact Steam Workshop update timestamp

Those questions require archive-content inspection.

The next content-verification stage should validate downloaded candidates using
descriptor Workshop IDs, file inventories, deterministic fingerprints, and
historical Git snapshot comparisons before assigning KNOWN + RECOVERED or
KNOWN + EXISTING statuses.

## Validation

Steam events: $($eventMatrix.Count)
Target mods: $($Sources.Count)
Parsed Skymods pages: $($pageSummaries.Count)
Parsed Skymods revisions: $($revisionRows.Count)
Steam/Skymods time candidate pairs: $($timeCandidates.Count)
Warnings: $($warnings.Count)
Validation errors: $($validationErrors.Count)
"@

$readme |
    Set-Content `
        -LiteralPath $readmePath `
        -Encoding utf8

if (Test-Path -LiteralPath $PackagePath) {
    Remove-Item -LiteralPath $PackagePath -Force
}

$packageSources = @(
    $OutputDirectory
)

if (-not [string]::IsNullOrWhiteSpace($PSCommandPath)) {
    $packageSources += $PSCommandPath
}

Compress-Archive `
    -LiteralPath $packageSources `
    -DestinationPath $PackagePath `
    -CompressionLevel Optimal

Write-Host ""
Write-Host "================ ANALYSIS 06 COMPLETE ================"
Write-Host ""

$summary |
    Format-Table `
        Repo,
        SteamEventCount,
        SkymodsRevisionCount,
        TimeCandidatePairCount,
        SteamEventsWithArchiveCandidate,
        SteamEventsWithoutArchiveCandidate `
        -AutoSize

Write-Host ""
Write-Host "Steam events: $($eventMatrix.Count)"
Write-Host "Target mods: $($Sources.Count)"
Write-Host "Parsed Skymods pages: $($pageSummaries.Count)"
Write-Host "Parsed Skymods revisions: $($revisionRows.Count)"
Write-Host "Steam/Skymods time candidate pairs: $($timeCandidates.Count)"
Write-Host "Warnings: $($warnings.Count)"
Write-Host "Validation errors: $($validationErrors.Count)"
Write-Host ""

if ($validationErrors.Count -eq 0) {
    Write-Host "Validation: PASS"
}
else {
    Write-Host "Validation: FAIL"

    foreach ($validationError in $validationErrors) {
        Write-Host "  - $validationError"
    }
}

Write-Host ""
Write-Host "Results:"
Write-Host "  $OutputDirectory"

Write-Host ""
Write-Host "Package:"
Write-Host "  $PackagePath"
