Set-StrictMode -Version Latest
$ErrorActionPreference = "Stop"

$RepoRoot = (
    Resolve-Path (
        Join-Path $PSScriptRoot "..\.."
    )
).Path

$AnalysisName = "10-event-resolution-matrix"

$OutputDirectory = Join-Path `
    $RepoRoot `
    "analysis\results\$AnalysisName"

$PackageDirectory = Join-Path `
    $RepoRoot `
    "analysis\packages"

$PackagePath = Join-Path `
    $PackageDirectory `
    "$AnalysisName.zip"

$InputFiles = [ordered]@{
    SteamEvents = Join-Path `
        $RepoRoot `
        "analysis\results\04-steam-event-inventory\steam-events.csv"

    CandidatePairs = Join-Path `
        $RepoRoot `
        "analysis\results\05-steam-git-candidate-mapping\candidate-pairs.csv"

    GitCommits = Join-Path `
        $RepoRoot `
        "analysis\results\05-steam-git-candidate-mapping\git-commit-classification.csv"

    SteamSkymodsAlignment = Join-Path `
        $RepoRoot `
        "analysis\results\07-archive-verification-plan\steam-skymods-alignment.csv"

    RevisionSummary = Join-Path `
        $RepoRoot `
        "analysis\results\09-first-pass-archive-verification\revision-summary.csv"

    ArchiveDescriptors = Join-Path `
        $RepoRoot `
        "analysis\results\09-first-pass-archive-verification\archive-descriptors.csv"

    GitComparisons = Join-Path `
        $RepoRoot `
        "analysis\results\09-first-pass-archive-verification\git-content-comparisons.csv"

    FileDifferences = Join-Path `
        $RepoRoot `
        "analysis\results\09-first-pass-archive-verification\file-differences.csv"

    ArchiveDownloads = Join-Path `
        $RepoRoot `
        "analysis\results\09-first-pass-archive-verification\archive-downloads.csv"
}

function Convert-ToBoolean {
    param(
        [AllowNull()]
        [object]$Value
    )

    if ($null -eq $Value) {
        return $false
    }

    $text = [string]$Value

    return (
        $text.Equals(
            "True",
            [System.StringComparison]::OrdinalIgnoreCase
        ) -or
        $text -eq "1"
    )
}

function Convert-ToInteger {
    param(
        [AllowNull()]
        [object]$Value
    )

    if ($null -eq $Value) {
        return 0
    }

    $text = [string]$Value

    if ([string]::IsNullOrWhiteSpace($text)) {
        return 0
    }

    $parsed = 0

    if (
        [int]::TryParse(
            $text,
            [ref]$parsed
        )
    ) {
        return $parsed
    }

    return 0
}

function Split-PipeValues {
    param(
        [AllowNull()]
        [object]$Value
    )

    if ($null -eq $Value) {
        return @()
    }

    $text = [string]$Value

    if ([string]::IsNullOrWhiteSpace($text)) {
        return @()
    }

    return @(
        $text.Split(
            "|",
            [System.StringSplitOptions]::RemoveEmptyEntries
        ) |
            ForEach-Object {
                $_.Trim()
            } |
            Where-Object {
                -not [string]::IsNullOrWhiteSpace($_)
            }
    )
}

function Join-UniqueValues {
    param(
        [AllowNull()]
        [object[]]$Values
    )

    if ($null -eq $Values) {
        return ""
    }

    return (
        @(
            $Values |
                ForEach-Object {
                    if ($null -ne $_) {
                        ([string]$_).Trim()
                    }
                } |
                Where-Object {
                    -not [string]::IsNullOrWhiteSpace($_)
                } |
                Sort-Object -Unique
        ) -join "|"
    )
}

function Join-KeyValues {
    param(
        [AllowNull()]
        [object[]]$Values
    )

    if ($null -eq $Values) {
        return ""
    }

    return (
        @(
            $Values |
                ForEach-Object {
                    if ($null -ne $_) {
                        ([string]$_).Trim()
                    }
                } |
                Where-Object {
                    -not [string]::IsNullOrWhiteSpace($_)
                } |
                Sort-Object -Unique
        ) -join ";"
    )
}

function New-GroupIndex {
    param(
        [object[]]$Rows,
        [scriptblock]$KeySelector
    )

    $index = @{}

    foreach ($row in $Rows) {
        $key = [string](
            & $KeySelector $row
        )

        if (-not $index.ContainsKey($key)) {
            $index[$key] = [System.Collections.Generic.List[object]]::new()
        }

        $index[$key].Add($row)
    }

    return $index
}

function Get-IndexedRows {
    param(
        [hashtable]$Index,
        [string]$Key
    )

    if ($Index.ContainsKey($Key)) {
        return @(
            $Index[$Key]
        )
    }

    return @()
}

function Get-PairKey {
    param(
        [string]$EventKey,
        [string]$RevisionKey
    )

    return "$EventKey`n$RevisionKey"
}

function Get-ComparisonKey {
    param(
        [string]$RevisionKey,
        [string]$CommitSha
    )

    return "$RevisionKey`n$CommitSha"
}

function Get-RelativePath {
    param(
        [string]$Path
    )

    return (
        [System.IO.Path]::GetRelativePath(
            $RepoRoot,
            $Path
        ) -replace "\\", "/"
    )
}

