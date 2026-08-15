$ErrorActionPreference = "Stop"

$Root = "F:\Storage\Codding\projects\ck3"
$OutDir = Join-Path $Root "_workshop_history_analysis_3"
$ZipPath = Join-Path $Root "ck3-workshop-history-analysis-3.zip"

$Targets = @(
    @{ Folder="Yusseter Community-Flavor-Pack";              Repo="Community-Flavor-Pack";              Abbr="CFP";         WorkshopId="2220098919" },
    @{ Folder="Yusseter Culture-and-Faith-Granularity";      Repo="Culture-and-Faith-Granularity";      Abbr="CFG";         WorkshopId="3206891770" },
    @{ Folder="Yusseter Culture-Expanded";                   Repo="Culture-Expanded";                   Abbr="CE";          WorkshopId="2829397295" },
    @{ Folder="Yusseter Demand-Tribute";                     Repo="Demand-Tribute";                     Abbr="DT";          WorkshopId="3473488611" },
    @{ Folder="Yusseter EPE-CFP";                            Repo="EPE-CFP";                            Abbr="EPE-CFP";     WorkshopId="2996881191" },
    @{ Folder="Yusseter Ethnicities-and-Portraits-Expanded"; Repo="Ethnicities-and-Portraits-Expanded"; Abbr="EPE";         WorkshopId="2507209632" },
    @{ Folder="Yusseter MBP-EPE-CFP";                        Repo="MBP-EPE-CFP";                        Abbr="MBP-EPE-CFP"; WorkshopId="2543865921" },
    @{ Folder="Yusseter MedievalImmersion";                  Repo="MedievalImmersion";                  Abbr="MI";          WorkshopId="3268020725" },
    @{ Folder="Yusseter MPE";                                Repo="MPE";                                Abbr="MPE";         WorkshopId="3726274827" },
    @{ Folder="Yusseter RICE";                               Repo="RICE";                               Abbr="RICE";        WorkshopId="2273832430" },
    @{ Folder="Yusseter Special-World";                      Repo="Special-World";                      Abbr="SW";          WorkshopId="2875587269" },
    @{ Folder="Yusseter Turkic-World-Expanded";              Repo="Turkic-World-Expanded";              Abbr="TWE";         WorkshopId="3668769244" },
    @{ Folder="Yusseter Western-Steppe-Expanded";            Repo="Western-Steppe-Expanded";           Abbr="WSE";         WorkshopId="3490396842" }
)

function Get-DescriptorValue {
    param(
        [string]$Text,
        [string]$Key
    )

    if ([string]::IsNullOrWhiteSpace($Text)) {
        return $null
    }

    $pattern =
        '(?m)^\s*' +
        [regex]::Escape($Key) +
        '\s*=\s*"([^"]*)"'

    $m = [regex]::Match($Text, $pattern)

    if ($m.Success) {
        return $m.Groups[1].Value
    }

    return $null
}

function Get-ExtFromPath {
    param([string]$Path)

    $ext = [IO.Path]::GetExtension($Path)

    if ([string]::IsNullOrWhiteSpace($ext)) {
        return "<no-extension>"
    }

    return $ext.ToLowerInvariant()
}

function Get-Sha256Text {
    param([string]$Text)

    $sha = [Security.Cryptography.SHA256]::Create()

    try {
        $bytes = [Text.Encoding]::UTF8.GetBytes($Text)
        $hash = $sha.ComputeHash($bytes)

        return (
            [BitConverter]::ToString($hash)
        ).Replace("-", "").ToLowerInvariant()
    }
    finally {
        $sha.Dispose()
    }
}

