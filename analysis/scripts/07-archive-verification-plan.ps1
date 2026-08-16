Set-StrictMode -Version Latest
$ErrorActionPreference = "Stop"

$AnalysisName = "07-archive-verification-plan"

$RepoRoot = (Resolve-Path (Join-Path $PSScriptRoot "..\..")).Path

$EventMatrixPath = Join-Path `
    $RepoRoot `
    "analysis\results\05-steam-git-candidate-mapping\steam-git-event-matrix.csv"

$CandidatePairsPath = Join-Path `
    $RepoRoot `
    "analysis\results\05-steam-git-candidate-mapping\candidate-pairs.csv"

$GitClassificationPath = Join-Path `
    $RepoRoot `
    "analysis\results\05-steam-git-candidate-mapping\git-commit-classification.csv"

$SkymodsRevisionsPath = Join-Path `
    $RepoRoot `
    "analysis\results\06-skymods-archive-inventory\skymods-revisions.csv"

$TimeCandidatesPath = Join-Path `
    $RepoRoot `
    "analysis\results\06-skymods-archive-inventory\steam-skymods-time-candidates.csv"

$OutputDirectory = Join-Path `
    $RepoRoot `
    "analysis\results\$AnalysisName"

$PackageDirectory = Join-Path $RepoRoot "analysis\packages"
$PackagePath = Join-Path $PackageDirectory "$AnalysisName.zip"

$ExpectedSteamEventCount = 1198
$ExpectedGitCommitCount = 116
$ExpectedSkymodsRevisionCount = 605
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

    if (
        [int]::TryParse(
            $Value,
            [System.Globalization.NumberStyles]::Integer,
            [System.Globalization.CultureInfo]::InvariantCulture,
            [ref]$result
        )
    ) {
        return $result
    }

    throw "Could not parse integer value '$Value'."
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

    throw "Could not parse Boolean value '$Value'."
}