foreach ($entry in $InputFiles.GetEnumerator()) {
    if (-not (Test-Path -LiteralPath $entry.Value)) {
        throw (
            "Required input is missing: " +
            "$($entry.Key) -> $($entry.Value)"
        )
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

Write-Host ""
Write-Host "Loading Analysis 10 inputs..."

$SteamEvents = @(
    Import-Csv -LiteralPath $InputFiles.SteamEvents
)

$CandidatePairs = @(
    Import-Csv -LiteralPath $InputFiles.CandidatePairs
)

$GitCommits = @(
    Import-Csv -LiteralPath $InputFiles.GitCommits
)

$SteamSkymodsAlignment = @(
    Import-Csv -LiteralPath $InputFiles.SteamSkymodsAlignment
)

$RevisionSummary = @(
    Import-Csv -LiteralPath $InputFiles.RevisionSummary
)

$ArchiveDescriptors = @(
    Import-Csv -LiteralPath $InputFiles.ArchiveDescriptors
)

$GitComparisons = @(
    Import-Csv -LiteralPath $InputFiles.GitComparisons
)

$FileDifferences = @(
    Import-Csv -LiteralPath $InputFiles.FileDifferences
)

$ArchiveDownloads = @(
    Import-Csv -LiteralPath $InputFiles.ArchiveDownloads
)

$Warnings = [System.Collections.Generic.List[string]]::new()
$ValidationErrors = [System.Collections.Generic.List[string]]::new()

$InputInventory = [System.Collections.Generic.List[object]]::new()

foreach ($entry in $InputFiles.GetEnumerator()) {
    $item = Get-Item -LiteralPath $entry.Value

    $hash = Get-FileHash `
        -LiteralPath $entry.Value `
        -Algorithm SHA256

    $InputInventory.Add(
        [pscustomobject]@{
            InputName = $entry.Key
            Path = Get-RelativePath $entry.Value
            Bytes = $item.Length
            Sha256 = $hash.Hash.ToLowerInvariant()
        }
    )
}

$CandidatePairsByEvent = New-GroupIndex `
    -Rows $CandidatePairs `
    -KeySelector {
        param($row)

        [string]$row.EventKey
    }

$CandidatePairsByGit = New-GroupIndex `
    -Rows $CandidatePairs `
    -KeySelector {
        param($row)

        [string]$row.GitCommitSha
    }

$GitCommitsBySha = @{}

foreach ($row in $GitCommits) {
    $sha = [string]$row.CommitSha

    if ($GitCommitsBySha.ContainsKey($sha)) {
        $ValidationErrors.Add(
            "Duplicate Git commit classification row: $sha"
        )
    }
    else {
        $GitCommitsBySha[$sha] = $row
    }
}

$AlignmentByPair = New-GroupIndex `
    -Rows $SteamSkymodsAlignment `
    -KeySelector {
        param($row)

        Get-PairKey `
            -EventKey ([string]$row.EventKey) `
            -RevisionKey ([string]$row.SkymodsRevisionKey)
    }

$RevisionByEvent = @{}

foreach ($revision in $RevisionSummary) {
    $eventKeys = @(
        [string]$revision.RelatedSteamEventKeys
    )

    foreach ($eventKey in $eventKeys) {
        if (-not $RevisionByEvent.ContainsKey($eventKey)) {
            $RevisionByEvent[$eventKey] = (
                [System.Collections.Generic.List[object]]::new()
            )
        }

        $RevisionByEvent[$eventKey].Add($revision)
    }
}

$DescriptorsByRevision = New-GroupIndex `
    -Rows $ArchiveDescriptors `
    -KeySelector {
        param($row)

        [string]$row.SkymodsRevisionKey
    }

$ComparisonsByRevision = New-GroupIndex `
    -Rows $GitComparisons `
    -KeySelector {
        param($row)

        [string]$row.SkymodsRevisionKey
    }

$DifferencesByComparison = New-GroupIndex `
    -Rows $FileDifferences `
    -KeySelector {
        param($row)

        Get-ComparisonKey `
            -RevisionKey ([string]$row.SkymodsRevisionKey) `
            -CommitSha ([string]$row.GitCommitSha)
    }

$DownloadsByRevision = New-GroupIndex `
    -Rows $ArchiveDownloads `
    -KeySelector {
        param($row)

        [string]$row.SkymodsRevisionKey
    }

$DownloadsBySha256 = @{}

foreach ($download in $ArchiveDownloads) {
    $sha256 = ([string]$download.ArchiveSha256).Trim().ToLowerInvariant()

    if ([string]::IsNullOrWhiteSpace($sha256)) {
        continue
    }

    if (-not $DownloadsBySha256.ContainsKey($sha256)) {
        $DownloadsBySha256[$sha256] = (
            [System.Collections.Generic.List[object]]::new()
        )
    }

    $DownloadsBySha256[$sha256].Add($download)
}

$DescriptorOnlyNearMatches = (
    [System.Collections.Generic.List[object]]::new()
)

$DescriptorOnlyNearMatchByRevision = @{}

foreach ($comparison in $GitComparisons) {
    if (
        Convert-ToBoolean `
            $comparison.ProjectedTrackedContentMatch
    ) {
        continue
    }

    $missingCount = Convert-ToInteger `
        $comparison.MissingFromArchiveCount

    $mismatchCount = Convert-ToInteger `
        $comparison.BlobMismatchCount

    if (
        $missingCount -ne 0 -or
        $mismatchCount -ne 1
    ) {
        continue
    }

    $comparisonKey = Get-ComparisonKey `
        -RevisionKey ([string]$comparison.SkymodsRevisionKey) `
        -CommitSha ([string]$comparison.GitCommitSha)

    $differenceRows = @(
        Get-IndexedRows `
            -Index $DifferencesByComparison `
            -Key $comparisonKey
    )

    if ($differenceRows.Count -ne 1) {
        continue
    }

    $difference = $differenceRows[0]

    $normalizedPath = (
        ([string]$difference.Path) -replace "\\", "/"
    ).TrimStart("/")

    if (
        -not $normalizedPath.Equals(
            "descriptor.mod",
            [System.StringComparison]::OrdinalIgnoreCase
        )
    ) {
        continue
    }

    $revisionKey = [string]$comparison.SkymodsRevisionKey

    $nearMatch = [pscustomobject]@{
        Repo = $comparison.Repo
        Abbreviation = $comparison.Abbreviation
        WorkshopId = $comparison.WorkshopId
        SkymodsRevisionKey = $revisionKey
        GitCommitSha = $comparison.GitCommitSha
        GitComparableFileCount = $comparison.GitComparableFileCount
        MatchingTrackedFileCount = $comparison.MatchingTrackedFileCount
        MissingFromArchiveCount = $comparison.MissingFromArchiveCount
        BlobMismatchCount = $comparison.BlobMismatchCount
        DifferencePath = $difference.Path
        GitBlobSha1 = $difference.GitBlobSha1
        ArchiveBlobSha1 = $difference.ArchiveBlobSha1
        DescriptorWorkshopIdMatches = (
            $comparison.DescriptorWorkshopIdMatches
        )
    }

    $DescriptorOnlyNearMatches.Add($nearMatch)

    if (
        -not $DescriptorOnlyNearMatchByRevision.ContainsKey(
            $revisionKey
        )
    ) {
        $DescriptorOnlyNearMatchByRevision[$revisionKey] = (
            [System.Collections.Generic.List[object]]::new()
        )
    }

    $DescriptorOnlyNearMatchByRevision[
        $revisionKey
    ].Add($nearMatch)
}

$VerifiedArchiveEventLinks = (
    [System.Collections.Generic.List[object]]::new()
)

foreach ($revision in $RevisionSummary) {
    $revisionKey = [string]$revision.SkymodsRevisionKey

    $eventKeys = @(
        [string]$revision.RelatedSteamEventKeys
    )

    $descriptorRows = @(
        Get-IndexedRows `
            -Index $DescriptorsByRevision `
            -Key $revisionKey
    )

    $descriptorValid = $false
    $descriptorCount = 0
    $descriptorRemoteFileId = ""

    if ($descriptorRows.Count -eq 1) {
        $descriptor = $descriptorRows[0]

        $descriptorValid = Convert-ToBoolean `
            $descriptor.DescriptorWorkshopIdMatches

        $descriptorCount = Convert-ToInteger `
            $descriptor.DescriptorCountInArchive

        $descriptorRemoteFileId = (
            [string]$descriptor.DescriptorRemoteFileId
        )
    }
    else {
        $Warnings.Add(
            "$revisionKey has $($descriptorRows.Count) descriptor rows."
        )
    }

    $downloadRows = @(
        Get-IndexedRows `
            -Index $DownloadsByRevision `
            -Key $revisionKey
    )

    $archiveSha256 = ""
    $duplicateArchiveRevisionKeys = ""
    $duplicateArchiveCount = 0

    if ($downloadRows.Count -ge 1) {
        $archiveSha256 = (
            [string]$downloadRows[0].ArchiveSha256
        ).Trim().ToLowerInvariant()

        if (
            -not [string]::IsNullOrWhiteSpace(
                $archiveSha256
            ) -and
            $DownloadsBySha256.ContainsKey(
                $archiveSha256
            )
        ) {
            $duplicateRows = @(
                $DownloadsBySha256[$archiveSha256]
            )

            $duplicateArchiveCount = $duplicateRows.Count

            $duplicateArchiveRevisionKeys = Join-KeyValues @(
                $duplicateRows |
                    ForEach-Object {
                        $_.SkymodsRevisionKey
                    }
            )
        }
    }

    $nearMatches = @()

    if (
        $DescriptorOnlyNearMatchByRevision.ContainsKey(
            $revisionKey
        )
    ) {
        $nearMatches = @(
            $DescriptorOnlyNearMatchByRevision[
                $revisionKey
            ]
        )
    }

    foreach ($eventKey in $eventKeys) {
        $pairKey = Get-PairKey `
            -EventKey $eventKey `
            -RevisionKey $revisionKey

        $alignmentRows = @(
            Get-IndexedRows `
                -Index $AlignmentByPair `
                -Key $pairKey
        )

        $alignmentFound = $alignmentRows.Count -gt 0

        $dominantAlignment = $false
        $bidirectionalUnique = $false

        $temporalPairStatuses = ""
        $observedOffsets = ""

        if ($alignmentFound) {
            $dominantAlignment = (
                @(
                    $alignmentRows |
                        Where-Object {
                            Convert-ToBoolean `
                                $_.IsDominantOffsetMatch
                        }
                ).Count -gt 0
            )

            $bidirectionalUnique = (
                @(
                    $alignmentRows |
                        Where-Object {
                            (
                                [string]$_.TemporalPairStatus
                            ) -eq "BIDIRECTIONAL_UNIQUE"
                        }
                ).Count -gt 0
            )

            $temporalPairStatuses = Join-UniqueValues @(
                $alignmentRows |
                    ForEach-Object {
                        $_.TemporalPairStatus
                    }
            )

            $observedOffsets = Join-UniqueValues @(
                $alignmentRows |
                    ForEach-Object {
                        $_.ObservedOffsetHours
                    }
            )
        }
        else {
            $Warnings.Add(
                "No Analysis 07 alignment row for " +
                "$eventKey -> $revisionKey."
            )
        }

        $VerifiedArchiveEventLinks.Add(
            [pscustomobject]@{
                EventKey = $eventKey
                Repo = $revision.Repo
                Abbreviation = $revision.Abbreviation
                WorkshopId = $revision.WorkshopId
                SkymodsRevisionKey = $revisionKey
                VerificationStatus = (
                    $revision.VerificationStatus
                )
                CandidateGitCommitCount = (
                    $revision.CandidateGitCommitCount
                )
                ExactProjectedGitMatchCount = (
                    $revision.ExactProjectedGitMatchCount
                )
                MatchedGitCommitShas = (
                    $revision.MatchedGitCommitShas
                )
                DescriptorWorkshopIdMatches = (
                    $descriptorValid
                )
                DescriptorCountInArchive = (
                    $descriptorCount
                )
                DescriptorRemoteFileId = (
                    $descriptorRemoteFileId
                )
                AlignmentFound = $alignmentFound
                DominantTemporalAlignment = (
                    $dominantAlignment
                )
                BidirectionalUniqueAlignment = (
                    $bidirectionalUnique
                )
                TemporalPairStatus = (
                    $temporalPairStatuses
                )
                ObservedOffsetHours = (
                    $observedOffsets
                )
                ArchiveSha256 = $archiveSha256
                DuplicateArchiveCount = (
                    $duplicateArchiveCount
                )
                DuplicateArchiveRevisionKeys = (
                    $duplicateArchiveRevisionKeys
                )
                DescriptorOnlyNearMatchCount = (
                    $nearMatches.Count
                )
                DescriptorOnlyNearMatchGitShas = (
                    Join-UniqueValues @(
                        $nearMatches |
                            ForEach-Object {
                                $_.GitCommitSha
                            }
                    )
                )
                Analysis07Reason = (
                    $revision.Analysis07Reason
                )
            }
        )
    }
}

