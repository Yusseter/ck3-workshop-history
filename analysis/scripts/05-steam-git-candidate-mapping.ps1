Set-StrictMode -Version Latest
$ErrorActionPreference = "Stop"

$AnalysisName = "05-steam-git-candidate-mapping"

$RepoRoot = (Resolve-Path (Join-Path $PSScriptRoot "..\..")).Path

$SteamEventsPath = Join-Path $RepoRoot "analysis\results\04-steam-event-inventory\steam-events.csv"
$CommitSnapshotsPath = Join-Path $RepoRoot "analysis\results\03-historical-commits\commit-snapshots.csv"
$CurrentComparisonPath = Join-Path $RepoRoot "analysis\results\02-content-classification\current-comparison-summary.csv"
$RepoSummaryPath = Join-Path $RepoRoot "analysis\results\01-inventory\repo-summary.csv"

$OutputDirectory = Join-Path $RepoRoot "analysis\results\$AnalysisName"
$PackageDirectory = Join-Path $RepoRoot "analysis\packages"
$PackagePath = Join-Path $PackageDirectory "$AnalysisName.zip"

$ExpectedSteamEventCount = 1198
$ExpectedRepoCount = 13

function ConvertTo-Integer {
    param(
        [AllowNull()]
        [AllowEmptyString()]
        [string]$Value
    )

    if ([string]::IsNullOrWhiteSpace($Value)) {
        return 0
    }

    $result = 0

    if ([int]::TryParse(
        $Value,
        [System.Globalization.NumberStyles]::Integer,
        [System.Globalization.CultureInfo]::InvariantCulture,
        [ref]$result
    )) {
        return $result
    }

    throw "Could not parse integer value: '$Value'"
}

function ConvertTo-Boolean {
    param(
        [AllowNull()]
        [AllowEmptyString()]
        [string]$Value
    )

    if ([string]::IsNullOrWhiteSpace($Value)) {
        return $false
    }

    $result = $false

    if ([bool]::TryParse($Value, [ref]$result)) {
        return $result
    }

    throw "Could not parse Boolean value: '$Value'"
}

function Get-SteamDisplayedDate {
    param(
        [AllowNull()]
        [AllowEmptyString()]
        [string]$Value
    )

    if ([string]::IsNullOrWhiteSpace($Value)) {
        return $null
    }

    $result = [datetime]::MinValue

    if ([datetime]::TryParseExact(
        $Value,
        "yyyy-MM-dd HH:mm",
        [System.Globalization.CultureInfo]::InvariantCulture,
        [System.Globalization.DateTimeStyles]::None,
        [ref]$result
    )) {
        return $result
    }

    return $null
}

function Get-GitWallClockDate {
    param(
        [AllowNull()]
        [AllowEmptyString()]
        [string]$Value
    )

    if ([string]::IsNullOrWhiteSpace($Value)) {
        return $null
    }

    try {
        $parsed = [datetimeoffset]::Parse(
            $Value,
            [System.Globalization.CultureInfo]::InvariantCulture,
            [System.Globalization.DateTimeStyles]::AllowWhiteSpaces
        )

        return $parsed.DateTime
    }
    catch {
        return $null
    }
}

function Get-SubjectDate {
    param(
        [AllowNull()]
        [AllowEmptyString()]
        [string]$Subject
    )

    if ([string]::IsNullOrWhiteSpace($Subject)) {
        return $null
    }

    $yearFirst = [regex]::Match(
        $Subject,
        '(?<!\d)(?<y>20\d{2})[.\-_](?<m>\d{1,2})[.\-_](?<d>\d{1,2})(?!\d)'
    )

    if ($yearFirst.Success) {
        try {
            return [datetime]::new(
                [int]$yearFirst.Groups["y"].Value,
                [int]$yearFirst.Groups["m"].Value,
                [int]$yearFirst.Groups["d"].Value
            )
        }
        catch {
            return $null
        }
    }

    $dayFirst = [regex]::Match(
        $Subject,
        '(?<!\d)(?<d>\d{1,2})[.\-_](?<m>\d{1,2})[.\-_](?<y>20\d{2})(?!\d)'
    )

    if ($dayFirst.Success) {
        try {
            return [datetime]::new(
                [int]$dayFirst.Groups["y"].Value,
                [int]$dayFirst.Groups["m"].Value,
                [int]$dayFirst.Groups["d"].Value
            )
        }
        catch {
            return $null
        }
    }

    return $null
}

function Get-VersionTokens {
    param(
        [AllowNull()]
        [AllowEmptyString()]
        [string]$Text
    )

    if ([string]::IsNullOrWhiteSpace($Text)) {
        return @()
    }

    $tokens = [System.Collections.Generic.List[string]]::new()

    foreach ($match in [regex]::Matches(
        $Text,
        '(?<!\d)(\d+(?:\.\d+){1,3})(?!\d)'
    )) {
        $token = $match.Groups[1].Value

        if ($token -match '^20\d{2}\.\d{1,2}\.\d{1,2}$') {
            continue
        }

        if (-not $tokens.Contains($token)) {
            $tokens.Add($token)
        }
    }

    return @($tokens)
}

