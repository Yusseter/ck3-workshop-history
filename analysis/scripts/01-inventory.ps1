$ErrorActionPreference = "Stop"

$Root = "F:\Storage\Codding\projects\ck3"
$OutDir = Join-Path $Root "_workshop_history_analysis"
$ZipPath = Join-Path $Root "ck3-workshop-history-analysis.zip"

$Targets = @(
    @{ Folder="Yusseter Community-Flavor-Pack";             Repo="Community-Flavor-Pack";              Abbr="CFP";         WorkshopId="2220098919" },
    @{ Folder="Yusseter Culture-and-Faith-Granularity";     Repo="Culture-and-Faith-Granularity";      Abbr="CFG";         WorkshopId="3206891770" },
    @{ Folder="Yusseter Culture-Expanded";                  Repo="Culture-Expanded";                   Abbr="CE";          WorkshopId="2829397295" },
    @{ Folder="Yusseter Demand-Tribute";                    Repo="Demand-Tribute";                     Abbr="DT";          WorkshopId="3473488611" },
    @{ Folder="Yusseter EPE-CFP";                           Repo="EPE-CFP";                            Abbr="EPE-CFP";     WorkshopId="2996881191" },
    @{ Folder="Yusseter Ethnicities-and-Portraits-Expanded";Repo="Ethnicities-and-Portraits-Expanded"; Abbr="EPE";         WorkshopId="2507209632" },
    @{ Folder="Yusseter MBP-EPE-CFP";                       Repo="MBP-EPE-CFP";                        Abbr="MBP-EPE-CFP"; WorkshopId="2543865921" },
    @{ Folder="Yusseter MedievalImmersion";                 Repo="MedievalImmersion";                  Abbr="MI";          WorkshopId="3268020725" },
    @{ Folder="Yusseter MPE";                               Repo="MPE";                                Abbr="MPE";         WorkshopId="3726274827" },
    @{ Folder="Yusseter RICE";                              Repo="RICE";                               Abbr="RICE";        WorkshopId="2273832430" },
    @{ Folder="Yusseter Special-World";                     Repo="Special-World";                      Abbr="SW";          WorkshopId="2875587269" },
    @{ Folder="Yusseter Turkic-World-Expanded";             Repo="Turkic-World-Expanded";              Abbr="TWE";         WorkshopId="3668769244" },
    @{ Folder="Yusseter Western-Steppe-Expanded";           Repo="Western-Steppe-Expanded";           Abbr="WSE";         WorkshopId="3490396842" }
)

function Get-Ext([string]$Name) {
    $ext = [IO.Path]::GetExtension($Name)
    if ([string]::IsNullOrWhiteSpace($ext)) {
        return "<no-extension>"
    }
    return $ext.ToLowerInvariant()
}