$VerifiedLinksByEvent = New-GroupIndex `
    -Rows @($VerifiedArchiveEventLinks) `
    -KeySelector {
        param($row)

        [string]$row.EventKey
    }

$EventResolutionMatrix = (
    [System.Collections.Generic.List[object]]::new()
)

foreach ($event in $SteamEvents) {
    $eventKey = (
        [string]$event.WorkshopId +
        "|" +
        [string]$event.NewestOrdinal
    )

    $candidateRows = @(
        Get-IndexedRows `
            -Index $CandidatePairsByEvent `
            -Key $eventKey
    )

    $candidateGitShas = @(
        $candidateRows |
            ForEach-Object {
                [string]$_.GitCommitSha
            } |
            Sort-Object -Unique
    )

    $candidateClassifications = @(
        $candidateRows |
            ForEach-Object {
                [string]$_.GitClassification
            } |
            Sort-Object -Unique
    )

    $verifiedLinks = @(
        Get-IndexedRows `
            -Index $VerifiedLinksByEvent `
            -Key $eventKey
    )

    $qualifiedLinks = @(
        $verifiedLinks |
            Where-Object {
                $_.DescriptorWorkshopIdMatches -eq $true -and
                $_.DescriptorCountInArchive -eq 1 -and
                $_.AlignmentFound -eq $true -and
                $_.DominantTemporalAlignment -eq $true
            }
    )

    $resolutionStatus = "UNVERIFIED"
    $resolutionConfidence = "UNRESOLVED"
    $resolutionBasis = (
        "No content-verified first-pass relationship " +
        "is sufficient for automatic resolution."
    )

    $selectedRevisionKey = ""
    $selectedGitCommitShas = ""
    $selectedTemporalPairStatus = ""
    $selectedVerificationStatus = ""
    $descriptorOnlyNearMatch = $false
    $gitIdentityAmbiguous = $false
    $existingViaEquivalentArchive = $false
    $equivalentArchiveRevisionKeys = ""

    if ($qualifiedLinks.Count -eq 1) {
        $link = $qualifiedLinks[0]

        $selectedRevisionKey = (
            [string]$link.SkymodsRevisionKey
        )

        $selectedGitCommitShas = (
            [string]$link.MatchedGitCommitShas
        )

        $selectedTemporalPairStatus = (
            [string]$link.TemporalPairStatus
        )

        $selectedVerificationStatus = (
            [string]$link.VerificationStatus
        )

        $descriptorOnlyNearMatch = (
            $link.DescriptorOnlyNearMatchCount -gt 0
        )

        $matchedShas = @(
            Split-PipeValues `
                $link.MatchedGitCommitShas
        )

        switch (
            [string]$link.VerificationStatus
        ) {
            "UNIQUE_PROJECTED_GIT_MATCH" {
                if ($matchedShas.Count -ne 1) {
                    $Warnings.Add(
                        "$eventKey / $selectedRevisionKey " +
                        "is UNIQUE_PROJECTED_GIT_MATCH but " +
                        "has $($matchedShas.Count) matched SHAs."
                    )

                    break
                }

                $matchedSha = $matchedShas[0]

                $candidateForThisEvent = (
                    $candidateGitShas -contains $matchedSha
                )

                $gitCandidateEvents = @(
                    Get-IndexedRows `
                        -Index $CandidatePairsByGit `
                        -Key $matchedSha |
                        ForEach-Object {
                            $_.EventKey
                        } |
                        Sort-Object -Unique
                )

                if (-not $candidateForThisEvent) {
                    $Warnings.Add(
                        "$eventKey / $selectedRevisionKey " +
                        "uniquely matches Git $matchedSha, " +
                        "but that SHA is not an Analysis 05 " +
                        "candidate for the event."
                    )

                    $resolutionBasis = (
                        "Archive content uniquely matches a Git " +
                        "snapshot, but the matched snapshot is not " +
                        "an Analysis 05 candidate for this Steam event."
                    )

                    break
                }

                if (
                    $link.BidirectionalUniqueAlignment -eq $true
                ) {
                    $resolutionStatus = "KNOWN + EXISTING"
                    $resolutionConfidence = "STRONG"

                    $resolutionBasis = (
                        "Content-verified archive uniquely matches " +
                        "an Analysis 05 Git candidate and the " +
                        "Steam/Skymods temporal relationship is " +
                        "bidirectionally unique."
                    )

                    break
                }

                if ($gitCandidateEvents.Count -eq 1) {
                    $resolutionStatus = "KNOWN + EXISTING"
                    $resolutionConfidence = "STRONG"

                    $resolutionBasis = (
                        "Content-verified archive uniquely matches " +
                        "a Git snapshot that is a candidate for only " +
                        "this Steam event; dominant temporal evidence " +
                        "provides the archive relationship."
                    )

                    break
                }

                $resolutionBasis = (
                    "Archive uniquely matches a Git snapshot, but " +
                    "the event identity remains ambiguous because " +
                    "the temporal relationship is not bidirectionally " +
                    "unique and the Git snapshot has multiple Steam " +
                    "event candidates."
                )
            }

            "NO_PROJECTED_GIT_MATCH" {
                if (
                    $link.BidirectionalUniqueAlignment -eq $true
                ) {
                    $equivalentExactMatchLinks = @(
                        $VerifiedArchiveEventLinks |
                            Where-Object {
                                $_.WorkshopId -eq $link.WorkshopId -and
                                $_.ArchiveSha256 -eq $link.ArchiveSha256 -and
                                -not [string]::IsNullOrWhiteSpace(
                                    [string]$_.ArchiveSha256
                                ) -and
                                $_.VerificationStatus -eq
                                "UNIQUE_PROJECTED_GIT_MATCH" -and
                                $_.DescriptorWorkshopIdMatches -eq $true -and
                                $_.DescriptorCountInArchive -eq 1
                            }
                    )

                    $equivalentGitShas = @(
                        $equivalentExactMatchLinks |
                            ForEach-Object {
                                Split-PipeValues `
                                    $_.MatchedGitCommitShas
                            } |
                            Sort-Object -Unique
                    )

                    if ($equivalentGitShas.Count -eq 1) {
                        $resolutionStatus = "KNOWN + EXISTING"
                        $resolutionConfidence = "STRONG"

                        $selectedGitCommitShas = (
                            $equivalentGitShas[0]
                        )

                        $existingViaEquivalentArchive = $true

                        $equivalentArchiveRevisionKeys = (
                            Join-KeyValues @(
                                $equivalentExactMatchLinks |
                                    ForEach-Object {
                                        $_.SkymodsRevisionKey
                                    }
                            )
                        )

                        $resolutionBasis = (
                            "The archive is bidirectionally anchored " +
                            "to this Steam event and is byte-identical " +
                            "to another verified revision whose archive " +
                            "has a unique exact projected historical " +
                            "Git match."
                        )

                        break
                    }

                    if ($equivalentGitShas.Count -gt 1) {
                        $gitIdentityAmbiguous = $true

                        $equivalentArchiveRevisionKeys = (
                            Join-KeyValues @(
                                $equivalentExactMatchLinks |
                                    ForEach-Object {
                                        $_.SkymodsRevisionKey
                                    }
                            )
                        )

                        $resolutionBasis = (
                            "The archive is bidirectionally anchored " +
                            "to this Steam event and is byte-identical " +
                            "to verified archive content associated " +
                            "with multiple exact historical Git matches. " +
                            "Git identity remains ambiguous."
                        )

                        break
                    }

                    if ($descriptorOnlyNearMatch) {
                        $resolutionBasis = (
                            "The archive is bidirectionally anchored " +
                            "to this Steam event. No exact projected " +
                            "Git match exists among the tested " +
                            "Analysis 09 candidates, while a historical " +
                            "Git candidate differs only in descriptor.mod. " +
                            "An exhaustive same-repository Git comparison " +
                            "is required before assigning EXISTING or " +
                            "RECOVERED."
                        )
                    }
                    else {
                        $resolutionBasis = (
                            "The archive is bidirectionally anchored " +
                            "to this Steam event, but no exact projected " +
                            "Git match exists among the tested Analysis 09 " +
                            "candidates. Candidate-limited absence does " +
                            "not prove that the content is absent from " +
                            "all historical Git snapshots, so an exhaustive " +
                            "same-repository comparison is required before " +
                            "assigning RECOVERED."
                        )
                    }

                    break
                }

                $resolutionBasis = (
                    "A verified archive exists and has no exact " +
                    "projected Git match among the tested candidates, " +
                    "but its temporal relationship is not " +
                    "bidirectionally unique."
                )
            }

            "MULTIPLE_PROJECTED_GIT_MATCHES" {
                $gitIdentityAmbiguous = $true

                $resolutionBasis = (
                    "The verified archive matches multiple historical " +
                    "Git snapshots exactly in projected tracked content. " +
                    "Git identity remains ambiguous."
                )
            }

            default {
                $resolutionBasis = (
                    "The verified archive has an unsupported or " +
                    "unresolved Analysis 09 verification status: " +
                    $link.VerificationStatus
                )
            }
        }
    }
    elseif ($qualifiedLinks.Count -gt 1) {
        $resolutionBasis = (
            "Multiple content-verified dominant archive relationships " +
            "remain for this Steam event."
        )

        $Warnings.Add(
            "$eventKey has $($qualifiedLinks.Count) qualified " +
            "Analysis 09 archive links."
        )
    }
    elseif ($verifiedLinks.Count -gt 0) {
        $resolutionBasis = (
            "Analysis 09 archive evidence exists, but descriptor or " +
            "dominant temporal requirements are not sufficient for " +
            "automatic status promotion."
        )
    }

    $EventResolutionMatrix.Add(
        [pscustomobject]@{
            EventKey = $eventKey
            Repo = $event.Repo
            Abbreviation = $event.Abbreviation
            WorkshopId = $event.WorkshopId
            SteamNewestOrdinal = $event.NewestOrdinal
            SteamRawDisplayedTime = (
                $event.RawDisplayedTime
            )
            SteamNormalizedFetchedTime = (
                $event.NormalizedFetchedTime
            )
            SteamVersionText = $event.VersionText
            SteamPreview = $event.Preview
            SteamCanonicalTimeVerified = (
                $event.CanonicalTimeVerified
            )
            CandidateGitCommitCount = (
                $candidateGitShas.Count
            )
            CandidateGitCommitShas = (
                Join-UniqueValues $candidateGitShas
            )
            CandidateGitClassifications = (
                Join-UniqueValues `
                    $candidateClassifications
            )
            VerifiedArchiveLinkCount = (
                $verifiedLinks.Count
            )
            QualifiedVerifiedArchiveLinkCount = (
                $qualifiedLinks.Count
            )
            VerifiedArchiveRevisionKeys = (
                Join-KeyValues @(
                    $verifiedLinks |
                        ForEach-Object {
                            $_.SkymodsRevisionKey
                        }
                )
            )
            SelectedSkymodsRevisionKey = (
                $selectedRevisionKey
            )
            SelectedArchiveVerificationStatus = (
                $selectedVerificationStatus
            )
            SelectedTemporalPairStatus = (
                $selectedTemporalPairStatus
            )
            MatchedGitCommitShas = (
                $selectedGitCommitShas
            )
            DescriptorOnlyNearMatch = (
                $descriptorOnlyNearMatch
            )
            GitIdentityAmbiguous = (
                $gitIdentityAmbiguous
            )
            ExistingViaEquivalentArchive = (
                $existingViaEquivalentArchive
            )
            EquivalentArchiveRevisionKeys = (
                $equivalentArchiveRevisionKeys
            )
            ResolutionStatus = (
                $resolutionStatus
            )
            ResolutionConfidence = (
                $resolutionConfidence
            )
            ResolutionBasis = (
                $resolutionBasis
            )
        }
    )
}

$ResolvedExistingEventsByGit = @{}

foreach ($eventRow in $EventResolutionMatrix) {
    if (
        $eventRow.ResolutionStatus -ne
        "KNOWN + EXISTING"
    ) {
        continue
    }

    foreach (
        $sha in @(
            Split-PipeValues `
                $eventRow.MatchedGitCommitShas
        )
    ) {
        if (
            -not $ResolvedExistingEventsByGit.ContainsKey(
                $sha
            )
        ) {
            $ResolvedExistingEventsByGit[$sha] = (
                [System.Collections.Generic.List[object]]::new()
            )
        }

        $ResolvedExistingEventsByGit[
            $sha
        ].Add($eventRow)
    }
}