function Get-VersionMatch {
    param(
        [string[]]$EventTokens,
        [string[]]$CommitTokens
    )

    $common = @(
        $EventTokens |
            Where-Object { $CommitTokens -contains $_ } |
            Select-Object -Unique
    )

    if ($common.Count -eq 0) {
        return [pscustomobject]@{
            Score  = 0
            Tokens = ""
        }
    }

    $bestScore = 0

    foreach ($token in $common) {
        $partCount = $token.Split(".").Count

        $score = switch ($partCount) {
            4 { 100 }
            3 { 90 }
            2 { 25 }
            default { 0 }
        }

        if ($score -gt $bestScore) {
            $bestScore = $score
        }
    }

    return [pscustomobject]@{
        Score  = $bestScore
        Tokens = ($common -join "|")
    }
}

function Get-AbsoluteDayDelta {
    param(
        [AllowNull()]
        $Left,

        [AllowNull()]
        $Right
    )

    if ($null -eq $Left -or $null -eq $Right) {
        return $null
    }

    return [math]::Abs(($Left.Date - $Right.Date).Days)
}

function Test-CurrentComparisonExact {
    param(
        [AllowNull()]
        $Row
    )

    if ($null -eq $Row) {
        return $false
    }

    return (
        (ConvertTo-Integer $Row.OnlyLocal) -eq 0 -and
        (ConvertTo-Integer $Row.OnlySteam) -eq 0 -and
        (ConvertTo-Integer $Row.SizeChanged) -eq 0 -and
        (ConvertTo-Integer $Row.ContentChanged) -eq 0 -and
        (ConvertTo-Integer $Row.HashErrors) -eq 0
    )
}

function Get-TopPairInfo {
    param(
        [object[]]$Pairs
    )

    if ($null -eq $Pairs -or $Pairs.Count -eq 0) {
        return $null
    }

    $ordered = @(
        $Pairs |
            Sort-Object -Property @(
                @{
                    Expression = { ConvertTo-Integer $_.Score }
                    Descending = $true
                },
                @{
                    Expression = { ConvertTo-Integer $_.GitOrdinal }
                    Descending = $true
                },
                @{
                    Expression = { ConvertTo-Integer $_.SteamNewestOrdinal }
                    Ascending = $true
                }
            )
    )

    $top = $ordered[0]
    $topScore = ConvertTo-Integer $top.Score

    $ties = @(
        $ordered |
            Where-Object { (ConvertTo-Integer $_.Score) -eq $topScore }
    )

    $secondScore = $null
    $margin = $null

    if ($ordered.Count -gt 1) {
        $secondScore = ConvertTo-Integer $ordered[1].Score
        $margin = $topScore - $secondScore
    }

    return [pscustomobject]@{
        TopPair     = $top
        TopScore    = $topScore
        TieCount    = $ties.Count
        Unique      = ($ties.Count -eq 1)
        SecondScore = $secondScore
        Margin      = $margin
    }
}

foreach ($requiredPath in @(
    $SteamEventsPath,
    $CommitSnapshotsPath,
    $CurrentComparisonPath,
    $RepoSummaryPath
)) {
    if (-not (Test-Path -LiteralPath $requiredPath)) {
        throw "Required input file not found: $requiredPath"
    }
}

if (Test-Path -LiteralPath $OutputDirectory) {
    Remove-Item -LiteralPath $OutputDirectory -Recurse -Force
}

New-Item -ItemType Directory -Path $OutputDirectory -Force | Out-Null
New-Item -ItemType Directory -Path $PackageDirectory -Force | Out-Null

$steamEvents = @(Import-Csv -LiteralPath $SteamEventsPath)
$commitSnapshots = @(Import-Csv -LiteralPath $CommitSnapshotsPath)
$currentComparison = @(Import-Csv -LiteralPath $CurrentComparisonPath)
$repoSummary = @(Import-Csv -LiteralPath $RepoSummaryPath)

$warnings = [System.Collections.Generic.List[string]]::new()
$validationErrors = [System.Collections.Generic.List[string]]::new()

if ($steamEvents.Count -ne $ExpectedSteamEventCount) {
    $validationErrors.Add(
        "Expected $ExpectedSteamEventCount Steam events from Analysis 04 but found $($steamEvents.Count)."
    )
}

$steamRepoCount = @($steamEvents.Repo | Select-Object -Unique).Count

if ($steamRepoCount -ne $ExpectedRepoCount) {
    $validationErrors.Add(
        "Expected $ExpectedRepoCount Steam repositories but found $steamRepoCount."
    )
}

$targetWorkshopIds = @(
    $steamEvents.WorkshopId |
        Where-Object { -not [string]::IsNullOrWhiteSpace($_) } |
        Select-Object -Unique
)

$currentComparisonByRepo = @{}

foreach ($row in $currentComparison) {
    $currentComparisonByRepo[$row.Repo] = $row
}

$repoSummaryByRepo = @{}

foreach ($row in $repoSummary) {
    $repoSummaryByRepo[$row.Repo] = $row
}

$latestOrdinalByRepo = @{}

