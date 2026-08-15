$ErrorActionPreference = "Stop"

$RepoRoot    = "F:\Storage\Codding\projects\ck3\ck3-workshop-history"
$OutDir      = Join-Path $RepoRoot "analysis\results\04-steam-event-inventory"
$RawDir      = Join-Path $OutDir "raw-pages"
$PackageDir  = Join-Path $RepoRoot "analysis\packages"
$PackagePath = Join-Path $PackageDir "04-steam-event-inventory.zip"

$ForceRefresh = $false
$MaxPages = 100

$MinDelayMs = 4000
$MaxDelayMs = 6000
$MaxAttempts = 4
$DefaultRateLimitWaitSeconds = 90

$Targets = @(
    @{ Repo="Community-Flavor-Pack";              Abbr="CFP";         WorkshopId="2220098919" },
    @{ Repo="Culture-and-Faith-Granularity";      Abbr="CFG";         WorkshopId="3206891770" },
    @{ Repo="Culture-Expanded";                   Abbr="CE";          WorkshopId="2829397295" },
    @{ Repo="Demand-Tribute";                     Abbr="DT";          WorkshopId="3473488611" },
    @{ Repo="EPE-CFP";                            Abbr="EPE-CFP";     WorkshopId="2996881191" },
    @{ Repo="Ethnicities-and-Portraits-Expanded"; Abbr="EPE";         WorkshopId="2507209632" },
    @{ Repo="MBP-EPE-CFP";                        Abbr="MBP-EPE-CFP"; WorkshopId="2543865921" },
    @{ Repo="MedievalImmersion";                  Abbr="MI";          WorkshopId="3268020725" },
    @{ Repo="MPE";                                Abbr="MPE";         WorkshopId="3726274827" },
    @{ Repo="RICE";                               Abbr="RICE";        WorkshopId="2273832430" },
    @{ Repo="Special-World";                      Abbr="SW";          WorkshopId="2875587269" },
    @{ Repo="Turkic-World-Expanded";              Abbr="TWE";         WorkshopId="3668769244" },
    @{ Repo="Western-Steppe-Expanded";            Abbr="WSE";         WorkshopId="3490396842" }
)

function Convert-HtmlFragmentToText {
    param(
        [string]$Html
    )

    $Text = $Html

    $Text = [regex]::Replace(
        $Text,
        '(?is)<script\b[^>]*>.*?</script>',
        ' '
    )

    $Text = [regex]::Replace(
        $Text,
        '(?is)<style\b[^>]*>.*?</style>',
        ' '
    )

    $Text = [regex]::Replace(
        $Text,
        '(?i)<br\s*/?>',
        "`n"
    )

    $Text = [regex]::Replace(
        $Text,
        '(?i)</(?:div|p|li|h[1-6]|tr|section|article)>',
        "`n"
    )

    $Text = [regex]::Replace(
        $Text,
        '<[^>]+>',
        ' '
    )

    $Text = [System.Net.WebUtility]::HtmlDecode($Text)
    $Text = $Text.Replace([char]0x00A0, ' ')

    $Lines = foreach ($Line in ($Text -split "\r?\n")) {
        $Clean = [regex]::Replace(
            $Line,
            '\s+',
            ' '
        ).Trim()

        if ($Clean) {
            $Clean
        }
    }

    return ($Lines -join "`n")
}

function Get-SteamUpdateHeadlineMatches {
    param(
        [string]$Html
    )

    # A real Steam Workshop event is represented by:
    #
    # <div class="changelog headline">Update: ...</div>
    #
    # Change-note bodies are allowed to contain ordinary text beginning
    # with "Update:" or "UPDATE:". Those must not be treated as events.
    $Pattern =
        '(?is)<div\b' +
        '(?=[^>]*\bclass\s*=\s*"[^"]*\bchangelog\b[^"]*")' +
        '(?=[^>]*\bclass\s*=\s*"[^"]*\bheadline\b[^"]*")' +
        '[^>]*>(.*?)</div>'

    return [regex]::Matches(
        $Html,
        $Pattern
    )
}