$GitResolutionMatrix = (
    [System.Collections.Generic.List[object]]::new()
)

$ExplicitInvalidClassifications = @(
    "PLACEHOLDER",
    "CROSS_TARGET_DESCRIPTOR_MISMATCH"
)

foreach ($git in $GitCommits) {
    $sha = [string]$git.CommitSha

    $candidateRows = @(
        Get-IndexedRows `
            -Index $CandidatePairsByGit `
            -Key $sha
    )

    $candidateEventKeys = @(
        $candidateRows |
            ForEach-Object {
                $_.EventKey
            } |
            Sort-Object -Unique
    )

    $resolvedExistingRows = @()

    if (
        $ResolvedExistingEventsByGit.ContainsKey(
            $sha
        )
    ) {
        $resolvedExistingRows = @(
            $ResolvedExistingEventsByGit[$sha]
        )
    }

    $gitStatus = "UNVERIFIED"
    $gitBasis = (
        "No final Git-snapshot classification is justified " +
        "by the current verified event evidence."
    )

    $structuralClassification = (
        [string]$git.StructuralClassification
    )

    if (
        $ExplicitInvalidClassifications -contains
        $structuralClassification
    ) {
        $gitStatus = "INVALID"

        $gitBasis = (
            "Analysis 05 structurally classifies this historical " +
            "snapshot as $structuralClassification."
        )
    }
    elseif ($resolvedExistingRows.Count -gt 0) {
        $gitStatus = "KNOWN + EXISTING"

        $gitBasis = (
            "This historical Git snapshot is an exact projected " +
            "content match for a Steam event resolved as " +
            "KNOWN + EXISTING."
        )
    }
    elseif (
        $structuralClassification -eq
        "EXTERNAL_DESCRIPTOR_MISMATCH"
    ) {
        $nearMatchRows = @(
            $DescriptorOnlyNearMatches |
                Where-Object {
                    $_.GitCommitSha -eq $sha
                }
        )

        $gitStatus = "UNVERIFIED"

        if ($nearMatchRows.Count -gt 0) {
            $gitBasis = (
                "The snapshot carries an external Workshop ID in " +
                "descriptor.mod, but Analysis 09 records a " +
                "descriptor-only near-match to a verified target " +
                "archive. It is not an exact Workshop snapshot and " +
                "is retained as related evidence rather than " +
                "classified as INVALID."
            )
        }
        else {
            $gitBasis = (
                "The snapshot carries an external Workshop ID in " +
                "descriptor.mod and is retained as UNVERIFIED pending " +
                "additional content evidence."
            )
        }
    }
    elseif (
        $structuralClassification -eq "LOCAL_ONLY" -or
        $structuralClassification -eq "REPAIR"
    ) {
        $gitStatus = "LOCAL-ONLY / REPAIR"

        $gitBasis = (
            "The historical commit carries an explicit local-only " +
            "or repair structural classification."
        )
    }

    $GitResolutionMatrix.Add(
        [pscustomobject]@{
            Repo = $git.Repo
            Abbreviation = $git.Abbreviation
            WorkshopId = $git.WorkshopId
            GitOrdinal = $git.GitOrdinal
            CommitSha = $sha
            Subject = $git.Subject
            AuthorDate = $git.AuthorDate
            DescriptorVersion = (
                $git.DescriptorVersion
            )
            DescriptorWorkshopId = (
                $git.DescriptorWorkshopId
            )
            DescriptorWorkshopIdRelation = (
                $git.DescriptorWorkshopIdRelation
            )
            StructuralClassification = (
                $structuralClassification
            )
            EligibleForCandidateMapping = (
                $git.EligibleForCandidateMapping
            )
            CandidateEventCount = (
                $candidateEventKeys.Count
            )
            CandidateEventKeys = (
                Join-KeyValues $candidateEventKeys
            )
            ResolvedExistingEventCount = (
                $resolvedExistingRows.Count
            )
            ResolvedExistingEventKeys = (
                Join-KeyValues @(
                    $resolvedExistingRows |
                        ForEach-Object {
                            $_.EventKey
                        }
                )
            )
            ResolutionStatus = $gitStatus
            ResolutionBasis = $gitBasis
        }
    )
}