foreach ($group in ($commitSnapshots | Group-Object Repo)) {
    $latestOrdinalByRepo[$group.Name] = (
        $group.Group |
            ForEach-Object { ConvertTo-Integer $_.Ordinal } |
            Measure-Object -Maximum
    ).Maximum
}

$placeholderFingerprints = [System.Collections.Generic.HashSet[string]]::new(
    [System.StringComparer]::OrdinalIgnoreCase
)

foreach ($group in ($commitSnapshots | Group-Object TreeFingerprint)) {
    if ([string]::IsNullOrWhiteSpace($group.Name)) {
        continue
    }

    $distinctRepos = @(
        $group.Group.Repo |
            Select-Object -Unique
    )

    if ($distinctRepos.Count -lt 2) {
        continue
    }

    $nonTinyRows = @(
        $group.Group |
            Where-Object {
                (ConvertTo-Integer $_.TrackedFileCount) -gt 1 -or
                -not [string]::IsNullOrWhiteSpace($_.DescriptorWorkshopId)
            }
    )

    if ($nonTinyRows.Count -eq 0) {
        [void]$placeholderFingerprints.Add($group.Name)
    }
}

$commitClassificationBySha = @{}

foreach ($commit in $commitSnapshots) {
    $descriptorWorkshopId = [string]$commit.DescriptorWorkshopId
    $expectedWorkshopId = [string]$commit.WorkshopId

    $isPlaceholder = (
        -not [string]::IsNullOrWhiteSpace($commit.TreeFingerprint) -and
        $placeholderFingerprints.Contains($commit.TreeFingerprint)
    )

    $descriptorRelation = "MATCH"

    if ([string]::IsNullOrWhiteSpace($descriptorWorkshopId)) {
        $descriptorRelation = "MISSING"
    }
    elseif ($descriptorWorkshopId -ne $expectedWorkshopId) {
        if ($targetWorkshopIds -contains $descriptorWorkshopId) {
            $descriptorRelation = "OTHER_TARGET"
        }
        else {
            $descriptorRelation = "EXTERNAL_MISMATCH"
        }
    }

    $classification = if ($isPlaceholder) {
        "PLACEHOLDER"
    }
    elseif ($descriptorRelation -eq "OTHER_TARGET") {
        "CROSS_TARGET_DESCRIPTOR_MISMATCH"
    }
    elseif ($descriptorRelation -eq "EXTERNAL_MISMATCH") {
        "EXTERNAL_DESCRIPTOR_MISMATCH"
    }
    elseif ($descriptorRelation -eq "MISSING") {
        "DESCRIPTOR_ID_MISSING"
    }
    else {
        "NORMAL"
    }

    $eligible = (
        -not $isPlaceholder -and
        $descriptorRelation -ne "OTHER_TARGET"
    )

    $subjectDate = Get-SubjectDate $commit.Subject

    $currentRow = if ($currentComparisonByRepo.ContainsKey($commit.Repo)) {
        $currentComparisonByRepo[$commit.Repo]
    }
    else {
        $null
    }

    $repoRow = if ($repoSummaryByRepo.ContainsKey($commit.Repo)) {
        $repoSummaryByRepo[$commit.Repo]
    }
    else {
        $null
    }

    $currentExact = Test-CurrentComparisonExact $currentRow

    $repoClean = (
        $null -ne $repoRow -and
        (ConvertTo-Integer $repoRow.DirtyStatusEntries) -eq 0
    )

    $isLatest = (
        (ConvertTo-Integer $commit.Ordinal) -eq
        (ConvertTo-Integer $latestOrdinalByRepo[$commit.Repo])
    )

    $classificationRow = [pscustomobject]@{
        Repo                         = $commit.Repo
        Abbreviation                 = $commit.Abbreviation
        WorkshopId                   = $commit.WorkshopId
        GitOrdinal                   = $commit.Ordinal
        CommitSha                    = $commit.CommitSha
        Subject                      = $commit.Subject
        AuthorDate                   = $commit.AuthorDate
        CommitterDate                = $commit.CommitterDate
        SubjectDate                  = if ($null -ne $subjectDate) {
            $subjectDate.ToString("yyyy-MM-dd")
        }
        else {
            ""
        }
        DescriptorName               = $commit.DescriptorName
        DescriptorVersion            = $commit.DescriptorVersion
        DescriptorSupportedVersion   = $commit.DescriptorSupportedVersion
        DescriptorWorkshopId         = $commit.DescriptorWorkshopId
        DescriptorWorkshopIdRelation = $descriptorRelation
        StructuralClassification     = $classification
        PlaceholderFingerprint       = $isPlaceholder
        EligibleForCandidateMapping  = $eligible
        IsLatestCommit               = $isLatest
        CurrentComparisonExact       = $currentExact
        RepositoryClean              = $repoClean
        TreeFingerprint              = $commit.TreeFingerprint
        TrackedFileCount             = $commit.TrackedFileCount
        TrackedBytes                 = $commit.TrackedBytes
    }

    $commitClassificationBySha[$commit.CommitSha] = $classificationRow

    if ($descriptorRelation -eq "OTHER_TARGET") {
        $warnings.Add(
            "$($commit.Repo) commit $($commit.CommitSha): descriptor Workshop ID $descriptorWorkshopId belongs to another selected target."
        )
    }
    elseif ($descriptorRelation -eq "EXTERNAL_MISMATCH") {
        $warnings.Add(
            "$($commit.Repo) commit $($commit.CommitSha): descriptor Workshop ID $descriptorWorkshopId differs from expected $expectedWorkshopId and is not another selected target."
        )
    }
}