function Get-TreeEntries {
    param(
        [string]$RepoPath,
        [string]$CommitSha
    )

    $result = @()

    $lines = @(
        & git -C $RepoPath `
            ls-tree `
            -r `
            -l `
            --full-tree `
            $CommitSha 2>$null
    )

    foreach ($line in $lines) {
        if (
            $line -match
            '^(\d+)\s+(\w+)\s+([0-9a-f]+)\s+(-|\d+)\t(.*)$'
        ) {
            $size = 0L

            if ($Matches[4] -ne "-") {
                $size = [int64]$Matches[4]
            }

            $result += [pscustomobject]@{
                Mode    = $Matches[1]
                Type    = $Matches[2]
                BlobSha = $Matches[3]
                Size    = $size
                Path    = $Matches[5]
            }
        }
    }

    return @($result)
}

if (-not (Test-Path $Root)) {
    throw "Root path not found: $Root"
}

if (Test-Path $OutDir) {
    Remove-Item -LiteralPath $OutDir -Recurse -Force
}

New-Item -ItemType Directory -Path $OutDir | Out-Null

$CommitSnapshots = [System.Collections.ArrayList]::new()
$FileChanges = [System.Collections.ArrayList]::new()
$ChangeExtensions = [System.Collections.ArrayList]::new()
$ExtensionInventory = [System.Collections.ArrayList]::new()
$DuplicateTrees = [System.Collections.ArrayList]::new()
$Warnings = [System.Collections.ArrayList]::new()

foreach ($t in $Targets) {
    $RepoPath = Join-Path $Root $t.Folder

    Write-Host "`n========================================"
    Write-Host "$($t.Repo) [$($t.WorkshopId)]"
    Write-Host "========================================"

    if (-not (Test-Path $RepoPath)) {
        [void]$Warnings.Add(
            "Missing repository folder: $RepoPath"
        )
        continue
    }

    if (-not (Test-Path (Join-Path $RepoPath ".git"))) {
        [void]$Warnings.Add(
            "Not a Git repository: $RepoPath"
        )
        continue
    }

    $Commits = @(
        & git -C $RepoPath rev-list --reverse HEAD 2>$null
    )

    Write-Host "Commits: $($Commits.Count)"

    $Ordinal = 0
    $PreviousTreeSha = $null
    $PreviousDescriptorVersion = $null

    foreach ($Sha in $Commits) {
        $Ordinal++

        Write-Host -NoNewline `
            "`r  Processing $Ordinal / $($Commits.Count)"

        $Subject = (
            @(
                & git -C $RepoPath `
                    show `
                    -s `
                    --format=%s `
                    $Sha 2>$null
            ) -join ""
        )

        $Message = (
            @(
                & git -C $RepoPath `
                    show `
                    -s `
                    --format=%B `
                    $Sha 2>$null
            ) -join "`n"
        ).TrimEnd()

        $AuthorDate = (
            @(
                & git -C $RepoPath `
                    show `
                    -s `
                    --format=%aI `
                    $Sha 2>$null
            ) -join ""
        ).Trim()

        $CommitterDate = (
            @(
                & git -C $RepoPath `
                    show `
                    -s `
                    --format=%cI `
                    $Sha 2>$null
            ) -join ""
        ).Trim()

        $ParentLine = (
            @(
                & git -C $RepoPath `
                    rev-list `
                    --parents `
                    -n 1 `
                    $Sha 2>$null
            ) -join ""
        ).Trim()

        $ParentParts = @(
            $ParentLine -split '\s+' |
            Where-Object { $_ }
        )

        $ParentCount = [Math]::Max(
            0,
            $ParentParts.Count - 1
        )

        $ParentSha = $null

        if ($ParentParts.Count -ge 2) {
            $ParentSha = $ParentParts[1]
        }

        $TreeSha = (
            @(
                & git -C $RepoPath `
                    rev-parse `
                    "$Sha^{tree}" 2>$null
            ) -join ""
        ).Trim()

        $Entries = @(
            Get-TreeEntries `
                -RepoPath $RepoPath `
                -CommitSha $Sha
        )

        $BlobEntries = @(
            $Entries |
            Where-Object { $_.Type -eq "blob" }
        )

        $TrackedBytes = (
            $BlobEntries |
            Measure-Object Size -Sum
        ).Sum

        if ($null -eq $TrackedBytes) {
            $TrackedBytes = 0
        }

        #
        # Deterministic fingerprint:
        # path + Git blob SHA + size
        #
        $FingerprintInput = (
            $Entries |
            Sort-Object Path |
            ForEach-Object {
                "$($_.Path)`t$($_.Type)`t$($_.BlobSha)`t$($_.Size)"
            }
        ) -join "`n"

        $TreeFingerprint = Get-Sha256Text $FingerprintInput

        #
        # Descriptor information at THIS commit
        #
        $DescriptorSpec = "${Sha}:descriptor.mod"

        $DescriptorLines = @(
            & git -C $RepoPath `
                show `
                $DescriptorSpec 2>$null
        )

        if ($LASTEXITCODE -eq 0) {
            $DescriptorText = $DescriptorLines -join "`n"
        }
        else {
            $DescriptorText = ""
        }

        $DescriptorName =
            Get-DescriptorValue `
                -Text $DescriptorText `
                -Key "name"

        $DescriptorVersion =
            Get-DescriptorValue `
                -Text $DescriptorText `
                -Key "version"

        $DescriptorSupported =
            Get-DescriptorValue `
                -Text $DescriptorText `
                -Key "supported_version"

        $DescriptorWorkshopId =
            Get-DescriptorValue `
                -Text $DescriptorText `
                -Key "remote_file_id"

        if (
            $DescriptorWorkshopId -and
            ($DescriptorWorkshopId -ne $t.WorkshopId)
        ) {
            [void]$Warnings.Add(
                "$($t.Repo) $Sha : descriptor remote_file_id=$DescriptorWorkshopId, expected=$($t.WorkshopId)"
            )
        }

        if (-not $DescriptorText) {
            [void]$Warnings.Add(
                "$($t.Repo) $Sha : descriptor.mod missing"
            )
        }

        #
        # .gitignore metadata at this commit
        #
        $GitIgnoreEntries = @(
            $Entries |
            Where-Object {
                $_.Path -eq ".gitignore" -or
                $_.Path -like "*/.gitignore"
            }
        )

        $RootGitIgnore = @(
            $Entries |
            Where-Object { $_.Path -eq ".gitignore" } |
            Select-Object -First 1
        )

        $RootGitIgnoreBlobSha = $null

        if ($RootGitIgnore.Count -gt 0) {
            $RootGitIgnoreBlobSha =
                $RootGitIgnore[0].BlobSha
        }

        #
        # Diff against first parent
        #
        if ($ParentSha) {
            $DiffLines = @(
                & git -C $RepoPath `
                    diff-tree `
                    --no-commit-id `
                    --name-status `
                    -r `
                    -M `
                    $ParentSha `
                    $Sha 2>$null
            )
        }
        else {
            $DiffLines = @(
                & git -C $RepoPath `
                    diff-tree `
                    --root `
                    --no-commit-id `
                    --name-status `
                    -r `
                    -M `
                    $Sha 2>$null
            )
        }

        $Added = 0
        $Modified = 0
        $Deleted = 0
        $Renamed = 0
        $Copied = 0
        $TypeChanged = 0
        $OtherChanges = 0

        $PerExt = @{}

        foreach ($line in $DiffLines) {
            if ([string]::IsNullOrWhiteSpace($line)) {
                continue
            }

            $Parts = $line -split "`t"

            if ($Parts.Count -lt 2) {
                continue
            }

            $StatusRaw = $Parts[0]
            $StatusKind = $StatusRaw.Substring(0, 1)

            $OldPath = $null
            $NewPath = $null

            if (
                $StatusKind -eq "R" -or
                $StatusKind -eq "C"
            ) {
                if ($Parts.Count -ge 3) {
                    $OldPath = $Parts[1]
                    $NewPath = $Parts[2]
                }
            }
            else {
                $NewPath = $Parts[1]

                if ($StatusKind -eq "D") {
                    $OldPath = $Parts[1]
                }
            }

            switch ($StatusKind) {
                "A" { $Added++ }
                "M" { $Modified++ }
                "D" { $Deleted++ }
                "R" { $Renamed++ }
                "C" { $Copied++ }
                "T" { $TypeChanged++ }
                default { $OtherChanges++ }
            }

            $PathForExtension = $NewPath

            if (-not $PathForExtension) {
                $PathForExtension = $OldPath
            }

            $Ext = Get-ExtFromPath $PathForExtension

            if (-not $PerExt.ContainsKey($Ext)) {
                $PerExt[$Ext] = @{
                    Added      = 0
                    Modified   = 0
                    Deleted    = 0
                    Renamed    = 0
                    Copied     = 0
                    TypeChange = 0
                    Other      = 0
                }
            }

            switch ($StatusKind) {
                "A" { $PerExt[$Ext].Added++ }
                "M" { $PerExt[$Ext].Modified++ }
                "D" { $PerExt[$Ext].Deleted++ }
                "R" { $PerExt[$Ext].Renamed++ }
                "C" { $PerExt[$Ext].Copied++ }
                "T" { $PerExt[$Ext].TypeChange++ }
                default { $PerExt[$Ext].Other++ }
            }

            [void]$FileChanges.Add([pscustomobject]@{
                Repo         = $t.Repo
                Abbreviation = $t.Abbr
                WorkshopId   = $t.WorkshopId
                Ordinal      = $Ordinal
                CommitSha    = $Sha
                Subject      = $Subject
                Status       = $StatusRaw
                OldPath      = $OldPath
                NewPath      = $NewPath
                Extension    = $Ext
            })
        }

        foreach ($Ext in ($PerExt.Keys | Sort-Object)) {
            $x = $PerExt[$Ext]

            [void]$ChangeExtensions.Add([pscustomobject]@{
                Repo         = $t.Repo
                Abbreviation = $t.Abbr
                WorkshopId   = $t.WorkshopId
                Ordinal      = $Ordinal
                CommitSha    = $Sha
                Subject      = $Subject
                Extension    = $Ext
                Added        = $x.Added
                Modified     = $x.Modified
                Deleted      = $x.Deleted
                Renamed      = $x.Renamed
                Copied       = $x.Copied
                TypeChanged  = $x.TypeChange
                Other        = $x.Other
            })
        }

        #
        # Complete tracked extension inventory for this snapshot
        #
        foreach ($g in (
            $BlobEntries |
            Group-Object {
                Get-ExtFromPath $_.Path
            }
        )) {
            $Items = @($g.Group)

            $ExtBytes = (
                $Items |
                Measure-Object Size -Sum
            ).Sum

            if ($null -eq $ExtBytes) {
                $ExtBytes = 0
            }

            [void]$ExtensionInventory.Add([pscustomobject]@{
                Repo         = $t.Repo
                Abbreviation = $t.Abbr
                WorkshopId   = $t.WorkshopId
                Ordinal      = $Ordinal
                CommitSha    = $Sha
                Subject      = $Subject
                Extension    = $g.Name
                FileCount    = $Items.Count
                TotalBytes   = $ExtBytes
                TotalMiB     = [Math]::Round(
                    $ExtBytes / 1MB,
                    6
                )
            })
        }

        $SameTreeAsPrevious = $false

        if (
            $PreviousTreeSha -and
            ($PreviousTreeSha -eq $TreeSha)
        ) {
            $SameTreeAsPrevious = $true
        }

        $SameVersionAsPrevious = $false

        if (
            $null -ne $PreviousDescriptorVersion -and
            $null -ne $DescriptorVersion -and
            $PreviousDescriptorVersion -eq $DescriptorVersion
        ) {
            $SameVersionAsPrevious = $true
        }

        [void]$CommitSnapshots.Add([pscustomobject]@{
            Repo                         = $t.Repo
            Abbreviation                 = $t.Abbr
            WorkshopId                   = $t.WorkshopId
            Ordinal                      = $Ordinal

            CommitSha                    = $Sha
            ParentSha                    = $ParentSha
            ParentCount                  = $ParentCount

            Subject                      = $Subject
            Message                      = $Message
            AuthorDate                   = $AuthorDate
            CommitterDate                = $CommitterDate

            TreeSha                      = $TreeSha
            TreeFingerprint              = $TreeFingerprint
            SameTreeAsPrevious           = $SameTreeAsPrevious

            TrackedFileCount              = $BlobEntries.Count
            TrackedBytes                  = $TrackedBytes
            TrackedMiB                    = [Math]::Round(
                $TrackedBytes / 1MB,
                6
            )

            DescriptorName                = $DescriptorName
            DescriptorVersion             = $DescriptorVersion
            DescriptorSupportedVersion    = $DescriptorSupported
            DescriptorWorkshopId          = $DescriptorWorkshopId
            SameVersionAsPrevious         = $SameVersionAsPrevious

            GitIgnoreFileCount            = $GitIgnoreEntries.Count
            RootGitIgnoreBlobSha          = $RootGitIgnoreBlobSha

            Added                         = $Added
            Modified                      = $Modified
            Deleted                       = $Deleted
            Renamed                       = $Renamed
            Copied                        = $Copied
            TypeChanged                   = $TypeChanged
            OtherChanges                  = $OtherChanges
            TotalChangedPaths             = $DiffLines.Count
        })

        $PreviousTreeSha = $TreeSha
        $PreviousDescriptorVersion = $DescriptorVersion
    }

    Write-Host ""
}

#
# Find identical snapshot trees within each repository
#
$Groups = @(
    $CommitSnapshots |
    Group-Object {
        "$($_.Repo)|$($_.TreeFingerprint)"
    } |
    Where-Object {
        $_.Count -gt 1
    }
)

foreach ($g in $Groups) {
    $Items = @(
        $g.Group |
        Sort-Object Ordinal
    )

    [void]$DuplicateTrees.Add([pscustomobject]@{
        Repo            = $Items[0].Repo
        Abbreviation    = $Items[0].Abbreviation
        WorkshopId      = $Items[0].WorkshopId
        TreeFingerprint = $Items[0].TreeFingerprint
        Count           = $Items.Count
        Ordinals        = (
            $Items.Ordinal -join " | "
        )
        CommitShas      = (
            $Items.CommitSha -join " | "
        )
        Subjects        = (
            $Items.Subject -join " | "
        )
    })
}

$CommitSnapshots |
    Export-Csv `
        (Join-Path $OutDir "commit-snapshots.csv") `
        -NoTypeInformation `
        -Encoding utf8

$FileChanges |
    Export-Csv `
        (Join-Path $OutDir "commit-file-changes.csv") `
        -NoTypeInformation `
        -Encoding utf8

$ChangeExtensions |
    Export-Csv `
        (Join-Path $OutDir "commit-changed-extensions.csv") `
        -NoTypeInformation `
        -Encoding utf8

$ExtensionInventory |
    Export-Csv `
        (Join-Path $OutDir "commit-extension-inventory.csv") `
        -NoTypeInformation `
        -Encoding utf8

$DuplicateTrees |
    Export-Csv `
        (Join-Path $OutDir "duplicate-trees.csv") `
        -NoTypeInformation `
        -Encoding utf8

$Warnings |
    Set-Content `
        (Join-Path $OutDir "warnings.txt") `
        -Encoding utf8

@"
CK3 Workshop History - Historical Commit Analysis
Generated: $(Get-Date -Format o)

Read-only analysis.

commit-snapshots.csv
Metadata and deterministic tree fingerprint for every historical commit.

commit-file-changes.csv
Every path changed by every commit.

commit-changed-extensions.csv
Added/modified/deleted/etc. counts grouped by extension and commit.

commit-extension-inventory.csv
Full tracked-file extension inventory for every historical snapshot.

duplicate-trees.csv
Commits that represent an identical Git tree.

warnings.txt
Missing descriptors / Workshop ID mismatches / repository issues.
"@ |
    Set-Content `
        (Join-Path $OutDir "README.txt") `
        -Encoding utf8

if (Test-Path $ZipPath) {
    Remove-Item -LiteralPath $ZipPath -Force
}

Compress-Archive `
    -Path (Join-Path $OutDir "*") `
    -DestinationPath $ZipPath `
    -CompressionLevel Optimal

$MissingDescriptors = @(
    $CommitSnapshots |
    Where-Object {
        [string]::IsNullOrWhiteSpace(
            $_.DescriptorWorkshopId
        )
    }
).Count

$SameTreeCommits = @(
    $CommitSnapshots |
    Where-Object {
        $_.SameTreeAsPrevious -eq $true
    }
).Count

Write-Host "`n=============================================="
Write-Host "HISTORICAL COMMIT ANALYSIS COMPLETE"
Write-Host "=============================================="

Write-Host "Commits analysed:"
Write-Host "  $($CommitSnapshots.Count)"

Write-Host "Identical-to-previous tree commits:"
Write-Host "  $SameTreeCommits"

Write-Host "Duplicate tree groups:"
Write-Host "  $($DuplicateTrees.Count)"

Write-Host "Commits without remote_file_id in descriptor:"
Write-Host "  $MissingDescriptors"

Write-Host "Warnings:"
Write-Host "  $($Warnings.Count)"

Write-Host "`nZIP:"
Write-Host "  $ZipPath"