$AllowedStatuses = @(
    "KNOWN + EXISTING",
    "KNOWN + RECOVERED",
    "KNOWN + MISSING",
    "LOCAL-ONLY / REPAIR",
    "INVALID",
    "UNVERIFIED"
)

foreach ($row in $EventResolutionMatrix) {
    if (
        $AllowedStatuses -notcontains
        $row.ResolutionStatus
    ) {
        $ValidationErrors.Add(
            "Unknown event resolution status: " +
            "$($row.EventKey) -> $($row.ResolutionStatus)"
        )
    }

    if (
        $row.ResolutionStatus -eq
        "KNOWN + EXISTING"
    ) {
        if (
            [string]::IsNullOrWhiteSpace(
                [string]$row.SelectedSkymodsRevisionKey
            )
        ) {
            $ValidationErrors.Add(
                "$($row.EventKey) is KNOWN + EXISTING " +
                "without a selected archive revision."
            )
        }

        if (
            [string]::IsNullOrWhiteSpace(
                [string]$row.MatchedGitCommitShas
            )
        ) {
            $ValidationErrors.Add(
                "$($row.EventKey) is KNOWN + EXISTING " +
                "without a matched Git SHA."
            )
        }
    }

    if (
        $row.ResolutionStatus -eq
        "KNOWN + RECOVERED" -and
        [string]::IsNullOrWhiteSpace(
            [string]$row.SelectedSkymodsRevisionKey
        )
    ) {
        $ValidationErrors.Add(
            "$($row.EventKey) is KNOWN + RECOVERED " +
            "without a selected archive revision."
        )
    }
}