$candidatePairs = [System.Collections.Generic.List[object]]::new()

foreach ($event in $steamEvents) {
    $eventDate = Get-SteamDisplayedDate $event.NormalizedFetchedTime

    if ($null -eq $eventDate) {
        $warnings.Add(
            "$($event.Repo) Steam event $($event.NewestOrdinal): could not parse NormalizedFetchedTime '$($event.NormalizedFetchedTime)'."
        )

        continue
    }

    $eventVersionText = @(
        [string]$event.VersionText,
        [string]$event.Preview
    ) -join " "

    $eventVersionTokens = @(Get-VersionTokens $eventVersionText)

    $sameRepoCommits = @(
        $commitSnapshots |
            Where-Object { $_.Repo -eq $event.Repo }
    )

    foreach ($commit in $sameRepoCommits) {
        $classification = $commitClassificationBySha[$commit.CommitSha]

        if (-not (ConvertTo-Boolean ([string]$classification.EligibleForCandidateMapping))) {
            continue
        }

        $score = 0
        $evidence = [System.Collections.Generic.List[string]]::new()

        $subjectDate = Get-SubjectDate $commit.Subject
        $authorDate = Get-GitWallClockDate $commit.AuthorDate

        $subjectDayDelta = Get-AbsoluteDayDelta $eventDate $subjectDate
        $authorDayDelta = Get-AbsoluteDayDelta $eventDate $authorDate

        if ($null -ne $subjectDayDelta) {
            switch ($subjectDayDelta) {
                0 {
                    $score += 140
                    $evidence.Add("subject-date-exact")
                }
                1 {
                    $score += 110
                    $evidence.Add("subject-date-1-day")
                }
                2 {
                    $score += 80
                    $evidence.Add("subject-date-2-days")
                }
                3 {
                    $score += 50
                    $evidence.Add("subject-date-3-days")
                }
                default {
                    if ($subjectDayDelta -le 7) {
                        $score += 25
                        $evidence.Add("subject-date-within-7-days")
                    }
                }
            }
        }

        if ($null -ne $authorDayDelta) {
            switch ($authorDayDelta) {
                0 {
                    $score += 30
                    $evidence.Add("author-date-exact")
                }
                1 {
                    $score += 20
                    $evidence.Add("author-date-1-day")
                }
                2 {
                    $score += 10
                    $evidence.Add("author-date-2-days")
                }
                default {
                    if ($authorDayDelta -le 7) {
                        $score += 5
                        $evidence.Add("author-date-within-7-days")
                    }
                }
            }
        }

        $commitVersionText = @(
            [string]$commit.DescriptorVersion,
            [string]$commit.Subject
        ) -join " "

        $commitVersionTokens = @(Get-VersionTokens $commitVersionText)

        $versionMatch = Get-VersionMatch `
            -EventTokens $eventVersionTokens `
            -CommitTokens $commitVersionTokens

        if ($versionMatch.Score -gt 0) {
            $score += $versionMatch.Score
            $evidence.Add("version-token:$($versionMatch.Tokens)")
        }

        if ($classification.DescriptorWorkshopIdRelation -eq "MATCH") {
            $score += 5
            $evidence.Add("descriptor-workshop-id-match")
        }
        elseif ($classification.DescriptorWorkshopIdRelation -eq "EXTERNAL_MISMATCH") {
            $score -= 25
            $evidence.Add("descriptor-workshop-id-external-mismatch")
        }

        $currentHeadEvidence = (
            (ConvertTo-Boolean ([string]$classification.CurrentComparisonExact)) -and
            (ConvertTo-Boolean ([string]$classification.RepositoryClean)) -and
            (ConvertTo-Boolean ([string]$classification.IsLatestCommit)) -and
            (ConvertTo-Integer $event.NewestOrdinal) -eq 1
        )

        if ($currentHeadEvidence) {
            $score += 400
            $evidence.Add("current-head-vs-steam-evidence")
        }

        $includePair = (
            $currentHeadEvidence -or
            ($null -ne $subjectDayDelta -and $subjectDayDelta -le 7) -or
            ($null -ne $authorDayDelta -and $authorDayDelta -le 3) -or
            $versionMatch.Score -ge 80
        )

        if (-not $includePair) {
            continue
        }

        $eventKey = "$($event.WorkshopId)|$($event.NewestOrdinal)"

        $candidatePairs.Add(
            [pscustomobject]@{
                EventKey                   = $eventKey
                Repo                       = $event.Repo
                Abbreviation               = $event.Abbreviation
                WorkshopId                 = $event.WorkshopId
                SteamNewestOrdinal         = $event.NewestOrdinal
                SteamRawDisplayedTime      = $event.RawDisplayedTime
                SteamNormalizedFetchedTime = $event.NormalizedFetchedTime
                SteamVersionText           = $event.VersionText
                SteamPreview               = $event.Preview
                SteamCanonicalTimeVerified = $event.CanonicalTimeVerified
                GitOrdinal                 = $commit.Ordinal
                GitCommitSha               = $commit.CommitSha
                GitSubject                 = $commit.Subject
                GitAuthorDate              = $commit.AuthorDate
                GitDescriptorVersion       = $commit.DescriptorVersion
                GitDescriptorWorkshopId    = $commit.DescriptorWorkshopId
                GitClassification          = $classification.StructuralClassification
                SubjectDayDelta            = if ($null -ne $subjectDayDelta) {
                    $subjectDayDelta
                }
                else {
                    ""
                }
                AuthorDayDelta             = if ($null -ne $authorDayDelta) {
                    $authorDayDelta
                }
                else {
                    ""
                }
                VersionTokensMatched        = $versionMatch.Tokens
                CurrentHeadEvidence         = $currentHeadEvidence
                Score                       = $score
                Evidence                    = ($evidence -join "; ")
            }
        )
    }
}

