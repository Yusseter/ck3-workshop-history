Set-StrictMode -Version Latest
$ErrorActionPreference = "Stop"

$RepoRoot = (Resolve-Path (Join-Path $PSScriptRoot "..\..")).Path

$AnalysisScript = Join-Path `
    $PSScriptRoot `
    "09-first-pass-archive-verification.ps1"

$QueueSummaryPath = Join-Path `
    $RepoRoot `
    "analysis\results\09-first-pass-archive-verification\queue-summary.csv"

$ExpectedRevisionCount = 52
$BatchNumber = 0

if (-not (Test-Path -LiteralPath $AnalysisScript)) {
    throw "Analysis 09 script not found: $AnalysisScript"
}

function Get-QueueState {
    if (-not (Test-Path -LiteralPath $QueueSummaryPath)) {
        return [pscustomobject]@{
            Total = $ExpectedRevisionCount
            Complete = 0
            Error = 0
            Pending = $ExpectedRevisionCount
        }
    }

    $rows = @(
        Import-Csv -LiteralPath $QueueSummaryPath
    )

    if ($rows.Count -ne $ExpectedRevisionCount) {
        throw (
            "Expected $ExpectedRevisionCount queue rows, " +
            "but found $($rows.Count)."
        )
    }

    $complete = @(
        $rows |
            Where-Object {
                $_.State -eq "COMPLETE"
            }
    ).Count

    $errors = @(
        $rows |
            Where-Object {
                $_.State -eq "ERROR"
            }
    ).Count

    return [pscustomobject]@{
        Total = $rows.Count
        Complete = $complete
        Error = $errors
        Pending = (
            $rows.Count -
            $complete -
            $errors
        )
    }
}

$initialState = Get-QueueState

Write-Host ""
Write-Host "============================================================"
Write-Host "ANALYSIS 09 - RUN TO COMPLETION"
Write-Host "============================================================"
Write-Host ""
Write-Host "Complete: $($initialState.Complete) / $($initialState.Total)"
Write-Host "Errors:   $($initialState.Error)"
Write-Host "Pending:  $($initialState.Pending)"
Write-Host ""

while ($true) {
    $before = Get-QueueState

    if (
        $before.Complete -eq $ExpectedRevisionCount -and
        $before.Error -eq 0
    ) {
        Write-Host ""
        Write-Host "============================================================"
        Write-Host "ANALYSIS 09 QUEUE COMPLETE"
        Write-Host "============================================================"
        Write-Host ""
        Write-Host "Completed revisions: $($before.Complete)"
        Write-Host "Errors: $($before.Error)"
        break
    }

    $BatchNumber++

    Write-Host ""
    Write-Host "############################################################"
    Write-Host "Starting automatic batch $BatchNumber"
    Write-Host "Complete before batch: $($before.Complete)"
    Write-Host "Errors before batch:   $($before.Error)"
    Write-Host "Pending before batch:  $($before.Pending)"
    Write-Host "############################################################"
    Write-Host ""

    & $AnalysisScript

    if ($LASTEXITCODE -ne 0) {
        throw (
            "Analysis 09 exited with code $LASTEXITCODE " +
            "during automatic batch $BatchNumber."
        )
    }

    $after = Get-QueueState

    Write-Host ""
    Write-Host "Automatic batch $BatchNumber finished."
    Write-Host "Complete: $($after.Complete) / $($after.Total)"
    Write-Host "Errors:   $($after.Error)"
    Write-Host "Pending:  $($after.Pending)"
    Write-Host ""

    if (
        $after.Complete -eq $ExpectedRevisionCount -and
        $after.Error -eq 0
    ) {
        continue
    }

    if (
        $after.Complete -le $before.Complete -and
        $after.Error -ge $before.Error
    ) {
        throw (
            "Analysis 09 made no successful progress during " +
            "automatic batch $BatchNumber. " +
            "Stopping to avoid an infinite retry loop."
        )
    }

    Start-Sleep -Seconds 10
}

Write-Host ""
Write-Host "Results:"
Write-Host (
    "  " +
    (Join-Path `
        $RepoRoot `
        "analysis\results\09-first-pass-archive-verification")
)

Write-Host ""
Write-Host "Package:"
Write-Host (
    "  " +
    (Join-Path `
        $RepoRoot `
        "analysis\packages\09-first-pass-archive-verification.zip")
)