foreach ($row in $GitResolutionMatrix) {
    if (
        $AllowedStatuses -notcontains
        $row.ResolutionStatus
    ) {
        $ValidationErrors.Add(
            "Unknown Git resolution status: " +
            "$($row.CommitSha) -> $($row.ResolutionStatus)"
        )
    }
}

$EventKeys = @(
    $EventResolutionMatrix |
        ForEach-Object {
            $_.EventKey
        }
)

$UniqueEventKeys = @(
    $EventKeys |
        Sort-Object -Unique
)

if ($SteamEvents.Count -ne 1198) {
    $ValidationErrors.Add(
        "Expected 1198 Steam events, found $($SteamEvents.Count)."
    )
}

if ($EventResolutionMatrix.Count -ne $SteamEvents.Count) {
    $ValidationErrors.Add(
        "Event matrix row count does not match Steam input count."
    )
}

if ($UniqueEventKeys.Count -ne $SteamEvents.Count) {
    $ValidationErrors.Add(
        "Event matrix contains duplicate EventKey values."
    )
}

if ($GitCommits.Count -ne 116) {
    $ValidationErrors.Add(
        "Expected 116 historical Git commits, found $($GitCommits.Count)."
    )
}

if ($GitResolutionMatrix.Count -ne $GitCommits.Count) {
    $ValidationErrors.Add(
        "Git resolution row count does not match Git input count."
    )
}

if ($RevisionSummary.Count -ne 52) {
    $ValidationErrors.Add(
        "Expected 52 Analysis 09 revisions, found $($RevisionSummary.Count)."
    )
}

if ($ArchiveDescriptors.Count -ne 52) {
    $ValidationErrors.Add(
        "Expected 52 Analysis 09 descriptor rows, found " +
        "$($ArchiveDescriptors.Count)."
    )
}

$InvalidDescriptorRows = @(
    $ArchiveDescriptors |
        Where-Object {
            -not (
                Convert-ToBoolean `
                    $_.DescriptorWorkshopIdMatches
            ) -or
            (
                Convert-ToInteger `
                    $_.DescriptorCountInArchive
            ) -ne 1
        }
)

if ($InvalidDescriptorRows.Count -gt 0) {
    $ValidationErrors.Add(
        "$($InvalidDescriptorRows.Count) Analysis 09 descriptor " +
        "rows fail Workshop-ID/count validation."
    )
}

$ExpectedVerifiedArchiveEventLinkCount = 0

foreach ($revision in $RevisionSummary) {
    $relatedEventCount = Convert-ToInteger `
        $revision.RelatedSteamEventCount

    $ExpectedVerifiedArchiveEventLinkCount += (
        $relatedEventCount
    )

    if ($relatedEventCount -ne 1) {
        $ValidationErrors.Add(
            "$($revision.SkymodsRevisionKey) declares " +
            "$relatedEventCount related Steam events. " +
            "Analysis 10 currently requires exactly one " +
            "RelatedSteamEventKey per verified revision."
        )
    }

    $actualRevisionLinks = @(
        $VerifiedArchiveEventLinks |
            Where-Object {
                $_.SkymodsRevisionKey -eq
                $revision.SkymodsRevisionKey
            }
    ).Count

    if ($actualRevisionLinks -ne $relatedEventCount) {
        $ValidationErrors.Add(
            "$($revision.SkymodsRevisionKey) expected " +
            "$relatedEventCount archive/event link(s), " +
            "but produced $actualRevisionLinks."
        )
    }
}

if (
    $VerifiedArchiveEventLinks.Count -ne
    $ExpectedVerifiedArchiveEventLinkCount
) {
    $ValidationErrors.Add(
        "Expected $ExpectedVerifiedArchiveEventLinkCount " +
        "verified archive/event links from Analysis 09, " +
        "but produced $($VerifiedArchiveEventLinks.Count)."
    )
}

$SteamEventKeySet = @{}

foreach ($event in $SteamEvents) {
    $steamEventKey = (
        [string]$event.WorkshopId +
        "|" +
        [string]$event.NewestOrdinal
    )

    $SteamEventKeySet[$steamEventKey] = $true
}

$UnknownVerifiedLinkEvents = @(
    $VerifiedArchiveEventLinks |
        Where-Object {
            -not $SteamEventKeySet.ContainsKey(
                [string]$_.EventKey
            )
        }
)

if ($UnknownVerifiedLinkEvents.Count -gt 0) {
    $ValidationErrors.Add(
        "$($UnknownVerifiedLinkEvents.Count) verified archive/event " +
        "link(s) reference EventKey values absent from Analysis 04."
    )
}

$DuplicateVerifiedLinkPairs = @(
    $VerifiedArchiveEventLinks |
        Group-Object {
            (
                [string]$_.EventKey +
                "`n" +
                [string]$_.SkymodsRevisionKey
            )
        } |
        Where-Object {
            $_.Count -gt 1
        }
)