$sortedCandidatePairs = @(
    $candidatePairs |
        Sort-Object -Property @(
            @{
                Expression = { $_.Repo }
                Ascending = $true
            },
            @{
                Expression = { ConvertTo-Integer $_.SteamNewestOrdinal }
                Ascending = $true
            },
            @{
                Expression = { ConvertTo-Integer $_.Score }
                Descending = $true
            },
            @{
                Expression = { ConvertTo-Integer $_.GitOrdinal }
                Descending = $true
            }
        )
)

$pairsByEvent = @{}
$pairsByCommit = @{}

foreach ($pair in $sortedCandidatePairs) {
    if (-not $pairsByEvent.ContainsKey($pair.EventKey)) {
        $pairsByEvent[$pair.EventKey] = [System.Collections.Generic.List[object]]::new()
    }

    $pairsByEvent[$pair.EventKey].Add($pair)

    if (-not $pairsByCommit.ContainsKey($pair.GitCommitSha)) {
        $pairsByCommit[$pair.GitCommitSha] = [System.Collections.Generic.List[object]]::new()
    }

    $pairsByCommit[$pair.GitCommitSha].Add($pair)
}

$eventTopInfo = @{}

foreach ($eventKey in $pairsByEvent.Keys) {
    $eventTopInfo[$eventKey] = Get-TopPairInfo @($pairsByEvent[$eventKey])
}

$commitTopInfo = @{}

foreach ($commitSha in $pairsByCommit.Keys) {
    $commitTopInfo[$commitSha] = Get-TopPairInfo @($pairsByCommit[$commitSha])
}

$eventMatrix = [System.Collections.Generic.List[object]]::new()

