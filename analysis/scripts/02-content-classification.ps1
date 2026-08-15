$ErrorActionPreference = "Stop"

$Root = "F:\Storage\Codding\projects\ck3"
$OutDir = Join-Path $Root "_workshop_history_analysis_2"
$ZipPath = Join-Path $Root "ck3-workshop-history-analysis-2.zip"

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

function Get-SteamLibraries {
    $libs = @()

    try {
        $p = (Get-ItemProperty "HKCU:\Software\Valve\Steam").SteamPath
        if ($p) { $libs += ($p -replace "/", "\") }
    }
    catch {}

    foreach ($p in @(
        "C:\Program Files (x86)\Steam",
        "C:\Program Files\Steam"
    )) {
        if ((Test-Path $p) -and ($p -notin $libs)) {
            $libs += $p
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

    @($libs | Select-Object -Unique)
}

function Find-WorkshopFolder([string[]]$Libraries, [string]$Id) {
    foreach ($lib in $Libraries) {
        $p = Join-Path $lib "steamapps\workshop\content\1158310\$Id"
        if (Test-Path $p) { return $p }
    }

    return $null
}

function Get-ContentFiles([string]$Base) {
    @(
        Get-ChildItem -LiteralPath $Base -File -Recurse -Force -ErrorAction SilentlyContinue |
        Where-Object {
            $_.FullName -notmatch '[\\/]\.git([\\/]|$)' -and
            $_.FullName -notmatch '[\\/]\.svn([\\/]|$)' -and
            $_.FullName -notmatch '[\\/]\.hg([\\/]|$)'
        }
    )
}

function Get-Relative([string]$Base, [string]$Path) {
    ([IO.Path]::GetRelativePath($Base, $Path) -replace "\\", "/")
}

function Get-ExtensionName([string]$Name) {
    $e = [IO.Path]::GetExtension($Name)

    if ([string]::IsNullOrWhiteSpace($e)) {
        return "<no-extension>"
    }

    return $e.ToLowerInvariant()
}

function Test-BinaryFile([string]$Path) {
    try {
        $fs = [IO.File]::Open(
            $Path,
            [IO.FileMode]::Open,
            [IO.FileAccess]::Read,
            [IO.FileShare]::ReadWrite
        )

        try {
            $len = [Math]::Min(16384, [int64]$fs.Length)

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

function Get-SHA256([string]$Path) {
    try {
        return (Get-FileHash -LiteralPath $Path -Algorithm SHA256).Hash
    }
    catch {
        return $null
    }
}

if (Test-Path $OutDir) {
    Remove-Item $OutDir -Recurse -Force
}

New-Item -ItemType Directory -Path $OutDir | Out-Null

$SteamLibraries = @(Get-SteamLibraries)

$ContentSummary = [System.Collections.ArrayList]::new()
$ExtensionStats = [System.Collections.ArrayList]::new()
$LargeFiles = [System.Collections.ArrayList]::new()
$Comparison = [System.Collections.ArrayList]::new()
$ComparisonSummary = [System.Collections.ArrayList]::new()
$GitIgnoreFiles = [System.Collections.ArrayList]::new()
$IgnoreProvenance = [System.Collections.ArrayList]::new()
$Warnings = [System.Collections.ArrayList]::new()

foreach ($t in $Targets) {
    Write-Host "`n========================================"
    Write-Host "$($t.Repo) [$($t.WorkshopId)]"
    Write-Host "========================================"

    $Local = Join-Path $Root $t.Folder
    $Steam = Find-WorkshopFolder $SteamLibraries $t.WorkshopId

    if (-not (Test-Path $Local)) {
        [void]$Warnings.Add("Local folder missing: $Local")
        continue
    }

    if (-not $Steam) {
        [void]$Warnings.Add("Steam Workshop folder missing: $($t.WorkshopId)")
        continue
    }

    $LocalFiles = @(Get-ContentFiles $Local)
    $SteamFiles = @(Get-ContentFiles $Steam)

    $LocalBytes = ($LocalFiles | Measure-Object Length -Sum).Sum
    $SteamBytes = ($SteamFiles | Measure-Object Length -Sum).Sum

    if ($null -eq $LocalBytes) { $LocalBytes = 0 }
    if ($null -eq $SteamBytes) { $SteamBytes = 0 }

    [void]$ContentSummary.Add([pscustomobject]@{
        Repo             = $t.Repo
        Abbreviation     = $t.Abbr
        WorkshopId       = $t.WorkshopId
        LocalFileCount   = $LocalFiles.Count
        LocalMiB         = [Math]::Round($LocalBytes / 1MB, 3)
        SteamFileCount   = $SteamFiles.Count
        SteamMiB         = [Math]::Round($SteamBytes / 1MB, 3)
        SizeDifferenceMiB = [Math]::Round(($SteamBytes - $LocalBytes) / 1MB, 3)
    })

    Write-Host "Local excluding .git : $($LocalFiles.Count) files / $([Math]::Round($LocalBytes / 1MB, 2)) MiB"
    Write-Host "Steam excluding .git : $($SteamFiles.Count) files / $([Math]::Round($SteamBytes / 1MB, 2)) MiB"

    #
    # Exact text/binary statistics on CURRENT Steam content
    #
    $Classified = foreach ($f in $SteamFiles) {
        $binary = Test-BinaryFile $f.FullName

        [pscustomobject]@{
            File      = $f
            Extension = Get-ExtensionName $f.Name
            Binary    = $binary
        }
    }

    foreach ($g in ($Classified | Group-Object Extension)) {
        $items = @($g.Group)

        $textCount = @($items | Where-Object { $_.Binary -eq $false }).Count
        $binaryCount = @($items | Where-Object { $_.Binary -eq $true }).Count
        $unknownCount = @($items | Where-Object { $null -eq $_.Binary }).Count

        $sizes = @($items | ForEach-Object { $_.File.Length })
        $total = ($sizes | Measure-Object -Sum).Sum
        $max = ($sizes | Measure-Object -Maximum).Maximum

        $classification =
            if (($binaryCount -gt 0) -and ($textCount -eq 0)) { "Binary" }
            elseif (($textCount -gt 0) -and ($binaryCount -eq 0)) { "Text" }
            elseif (($binaryCount -gt 0) -and ($textCount -gt 0)) { "Mixed" }
            else { "Unknown" }

        [void]$ExtensionStats.Add([pscustomobject]@{
            Repo           = $t.Repo
            Abbreviation   = $t.Abbr
            WorkshopId     = $t.WorkshopId
            Extension      = $g.Name
            FileCount      = $items.Count
            TextCount      = $textCount
            BinaryCount    = $binaryCount
            UnknownCount   = $unknownCount
            Classification = $classification
            TotalMiB       = [Math]::Round($total / 1MB, 3)
            MaxFileMiB     = [Math]::Round($max / 1MB, 3)
        })
    }

    foreach ($x in ($Classified | Where-Object { $_.File.Length -ge 10MB })) {
        [void]$LargeFiles.Add([pscustomobject]@{
            Repo           = $t.Repo
            Abbreviation   = $t.Abbr
            WorkshopId     = $t.WorkshopId
            RelativePath   = Get-Relative $Steam $x.File.FullName
            Extension      = $x.Extension
            Classification = if ($x.Binary -eq $true) { "Binary" } elseif ($x.Binary -eq $false) { "Text" } else { "Unknown" }
            SizeMiB        = [Math]::Round($x.File.Length / 1MB, 3)
            Over100MiB     = ($x.File.Length -ge 100MB)
        })
    }

    #
    # Find every .gitignore in local snapshot, excluding repository .git
    #
    foreach ($gi in (
        Get-ChildItem -LiteralPath $Local -Filter ".gitignore" -File -Recurse -Force -ErrorAction SilentlyContinue |
        Where-Object { $_.FullName -notmatch '[\\/]\.git([\\/]|$)' }
    )) {
        $lineNumber = 0

        foreach ($line in Get-Content -LiteralPath $gi.FullName -ErrorAction SilentlyContinue) {
            $lineNumber++

            [void]$GitIgnoreFiles.Add([pscustomobject]@{
                Repo         = $t.Repo
                Abbreviation = $t.Abbr
                WorkshopId   = $t.WorkshopId
                GitIgnorePath = Get-Relative $Local $gi.FullName
                Line         = $lineNumber
                Rule         = $line
            })
        }
    }

    #
    # Ask Git exactly WHY files are ignored.
    #
    $AllLocalRelative = @(
        $LocalFiles | ForEach-Object {
            Get-Relative $Local $_.FullName
        }
    )

    if ($AllLocalRelative.Count -gt 0) {
        $IgnoreOutput = @(
            $AllLocalRelative |
            & git -C $Local check-ignore -v --no-index --stdin 2>$null
        )

        foreach ($line in $IgnoreOutput) {
            if ($line -match '^(.*?)\t(.*)$') {
                $ruleInfo = $Matches[1]
                $filePath = $Matches[2]

                [void]$IgnoreProvenance.Add([pscustomobject]@{
                    Repo         = $t.Repo
                    Abbreviation = $t.Abbr
                    WorkshopId   = $t.WorkshopId
                    RuleInfo     = $ruleInfo
                    RelativePath = $filePath
                })
            }
        }
    }

    #
    # Exact comparison: local archive working tree vs current Steam content.
    #
    $LocalMap = [System.Collections.Generic.Dictionary[string,System.IO.FileInfo]]::new(
        [System.StringComparer]::OrdinalIgnoreCase
    )

    $SteamMap = [System.Collections.Generic.Dictionary[string,System.IO.FileInfo]]::new(
        [System.StringComparer]::OrdinalIgnoreCase
    )

    foreach ($f in $LocalFiles) {
        $LocalMap[(Get-Relative $Local $f.FullName)] = $f
    }

    foreach ($f in $SteamFiles) {
        $SteamMap[(Get-Relative $Steam $f.FullName)] = $f
    }

    $AllPaths = @(
        @($LocalMap.Keys) + @($SteamMap.Keys) |
        Sort-Object -Unique
    )

    $Identical = 0
    $OnlyLocal = 0
    $OnlySteam = 0
    $SizeChanged = 0
    $ContentChanged = 0
    $HashErrors = 0

    foreach ($rel in $AllPaths) {
        $hasLocal = $LocalMap.ContainsKey($rel)
        $hasSteam = $SteamMap.ContainsKey($rel)

        if ($hasLocal -and -not $hasSteam) {
            $OnlyLocal++

            [void]$Comparison.Add([pscustomobject]@{
                Repo         = $t.Repo
                Abbreviation = $t.Abbr
                WorkshopId   = $t.WorkshopId
                RelativePath = $rel
                Status       = "OnlyLocal"
                LocalMiB     = [Math]::Round($LocalMap[$rel].Length / 1MB, 6)
                SteamMiB     = $null
            })

            continue
        }

        if ($hasSteam -and -not $hasLocal) {
            $OnlySteam++

            [void]$Comparison.Add([pscustomobject]@{
                Repo         = $t.Repo
                Abbreviation = $t.Abbr
                WorkshopId   = $t.WorkshopId
                RelativePath = $rel
                Status       = "OnlySteam"
                LocalMiB     = $null
                SteamMiB     = [Math]::Round($SteamMap[$rel].Length / 1MB, 6)
            })

            continue
        }

        $lf = $LocalMap[$rel]
        $sf = $SteamMap[$rel]

        if ($lf.Length -ne $sf.Length) {
            $SizeChanged++

            [void]$Comparison.Add([pscustomobject]@{
                Repo         = $t.Repo
                Abbreviation = $t.Abbr
                WorkshopId   = $t.WorkshopId
                RelativePath = $rel
                Status       = "SizeChanged"
                LocalMiB     = [Math]::Round($lf.Length / 1MB, 6)
                SteamMiB     = [Math]::Round($sf.Length / 1MB, 6)
            })

            continue
        }

        $lh = Get-SHA256 $lf.FullName
        $sh = Get-SHA256 $sf.FullName

        if (($null -eq $lh) -or ($null -eq $sh)) {
            $HashErrors++

            [void]$Comparison.Add([pscustomobject]@{
                Repo         = $t.Repo
                Abbreviation = $t.Abbr
                WorkshopId   = $t.WorkshopId
                RelativePath = $rel
                Status       = "HashError"
                LocalMiB     = [Math]::Round($lf.Length / 1MB, 6)
                SteamMiB     = [Math]::Round($sf.Length / 1MB, 6)
            })
        }
        elseif ($lh -eq $sh) {
            $Identical++
        }
        else {
            $ContentChanged++

            [void]$Comparison.Add([pscustomobject]@{
                Repo         = $t.Repo
                Abbreviation = $t.Abbr
                WorkshopId   = $t.WorkshopId
                RelativePath = $rel
                Status       = "ContentChanged"
                LocalMiB     = [Math]::Round($lf.Length / 1MB, 6)
                SteamMiB     = [Math]::Round($sf.Length / 1MB, 6)
            })
        }
    }

    [void]$ComparisonSummary.Add([pscustomobject]@{
        Repo           = $t.Repo
        Abbreviation   = $t.Abbr
        WorkshopId     = $t.WorkshopId
        Identical      = $Identical
        OnlyLocal      = $OnlyLocal
        OnlySteam      = $OnlySteam
        SizeChanged    = $SizeChanged
        ContentChanged = $ContentChanged
        HashErrors     = $HashErrors
    })

    Write-Host "Comparison:"
    Write-Host "  Identical      : $Identical"
    Write-Host "  Only local     : $OnlyLocal"
    Write-Host "  Only Steam     : $OnlySteam"
    Write-Host "  Size changed   : $SizeChanged"
    Write-Host "  Content changed: $ContentChanged"
}

$ContentSummary |
    Export-Csv (Join-Path $OutDir "current-content-summary.csv") -NoTypeInformation -Encoding utf8

$ExtensionStats |
    Export-Csv (Join-Path $OutDir "exact-extension-classification.csv") -NoTypeInformation -Encoding utf8

$LargeFiles |
    Export-Csv (Join-Path $OutDir "real-large-files.csv") -NoTypeInformation -Encoding utf8

$ComparisonSummary |
    Export-Csv (Join-Path $OutDir "current-comparison-summary.csv") -NoTypeInformation -Encoding utf8

$Comparison |
    Export-Csv (Join-Path $OutDir "current-comparison-differences.csv") -NoTypeInformation -Encoding utf8

$GitIgnoreFiles |
    Export-Csv (Join-Path $OutDir "all-gitignore-rules.csv") -NoTypeInformation -Encoding utf8

$IgnoreProvenance |
    Export-Csv (Join-Path $OutDir "ignore-provenance.csv") -NoTypeInformation -Encoding utf8

$Warnings |
    Set-Content (Join-Path $OutDir "warnings.txt") -Encoding utf8

if (Test-Path $ZipPath) {
    Remove-Item $ZipPath -Force
}

Compress-Archive `
    -Path (Join-Path $OutDir "*") `
    -DestinationPath $ZipPath `
    -CompressionLevel Optimal

Write-Host "`n=============================================="
Write-Host "SECOND ANALYSIS COMPLETE"
Write-Host "=============================================="
Write-Host "ZIP:"
Write-Host "  $ZipPath"

Write-Host "`nTRUE CONTENT SIZES (.git excluded):"
$ContentSummary |
    Format-Table Repo,LocalMiB,SteamMiB,SizeDifferenceMiB -AutoSize

Write-Host "`nCURRENT SNAPSHOT COMPARISON:"
$ComparisonSummary |
    Format-Table Repo,Identical,OnlyLocal,OnlySteam,SizeChanged,ContentChanged,HashErrors -AutoSize