function Normalize-SteamDisplayedTime {
    param(
        [string]$Raw,
        [int]$DefaultYear
    )

    $Culture =
        [Globalization.CultureInfo]::InvariantCulture

    $Styles =
        [Globalization.DateTimeStyles]::AllowWhiteSpaces

    $Value = $Raw.Trim()

    if ($Value -match ',\s*\d{4}\s*@') {
        $Candidate = $Value
    }
    else {
        $Candidate =
            $Value -replace '\s*@', ", $DefaultYear @"
    }

    $Formats = @(
        "d MMM, yyyy @ h:mmtt",
        "dd MMM, yyyy @ h:mmtt",
        "d MMM, yyyy @ hh:mmtt",
        "dd MMM, yyyy @ hh:mmtt"
    )

    foreach ($Format in $Formats) {
        $Parsed = [datetime]::MinValue

        if (
            [datetime]::TryParseExact(
                $Candidate,
                $Format,
                $Culture,
                $Styles,
                [ref]$Parsed
            )
        ) {
            return $Parsed.ToString(
                "yyyy-MM-dd HH:mm"
            )
        }
    }

    return $null
}

function Test-SteamChangeLogHtml {
    param(
        [string]$Html,
        [string]$Url
    )

    if ([string]::IsNullOrWhiteSpace($Html)) {
        throw "Steam returned an empty response: $Url"
    }

    if (
        $Html -match
        '(?is)<title>\s*Steam Community\s*::\s*Error\s*</title>'
    ) {
        throw "Steam returned an error page: $Url"
    }

    if (
        $Html -notmatch
        '(?is)changeLogCtn|changelog headline|Showing\s+\d+\s*-\s*\d+\s+of'
    ) {
        throw "Response does not look like a Steam Change Notes page: $Url"
    }
}

function Get-HttpStatusCode {
    param(
        $ErrorRecord
    )

    try {
        return [int]$ErrorRecord.Exception.Response.StatusCode
    }
    catch {
        return $null
    }
}

function Get-RetryAfterSeconds {
    param(
        $ErrorRecord,
        [int]$FallbackSeconds
    )

    try {
        $Values = @(
            $ErrorRecord.Exception.Response.Headers.GetValues(
                "Retry-After"
            )
        )

        if ($Values.Count -gt 0) {
            $Seconds = 0

            if (
                [int]::TryParse(
                    $Values[0],
                    [ref]$Seconds
                )
            ) {
                return [Math]::Max(
                    $Seconds,
                    $FallbackSeconds
                )
            }
        }
    }
    catch {
    }

    return $FallbackSeconds
}

function Wait-BetweenSteamRequests {
    $Delay = Get-Random `
        -Minimum $MinDelayMs `
        -Maximum ($MaxDelayMs + 1)

    Write-Host (
        "Waiting {0:N1}s before the next Steam request..." -f
        ($Delay / 1000)
    )

    Start-Sleep -Milliseconds $Delay
}