foreach ($event in $steamEvents) {
    $eventKey = "$($event.WorkshopId)|$($event.NewestOrdinal)"

    $topInfo = if ($eventTopInfo.ContainsKey($eventKey)) {
        $eventTopInfo[$eventKey]
    }
    else {
        $null
    }

    $topPair = if ($null -ne $topInfo) {
        $topInfo.TopPair
    }
    else {
        $null
    }

    $mutualBest = $false

    if ($null -ne $topInfo -and $topInfo.Unique) {
        $commitSha = $topPair.GitCommitSha

        if ($commitTopInfo.ContainsKey($commitSha)) {
            $commitInfo = $commitTopInfo[$commitSha]

            if (
                $commitInfo.Unique -and
                $commitInfo.TopPair.EventKey -eq $eventKey
            ) {
                $mutualBest = $true
            }
        }
    }

    $autoClassification = "UNRESOLVED"

    if ($null -ne $topPair) {
        if (ConvertTo-Boolean ([string]$topPair.CurrentHeadEvidence)) {
            $autoClassification = "CURRENT_HEAD_EVIDENCE"
        }
        elseif (
            $mutualBest -and
            (ConvertTo-Integer $topPair.Score) -ge 170
        ) {
            $autoClassification = "STRONG_CANDIDATE"
        }
        elseif (
            $mutualBest -and
            (ConvertTo-Integer $topPair.Score) -ge 100
        ) {
            $autoClassification = "CANDIDATE"
        }
        else {
            $autoClassification = "AMBIGUOUS"
        }
    }

    $eventMatrix.Add(
        [pscustomobject]@{
            Repo                       = $event.Repo
            Abbreviation               = $event.Abbreviation
            WorkshopId                 = $event.WorkshopId
            SteamNewestOrdinal         = $event.NewestOrdinal
            SteamRawDisplayedTime      = $event.RawDisplayedTime
            SteamNormalizedFetchedTime = $event.NormalizedFetchedTime
            SteamVersionText           = $event.VersionText
            SteamPreview               = $event.Preview
            SteamSourceUrl             = $event.SourceUrl
            SteamRawPageSha256         = $event.RawPageSha256
            CanonicalTimeVerified      = $event.CanonicalTimeVerified
            AutoClassification         = $autoClassification
            FinalStatus                = "UNVERIFIED"
            CandidatePairCount         = if ($pairsByEvent.ContainsKey($eventKey)) {
                $pairsByEvent[$eventKey].Count
            }
            else {
                0
            }
            TopCandidateUnique         = if ($null -ne $topInfo) {
                $topInfo.Unique
            }
            else {
                $false
            }
            MutualBest                 = $mutualBest
            TopScore                   = if ($null -ne $topInfo) {
                $topInfo.TopScore
            }
            else {
                ""
            }
            SecondScore                = if (
                $null -ne $topInfo -and
                $null -ne $topInfo.SecondScore
            ) {
                $topInfo.SecondScore
            }
            else {
                ""
            }
            ScoreMargin                = if (
                $null -ne $topInfo -and
                $null -ne $topInfo.Margin
            ) {
                $topInfo.Margin
            }
            else {
                ""
            }
            GitOrdinal                 = if ($null -ne $topPair) {
                $topPair.GitOrdinal
            }
            else {
                ""
            }
            GitCommitSha               = if ($null -ne $topPair) {
                $topPair.GitCommitSha
            }
            else {
                ""
            }
            GitSubject                 = if ($null -ne $topPair) {
                $topPair.GitSubject
            }
            else {
                ""
            }
            GitAuthorDate              = if ($null -ne $topPair) {
                $topPair.GitAuthorDate
            }
            else {
                ""
            }
            GitDescriptorVersion       = if ($null -ne $topPair) {
                $topPair.GitDescriptorVersion
            }
            else {
                ""
            }
            GitDescriptorWorkshopId    = if ($null -ne $topPair) {
                $topPair.GitDescriptorWorkshopId
            }
            else {
                ""
            }
            GitClassification          = if ($null -ne $topPair) {
                $topPair.GitClassification
            }
            else {
                ""
            }
            SubjectDayDelta            = if ($null -ne $topPair) {
                $topPair.SubjectDayDelta
            }
            else {
                ""
            }
            AuthorDayDelta             = if ($null -ne $topPair) {
                $topPair.AuthorDayDelta
            }
            else {
                ""
            }
            VersionTokensMatched       = if ($null -ne $topPair) {
                $topPair.VersionTokensMatched
            }
            else {
                ""
            }
            CurrentHeadEvidence        = if ($null -ne $topPair) {
                $topPair.CurrentHeadEvidence
            }
            else {
                $false
            }
            Evidence                   = if ($null -ne $topPair) {
                $topPair.Evidence
            }
            else {
                ""
            }
        }
    )
}

$selectedCommitCounts = @{}

foreach ($row in $eventMatrix) {
    if (
        -not [string]::IsNullOrWhiteSpace($row.GitCommitSha) -and
        $row.AutoClassification -in @(
            "CURRENT_HEAD_EVIDENCE",
            "STRONG_CANDIDATE",
            "CANDIDATE"
        )
    ) {
        if (-not $selectedCommitCounts.ContainsKey($row.GitCommitSha)) {
            $selectedCommitCounts[$row.GitCommitSha] = 0
        }

        $selectedCommitCounts[$row.GitCommitSha]++
    }
}

$gitCommitClassification = [System.Collections.Generic.List[object]]::new()

foreach ($commit in $commitSnapshots) {
    $classification = $commitClassificationBySha[$commit.CommitSha]

    $bestInfo = if ($commitTopInfo.ContainsKey($commit.CommitSha)) {
        $commitTopInfo[$commit.CommitSha]
    }
    else {
        $null
    }

    $bestPair = if ($null -ne $bestInfo) {
        $bestInfo.TopPair
    }
    else {
        $null
    }

    $gitCommitClassification.Add(
        [pscustomobject]@{
            Repo                         = $classification.Repo
            Abbreviation                 = $classification.Abbreviation
            WorkshopId                   = $classification.WorkshopId
            GitOrdinal                   = $classification.GitOrdinal
            CommitSha                    = $classification.CommitSha
            Subject                      = $classification.Subject
            AuthorDate                   = $classification.AuthorDate
            CommitterDate                = $classification.CommitterDate
            SubjectDate                  = $classification.SubjectDate
            DescriptorName               = $classification.DescriptorName
            DescriptorVersion            = $classification.DescriptorVersion
            DescriptorSupportedVersion   = $classification.DescriptorSupportedVersion
            DescriptorWorkshopId         = $classification.DescriptorWorkshopId
            DescriptorWorkshopIdRelation = $classification.DescriptorWorkshopIdRelation
            StructuralClassification     = $classification.StructuralClassification
            PlaceholderFingerprint       = $classification.PlaceholderFingerprint
            EligibleForCandidateMapping  = $classification.EligibleForCandidateMapping
            IsLatestCommit               = $classification.IsLatestCommit
            CurrentComparisonExact       = $classification.CurrentComparisonExact
            RepositoryClean              = $classification.RepositoryClean
            TreeFingerprint              = $classification.TreeFingerprint
            TrackedFileCount             = $classification.TrackedFileCount
            TrackedBytes                 = $classification.TrackedBytes
            CandidatePairCount           = if ($pairsByCommit.ContainsKey($commit.CommitSha)) {
                $pairsByCommit[$commit.CommitSha].Count
            }
            else {
                0
            }
            BestCandidateUnique          = if ($null -ne $bestInfo) {
                $bestInfo.Unique
            }
            else {
                $false
            }
            BestCandidateScore           = if ($null -ne $bestInfo) {
                $bestInfo.TopScore
            }
            else {
                ""
            }
            BestSteamNewestOrdinal       = if ($null -ne $bestPair) {
                $bestPair.SteamNewestOrdinal
            }
            else {
                ""
            }
            BestSteamDisplayedTime       = if ($null -ne $bestPair) {
                $bestPair.SteamRawDisplayedTime
            }
            else {
                ""
            }
            BestSteamNormalizedTime      = if ($null -ne $bestPair) {
                $bestPair.SteamNormalizedFetchedTime
            }
            else {
                ""
            }
            SelectedEventCount           = if ($selectedCommitCounts.ContainsKey($commit.CommitSha)) {
                $selectedCommitCounts[$commit.CommitSha]
            }
            else {
                0
            }
        }
    )
}