if ($DuplicateVerifiedLinkPairs.Count -gt 0) {
    $ValidationErrors.Add(
        "$($DuplicateVerifiedLinkPairs.Count) duplicate " +
        "EventKey/SkymodsRevisionKey pair(s) were produced."
    )
}

$UniqueVerifiedRevisionKeys = @(
    $VerifiedArchiveEventLinks |
        ForEach-Object {
            $_.SkymodsRevisionKey
        } |
        Sort-Object -Unique
)

if (
    $UniqueVerifiedRevisionKeys.Count -ne
    $RevisionSummary.Count
) {
    $ValidationErrors.Add(
        "Expected verified links for all " +
        "$($RevisionSummary.Count) Analysis 09 revisions, " +
        "but found $($UniqueVerifiedRevisionKeys.Count) " +
        "unique revision keys."
    )
}
$KnownMissingCount = @(
    $EventResolutionMatrix |
        Where-Object {
            $_.ResolutionStatus -eq
            "KNOWN + MISSING"
        }
).Count

if ($KnownMissingCount -ne 0) {
    $ValidationErrors.Add(
        "Analysis 10 must not assign KNOWN + MISSING yet."
    )
}

$KnownRecoveredCountForValidation = @(
    $EventResolutionMatrix |
        Where-Object {
            $_.ResolutionStatus -eq
            "KNOWN + RECOVERED"
        }
).Count

if ($KnownRecoveredCountForValidation -ne 0) {
    $ValidationErrors.Add(
        "Analysis 10 must not assign KNOWN + RECOVERED from " +
        "candidate-limited no-match evidence. Exhaustive " +
        "same-repository Git comparison is required first."
    )
}

$EquivalentArchiveExistingRows = @(
    $EventResolutionMatrix |
        Where-Object {
            Convert-ToBoolean `
                $_.ExistingViaEquivalentArchive
        }
)

foreach ($row in $EquivalentArchiveExistingRows) {
    if ($row.ResolutionStatus -ne "KNOWN + EXISTING") {
        $ValidationErrors.Add(
            "$($row.EventKey) carries equivalent-archive evidence " +
            "without KNOWN + EXISTING status."
        )
    }

    if (
        [string]::IsNullOrWhiteSpace(
            [string]$row.EquivalentArchiveRevisionKeys
        )
    ) {
        $ValidationErrors.Add(
            "$($row.EventKey) carries equivalent-archive evidence " +
            "without source revision keys."
        )
    }

    if (
        [string]::IsNullOrWhiteSpace(
            [string]$row.MatchedGitCommitShas
        )
    ) {
        $ValidationErrors.Add(
            "$($row.EventKey) carries equivalent-archive evidence " +
            "without an inherited Git match."
        )
    }
}

$EventStatusSummary = @(
    $EventResolutionMatrix |
        Group-Object ResolutionStatus |
        Sort-Object Name |
        ForEach-Object {
            [pscustomobject]@{
                ResolutionStatus = $_.Name
                EventCount = $_.Count
            }
        }
)

$GitStatusSummary = @(
    $GitResolutionMatrix |
        Group-Object ResolutionStatus |
        Sort-Object Name |
        ForEach-Object {
            [pscustomobject]@{
                ResolutionStatus = $_.Name
                GitCommitCount = $_.Count
            }
        }
)

$RepoSummary = @(
    $EventResolutionMatrix |
        Group-Object Repo |
        Sort-Object Name |
        ForEach-Object {
            $rows = @($_.Group)

            [pscustomobject]@{
                Repo = $_.Name
                SteamEventCount = $rows.Count
                KnownExistingCount = @(
                    $rows |
                        Where-Object {
                            $_.ResolutionStatus -eq
                            "KNOWN + EXISTING"
                        }
                ).Count
                KnownRecoveredCount = @(
                    $rows |
                        Where-Object {
                            $_.ResolutionStatus -eq
                            "KNOWN + RECOVERED"
                        }
                ).Count
                KnownMissingCount = @(
                    $rows |
                        Where-Object {
                            $_.ResolutionStatus -eq
                            "KNOWN + MISSING"
                        }
                ).Count
                UnverifiedCount = @(
                    $rows |
                        Where-Object {
                            $_.ResolutionStatus -eq
                            "UNVERIFIED"
                        }
                ).Count
            }
        }
)

$InputInventory |
    Export-Csv `
        -LiteralPath (
            Join-Path `
                $OutputDirectory `
                "input-files.csv"
        ) `
        -NoTypeInformation `
        -Encoding utf8

$EventResolutionMatrix |
    Export-Csv `
        -LiteralPath (
            Join-Path `
                $OutputDirectory `
                "event-resolution-matrix.csv"
        ) `
        -NoTypeInformation `
        -Encoding utf8

$VerifiedArchiveEventLinks |
    Export-Csv `
        -LiteralPath (
            Join-Path `
                $OutputDirectory `
                "verified-archive-event-links.csv"
        ) `
        -NoTypeInformation `
        -Encoding utf8

$GitResolutionMatrix |
    Export-Csv `
        -LiteralPath (
            Join-Path `
                $OutputDirectory `
                "git-resolution-matrix.csv"
        ) `
        -NoTypeInformation `
        -Encoding utf8

$DescriptorOnlyNearMatches |
    Export-Csv `
        -LiteralPath (
            Join-Path `
                $OutputDirectory `
                "descriptor-only-near-matches.csv"
        ) `
        -NoTypeInformation `
        -Encoding utf8

$EventStatusSummary |
    Export-Csv `
        -LiteralPath (
            Join-Path `
                $OutputDirectory `
                "event-status-summary.csv"
        ) `
        -NoTypeInformation `
        -Encoding utf8

$GitStatusSummary |
    Export-Csv `
        -LiteralPath (
            Join-Path `
                $OutputDirectory `
                "git-status-summary.csv"
        ) `
        -NoTypeInformation `
        -Encoding utf8

$RepoSummary |
    Export-Csv `
        -LiteralPath (
            Join-Path `
                $OutputDirectory `
                "repo-summary.csv"
        ) `
        -NoTypeInformation `
        -Encoding utf8

if ($Warnings.Count -gt 0) {
    $Warnings |
        Set-Content `
            -LiteralPath (
                Join-Path `
                    $OutputDirectory `
                    "warnings.txt"
            ) `
            -Encoding utf8
}
else {
    "No warnings." |
        Set-Content `
            -LiteralPath (
                Join-Path `
                    $OutputDirectory `
                    "warnings.txt"
            ) `
            -Encoding utf8
}

if ($ValidationErrors.Count -gt 0) {
    $ValidationErrors |
        Set-Content `
            -LiteralPath (
                Join-Path `
                    $OutputDirectory `
                    "validation-errors.txt"
            ) `
            -Encoding utf8
}
else {
    "No validation errors." |
        Set-Content `
            -LiteralPath (
                Join-Path `
                    $OutputDirectory `
                    "validation-errors.txt"
            ) `
            -Encoding utf8
}

$KnownExistingEvents = @(
    $EventResolutionMatrix |
        Where-Object {
            $_.ResolutionStatus -eq
            "KNOWN + EXISTING"
        }
).Count

$EquivalentArchiveExistingEvents = @(
    $EventResolutionMatrix |
        Where-Object {
            Convert-ToBoolean `
                $_.ExistingViaEquivalentArchive
        }
).Count