function Get-SteamPage {
    param(
        [string]$WorkshopId,
        [int]$Page
    )

    $Url =
        "https://steamcommunity.com/sharedfiles/filedetails/changelog/${WorkshopId}?p=$Page&l=english"

    $RawModDir =
        Join-Path $RawDir $WorkshopId

    New-Item `
        -ItemType Directory `
        -Path $RawModDir `
        -Force |
        Out-Null

    $RawPath = Join-Path $RawModDir (
        "page-{0:D3}.html" -f $Page
    )

    if (
        (-not $ForceRefresh) -and
        (Test-Path $RawPath)
    ) {
        $Html = Get-Content `
            -LiteralPath $RawPath `
            -Raw `
            -Encoding utf8

        try {
            Test-SteamChangeLogHtml `
                -Html $Html `
                -Url $Url

            return [pscustomobject]@{
                Url       = $Url
                Html      = $Html
                RawPath   = $RawPath
                FromCache = $true

                FetchedAt = (
                    Get-Item $RawPath
                ).LastWriteTimeUtc.ToString("o")
            }
        }
        catch {
            Write-Host (
                "Cached page {0} is invalid; downloading it again." -f
                $Page
            )

            Remove-Item `
                -LiteralPath $RawPath `
                -Force
        }
    }

    $Headers = @{
        "User-Agent" =
            "Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 Chrome/151 Safari/537.36"

        "Accept-Language" =
            "en-US,en;q=0.9"

        "Accept" =
            "text/html,application/xhtml+xml,application/xml;q=0.9,*/*;q=0.8"
    }

    $LastError = $null

    for (
        $Attempt = 1;
        $Attempt -le $MaxAttempts;
        $Attempt++
    ) {
        try {
            $Response = Invoke-WebRequest `
                -Uri $Url `
                -Headers $Headers `
                -TimeoutSec 45 `
                -MaximumRedirection 5

            $Html = $Response.Content

            Test-SteamChangeLogHtml `
                -Html $Html `
                -Url $Url

            Set-Content `
                -LiteralPath $RawPath `
                -Value $Html `
                -Encoding utf8

            Wait-BetweenSteamRequests

            return [pscustomobject]@{
                Url       = $Url
                Html      = $Html
                RawPath   = $RawPath
                FromCache = $false

                FetchedAt = (
                    Get-Date
                ).ToUniversalTime().ToString("o")
            }
        }
        catch {
            $LastError = $_
            $StatusCode =
                Get-HttpStatusCode $_

            if ($StatusCode -eq 429) {
                $FallbackWait =
                    $DefaultRateLimitWaitSeconds * $Attempt

                $WaitSeconds =
                    Get-RetryAfterSeconds `
                        -ErrorRecord $_ `
                        -FallbackSeconds $FallbackWait

                Write-Host ""
                Write-Host (
                    "Steam returned HTTP 429 for page {0}." -f
                    $Page
                )

                if ($Attempt -lt $MaxAttempts) {
                    Write-Host (
                        "Cooling down for {0}s before retry {1}/{2}..." -f
                        $WaitSeconds,
                        ($Attempt + 1),
                        $MaxAttempts
                    )

                    Start-Sleep `
                        -Seconds $WaitSeconds

                    continue
                }
            }

            if ($Attempt -lt $MaxAttempts) {
                $WaitSeconds = [Math]::Pow(
                    2,
                    $Attempt
                )

                Write-Host (
                    "Request failed. Retrying in {0}s ({1}/{2})..." -f
                    $WaitSeconds,
                    ($Attempt + 1),
                    $MaxAttempts
                )

                Start-Sleep `
                    -Seconds $WaitSeconds
            }
        }
    }

    throw (
        "Failed to fetch {0} after {1} attempts: {2}" -f
        $Url,
        $MaxAttempts,
        $LastError.Exception.Message
    )
}

function Get-UsefulPreviewLines {
    param(
        [string]$Segment
    )

    $Result = foreach (
        $Line in ($Segment -split "\r?\n")
    ) {
        $Value = $Line.Trim()

        if (-not $Value) {
            continue
        }

        if ($Value -match '^by\s+') {
            continue
        }

        if ($Value -match '^Image(?:\s|$)') {
            continue
        }

        if ($Value -match '^Discuss this update') {
            continue
        }

        if ($Value -match '^You need to sign in') {
            continue
        }

        if (
            $Value -match
            '^(?:Sign In|Create an Account|Cancel)$'
        ) {
            continue
        }

        $Value
    }

    return @($Result)
}

function New-AnalysisPackage {
    param(
        [string]$ResultDirectory
    )

    New-Item `
        -ItemType Directory `
        -Path $PackageDir `
        -Force |
        Out-Null

    if (Test-Path $PackagePath) {
        Remove-Item `
            -LiteralPath $PackagePath `
            -Force
    }

    $Items = @(
        $ResultDirectory
    )

    if (
        $PSCommandPath -and
        (Test-Path $PSCommandPath)
    ) {
        $Items += $PSCommandPath
    }

    Compress-Archive `
        -Path $Items `
        -DestinationPath $PackagePath `
        -CompressionLevel Optimal `
        -Force
}