$summary = [System.Collections.Generic.List[object]]::new()

foreach ($repo in @($steamEvents.Repo | Select-Object -Unique | Sort-Object)) {
    $repoEvents = @($eventMatrix | Where-Object { $_.Repo -eq $repo })
    $repoCommits = @($gitCommitClassification | Where-Object { $_.Repo -eq $repo })

    $currentRow = if ($currentComparisonByRepo.ContainsKey($repo)) {
        $currentComparisonByRepo[$repo]
    }
    else {
        $null
    }

    $repoRow = if ($repoSummaryByRepo.ContainsKey($repo)) {
        $repoSummaryByRepo[$repo]
    }
    else {
        $null
    }

    $summary.Add(
        [pscustomobject]@{
            Repo                          = $repo
            Abbreviation                  = ($repoEvents | Select-Object -First 1).Abbreviation
            WorkshopId                    = ($repoEvents | Select-Object -First 1).WorkshopId
            SteamEventCount               = $repoEvents.Count
            GitCommitCount                = $repoCommits.Count
            EligibleGitCommitCount        = @(
                $repoCommits |
                    Where-Object {
                        ConvertTo-Boolean ([string]$_.EligibleForCandidateMapping)
                    }
            ).Count
            PlaceholderCommitCount        = @(
                $repoCommits |
                    Where-Object { $_.StructuralClassification -eq "PLACEHOLDER" }
            ).Count
            CrossTargetMismatchCount      = @(
                $repoCommits |
                    Where-Object {
                        $_.StructuralClassification -eq "CROSS_TARGET_DESCRIPTOR_MISMATCH"
                    }
            ).Count
            ExternalDescriptorMismatchCount = @(
                $repoCommits |
                    Where-Object {
                        $_.StructuralClassification -eq "EXTERNAL_DESCRIPTOR_MISMATCH"
                    }
            ).Count
            CurrentComparisonExact        = Test-CurrentComparisonExact $currentRow
            RepositoryClean               = (
                $null -ne $repoRow -and
                (ConvertTo-Integer $repoRow.DirtyStatusEntries) -eq 0
            )
            CurrentHeadEvidenceCount      = @(
                $repoEvents |
                    Where-Object { $_.AutoClassification -eq "CURRENT_HEAD_EVIDENCE" }
            ).Count
            StrongCandidateCount          = @(
                $repoEvents |
                    Where-Object { $_.AutoClassification -eq "STRONG_CANDIDATE" }
            ).Count
            CandidateCount                = @(
                $repoEvents |
                    Where-Object { $_.AutoClassification -eq "CANDIDATE" }
            ).Count
            AmbiguousCount                = @(
                $repoEvents |
                    Where-Object { $_.AutoClassification -eq "AMBIGUOUS" }
            ).Count
            UnresolvedCount               = @(
                $repoEvents |
                    Where-Object { $_.AutoClassification -eq "UNRESOLVED" }
            ).Count
        }
    )
}

$duplicateEventKeys = @(
    $eventMatrix |
        Group-Object {
            "$($_.WorkshopId)|$($_.SteamNewestOrdinal)"
        } |
        Where-Object { $_.Count -ne 1 }
)

if ($eventMatrix.Count -ne $steamEvents.Count) {
    $validationErrors.Add(
        "Event matrix contains $($eventMatrix.Count) rows but Steam input contains $($steamEvents.Count)."
    )
}

if ($duplicateEventKeys.Count -gt 0) {
    $validationErrors.Add(
        "Event matrix contains duplicate WorkshopId/NewestOrdinal keys."
    )
}

$invalidCandidatePairs = @(
    $sortedCandidatePairs |
        Where-Object {
            $_.GitClassification -in @(
                "PLACEHOLDER",
                "CROSS_TARGET_DESCRIPTOR_MISMATCH"
            )
        }
)

if ($invalidCandidatePairs.Count -gt 0) {
    $validationErrors.Add(
        "Candidate-pairs output contains commits that should have been excluded from automatic mapping."
    )
}