$KnownRecoveredEvents = @(
    $EventResolutionMatrix |
        Where-Object {
            $_.ResolutionStatus -eq
            "KNOWN + RECOVERED"
        }
).Count

$UnverifiedEvents = @(
    $EventResolutionMatrix |
        Where-Object {
            $_.ResolutionStatus -eq
            "UNVERIFIED"
        }
).Count

$InvalidGitCommits = @(
    $GitResolutionMatrix |
        Where-Object {
            $_.ResolutionStatus -eq
            "INVALID"
        }
).Count

$KnownExistingGitCommits = @(
    $GitResolutionMatrix |
        Where-Object {
            $_.ResolutionStatus -eq
            "KNOWN + EXISTING"
        }
).Count

$DuplicateArchiveGroups = @(
    $DownloadsBySha256.GetEnumerator() |
        Where-Object {
            @($_.Value).Count -gt 1
        }
).Count

$GeneratedTimestamp = (
    Get-Date -Format "yyyy-MM-dd HH:mm:ss zzz"
)

$Readme = @"
# Analysis 10 - Event Resolution Matrix

Generated: $GeneratedTimestamp

This analysis combines Steam events, historical Git candidates, Analysis 07
Steam/Skymods temporal alignment, and Analysis 09 content-verified archives into
one conservative event-level resolution matrix.

## Inputs

- Analysis 04 Steam event inventory
- Analysis 05 Steam/Git candidate mapping and Git structural classification
- Analysis 07 Steam/Skymods temporal alignment
- Analysis 09 first-pass archive verification

Input files are recorded with SHA-256 provenance in ``input-files.csv``.

## Resolution policy

This stage promotes a Steam event to ``KNOWN + EXISTING`` when a
content-verified archive has a unique exact projected historical Git match and
the archive is sufficiently anchored to the Steam event.

An event may also resolve to ``KNOWN + EXISTING`` when its verified archive is
byte-identical to another verified revision whose archive already has one
unique exact historical Git match. This preserves repeated Workshop events that
published identical content without incorrectly treating the later event as a
recovery.

A ``NO_PROJECTED_GIT_MATCH`` result from Analysis 09 rules out only the tested
candidate Git commits. It is therefore not sufficient by itself to assign
``KNOWN + RECOVERED``. Those archives remain ``UNVERIFIED`` until they are
compared exhaustively against every historical Git snapshot in the same
repository.

Multiple projected Git matches remain ``UNVERIFIED`` because Git identity is
still ambiguous.

``KNOWN + MISSING`` is deliberately not assigned by this stage.

Historical Git placeholders and cross-target snapshots are classified
``INVALID``. An ``EXTERNAL_DESCRIPTOR_MISMATCH`` is not automatically
classified as invalid, because descriptor-only near-match evidence may still
show that the snapshot is closely related to the target Workshop content.

Steam timestamps remain the captured Steam-displayed values from Analysis 04.
This stage does not perform timezone conversion or promote
``CanonicalTimeVerified``.

## Results

Steam events: $($EventResolutionMatrix.Count)
Historical Git commits: $($GitResolutionMatrix.Count)
Analysis 09 verified archive/event links: $($VerifiedArchiveEventLinks.Count)

KNOWN + EXISTING events: $KnownExistingEvents
KNOWN + RECOVERED events: $KnownRecoveredEvents
KNOWN + MISSING events: $KnownMissingCount
UNVERIFIED events: $UnverifiedEvents

KNOWN + EXISTING Git commits: $KnownExistingGitCommits
INVALID Git commits: $InvalidGitCommits

Descriptor-only near matches: $($DescriptorOnlyNearMatches.Count)
Duplicate verified archive SHA-256 groups: $DuplicateArchiveGroups
EXISTING events resolved through byte-identical archive evidence: $EquivalentArchiveExistingEvents

Warnings: $($Warnings.Count)
Validation errors: $($ValidationErrors.Count)

## Outputs

- ``input-files.csv``
- ``event-resolution-matrix.csv``
- ``verified-archive-event-links.csv``
- ``git-resolution-matrix.csv``
- ``descriptor-only-near-matches.csv``
- ``event-status-summary.csv``
- ``git-status-summary.csv``
- ``repo-summary.csv``
- ``warnings.txt``
- ``validation-errors.txt``

This is the first conservative status-assignment pass. Remaining unverified
events and Git snapshots require later archive-recovery or local-repair
analysis before canonical Workshop history is constructed.
"@

$Readme |
    Set-Content `
        -LiteralPath (
            Join-Path `
                $OutputDirectory `
                "README.md"
        ) `
        -Encoding utf8

if (Test-Path -LiteralPath $PackagePath) {
    Remove-Item `
        -LiteralPath $PackagePath `
        -Force
}

Compress-Archive `
    -Path (
        Join-Path `
            $OutputDirectory `
            "*"
    ) `
    -DestinationPath $PackagePath `
    -CompressionLevel Optimal

Write-Host ""
Write-Host "================ ANALYSIS 10 COMPLETE ================"
Write-Host ""
Write-Host "Steam events               : $($EventResolutionMatrix.Count)"
Write-Host "Historical Git commits     : $($GitResolutionMatrix.Count)"
Write-Host "Verified archive/event links: $($VerifiedArchiveEventLinks.Count)"
Write-Host ""
Write-Host "KNOWN + EXISTING events    : $KnownExistingEvents"
Write-Host "KNOWN + RECOVERED events   : $KnownRecoveredEvents"
Write-Host "KNOWN + MISSING events     : $KnownMissingCount"
Write-Host "UNVERIFIED events          : $UnverifiedEvents"
Write-Host ""
Write-Host "KNOWN + EXISTING Git commits: $KnownExistingGitCommits"
Write-Host "INVALID Git commits         : $InvalidGitCommits"
Write-Host "Descriptor-only near matches: $($DescriptorOnlyNearMatches.Count)"
Write-Host "Duplicate archive groups    : $DuplicateArchiveGroups"
Write-Host ""
Write-Host "Warnings                    : $($Warnings.Count)"
Write-Host "Validation errors           : $($ValidationErrors.Count)"
Write-Host ""

if ($ValidationErrors.Count -eq 0) {
    Write-Host "Run validation: PASS"
}
else {
    Write-Host "Run validation: FAIL"
}

Write-Host ""
Write-Host "Results:"
Write-Host "  $OutputDirectory"
Write-Host ""
Write-Host "Package:"
Write-Host "  $PackagePath"

if ($ValidationErrors.Count -gt 0) {
    throw (
        "Analysis 10 completed with " +
        "$($ValidationErrors.Count) validation error(s)."
    )
}