if (-not (Test-Path $RepoRoot)) {
    throw "Repository not found: $RepoRoot"
}

New-Item `
    -ItemType Directory `
    -Path $OutDir `
    -Force |
    Out-Null

New-Item `
    -ItemType Directory `
    -Path $RawDir `
    -Force |
    Out-Null

$Events =
    [System.Collections.ArrayList]::new()

$Summaries =
    [System.Collections.ArrayList]::new()

$RawIndex =
    [System.Collections.ArrayList]::new()

$Warnings =
    [System.Collections.ArrayList]::new()

foreach ($Target in $Targets) {
    Write-Host ""
    Write-Host "============================================================"
    Write-Host "$($Target.Repo) [$($Target.WorkshopId)]"
    Write-Host "============================================================"

    $DeclaredCount = $null
    $ExpectedPages = $null
    $GlobalOrdinal = 0
    $ParsedForMod = 0
    $PagesFetched = 0

    for (
        $Page = 1;
        $Page -le $MaxPages;
        $Page++
    ) {
        if (
            $ExpectedPages -and
            ($Page -gt $ExpectedPages)
        ) {
            break
        }

        try {
            $PageData = Get-SteamPage `
                -WorkshopId $Target.WorkshopId `
                -Page $Page
        }
        catch {
            [void]$Warnings.Add(
                "$($Target.Repo) page $Page fetch failed: $($_.Exception.Message)"
            )

            break
        }

        $PagesFetched++

        $RawHash = (
            Get-FileHash `
                -LiteralPath $PageData.RawPath `
                -Algorithm SHA256
        ).Hash.ToLowerInvariant()

        $RawRelativePath = (
            [IO.Path]::GetRelativePath(
                $OutDir,
                $PageData.RawPath
            )
        ) -replace '\\', '/'

        [void]$RawIndex.Add(
            [pscustomobject]@{
                Repo         = $Target.Repo
                Abbreviation = $Target.Abbr
                WorkshopId   = $Target.WorkshopId
                Page         = $Page
                Url          = $PageData.Url
                FromCache    = $PageData.FromCache
                FetchedAtUtc = $PageData.FetchedAt
                Sha256       = $RawHash
                RawFile      = $RawRelativePath
            }
        )

        $PageText =
            Convert-HtmlFragmentToText `
                -Html $PageData.Html

        if ($Page -eq 1) {
            $CountMatch = [regex]::Match(
                $PageText,
                '(?im)Showing\s+\d+\s*-\s*\d+\s+of\s+([\d,]+)\s+entries'
            )

            if ($CountMatch.Success) {
                $DeclaredCount = [int](
                    $CountMatch.Groups[1].Value -replace ',', ''
                )

                $ExpectedPages =
                    [int][Math]::Ceiling(
                        $DeclaredCount / 10.0
                    )

                Write-Host (
                    "Steam declares {0} events across {1} pages." -f
                    $DeclaredCount,
                    $ExpectedPages
                )
            }
            else {
                [void]$Warnings.Add(
                    "$($Target.Repo): could not parse Steam's declared entry count."
                )

                Write-Host (
                    "Could not parse declared entry count; using end-of-pages detection."
                )
            }
        }

        $UpdateHeadlines = @(
            Get-SteamUpdateHeadlineMatches `
                -Html $PageData.Html
        )

        if ($UpdateHeadlines.Count -eq 0) {
            if ($Page -eq 1) {
                [void]$Warnings.Add(
                    "$($Target.Repo): no real Steam update headlines found on page 1."
                )
            }

            if (-not $ExpectedPages) {
                break
            }

            continue
        }

        Write-Host (
            "Page {0} -> {1} events" -f
            $Page,
            $UpdateHeadlines.Count
        )

        try {
            $PageCaptureYear = (
                [DateTimeOffset]::Parse(
                    $PageData.FetchedAt,
                    [Globalization.CultureInfo]::InvariantCulture
                )
            ).Year
        }
        catch {
            $PageCaptureYear =
                (Get-Date).Year
        }

        for (
            $Index = 0;
            $Index -lt $UpdateHeadlines.Count;
            $Index++
        ) {
            $UpdateHeadline =
                $UpdateHeadlines[$Index]

            $GlobalOrdinal++
            $ParsedForMod++

            $HeadlineText =
                Convert-HtmlFragmentToText `
                    -Html $UpdateHeadline.Groups[1].Value

            $RawWhen = (
                $HeadlineText -replace
                '(?i)^Update:\s*',
                ''
            ).Trim()

            $SegmentStart = (
                $UpdateHeadline.Index +
                $UpdateHeadline.Length
            )

            if (
                $Index + 1 -lt
                $UpdateHeadlines.Count
            ) {
                $SegmentEnd =
                    $UpdateHeadlines[
                        $Index + 1
                    ].Index
            }
            else {
                $SegmentEnd =
                    $PageData.Html.Length
            }

            if ($SegmentEnd -gt $SegmentStart) {
                $SegmentHtml =
                    $PageData.Html.Substring(
                        $SegmentStart,
                        $SegmentEnd - $SegmentStart
                    )
            }
            else {
                $SegmentHtml = ""
            }

            $SegmentText =
                Convert-HtmlFragmentToText `
                    -Html $SegmentHtml

            $PreviewLines = @(
                Get-UsefulPreviewLines `
                    -Segment $SegmentText
            )

            $VersionText = @(
                $PreviewLines |
                    Where-Object {
                        [regex]::IsMatch(
                            $_,
                            '^(?:Version\s+|v?\d+(?:\.\d+)+)'
                        )
                    } |
                    Select-Object -First 1
            )

            $Preview = @(
                $PreviewLines |
                    Select-Object -First 1
            )

            $NormalizedFetchedTime =
                Normalize-SteamDisplayedTime `
                    -Raw $RawWhen `
                    -DefaultYear $PageCaptureYear

            if (-not $NormalizedFetchedTime) {
                [void]$Warnings.Add(
                    "$($Target.Repo) page $Page event $($Index + 1): timestamp parse failed: '$RawWhen'"
                )
            }

            [void]$Events.Add(
                [pscustomobject]@{
                    Repo                  = $Target.Repo
                    Abbreviation          = $Target.Abbr
                    WorkshopId            = $Target.WorkshopId
                    NewestOrdinal         = $GlobalOrdinal
                    Page                  = $Page
                    PositionOnPage        = $Index + 1
                    RawDisplayedTime      = $RawWhen
                    NormalizedFetchedTime = $NormalizedFetchedTime

                    VersionText =
                        if ($VersionText.Count) {
                            $VersionText[0]
                        }
                        else {
                            $null
                        }

                    Preview =
                        if ($Preview.Count) {
                            $Preview[0]
                        }
                        else {
                            $null
                        }

                    SourceUrl =
                        $PageData.Url

                    RawPageSha256 =
                        $RawHash

                    CanonicalTimeVerified =
                        $false
                }
            )
        }

        if (
            (-not $ExpectedPages) -and
            ($UpdateHeadlines.Count -lt 10)
        ) {
            break
        }
    }

    if (
        ($null -ne $DeclaredCount) -and
        ($ParsedForMod -ne $DeclaredCount)
    ) {
        [void]$Warnings.Add(
            "$($Target.Repo): Steam declares $DeclaredCount entries but parser found $ParsedForMod."
        )
    }

    [void]$Summaries.Add(
        [pscustomobject]@{
            Repo               = $Target.Repo
            Abbreviation       = $Target.Abbr
            WorkshopId         = $Target.WorkshopId
            DeclaredEventCount = $DeclaredCount
            ParsedEventCount   = $ParsedForMod
            PagesFetched       = $PagesFetched

            CountsMatch = (
                ($null -ne $DeclaredCount) -and
                ($DeclaredCount -eq $ParsedForMod)
            )
        }
    )
}

$Events |
    Export-Csv `
        (Join-Path $OutDir "steam-events.csv") `
        -NoTypeInformation `
        -Encoding utf8

$Summaries |
    Export-Csv `
        (Join-Path $OutDir "steam-mod-summary.csv") `
        -NoTypeInformation `
        -Encoding utf8

$RawIndex |
    Export-Csv `
        (Join-Path $OutDir "raw-page-index.csv") `
        -NoTypeInformation `
        -Encoding utf8

if ($Warnings.Count -gt 0) {
    $Warnings |
        Set-Content `
            (Join-Path $OutDir "warnings.txt") `
            -Encoding utf8
}
else {
    "No warnings." |
        Set-Content `
            (Join-Path $OutDir "warnings.txt") `
            -Encoding utf8
}

@'
# Analysis 04 — Steam Event Inventory

Read-only inventory of Steam Workshop Change Notes for the selected CK3 mods.

## Outputs

- `steam-events.csv`
- `steam-mod-summary.csv`
- `raw-page-index.csv`
- `warnings.txt`
- `raw-pages/`

Every fetched Steam Change Notes page is retained as raw HTML and indexed by
SHA-256 so the parser results can be audited and reproduced.

`raw-pages/` also acts as the local cache for subsequent analysis runs. Set
`$ForceRefresh = $true` in the analysis script when the Steam pages should be
downloaded again.

Events are identified from Steam's actual changelog headline HTML structure
(`div.changelog.headline`) rather than from arbitrary text beginning with
`Update:`. Change-note bodies may themselves contain text beginning with
`Update:` and must not be interpreted as separate Workshop events.

`RawDisplayedTime` is the timestamp text returned by the direct Steam HTTP
request used for this analysis.

`NormalizedFetchedTime` converts that returned text to `YYYY-MM-DD HH:mm`
without performing a timezone conversion.

It is not yet treated as the canonical Workshop timestamp. Steam's browser
display context must first be compared against these values. Every event is
therefore emitted with `CanonicalTimeVerified=False`.

This analysis does not modify any source archive repository or Steam Workshop
folder and does not automatically classify Git snapshot matches.
'@ |
    Set-Content `
        (Join-Path $OutDir "README.md") `
        -Encoding utf8

New-AnalysisPackage `
    -ResultDirectory $OutDir

$FailedCounts = @(
    $Summaries |
        Where-Object {
            -not $_.CountsMatch
        }
)

Write-Host ""
Write-Host "================ ANALYSIS 04 COMPLETE ================"

$Summaries |
    Format-Table `
        Repo,
        DeclaredEventCount,
        ParsedEventCount,
        PagesFetched,
        CountsMatch `
        -AutoSize

Write-Host ""
Write-Host "Total parsed Steam events: $($Events.Count)"
Write-Host "Warnings: $($Warnings.Count)"

Write-Host ""

if ($FailedCounts.Count -eq 0) {
    Write-Host "Validation: PASS"
}
else {
    Write-Host (
        "Validation: FAIL ({0} mod(s) have mismatched event counts)" -f
        $FailedCounts.Count
    )
}

Write-Host ""
Write-Host "Results:"
Write-Host "  $OutDir"

Write-Host ""
Write-Host "Package:"
Write-Host "  $PackagePath"