if ($summary.Count -ne $ExpectedRepoCount) {
    $validationErrors.Add(
        "Expected $ExpectedRepoCount repository summary rows but found $($summary.Count)."
    )
}

$eventMatrixPath = Join-Path $OutputDirectory "steam-git-event-matrix.csv"
$candidatePairsPath = Join-Path $OutputDirectory "candidate-pairs.csv"
$commitClassificationPath = Join-Path $OutputDirectory "git-commit-classification.csv"
$summaryPath = Join-Path $OutputDirectory "summary.csv"
$warningsPath = Join-Path $OutputDirectory "warnings.txt"
$readmePath = Join-Path $OutputDirectory "README.md"

$eventMatrix |
    Sort-Object -Property @(
        @{
            Expression = { $_.Repo }
            Ascending = $true
        },
        @{
            Expression = { ConvertTo-Integer $_.SteamNewestOrdinal }
            Ascending = $true
        }
    ) |
    Export-Csv -LiteralPath $eventMatrixPath -NoTypeInformation -Encoding utf8

$sortedCandidatePairs |
    Export-Csv -LiteralPath $candidatePairsPath -NoTypeInformation -Encoding utf8

$gitCommitClassification |
    Sort-Object -Property @(
        @{
            Expression = { $_.Repo }
            Ascending = $true
        },
        @{
            Expression = { ConvertTo-Integer $_.GitOrdinal }
            Ascending = $true
        }
    ) |
    Export-Csv -LiteralPath $commitClassificationPath -NoTypeInformation -Encoding utf8

$summary |
    Export-Csv -LiteralPath $summaryPath -NoTypeInformation -Encoding utf8

if ($warnings.Count -gt 0) {
    $warnings |
        Set-Content -LiteralPath $warningsPath -Encoding utf8
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
# Analysis 05 - Steam / Git Candidate Mapping

Generated: $generatedAt

This analysis compares the authoritative Steam Change Notes event inventory from
Analysis 04 with the historical Git snapshot inventory from Analysis 03.

It is intentionally a candidate-generation stage, not a final reconstruction
decision stage.

## Inputs

- analysis/results/04-steam-event-inventory/steam-events.csv
- analysis/results/03-historical-commits/commit-snapshots.csv
- analysis/results/02-content-classification/current-comparison-summary.csv
- analysis/results/01-inventory/repo-summary.csv

## Outputs

### steam-git-event-matrix.csv

One row for every Steam Change Notes event.

The automatically selected Git row, when present, is only a candidate.
FinalStatus remains UNVERIFIED for every event in this analysis.

### candidate-pairs.csv

All Git / Steam candidate pairs admitted by deterministic matching rules.

Evidence may include:

- commit subject calendar-date proximity
- Git author calendar-date proximity
- matching version tokens
- matching descriptor Workshop ID
- current-head evidence from the existing local/Steam comparison

### git-commit-classification.csv

Classifies every historical Git commit before candidate matching.

Important structural categories include:

- NORMAL
- PLACEHOLDER
- CROSS_TARGET_DESCRIPTOR_MISMATCH
- EXTERNAL_DESCRIPTOR_MISMATCH
- DESCRIPTOR_ID_MISSING

Placeholder commits and commits whose descriptor points to another selected
target mod are excluded from automatic candidate mapping.

### summary.csv

Per-mod counts for Steam events, historical Git commits, candidate classes,
ambiguities, unresolved events, and structural commit classifications.

### warnings.txt

Review items that are not fatal validation errors.

## Matching policy

Steam NormalizedFetchedTime is used only as the calendar/time representation
captured by Analysis 04. It is not treated as a timezone-converted canonical
timestamp.

A Git commit is not declared to be a real Workshop revision merely because its
date or version resembles a Steam event.

Same-day and near-same-day events are deliberately left ambiguous when the
available evidence does not distinguish them.

Current-head evidence is stronger than date-only evidence, but still does not
change FinalStatus from UNVERIFIED in this stage.

Skymods and other external archive candidates are outside the scope of this
analysis and will be added only after the Steam/Git relationship has been
mapped independently.

## Validation

Steam events: $($steamEvents.Count)
Git commits: $($commitSnapshots.Count)
Candidate pairs: $($sortedCandidatePairs.Count)
Event matrix rows: $($eventMatrix.Count)
Repositories: $($summary.Count)
Warnings: $($warnings.Count)
Validation errors: $($validationErrors.Count)
"@

$readme |
    Set-Content -LiteralPath $readmePath -Encoding utf8

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
Write-Host "================ ANALYSIS 05 COMPLETE ================"
Write-Host ""

$summary |
    Format-Table `
        Repo,
        SteamEventCount,
        GitCommitCount,
        CurrentHeadEvidenceCount,
        StrongCandidateCount,
        CandidateCount,
        AmbiguousCount,
        UnresolvedCount `
        -AutoSize

Write-Host ""
Write-Host "Steam events: $($steamEvents.Count)"
Write-Host "Git commits: $($commitSnapshots.Count)"
Write-Host "Candidate pairs: $($sortedCandidatePairs.Count)"
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