function Get-DescriptorValue([string]$Text, [string]$Key) {
    if ($Text -match "(?m)^\s*$([regex]::Escape($Key))\s*=\s*`"([^`"]*)`"") {
        return $Matches[1]
    }
    return $null
}

function Test-BinarySample([string]$Path) {
    try {
        $fs = [IO.File]::Open(
            $Path,
            [IO.FileMode]::Open,
            [IO.FileAccess]::Read,
            [IO.FileShare]::ReadWrite
        )

        try {
            $len = [Math]::Min(8192, [int64]$fs.Length)

            if ($len -eq 0) {
                return $false
            }

            $buf = New-Object byte[] $len
            [void]$fs.Read($buf, 0, $len)

            $nul = 0
            $ctrl = 0

            foreach ($b in $buf) {
                if ($b -eq 0) {
                    $nul++
                }
                elseif (($b -lt 9) -or (($b -gt 13) -and ($b -lt 32))) {
                    $ctrl++
                }
            }

            if ($nul -gt 0) {
                return $true
            }

            return (($ctrl / [double]$len) -gt 0.05)
        }
        finally {
            $fs.Dispose()
        }
    }
    catch {
        return $null
    }
}

function Get-SteamLibraries {
    $libs = @()

    try {
        $steamPath = (Get-ItemProperty "HKCU:\Software\Valve\Steam").SteamPath

        if ($steamPath) {
            $libs += ($steamPath -replace "/", "\")
        }
    }
    catch {}

    foreach ($candidate in @(
        "C:\Program Files (x86)\Steam",
        "C:\Program Files\Steam"
    )) {
        if ((Test-Path $candidate) -and ($candidate -notin $libs)) {
            $libs += $candidate
        }
    }

    foreach ($base in @($libs)) {
        $vdf = Join-Path $base "steamapps\libraryfolders.vdf"

        if (Test-Path $vdf) {
            foreach ($line in Get-Content $vdf -ErrorAction SilentlyContinue) {
                if ($line -match '"path"\s+"([^"]+)"') {
                    $p = $Matches[1] -replace "\\\\", "\"

                    if ((Test-Path $p) -and ($p -notin $libs)) {
                        $libs += $p
                    }
                }
            }
        }
    }

    return @($libs | Select-Object -Unique)
}

function Find-WorkshopFolder(
    [string[]]$Libraries,
    [string]$WorkshopId
) {
    foreach ($lib in $Libraries) {
        $p = Join-Path $lib "steamapps\workshop\content\1158310\$WorkshopId"

        if (Test-Path $p) {
            return $p
        }
    }

    return $null
}

function Add-ExtensionStats {
    param(
        [System.Collections.ArrayList]$Destination,
        [string]$Source,
        [string]$Repo,
        [string]$Abbr,
        [string]$WorkshopId,
        [array]$Files
    )

    if (-not $Files -or $Files.Count -eq 0) {
        return
    }

    foreach ($g in ($Files | Group-Object { Get-Ext $_.Name })) {
        $items = @($g.Group)

        $sample = @(
            $items |
            Sort-Object Length -Descending |
            Select-Object -First 12
        )

        $binary = 0
        $text = 0
        $unknown = 0

        foreach ($f in $sample) {
            $r = Test-BinarySample $f.FullName

            if ($null -eq $r) {
                $unknown++
            }
            elseif ($r) {
                $binary++
            }
            else {
                $text++
            }
        }

        if (($binary -gt 0) -and ($text -eq 0)) {
            $class = "Binary"
        }
        elseif (($text -gt 0) -and ($binary -eq 0)) {
            $class = "Text"
        }
        elseif (($text -gt 0) -and ($binary -gt 0)) {
            $class = "Mixed"
        }
        else {
            $class = "Unknown"
        }

        $total = ($items | Measure-Object Length -Sum).Sum
        $max = ($items | Measure-Object Length -Maximum).Maximum

        [void]$Destination.Add([pscustomobject]@{
            Source         = $Source
            Repo           = $Repo
            Abbreviation   = $Abbr
            WorkshopId     = $WorkshopId
            Extension      = $g.Name
            FileCount      = $items.Count
            TotalMiB       = [Math]::Round($total / 1MB, 3)
            MaxFileMiB     = [Math]::Round($max / 1MB, 3)
            SampleText     = $text
            SampleBinary   = $binary
            SampleUnknown  = $unknown
            Classification = $class
        })
    }
}

if (-not (Test-Path $Root)) {
    throw "Root path not found: $Root"
}

if (Test-Path $OutDir) {
    Remove-Item $OutDir -Recurse -Force
}

New-Item -ItemType Directory -Path $OutDir | Out-Null

$SteamLibraries = @(Get-SteamLibraries)

Write-Host "`nSteam libraries:"
$SteamLibraries | ForEach-Object {
    Write-Host "  $_"
}

$RepoSummary      = New-Object System.Collections.ArrayList
$CommitHistory    = New-Object System.Collections.ArrayList
$ExtensionSummary = New-Object System.Collections.ArrayList
$LargeFiles       = New-Object System.Collections.ArrayList
$IgnoreRules      = New-Object System.Collections.ArrayList
$IgnoredSummary   = New-Object System.Collections.ArrayList
$Warnings         = New-Object System.Collections.ArrayList

foreach ($t in $Targets) {

    $path = Join-Path $Root $t.Folder

    Write-Host "`n========================================"
    Write-Host $t.Repo
    Write-Host "========================================"

    if (-not (Test-Path $path)) {
        [void]$Warnings.Add("Missing local repo folder: $path")
        Write-Host "MISSING LOCAL FOLDER"
        continue
    }

    if (-not (Test-Path (Join-Path $path ".git"))) {
        [void]$Warnings.Add("Not a Git repo: $path")
        Write-Host "NOT A GIT REPOSITORY"
        continue
    }

    $descriptorPath = Join-Path $path "descriptor.mod"

    if (Test-Path $descriptorPath) {
        $descriptorText = Get-Content $descriptorPath -Raw -ErrorAction SilentlyContinue
    }
    else {
        $descriptorText = ""
    }

    $descId           = Get-DescriptorValue $descriptorText "remote_file_id"
    $modName          = Get-DescriptorValue $descriptorText "name"
    $modVersion       = Get-DescriptorValue $descriptorText "version"
    $supportedVersion = Get-DescriptorValue $descriptorText "supported_version"

    if ($descId -and ($descId -ne $t.WorkshopId)) {
        [void]$Warnings.Add(
            "Workshop ID mismatch for $($t.Repo): expected $($t.WorkshopId), descriptor has $descId"
        )
    }

    $origin = (& git -C $path remote get-url origin 2>$null) -join ""

    $status = @(
        & git -C $path status --porcelain=v1 -uall 2>$null
    )

    $commitLines = @(
        & git -C $path log --all --reverse `
            --date=iso-strict `
            --pretty=format:"%H`t%aI`t%cI`t%s" 2>$null
    )

    foreach ($line in $commitLines) {
        $parts = $line -split "`t", 4

        if ($parts.Count -eq 4) {
            [void]$CommitHistory.Add([pscustomobject]@{
                Repo          = $t.Repo
                Abbreviation  = $t.Abbr
                WorkshopId    = $t.WorkshopId
                SHA           = $parts[0]
                AuthorDate    = $parts[1]
                CommitterDate = $parts[2]
                Subject       = $parts[3]
            })
        }
    }

    $files = @(
        Get-ChildItem $path -File -Recurse -Force -ErrorAction SilentlyContinue |
        Where-Object {
            $_.FullName -notmatch '[\\/]\.git([\\/]|$)'
        }
    )

    $totalBytes = (
        $files |
        Measure-Object Length -Sum
    ).Sum

    if ($null -eq $totalBytes) {
        $totalBytes = 0
    }

    $trackedRel = @(
        & git -C $path ls-files 2>$null
    )

    $ignoredRel = @(
        & git -C $path ls-files `
            --others `
            --ignored `
            --exclude-standard 2>$null
    )

    $trackedBytes = 0L

    foreach ($rel in $trackedRel) {
        $fp = Join-Path $path $rel

        if (Test-Path $fp -PathType Leaf) {
            $trackedBytes += (Get-Item $fp).Length
        }
    }

    $ignoredFilesForStats = @()
    $ignoredBytes = 0L

    foreach ($rel in $ignoredRel) {
        $fp = Join-Path $path $rel

        if (Test-Path $fp -PathType Leaf) {
            $fi = Get-Item $fp
            $ignoredFilesForStats += $fi
            $ignoredBytes += $fi.Length
        }
    }

    if ($ignoredFilesForStats.Count -gt 0) {
        foreach ($g in (
            $ignoredFilesForStats |
            Group-Object { Get-Ext $_.Name }
        )) {
            $items = @($g.Group)

            $sum = (
                $items |
                Measure-Object Length -Sum
            ).Sum

            [void]$IgnoredSummary.Add([pscustomobject]@{
                Repo         = $t.Repo
                Abbreviation = $t.Abbr
                WorkshopId   = $t.WorkshopId
                Extension    = $g.Name
                FileCount    = $items.Count
                TotalMiB     = [Math]::Round($sum / 1MB, 3)
            })
        }
    }

    Add-ExtensionStats `
        -Destination $ExtensionSummary `
        -Source "LocalRepoWorkingTree" `
        -Repo $t.Repo `
        -Abbr $t.Abbr `
        -WorkshopId $t.WorkshopId `
        -Files $files

    foreach ($f in (
        $files |
        Where-Object Length -GE 10MB |
        Sort-Object Length -Descending
    )) {
        $rel = $f.FullName.Substring($path.Length).TrimStart("\","/")

        [void]$LargeFiles.Add([pscustomobject]@{
            Source       = "LocalRepoWorkingTree"
            Repo         = $t.Repo
            Abbreviation = $t.Abbr
            WorkshopId   = $t.WorkshopId
            RelativePath = $rel
            Extension    = Get-Ext $f.Name
            SizeMiB      = [Math]::Round($f.Length / 1MB, 3)
            Over100MiB   = ($f.Length -ge 100MB)
        })
    }

    $gitignore = Join-Path $path ".gitignore"

    if (Test-Path $gitignore) {
        $lineNumber = 0

        foreach ($rule in Get-Content $gitignore -ErrorAction SilentlyContinue) {
            $lineNumber++

            [void]$IgnoreRules.Add([pscustomobject]@{
                Repo         = $t.Repo
                Abbreviation = $t.Abbr
                WorkshopId   = $t.WorkshopId
                Line         = $lineNumber
                Rule         = $rule
            })
        }
    }

    $workshopFolder = Find-WorkshopFolder `
        -Libraries $SteamLibraries `
        -WorkshopId $t.WorkshopId

    $steamSize = $null
    $steamCount = $null

    if ($workshopFolder) {

        Write-Host "Steam Workshop:"
        Write-Host "  $workshopFolder"

        $steamFiles = @(
            Get-ChildItem $workshopFolder `
                -File `
                -Recurse `
                -Force `
                -ErrorAction SilentlyContinue
        )

        $steamCount = $steamFiles.Count

        $steamSize = (
            $steamFiles |
            Measure-Object Length -Sum
        ).Sum

        if ($null -eq $steamSize) {
            $steamSize = 0
        }

        Add-ExtensionStats `
            -Destination $ExtensionSummary `
            -Source "SteamWorkshopCurrent" `
            -Repo $t.Repo `
            -Abbr $t.Abbr `
            -WorkshopId $t.WorkshopId `
            -Files $steamFiles

        foreach ($f in (
            $steamFiles |
            Where-Object Length -GE 10MB |
            Sort-Object Length -Descending
        )) {
            $rel = $f.FullName.Substring($workshopFolder.Length).TrimStart("\","/")

            [void]$LargeFiles.Add([pscustomobject]@{
                Source       = "SteamWorkshopCurrent"
                Repo         = $t.Repo
                Abbreviation = $t.Abbr
                WorkshopId   = $t.WorkshopId
                RelativePath = $rel
                Extension    = Get-Ext $f.Name
                SizeMiB      = [Math]::Round($f.Length / 1MB, 3)
                Over100MiB   = ($f.Length -ge 100MB)
            })
        }
    }
    else {
        Write-Host "Steam Workshop folder: NOT FOUND"

        [void]$Warnings.Add(
            "Current Steam Workshop folder not found for $($t.Repo) [$($t.WorkshopId)]"
        )
    }

    [void]$RepoSummary.Add([pscustomobject]@{
        Repo                  = $t.Repo
        LocalFolder           = $t.Folder
        AbbreviationCandidate = $t.Abbr
        WorkshopIdExpected    = $t.WorkshopId
        WorkshopIdDescriptor  = $descId
        ModNameDescriptor     = $modName
        ModVersionDescriptor  = $modVersion
        SupportedVersion      = $supportedVersion
        Origin                = $origin
        CommitCount           = $commitLines.Count
        DirtyStatusEntries    = $status.Count
        LocalFiles            = $files.Count
        LocalWorkingTreeMiB   = [Math]::Round($totalBytes / 1MB, 3)
        TrackedFiles          = $trackedRel.Count
        TrackedCurrentMiB     = [Math]::Round($trackedBytes / 1MB, 3)
        IgnoredFilesPresent   = $ignoredRel.Count
        IgnoredCurrentMiB     = [Math]::Round($ignoredBytes / 1MB, 3)
        SteamFolder           = $workshopFolder
        SteamCurrentFiles     = $steamCount
        SteamCurrentMiB       = if ($null -ne $steamSize) {
            [Math]::Round($steamSize / 1MB, 3)
        }
        else {
            $null
        }
    })

    Write-Host "Commits: $($commitLines.Count)"
    Write-Host "Tracked current: $([Math]::Round($trackedBytes / 1MB, 2)) MiB"
    Write-Host "Ignored current: $([Math]::Round($ignoredBytes / 1MB, 2)) MiB"

    if ($null -ne $steamSize) {
        Write-Host "Steam current: $([Math]::Round($steamSize / 1MB, 2)) MiB"
    }
}

$RepoSummary |
    Export-Csv (Join-Path $OutDir "repo-summary.csv") `
        -NoTypeInformation `
        -Encoding utf8

$CommitHistory |
    Export-Csv (Join-Path $OutDir "commit-history.csv") `
        -NoTypeInformation `
        -Encoding utf8

$ExtensionSummary |
    Export-Csv (Join-Path $OutDir "extension-summary.csv") `
        -NoTypeInformation `
        -Encoding utf8

$LargeFiles |
    Export-Csv (Join-Path $OutDir "large-files.csv") `
        -NoTypeInformation `
        -Encoding utf8

$IgnoreRules |
    Export-Csv (Join-Path $OutDir "gitignore-rules.csv") `
        -NoTypeInformation `
        -Encoding utf8

$IgnoredSummary |
    Export-Csv (Join-Path $OutDir "ignored-summary.csv") `
        -NoTypeInformation `
        -Encoding utf8

$Warnings |
    Set-Content (Join-Path $OutDir "warnings.txt") `
        -Encoding utf8

@"
CK3 Workshop History Analysis
Generated: $(Get-Date -Format o)

No Git repository or Steam Workshop file was modified.

repo-summary.csv
commit-history.csv
extension-summary.csv
large-files.csv
gitignore-rules.csv
ignored-summary.csv
warnings.txt
"@ |
    Set-Content (Join-Path $OutDir "README.txt") `
        -Encoding utf8

if (Test-Path $ZipPath) {
    Remove-Item $ZipPath -Force
}

Compress-Archive `
    -Path (Join-Path $OutDir "*") `
    -DestinationPath $ZipPath `
    -CompressionLevel Optimal

Write-Host "`n=============================================="
Write-Host "ANALYSIS COMPLETE"
Write-Host "=============================================="
Write-Host "Folder:"
Write-Host "  $OutDir"
Write-Host "ZIP:"
Write-Host "  $ZipPath"

Write-Host "`nRepo summary:"
$RepoSummary |
    Format-Table `
        Repo,
        WorkshopIdExpected,
        CommitCount,
        TrackedCurrentMiB,
        IgnoredCurrentMiB,
        SteamCurrentMiB `
        -AutoSize

if ($Warnings.Count -gt 0) {
    Write-Host "`nWarnings:"
    $Warnings | ForEach-Object {
        Write-Host "  $_"
    }
}