function ConvertTo-Time {
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

function Get-PriorityRank {
    param(
        [Parameter(Mandatory)]
        [string]$Priority
    )

    if ($Priority.StartsWith("P0_")) {
        return 0
    }

    if ($Priority.StartsWith("P1_")) {
        return 1
    }

    if ($Priority.StartsWith("P2_")) {
        return 2
    }

    if ($Priority.StartsWith("P3_")) {
        return 3
    }

    return 99
}

foreach ($requiredPath in @(
    $EventMatrixPath,
    $CandidatePairsPath,
    $GitClassificationPath,
    $SkymodsRevisionsPath,
    $TimeCandidatesPath
)) {
    if (-not (Test-Path -LiteralPath $requiredPath)) {
        throw "Required input file not found: $requiredPath"
    }
}

if (Test-Path -LiteralPath $OutputDirectory) {
    Remove-Item `
        -LiteralPath $OutputDirectory `
        -Recurse `
        -Force
}

New-Item `
    -ItemType Directory `
    -Path $OutputDirectory `
    -Force |
    Out-Null

New-Item `
    -ItemType Directory `
    -Path $PackageDirectory `
    -Force |
    Out-Null

$eventMatrix = @(Import-Csv -LiteralPath $EventMatrixPath)
$candidatePairs = @(Import-Csv -LiteralPath $CandidatePairsPath)
$gitClassification = @(Import-Csv -LiteralPath $GitClassificationPath)
$skymodsRevisions = @(Import-Csv -LiteralPath $SkymodsRevisionsPath)
$timeCandidates = @(Import-Csv -LiteralPath $TimeCandidatesPath)

$warnings = [System.Collections.Generic.List[string]]::new()
$validationErrors = [System.Collections.Generic.List[string]]::new()

if ($eventMatrix.Count -ne $ExpectedSteamEventCount) {
    $validationErrors.Add(
        "Expected $ExpectedSteamEventCount Steam events but found $($eventMatrix.Count)."
    )
}

if ($gitClassification.Count -ne $ExpectedGitCommitCount) {
    $validationErrors.Add(
        "Expected $ExpectedGitCommitCount Git commits but found $($gitClassification.Count)."
    )
}

if ($skymodsRevisions.Count -ne $ExpectedSkymodsRevisionCount) {
    $validationErrors.Add(
        "Expected $ExpectedSkymodsRevisionCount Skymods revisions but found $($skymodsRevisions.Count)."
    )
}

$repoCount = @(
    $eventMatrix.Repo |
        Select-Object -Unique
).Count

if ($repoCount -ne $ExpectedRepoCount) {
    $validationErrors.Add(
        "Expected $ExpectedRepoCount repositories but found $repoCount."
    )
}

$eventByKey = @{}

foreach ($event in $eventMatrix) {
    $eventKey = "$($event.WorkshopId)|$($event.SteamNewestOrdinal)"

    if ($eventByKey.ContainsKey($eventKey)) {
        $validationErrors.Add(
            "Duplicate Steam event key: $eventKey"
        )

        continue
    }

    $eventByKey[$eventKey] = $event
}

$revisionByKey = @{}

foreach ($revision in $skymodsRevisions) {
    if ($revisionByKey.ContainsKey($revision.RevisionKey)) {
        $validationErrors.Add(
            "Duplicate Skymods revision key: $($revision.RevisionKey)"
        )

        continue
    }

    $revisionByKey[$revision.RevisionKey] = $revision
}

$gitBySha = @{}

foreach ($commit in $gitClassification) {
    if ($gitBySha.ContainsKey($commit.CommitSha)) {
        $validationErrors.Add(
            "Duplicate Git commit SHA: $($commit.CommitSha)"
        )

        continue
    }

    $gitBySha[$commit.CommitSha] = $commit
}

foreach ($pair in $candidatePairs) {
    if (-not $gitBySha.ContainsKey($pair.GitCommitSha)) {
        $validationErrors.Add(
            "Candidate pair references unknown Git commit $($pair.GitCommitSha)."
        )
    }
}

$workingTimeCandidates = [System.Collections.Generic.List[object]]::new()

foreach ($candidate in $timeCandidates) {
    $steamTime = ConvertTo-Time $candidate.SteamNormalizedFetchedTime
    $skymodsTime = ConvertTo-Time $candidate.SkymodsNormalizedUtcTime

    if ($null -eq $steamTime) {
        $warnings.Add(
            "$($candidate.Repo) Steam event $($candidate.SteamNewestOrdinal): could not parse Steam time '$($candidate.SteamNormalizedFetchedTime)'."
        )

        continue
    }

    if ($null -eq $skymodsTime) {
        $warnings.Add(
            "$($candidate.Repo) revision $($candidate.SkymodsRevisionKey): could not parse Skymods time '$($candidate.SkymodsNormalizedUtcTime)'."
        )

        continue
    }

    $deltaHours = (
        $skymodsTime -
        $steamTime
    ).TotalHours

    $roundedHour = [math]::Round(
        $deltaHours,
        0,
        [System.MidpointRounding]::AwayFromZero
    )

    $wholeHourMatch = (
        [math]::Abs(
            $deltaHours -
            $roundedHour
        ) -lt 0.001
    )

    $sameMinute = (
        $steamTime.Minute -eq
        $skymodsTime.Minute
    )

    $offsetEligible = (
        $sameMinute -and
        $wholeHourMatch -and
        $deltaHours -ge 0 -and
        $deltaHours -le 12
    )

    $eventKey = "$($candidate.WorkshopId)|$($candidate.SteamNewestOrdinal)"

    $workingTimeCandidates.Add(
        [pscustomobject]@{
            EventKey = $eventKey

            Repo = $candidate.Repo
            Abbreviation = $candidate.Abbreviation
            WorkshopId = $candidate.WorkshopId

            SteamNewestOrdinal = $candidate.SteamNewestOrdinal
            SteamRawDisplayedTime = $candidate.SteamRawDisplayedTime
            SteamNormalizedFetchedTime = $candidate.SteamNormalizedFetchedTime
            SteamVersionText = $candidate.SteamVersionText

            SkymodsRevisionKey = $candidate.SkymodsRevisionKey
            SkymodsNewestOrdinal = $candidate.SkymodsNewestOrdinal
            SkymodsIsCurrentRevision = $candidate.SkymodsIsCurrentRevision
            SkymodsRawDisplayedTime = $candidate.SkymodsRawDisplayedTime
            SkymodsNormalizedUtcTime = $candidate.SkymodsNormalizedUtcTime
            SkymodsDownloadUrl = $candidate.SkymodsDownloadUrl

            CalendarDayDelta = (
                $skymodsTime.Date -
                $steamTime.Date
            ).Days

            ObservedOffsetHours = [math]::Round(
                $deltaHours,
                2
            )

            RoundedWholeHourOffset = if ($wholeHourMatch) {
                [int]$roundedHour
            }
            else {
                ""
            }

            SameMinute = $sameMinute
            WholeHourOffset = $wholeHourMatch
            OffsetClusterEligible = $offsetEligible

            IsDominantOffsetMatch = $false
            TemporalPairStatus = ""
        }
    )
}

$offsetClusters = [System.Collections.Generic.List[object]]::new()

$eligibleOffsetRows = @(
    $workingTimeCandidates |
        Where-Object {
            $_.OffsetClusterEligible -eq $true
        }
)

$offsetGroups = @(
    $eligibleOffsetRows |
        Group-Object RoundedWholeHourOffset |
        Sort-Object {
            [int]$_.Name
        }
)

$dominantOffsets = [System.Collections.Generic.HashSet[int]]::new()

foreach ($group in $offsetGroups) {
    $offset = [int]$group.Name
    $pairCount = $group.Count

    $uniqueEvents = @(
        $group.Group.EventKey |
            Select-Object -Unique
    ).Count

    $uniqueRevisions = @(
        $group.Group.SkymodsRevisionKey |
            Select-Object -Unique
    ).Count

    $isDominant = ($pairCount -ge 5)

    if ($isDominant) {
        [void]$dominantOffsets.Add($offset)
    }

    $offsetClusters.Add(
        [pscustomobject]@{
            ObservedWholeHourOffset = $offset
            PairCount = $pairCount
            UniqueSteamEvents = $uniqueEvents
            UniqueSkymodsRevisions = $uniqueRevisions
            IsDominant = $isDominant
        }
    )
}

if ($dominantOffsets.Count -eq 0) {
    $validationErrors.Add(
        "No dominant Steam/Skymods whole-hour offset clusters were identified."
    )
}

foreach ($row in $workingTimeCandidates) {
    if (
        $row.OffsetClusterEligible -eq $true -and
        $dominantOffsets.Contains(
            [int]$row.RoundedWholeHourOffset
        )
    ) {
        $row.IsDominantOffsetMatch = $true
    }
}

$dominantRows = @(
    $workingTimeCandidates |
        Where-Object {
            $_.IsDominantOffsetMatch -eq $true
        }
)

$dominantEventCounts = @{}

foreach ($group in ($dominantRows | Group-Object EventKey)) {
    $dominantEventCounts[$group.Name] = $group.Count
}

$dominantRevisionCounts = @{}

foreach ($group in ($dominantRows | Group-Object SkymodsRevisionKey)) {
    $dominantRevisionCounts[$group.Name] = $group.Count
}

foreach ($row in $workingTimeCandidates) {
    if ($row.IsDominantOffsetMatch -ne $true) {
        $row.TemporalPairStatus = "WEAK_TIME_CANDIDATE"
        continue
    }

    $eventCount = $dominantEventCounts[$row.EventKey]
    $revisionCount = $dominantRevisionCounts[$row.SkymodsRevisionKey]

    if (
        $eventCount -eq 1 -and
        $revisionCount -eq 1
    ) {
        $row.TemporalPairStatus = "BIDIRECTIONAL_UNIQUE"
    }
    elseif (
        $eventCount -gt 1 -and
        $revisionCount -eq 1
    ) {
        $row.TemporalPairStatus = "EVENT_AMBIGUOUS"
    }
    elseif (
        $eventCount -eq 1 -and
        $revisionCount -gt 1
    ) {
        $row.TemporalPairStatus = "REVISION_AMBIGUOUS"
    }
    else {
        $row.TemporalPairStatus = "BIDIRECTIONAL_AMBIGUOUS"
    }
}

$dominantRows = @(
    $workingTimeCandidates |
        Where-Object {
            $_.IsDominantOffsetMatch -eq $true
        }
)

$dominantByEvent = @{}

foreach ($row in $dominantRows) {
    if (-not $dominantByEvent.ContainsKey($row.EventKey)) {
        $dominantByEvent[$row.EventKey] =
            [System.Collections.Generic.List[object]]::new()
    }

    $dominantByEvent[$row.EventKey].Add($row)
}

$eventGitStats = @{}

foreach ($group in ($candidatePairs | Group-Object EventKey)) {
    $scores = @(
        $group.Group |
            ForEach-Object {
                ConvertTo-Integer $_.Score
            }
    )

    $topScore = (
        $scores |
            Measure-Object -Maximum
    ).Maximum

    $topCount = @(
        $group.Group |
            Where-Object {
                (ConvertTo-Integer $_.Score) -eq $topScore
            }
    ).Count

    $eventGitStats[$group.Name] = [pscustomobject]@{
        TopScore = $topScore
        TopCount = $topCount
    }
}

$gitSkymodsCandidates = [System.Collections.Generic.List[object]]::new()

foreach ($gitPair in $candidatePairs) {
    $eventKey = $gitPair.EventKey

    if (-not $dominantByEvent.ContainsKey($eventKey)) {
        continue
    }

    $event = if ($eventByKey.ContainsKey($eventKey)) {
        $eventByKey[$eventKey]
    }
    else {
        $null
    }

    $gitStats = $eventGitStats[$eventKey]
    $gitScore = ConvertTo-Integer $gitPair.Score

    $gitIsTopCandidate = (
        $gitScore -eq
        $gitStats.TopScore
    )

    $gitIsUniqueTopCandidate = (
        $gitIsTopCandidate -and
        $gitStats.TopCount -eq 1
    )

    foreach ($temporalPair in $dominantByEvent[$eventKey]) {
        $gitSkymodsCandidates.Add(
            [pscustomobject]@{
                Repo = $gitPair.Repo
                Abbreviation = $gitPair.Abbreviation
                WorkshopId = $gitPair.WorkshopId

                EventKey = $eventKey
                SteamNewestOrdinal = $gitPair.SteamNewestOrdinal
                SteamRawDisplayedTime = $gitPair.SteamRawDisplayedTime
                SteamNormalizedFetchedTime = $gitPair.SteamNormalizedFetchedTime
                SteamVersionText = $gitPair.SteamVersionText

                EventAutoClassification = if ($null -ne $event) {
                    $event.AutoClassification
                }
                else {
                    ""
                }

                GitOrdinal = $gitPair.GitOrdinal
                GitCommitSha = $gitPair.GitCommitSha
                GitSubject = $gitPair.GitSubject
                GitDescriptorVersion = $gitPair.GitDescriptorVersion
                GitDescriptorWorkshopId = $gitPair.GitDescriptorWorkshopId
                GitClassification = $gitPair.GitClassification

                GitCandidateScore = $gitScore
                GitIsEventTopCandidate = $gitIsTopCandidate
                GitIsEventUniqueTopCandidate = $gitIsUniqueTopCandidate
                CurrentHeadEvidence = ConvertTo-Boolean $gitPair.CurrentHeadEvidence

                SkymodsRevisionKey = $temporalPair.SkymodsRevisionKey
                SkymodsNewestOrdinal = $temporalPair.SkymodsNewestOrdinal
                SkymodsRawDisplayedTime = $temporalPair.SkymodsRawDisplayedTime
                SkymodsNormalizedUtcTime = $temporalPair.SkymodsNormalizedUtcTime
                SkymodsDownloadUrl = $temporalPair.SkymodsDownloadUrl

                ObservedOffsetHours = $temporalPair.ObservedOffsetHours
                TemporalPairStatus = $temporalPair.TemporalPairStatus

                ArchiveCandidateGitCommitCount = 0
                GitCandidateArchiveRevisionCount = 0

                VerificationPriority = ""
                PriorityReason = ""
            }
        )
    }
}

$archiveGitCommitCounts = @{}

foreach (
    $group in (
        $gitSkymodsCandidates |
            Group-Object SkymodsRevisionKey
    )
) {
    $archiveGitCommitCounts[$group.Name] = @(
        $group.Group.GitCommitSha |
            Select-Object -Unique
    ).Count
}

$gitArchiveRevisionCounts = @{}

foreach (
    $group in (
        $gitSkymodsCandidates |
            Group-Object GitCommitSha
    )
) {
    $gitArchiveRevisionCounts[$group.Name] = @(
        $group.Group.SkymodsRevisionKey |
            Select-Object -Unique
    ).Count
}

foreach ($row in $gitSkymodsCandidates) {
    $archiveCommitCount =
        $archiveGitCommitCounts[$row.SkymodsRevisionKey]

    $commitArchiveCount =
        $gitArchiveRevisionCounts[$row.GitCommitSha]

    $row.ArchiveCandidateGitCommitCount =
        $archiveCommitCount

    $row.GitCandidateArchiveRevisionCount =
        $commitArchiveCount

    $reasons = [System.Collections.Generic.List[string]]::new()

    $priority = ""

    if ($row.CurrentHeadEvidence -eq $true) {
        $priority = "P3_CURRENT_HEAD_OPTIONAL"
        $reasons.Add("current-head-evidence")
    }

    if (
        $row.TemporalPairStatus -ne "BIDIRECTIONAL_UNIQUE"
    ) {
        $priority = "P0_AMBIGUOUS"
        $reasons.Add("temporal-ambiguity")
    }

    if ($archiveCommitCount -gt 1) {
        $priority = "P0_AMBIGUOUS"
        $reasons.Add("archive-candidate-for-multiple-git-commits")
    }

    if ($commitArchiveCount -gt 1) {
        $priority = "P0_AMBIGUOUS"
        $reasons.Add("git-commit-has-multiple-archive-candidates")
    }

    if (
        $row.EventAutoClassification -eq "AMBIGUOUS"
    ) {
        $priority = "P0_AMBIGUOUS"
        $reasons.Add("steam-git-event-ambiguity")
    }

    if (
        $row.GitIsEventUniqueTopCandidate -ne $true
    ) {
        $priority = "P0_AMBIGUOUS"
        $reasons.Add("git-candidate-not-unique-top")
    }

    if ([string]::IsNullOrWhiteSpace($priority)) {
        if ($row.GitCandidateScore -ge 170) {
            $priority = "P2_STRONG_GIT_CANDIDATE"
            $reasons.Add("strong-git-candidate")
        }
        else {
            $priority = "P1_VERIFY_GIT_CANDIDATE"
            $reasons.Add("git-candidate-needs-content-verification")
        }
    }

    $row.VerificationPriority = $priority
    $row.PriorityReason = (
        $reasons |
            Select-Object -Unique
    ) -join "; "
}

$gitCandidatesByRevision = @{}

foreach ($row in $gitSkymodsCandidates) {
    if (
        -not $gitCandidatesByRevision.ContainsKey(
            $row.SkymodsRevisionKey
        )
    ) {
        $gitCandidatesByRevision[$row.SkymodsRevisionKey] =
            [System.Collections.Generic.List[object]]::new()
    }

    $gitCandidatesByRevision[$row.SkymodsRevisionKey].Add($row)
}

$dominantByRevision = @{}

foreach ($row in $dominantRows) {
    if (
        -not $dominantByRevision.ContainsKey(
            $row.SkymodsRevisionKey
        )
    ) {
        $dominantByRevision[$row.SkymodsRevisionKey] =
            [System.Collections.Generic.List[object]]::new()
    }

    $dominantByRevision[$row.SkymodsRevisionKey].Add($row)
}

$downloadPlan = [System.Collections.Generic.List[object]]::new()

foreach ($revision in $skymodsRevisions) {
    $revisionKey = $revision.RevisionKey

	$gitRows = @(
	    if (
	        $gitCandidatesByRevision.ContainsKey($revisionKey)
	    ) {
	        $gitCandidatesByRevision[$revisionKey]
	    }
	)

	$temporalRows = @(
	    if (
	        $dominantByRevision.ContainsKey($revisionKey)
	    ) {
	        $dominantByRevision[$revisionKey]
	    }
	)

    $category = ""
    $priority = ""
    $firstPass = $false
    $reason = ""

    if ($gitRows.Count -gt 0) {
        $bestGitRow = @(
            $gitRows |
                Sort-Object {
                    Get-PriorityRank $_.VerificationPriority
                },
                @{
                    Expression = {
                        $_.GitCandidateScore
                    }
                    Descending = $true
                }
        )[0]

        $priority = $bestGitRow.VerificationPriority

        switch -Wildcard ($priority) {
            "P0_*" {
                $category = "VERIFY_AMBIGUOUS_GIT"
                $firstPass = $true
            }

            "P1_*" {
                $category = "VERIFY_GIT"
            }

            "P2_*" {
                $category = "VERIFY_STRONG_GIT"
            }

            "P3_*" {
                $category = "CURRENT_HEAD_OPTIONAL"
            }

            default {
                $category = "VERIFY_GIT"
            }
        }

        $reason = (
            $gitRows.PriorityReason |
                Where-Object {
                    -not [string]::IsNullOrWhiteSpace($_)
                } |
                Select-Object -Unique
        ) -join "; "
    }
    elseif ($temporalRows.Count -gt 0) {
        $uniqueTemporalRows = @(
            $temporalRows |
                Where-Object {
                    $_.TemporalPairStatus -eq "BIDIRECTIONAL_UNIQUE"
                }
        )

        if (
            $uniqueTemporalRows.Count -eq 1 -and
            $temporalRows.Count -eq 1
        ) {
            $category = "RECOVERY_CANDIDATE"
            $priority = "P4_RECOVERY_LATER"
            $reason = "temporally-aligned-skymods-revision-without-git-candidate"
        }
        else {
            $category = "TEMPORAL_AMBIGUITY"
            $priority = "P5_REVIEW_LATER"
            $reason = "dominant-time-match-is-not-bidirectionally-unique"
        }
    }
    else {
        $category = "NO_DOMINANT_TIME_MATCH"
        $priority = "P6_UNRESOLVED"
        $reason = "no-dominant-temporal-alignment"
    }

	$relatedEvents = @(
	    $temporalRows |
	        ForEach-Object {
	            $_.EventKey
	        } |
	        Select-Object -Unique
	)
		
	$relatedCommits = @(
	    $gitRows |
	        ForEach-Object {
	            $_.GitCommitSha
	        } |
	        Select-Object -Unique
	)

    $downloadPlan.Add(
        [pscustomobject]@{
            Repo = $revision.Repo
            Abbreviation = $revision.Abbreviation
            WorkshopId = $revision.WorkshopId

            SkymodsRevisionKey = $revision.RevisionKey
            SkymodsNewestOrdinal = $revision.NewestOrdinal
            SkymodsIsCurrentRevision = $revision.IsCurrentRevision
            SkymodsRawDisplayedTime = $revision.RawDisplayedTime
            SkymodsNormalizedUtcTime = $revision.NormalizedUtcTime
            SkymodsDownloadUrl = $revision.DownloadUrl

            Category = $category
            VerificationPriority = $priority
            FirstPassRecommended = $firstPass

            RelatedSteamEventCount = $relatedEvents.Count
            RelatedSteamEventKeys = $relatedEvents -join "|"

            RelatedGitCommitCount = $relatedCommits.Count
            RelatedGitCommitShas = $relatedCommits -join "|"

            Reason = $reason
            ContentDownloaded = $false
            ContentVerified = $false
        }
    )
}

$gitCandidatesByCommit = @{}

foreach ($row in $gitSkymodsCandidates) {
    if (
        -not $gitCandidatesByCommit.ContainsKey(
            $row.GitCommitSha
        )
    ) {
        $gitCandidatesByCommit[$row.GitCommitSha] =
            [System.Collections.Generic.List[object]]::new()
    }

    $gitCandidatesByCommit[$row.GitCommitSha].Add($row)
}

$gitVerificationSummary = [System.Collections.Generic.List[object]]::new()

foreach ($commit in $gitClassification) {
	$rows = @(
	    if (
	        $gitCandidatesByCommit.ContainsKey(
	            $commit.CommitSha
	        )
	    ) {
	        $gitCandidatesByCommit[$commit.CommitSha]
	    }
	)

    $eligible = ConvertTo-Boolean $commit.EligibleForCandidateMapping

    $status = ""
    $firstPassNeeded = $false

    if (-not $eligible) {
        $status = "EXCLUDED"
    }
    elseif ($rows.Count -eq 0) {
        $status = "NO_ARCHIVE_CANDIDATE"
    }
    else {
        $best = @(
            $rows |
                Sort-Object {
                    Get-PriorityRank $_.VerificationPriority
                },
                @{
                    Expression = {
                        $_.GitCandidateScore
                    }
                    Descending = $true
                }
        )[0]

        $status = $best.VerificationPriority
        $firstPassNeeded = $status.StartsWith("P0_")
    }

	$revisionKeys = @(
	    $rows |
	        ForEach-Object {
	            $_.SkymodsRevisionKey
	        } |
	        Select-Object -Unique
	)
		
	$eventKeys = @(
	    $rows |
	        ForEach-Object {
	            $_.EventKey
	        } |
	        Select-Object -Unique
	)

    $gitVerificationSummary.Add(
        [pscustomobject]@{
            Repo = $commit.Repo
            Abbreviation = $commit.Abbreviation
            WorkshopId = $commit.WorkshopId

            GitOrdinal = $commit.GitOrdinal
            CommitSha = $commit.CommitSha
            Subject = $commit.Subject

            StructuralClassification = $commit.StructuralClassification
            EligibleForCandidateMapping = $eligible
            CurrentComparisonExact = $commit.CurrentComparisonExact
            IsLatestCommit = $commit.IsLatestCommit

            ArchiveCandidateCount = $revisionKeys.Count
            ArchiveCandidateRevisionKeys = $revisionKeys -join "|"

            RelatedSteamEventCount = $eventKeys.Count
            RelatedSteamEventKeys = $eventKeys -join "|"

            VerificationStatus = $status
            FirstPassNeeded = $firstPassNeeded
        }
    )
}

$summary = [System.Collections.Generic.List[object]]::new()

foreach (
    $repo in (
        $eventMatrix.Repo |
            Select-Object -Unique |
            Sort-Object
    )
) {
    $repoEvents = @(
        $eventMatrix |
            Where-Object {
                $_.Repo -eq $repo
            }
    )

    $repoRevisions = @(
        $skymodsRevisions |
            Where-Object {
                $_.Repo -eq $repo
            }
    )

    $repoDominantRows = @(
        $dominantRows |
            Where-Object {
                $_.Repo -eq $repo
            }
    )

    $repoGitCommits = @(
        $gitVerificationSummary |
            Where-Object {
                $_.Repo -eq $repo
            }
    )

    $repoPlan = @(
        $downloadPlan |
            Where-Object {
                $_.Repo -eq $repo
            }
    )

    $summary.Add(
        [pscustomobject]@{
            Repo = $repo

            SteamEventCount = $repoEvents.Count
            SkymodsRevisionCount = $repoRevisions.Count

            DominantTemporalPairCount = $repoDominantRows.Count

            BidirectionalUniquePairCount = @(
                $repoDominantRows |
                    Where-Object {
                        $_.TemporalPairStatus -eq "BIDIRECTIONAL_UNIQUE"
                    }
            ).Count

            TemporalAmbiguityPairCount = @(
                $repoDominantRows |
                    Where-Object {
                        $_.TemporalPairStatus -ne "BIDIRECTIONAL_UNIQUE"
                    }
            ).Count

            GitCommitCount = $repoGitCommits.Count

            GitCommitsWithArchiveCandidate = @(
                $repoGitCommits |
                    Where-Object {
                        $_.ArchiveCandidateCount -gt 0
                    }
            ).Count

            FirstPassGitCommitCount = @(
                $repoGitCommits |
                    Where-Object {
                        $_.FirstPassNeeded -eq $true
                    }
            ).Count

            FirstPassRevisionCount = @(
                $repoPlan |
                    Where-Object {
                        $_.FirstPassRecommended -eq $true
                    }
            ).Count

            RecoveryCandidateRevisionCount = @(
                $repoPlan |
                    Where-Object {
                        $_.Category -eq "RECOVERY_CANDIDATE"
                    }
            ).Count

            NoDominantTimeMatchRevisionCount = @(
                $repoPlan |
                    Where-Object {
                        $_.Category -eq "NO_DOMINANT_TIME_MATCH"
                    }
            ).Count
        }
    )
}

$ambiguousEvents = @(
    $dominantRows |
        Group-Object EventKey |
        Where-Object {
            $_.Count -gt 1
        }
)

$ambiguousRevisions = @(
    $dominantRows |
        Group-Object SkymodsRevisionKey |
        Where-Object {
            $_.Count -gt 1
        }
)

$revisionsWithoutDominantMatch = @(
    $downloadPlan |
        Where-Object {
            $_.Category -eq "NO_DOMINANT_TIME_MATCH"
        }
)

if ($ambiguousEvents.Count -gt 0) {
    $warnings.Add(
        "$($ambiguousEvents.Count) Steam event(s) have multiple dominant Skymods temporal candidates."
    )
}

if ($ambiguousRevisions.Count -gt 0) {
    $warnings.Add(
        "$($ambiguousRevisions.Count) Skymods revision(s) have multiple dominant Steam temporal candidates."
    )
}

if ($revisionsWithoutDominantMatch.Count -gt 0) {
    $warnings.Add(
        "$($revisionsWithoutDominantMatch.Count) Skymods revision(s) have no dominant temporal match."
    )

    foreach ($revision in $revisionsWithoutDominantMatch) {
        $warnings.Add(
            "No dominant temporal match: $($revision.Repo) $($revision.SkymodsRevisionKey) [$($revision.SkymodsRawDisplayedTime)]"
        )
    }
}

if ($workingTimeCandidates.Count -ne $timeCandidates.Count) {
    $validationErrors.Add(
        "Temporal alignment output contains $($workingTimeCandidates.Count) rows but Analysis 06 supplied $($timeCandidates.Count)."
    )
}

if ($downloadPlan.Count -ne $skymodsRevisions.Count) {
    $validationErrors.Add(
        "Download plan contains $($downloadPlan.Count) rows but Analysis 06 supplied $($skymodsRevisions.Count) revisions."
    )
}

$missingFirstPassUrls = @(
    $downloadPlan |
        Where-Object {
            $_.FirstPassRecommended -eq $true -and
            [string]::IsNullOrWhiteSpace($_.SkymodsDownloadUrl)
        }
)

if ($missingFirstPassUrls.Count -gt 0) {
    $validationErrors.Add(
        "$($missingFirstPassUrls.Count) first-pass archive candidate(s) have no download URL."
    )
}

$offsetClustersPath = Join-Path `
    $OutputDirectory `
    "offset-clusters.csv"

$alignmentPath = Join-Path `
    $OutputDirectory `
    "steam-skymods-alignment.csv"

$gitSkymodsPath = Join-Path `
    $OutputDirectory `
    "git-skymods-candidates.csv"

$gitSummaryPath = Join-Path `
    $OutputDirectory `
    "git-verification-summary.csv"

$downloadPlanPath = Join-Path `
    $OutputDirectory `
    "download-plan.csv"

$summaryPath = Join-Path `
    $OutputDirectory `
    "summary.csv"

$warningsPath = Join-Path `
    $OutputDirectory `
    "warnings.txt"

$readmePath = Join-Path `
    $OutputDirectory `
    "README.md"

$offsetClusters |
    Export-Csv `
        -LiteralPath $offsetClustersPath `
        -NoTypeInformation `
        -Encoding utf8

$workingTimeCandidates |
    Sort-Object -Property @(
        @{
            Expression = { $_.Repo }
            Ascending = $true
        },
        @{
            Expression = {
                ConvertTo-Integer $_.SteamNewestOrdinal
            }
            Ascending = $true
        },
        @{
            Expression = {
                ConvertTo-Integer $_.SkymodsNewestOrdinal
            }
            Ascending = $true
        }
    ) |
    Export-Csv `
        -LiteralPath $alignmentPath `
        -NoTypeInformation `
        -Encoding utf8

$gitSkymodsCandidates |
    Sort-Object -Property @(
        @{
            Expression = { $_.Repo }
            Ascending = $true
        },
        @{
            Expression = {
                Get-PriorityRank $_.VerificationPriority
            }
            Ascending = $true
        },
        @{
            Expression = {
                ConvertTo-Integer $_.GitOrdinal
            }
            Ascending = $true
        }
    ) |
    Export-Csv `
        -LiteralPath $gitSkymodsPath `
        -NoTypeInformation `
        -Encoding utf8

$gitVerificationSummary |
    Sort-Object -Property @(
        @{
            Expression = { $_.Repo }
            Ascending = $true
        },
        @{
            Expression = {
                ConvertTo-Integer $_.GitOrdinal
            }
            Ascending = $true
        }
    ) |
    Export-Csv `
        -LiteralPath $gitSummaryPath `
        -NoTypeInformation `
        -Encoding utf8

$downloadPlan |
    Sort-Object -Property @(
        @{
            Expression = {
                Get-PriorityRank $_.VerificationPriority
            }
            Ascending = $true
        },
        @{
            Expression = { $_.Repo }
            Ascending = $true
        },
        @{
            Expression = {
                ConvertTo-Integer $_.SkymodsNewestOrdinal
            }
            Ascending = $true
        }
    ) |
    Export-Csv `
        -LiteralPath $downloadPlanPath `
        -NoTypeInformation `
        -Encoding utf8

$summary |
    Export-Csv `
        -LiteralPath $summaryPath `
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

$dominantOffsetText = @(
    $dominantOffsets |
        Sort-Object
) -join ", "

$firstPassRevisionCount = @(
    $downloadPlan |
        Where-Object {
            $_.FirstPassRecommended -eq $true
        }
).Count

$recoveryRevisionCount = @(
    $downloadPlan |
        Where-Object {
            $_.Category -eq "RECOVERY_CANDIDATE"
        }
).Count

$generatedAt = Get-Date -Format "yyyy-MM-dd HH:mm:ss zzz"

$readme = @"
# Analysis 07 - Archive Verification Plan

Generated: $generatedAt

This analysis combines the Steam/Git candidate mapping from Analysis 05 with
the Skymods revision inventory from Analysis 06.

It does not download or inspect any archive content.

The purpose of this stage is to reduce the archive-content verification problem
to a deterministic and auditable retrieval plan before large historical mod
archives are downloaded.

## Inputs

- analysis/results/05-steam-git-candidate-mapping/steam-git-event-matrix.csv
- analysis/results/05-steam-git-candidate-mapping/candidate-pairs.csv
- analysis/results/05-steam-git-candidate-mapping/git-commit-classification.csv
- analysis/results/06-skymods-archive-inventory/skymods-revisions.csv
- analysis/results/06-skymods-archive-inventory/steam-skymods-time-candidates.csv

## Temporal alignment

Analysis 06 deliberately treated Steam and Skymods timestamps as different time
bases.

This analysis therefore does not assume a named timezone conversion.

Instead, it measures repeated whole-hour relationships directly from the
captured datasets.

The dominant observed whole-hour offsets are:

$dominantOffsetText hours

A temporal pair is considered bidirectionally unique only when:

- its observed offset belongs to a dominant cluster
- the Steam and Skymods timestamps have the same minute
- the Steam event has only one dominant Skymods candidate
- the Skymods revision has only one dominant Steam event candidate

Temporal alignment is evidence for selecting an archive candidate. It is not
content verification.

## Verification priorities

P0_AMBIGUOUS

Archive content is particularly useful because the temporal relationship,
Steam/Git relationship, or Git/archive relationship is ambiguous.

P1_VERIFY_GIT_CANDIDATE

A plausible Git/archive relationship exists but still requires content
verification.

P2_STRONG_GIT_CANDIDATE

Existing metadata gives a strong relationship. Content verification is useful
but not the first retrieval priority.

P3_CURRENT_HEAD_OPTIONAL

The current Git working tree already has independent current-Steam comparison
evidence, so downloading the corresponding Skymods archive is optional for the
first verification pass.

## Outputs

### offset-clusters.csv

Observed whole-hour relationships between the captured Steam and Skymods
timestamps.

### steam-skymods-alignment.csv

Every Analysis 06 time candidate with its measured offset and temporal
classification.

### git-skymods-candidates.csv

Candidate relationships connecting:

Steam event -> historical Git commit -> Skymods revision

No relationship in this file is content-verified.

### git-verification-summary.csv

One row for every historical Git commit, including archive candidate counts and
the resulting verification priority.

### download-plan.csv

One row for every Skymods revision.

FirstPassRecommended identifies the archive candidates that should be reviewed
before bulk recovery work because they can resolve ambiguous historical Git
relationships.

### summary.csv

Per-mod verification-planning statistics.

## Next stage

The next analysis should download only a reviewed subset of the archive plan
and compare archive contents against historical Git snapshots.

Content verification should include at minimum:

- archive integrity
- descriptor remote_file_id
- descriptor metadata
- path inventory
- byte hashes for files represented by the historical Git snapshot
- deterministic projected snapshot fingerprints

Only content evidence should promote an archive relationship to a validated
historical snapshot.

## Validation

Steam events: $($eventMatrix.Count)
Historical Git commits: $($gitClassification.Count)
Skymods revisions: $($skymodsRevisions.Count)
Analysis 06 time candidates: $($timeCandidates.Count)
Dominant temporal pairs: $($dominantRows.Count)
Git/Skymods candidate rows: $($gitSkymodsCandidates.Count)
First-pass archive revisions: $firstPassRevisionCount
Recovery-candidate revisions: $recoveryRevisionCount
Warnings: $($warnings.Count)
Validation errors: $($validationErrors.Count)
"@

$readme |
    Set-Content `
        -LiteralPath $readmePath `
        -Encoding utf8

if (Test-Path -LiteralPath $PackagePath) {
    Remove-Item `
        -LiteralPath $PackagePath `
        -Force
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
Write-Host "================ ANALYSIS 07 COMPLETE ================"
Write-Host ""

Write-Host "Dominant observed offsets: $dominantOffsetText hours"
Write-Host ""

$summary |
    Format-Table `
        Repo,
        SkymodsRevisionCount,
        BidirectionalUniquePairCount,
        TemporalAmbiguityPairCount,
        GitCommitsWithArchiveCandidate,
        FirstPassGitCommitCount,
        FirstPassRevisionCount,
        RecoveryCandidateRevisionCount `
        -AutoSize

Write-Host ""
Write-Host "Steam events: $($eventMatrix.Count)"
Write-Host "Historical Git commits: $($gitClassification.Count)"
Write-Host "Skymods revisions: $($skymodsRevisions.Count)"
Write-Host "Analysis 06 time candidates: $($timeCandidates.Count)"
Write-Host "Dominant temporal pairs: $($dominantRows.Count)"
Write-Host "Git/Skymods candidate rows: $($gitSkymodsCandidates.Count)"
Write-Host "First-pass archive revisions: $firstPassRevisionCount"
Write-Host "Recovery-candidate revisions: $recoveryRevisionCount"
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
