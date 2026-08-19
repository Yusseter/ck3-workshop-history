param(
    [ValidateRange(1, 25)]
    [int]$BatchSize = 8
)

Set-StrictMode -Version Latest
$ErrorActionPreference = "Stop"

$AnalysisName = "09-first-pass-archive-verification"
$ExpectedFirstPassCount = 52

$RepoRoot = (Resolve-Path (Join-Path $PSScriptRoot "..\..")).Path
$OldReposRoot = Split-Path -Parent $RepoRoot

$DownloadPlanPath = Join-Path $RepoRoot "analysis\results\07-archive-verification-plan\download-plan.csv"
$RepoSummaryPath = Join-Path $RepoRoot "analysis\results\01-inventory\repo-summary.csv"

$OutputDirectory = Join-Path $RepoRoot "analysis\results\$AnalysisName"
$RawPagesDirectory = Join-Path $OutputDirectory "raw-pages"

$CacheDirectory = Join-Path $RepoRoot "analysis\cache\$AnalysisName"
$ArchiveDirectory = Join-Path $CacheDirectory "archives"
$ExtractDirectory = Join-Path $CacheDirectory "extracted"
$BrowserPageCacheDirectory = Join-Path $CacheDirectory "browser-pages"
$RecordDirectory = Join-Path $CacheDirectory "records"
$RunHistoryPath = Join-Path $CacheDirectory "run-history.csv"

$Analysis08CacheDirectory = Join-Path $RepoRoot "analysis\cache\08-archive-content-pilot"
$Analysis08ArchiveDirectory = Join-Path $Analysis08CacheDirectory "archives"
$Analysis08BrowserPageDirectory = Join-Path $Analysis08CacheDirectory "browser-pages"

$PackageDirectory = Join-Path $RepoRoot "analysis\packages"
$PackagePath = Join-Path $PackageDirectory "$AnalysisName.zip"

$script:CdpCommandId = 0
$script:GitTreeCache = @{}

function Get-SafeName {
    param([Parameter(Mandatory)][string]$Value)

    return (
        $Value `
            -replace '[^\p{L}\p{Nd}._-]+', '_' `
            -replace '_+', '_'
    ).Trim("_")
}

function Get-Sha256 {
    param([Parameter(Mandatory)][string]$Path)

    return (
        Get-FileHash -LiteralPath $Path -Algorithm SHA256
    ).Hash.ToLowerInvariant()
}

function Get-PropertyValue {
    param(
        [AllowNull()]$Object,
        [Parameter(Mandatory)][string]$Name,
        $DefaultValue = ""
    )

    if (
        $null -ne $Object -and
        $Object.PSObject.Properties.Name -contains $Name
    ) {
        return $Object.$Name
    }

    return $DefaultValue
}

function Export-CsvSafe {
    param(
        [Parameter(Mandatory)]$Rows,
        [Parameter(Mandatory)][string]$Path
    )

    $items = @(
        $Rows |
            ForEach-Object {
                $_
            }
    )

    if ($items.Count -gt 0) {
        $items |
            Export-Csv `
                -LiteralPath $Path `
                -NoTypeInformation `
                -Encoding utf8
    }
    else {
        [System.IO.File]::WriteAllText(
            $Path,
            "",
            [System.Text.UTF8Encoding]::new($false)
        )
    }
}

function Import-CsvSafe {
    param([Parameter(Mandatory)][string]$Path)

    if (
        -not (Test-Path -LiteralPath $Path) -or
        (Get-Item -LiteralPath $Path).Length -eq 0
    ) {
        return @()
    }

    return @(
        Import-Csv -LiteralPath $Path
    )
}

function Get-GitProjectedBlobSha1 {
    param(
        [Parameter(Mandatory)][string]$RepositoryPath,
        [Parameter(Mandatory)][string]$RelativePath,
        [Parameter(Mandatory)][string]$ArchivePath
    )

    $output = @(
        & git `
            -C $RepositoryPath `
            hash-object `
            "--path=$RelativePath" `
            -- `
            $ArchivePath `
            2>&1
    )

    if ($LASTEXITCODE -ne 0) {
        throw (
            "git hash-object failed for archive file " +
            "'$ArchivePath' as '$RelativePath': " +
            ($output -join " ")
        )
    }

    $hashes = @(
        $output |
            ForEach-Object {
                [string]$_
            } |
            Where-Object {
                $_ -match '^[0-9a-fA-F]{40}$'
            }
    )

    if ($hashes.Count -ne 1) {
        throw (
            "Expected exactly one Git blob SHA-1 for " +
            "'$RelativePath', but found $($hashes.Count). " +
            "Output: $($output -join ' ')"
        )
    }

    return $hashes[0].ToLowerInvariant()
}

function Test-ZipArchive {
    param([Parameter(Mandatory)][string]$Path)

    try {
        Add-Type -AssemblyName System.IO.Compression.FileSystem

        $archive = [System.IO.Compression.ZipFile]::OpenRead($Path)

        try {
            $null = $archive.Entries.Count
        }
        finally {
            $archive.Dispose()
        }

        return $true
    }
    catch {
        return $false
    }
}

function Expand-ZipSafely {
    param(
        [Parameter(Mandatory)][string]$ArchivePath,
        [Parameter(Mandatory)][string]$Destination
    )

    if (Test-Path -LiteralPath $Destination) {
        Remove-Item -LiteralPath $Destination -Recurse -Force
    }

    New-Item -ItemType Directory -Path $Destination -Force | Out-Null
    Add-Type -AssemblyName System.IO.Compression.FileSystem

    $destinationFull = (
        [System.IO.Path]::GetFullPath($Destination)
    ).TrimEnd(
        [System.IO.Path]::DirectorySeparatorChar,
        [System.IO.Path]::AltDirectorySeparatorChar
    )

    $destinationPrefix = (
        $destinationFull +
        [System.IO.Path]::DirectorySeparatorChar
    )

    $archive = [System.IO.Compression.ZipFile]::OpenRead($ArchivePath)

    try {
        foreach ($entry in $archive.Entries) {
            $entryPath = $entry.FullName.Replace(
                "/",
                [System.IO.Path]::DirectorySeparatorChar
            )

            $targetPath = [System.IO.Path]::GetFullPath(
                (Join-Path $Destination $entryPath)
            )

            if (
                $targetPath -ne $destinationFull -and
                -not $targetPath.StartsWith(
                    $destinationPrefix,
                    [System.StringComparison]::OrdinalIgnoreCase
                )
            ) {
                throw "Unsafe ZIP path detected: $($entry.FullName)"
            }

            if ([string]::IsNullOrEmpty($entry.Name)) {
                New-Item -ItemType Directory -Path $targetPath -Force |
                    Out-Null
                continue
            }

            $parent = Split-Path -Parent $targetPath

            New-Item -ItemType Directory -Path $parent -Force |
                Out-Null

            $inputStream = $entry.Open()

            try {
                $outputStream = [System.IO.File]::Create($targetPath)

                try {
                    $inputStream.CopyTo($outputStream)
                }
                finally {
                    $outputStream.Dispose()
                }
            }
            finally {
                $inputStream.Dispose()
            }
        }
    }
    finally {
        $archive.Dispose()
    }
}

function Get-DescriptorMetadata {
    param([Parameter(Mandatory)][string]$DescriptorPath)

    $text = [System.IO.File]::ReadAllText($DescriptorPath)

    function Get-Value {
        param([Parameter(Mandatory)][string]$Name)

        $escaped = [regex]::Escape($Name)
        $pattern = '(?im)^\s*' + $escaped +
            '\s*=\s*"?(?<value>[^"\r\n]+)"?\s*$'

        $match = [regex]::Match($text, $pattern)

        if ($match.Success) {
            return $match.Groups["value"].Value.Trim()
        }

        return ""
    }

    return [pscustomobject]@{
        Name = Get-Value "name"
        Version = Get-Value "version"
        SupportedVersion = Get-Value "supported_version"
        RemoteFileId = Get-Value "remote_file_id"
    }
}

function Find-ArchiveRoot {
    param(
        [Parameter(Mandatory)][string]$ExtractedDirectory,
        [Parameter(Mandatory)][string]$ExpectedWorkshopId
    )

    $descriptorFiles = @(
        Get-ChildItem `
            -LiteralPath $ExtractedDirectory `
            -Recurse `
            -File `
            -Filter "descriptor.mod"
    )

    if ($descriptorFiles.Count -eq 0) {
        throw "No descriptor.mod was found in extracted archive."
    }

    $matching = [System.Collections.Generic.List[object]]::new()

    foreach ($descriptorFile in $descriptorFiles) {
        $metadata = Get-DescriptorMetadata $descriptorFile.FullName

        if ($metadata.RemoteFileId -eq $ExpectedWorkshopId) {
            $matching.Add(
                [pscustomobject]@{
                    File = $descriptorFile
                    Metadata = $metadata
                }
            )
        }
    }

    if ($matching.Count -eq 1) {
        return [pscustomobject]@{
            Root = $matching[0].File.Directory.FullName
            Descriptor = $matching[0].File.FullName
            Metadata = $matching[0].Metadata
            Selection = "EXPECTED_WORKSHOP_ID"
            DescriptorCount = $descriptorFiles.Count
        }
    }

    if (
        $matching.Count -eq 0 -and
        $descriptorFiles.Count -eq 1
    ) {
        $metadata = Get-DescriptorMetadata $descriptorFiles[0].FullName

        return [pscustomobject]@{
            Root = $descriptorFiles[0].Directory.FullName
            Descriptor = $descriptorFiles[0].FullName
            Metadata = $metadata
            Selection = "ONLY_DESCRIPTOR"
            DescriptorCount = 1
        }
    }

    throw (
        "Could not identify a unique archive root. " +
        "descriptor.mod count=$($descriptorFiles.Count), " +
        "matching Workshop ID count=$($matching.Count)."
    )
}

function Get-GitTree {
    param(
        [Parameter(Mandatory)][string]$RepositoryPath,
        [Parameter(Mandatory)][string]$CommitSha
    )

    $cacheKey = "$RepositoryPath|$CommitSha"

    if ($script:GitTreeCache.ContainsKey($cacheKey)) {
        return @(
            $script:GitTreeCache[$cacheKey]
        )
    }

    $lines = @(
        & git -C $RepositoryPath ls-tree -r $CommitSha
    )

    if ($LASTEXITCODE -ne 0) {
        throw "git ls-tree failed for $CommitSha in $RepositoryPath"
    }

    $rows = [System.Collections.Generic.List[object]]::new()

    foreach ($line in $lines) {
        $match = [regex]::Match(
            $line,
            '^(?<mode>\d+)\s+(?<type>\S+)\s+(?<sha>[0-9a-f]{40})\t(?<path>.+)$'
        )

        if (-not $match.Success) {
            throw "Could not parse git ls-tree line: $line"
        }

        if ($match.Groups["type"].Value -ne "blob") {
            continue
        }

        $rows.Add(
            [pscustomobject]@{
                Mode = $match.Groups["mode"].Value
                BlobSha = $match.Groups["sha"].Value
                Path = $match.Groups["path"].Value
            }
        )
    }

    $result = @($rows)
    $script:GitTreeCache[$cacheKey] = $result

    return @($result)
}

function Test-IsRepositoryMetadataPath {
    param([Parameter(Mandatory)][string]$RelativePath)

    $normalized = $RelativePath.Replace("\", "/")

    return $normalized -in @(
        ".gitignore"
        ".gitattributes"
    )
}

function Get-ArchiveFilesByRelativePath {
    param([Parameter(Mandatory)][string]$ArchiveRoot)

    $dictionary = [System.Collections.Generic.Dictionary[string, object]]::new(
        [System.StringComparer]::OrdinalIgnoreCase
    )

    $files = @(
        Get-ChildItem -LiteralPath $ArchiveRoot -Recurse -File
    )

    foreach ($file in $files) {
        $relative = (
            [System.IO.Path]::GetRelativePath(
                $ArchiveRoot,
                $file.FullName
            )
        ).Replace("\", "/")

        if (
            $relative.StartsWith(
                ".git/",
                [System.StringComparison]::OrdinalIgnoreCase
            )
        ) {
            continue
        }

        if (-not $dictionary.ContainsKey($relative)) {
            $dictionary[$relative] = $file
        }
    }

    return $dictionary
}

function Get-ChromePath {
    $candidates = @(
        (Join-Path $env:ProgramFiles "Google\Chrome\Application\chrome.exe")
        (Join-Path ${env:ProgramFiles(x86)} "Google\Chrome\Application\chrome.exe")
        (Join-Path $env:LOCALAPPDATA "Google\Chrome\Application\chrome.exe")
    )

    foreach ($candidate in $candidates) {
        if (
            -not [string]::IsNullOrWhiteSpace($candidate) -and
            (Test-Path -LiteralPath $candidate)
        ) {
            return $candidate
        }
    }

    $command = Get-Command "chrome.exe" -ErrorAction SilentlyContinue

    if ($null -ne $command) {
        return $command.Source
    }

    throw "Google Chrome could not be found."
}

function Get-FreeTcpPort {
    $listener = [System.Net.Sockets.TcpListener]::new(
        [System.Net.IPAddress]::Loopback,
        0
    )

    try {
        $listener.Start()

        return (
            [System.Net.IPEndPoint]$listener.LocalEndpoint
        ).Port
    }
    finally {
        $listener.Stop()
    }
}

function Wait-DevToolsEndpoint {
    param(
        [Parameter(Mandatory)][int]$Port,
        [int]$TimeoutSeconds = 30
    )

    $deadline = (Get-Date).AddSeconds($TimeoutSeconds)
    $lastError = $null

    while ((Get-Date) -lt $deadline) {
        try {
            return Invoke-RestMethod `
                -Uri "http://127.0.0.1:$Port/json/version" `
                -TimeoutSec 2
        }
        catch {
            $lastError = $_
            Start-Sleep -Milliseconds 300
        }
    }

    throw (
        "Chrome DevTools endpoint did not become ready on port $Port. " +
        "Last error: $($lastError.Exception.Message)"
    )
}

function Get-CdpPageSocketUrl {
    param([Parameter(Mandatory)][int]$Port)

    $targets = @(
        Invoke-RestMethod `
            -Uri "http://127.0.0.1:$Port/json/list" `
            -TimeoutSec 5 |
            Where-Object {
                $_.type -eq "page"
            }
    )

    $page = @(
        $targets |
            Where-Object {
                $null -ne $_ -and
                $_.PSObject.Properties.Name -contains
                    "webSocketDebuggerUrl" -and
                -not [string]::IsNullOrWhiteSpace(
                    [string]$_.webSocketDebuggerUrl
                )
            }
    ) |
        Select-Object -First 1

    if ($null -eq $page) {
        $encodedUrl = [System.Uri]::EscapeDataString("about:blank")

        $page = Invoke-RestMethod `
            -Method Put `
            -Uri "http://127.0.0.1:$Port/json/new?$encodedUrl" `
            -TimeoutSec 5
    }

    $urls = @(
        $page |
            ForEach-Object {
                if (
                    $null -ne $_ -and
                    $_.PSObject.Properties.Name -contains
                        "webSocketDebuggerUrl"
                ) {
                    $value = [string]$_.webSocketDebuggerUrl

                    if (-not [string]::IsNullOrWhiteSpace($value)) {
                        $value
                    }
                }
            }
    )

    if ($urls.Count -ne 1) {
        throw (
            "Expected exactly one Chrome page WebSocket URL, " +
            "but found $($urls.Count)."
        )
    }

    return [string]$urls[0]
}

function New-CdpSocket {
    param(
        [Parameter(Mandatory)][string]$WebSocketUrl,
        [Parameter(Mandatory)][ref]$Socket
    )

    if ([string]::IsNullOrWhiteSpace($WebSocketUrl)) {
        throw "Chrome DevTools WebSocket URL is empty."
    }

    $client = [System.Net.WebSockets.ClientWebSocket]::new()

    try {
        $connectTask = $client.ConnectAsync(
            [System.Uri]$WebSocketUrl,
            [System.Threading.CancellationToken]::None
        )

        $null = $connectTask.GetAwaiter().GetResult()

        if (
            $client.State -ne
            [System.Net.WebSockets.WebSocketState]::Open
        ) {
            throw (
                "Chrome DevTools WebSocket did not open. " +
                "State: $($client.State)"
            )
        }

        $Socket.Value = $client
    }
    catch {
        $client.Dispose()
        throw
    }
}

function Receive-CdpText {
    param(
        [Parameter(Mandatory)]
        [System.Net.WebSockets.ClientWebSocket]$Socket
    )

    $buffer = [byte[]]::new(65536)
    $stream = [System.IO.MemoryStream]::new()

    try {
        do {
            $segment = [System.ArraySegment[byte]]::new($buffer)

            $result = $Socket.ReceiveAsync(
                $segment,
                [System.Threading.CancellationToken]::None
            ).GetAwaiter().GetResult()

            if (
                $result.MessageType -eq
                [System.Net.WebSockets.WebSocketMessageType]::Close
            ) {
                throw "Chrome DevTools WebSocket closed unexpectedly."
            }

            $stream.Write($buffer, 0, $result.Count)
        }
        while (-not $result.EndOfMessage)

        return [System.Text.Encoding]::UTF8.GetString(
            $stream.ToArray()
        )
    }
    finally {
        $stream.Dispose()
    }
}

function Invoke-CdpCommand {
    param(
        [Parameter(Mandatory)]
        [System.Net.WebSockets.ClientWebSocket]$Socket,

        [Parameter(Mandatory)]
        [string]$Method,

        [AllowNull()]$Params = $null
    )

    $script:CdpCommandId++
    $id = $script:CdpCommandId

    $payload = [ordered]@{
        id = $id
        method = $Method
    }

    if ($null -ne $Params) {
        $payload.params = $Params
    }

    $json = $payload |
        ConvertTo-Json -Depth 30 -Compress

    $bytes = [System.Text.Encoding]::UTF8.GetBytes($json)
    $segment = [System.ArraySegment[byte]]::new($bytes)

    $Socket.SendAsync(
        $segment,
        [System.Net.WebSockets.WebSocketMessageType]::Text,
        $true,
        [System.Threading.CancellationToken]::None
    ).GetAwaiter().GetResult() |
        Out-Null

    while ($true) {
        $message = Receive-CdpText $Socket
        $response = $message | ConvertFrom-Json

        if (
            $response.PSObject.Properties.Name -contains "id" -and
            [int]$response.id -eq $id
        ) {
            if ($response.PSObject.Properties.Name -contains "error") {
                $errorText = $response.error |
                    ConvertTo-Json -Depth 10 -Compress

                throw (
                    "Chrome DevTools command '$Method' failed: " +
                    $errorText
                )
            }

            if ($response.PSObject.Properties.Name -contains "result") {
                return $response.result
            }

            return $null
        }
    }
}

function Invoke-CdpEvaluate {
    param(
        [Parameter(Mandatory)]
        [System.Net.WebSockets.ClientWebSocket]$Socket,

        [Parameter(Mandatory)]
        [string]$Expression,

        [switch]$UserGesture
    )

    $result = Invoke-CdpCommand `
        -Socket $Socket `
        -Method "Runtime.evaluate" `
        -Params @{
            expression = $Expression
            returnByValue = $true
            awaitPromise = $true
            userGesture = [bool]$UserGesture
        }

    if ($result.PSObject.Properties.Name -contains "exceptionDetails") {
        $details = $result.exceptionDetails |
            ConvertTo-Json -Depth 10 -Compress

        throw "JavaScript evaluation failed: $details"
    }

    if (-not ($result.PSObject.Properties.Name -contains "result")) {
        return $null
    }

    $remote = $result.result

    if ($remote.PSObject.Properties.Name -contains "value") {
        return $remote.value
    }

    return $null
}

function Wait-CdpReady {
    param(
        [Parameter(Mandatory)]
        [System.Net.WebSockets.ClientWebSocket]$Socket,

        [int]$TimeoutSeconds = 45
    )

    $deadline = (Get-Date).AddSeconds($TimeoutSeconds)

    while ((Get-Date) -lt $deadline) {
        try {
            $state = Invoke-CdpEvaluate `
                -Socket $Socket `
                -Expression "document.readyState"

            if ($state -in @("interactive", "complete")) {
                return
            }
        }
        catch {
        }

        Start-Sleep -Milliseconds 400
    }

    throw "Timed out waiting for the browser page to become ready."
}

function Invoke-CdpNavigate {
    param(
        [Parameter(Mandatory)]
        [System.Net.WebSockets.ClientWebSocket]$Socket,

        [Parameter(Mandatory)][string]$Url
    )

    $null = Invoke-CdpCommand `
        -Socket $Socket `
        -Method "Page.navigate" `
        -Params @{
            url = $Url
        }

    Wait-CdpReady -Socket $Socket
}

function Get-CdpActionState {
    param(
        [Parameter(Mandatory)]
        [System.Net.WebSockets.ClientWebSocket]$Socket,

        [Parameter(Mandatory)][string]$Label
    )

    $labelJson = $Label |
        ConvertTo-Json -Compress

    $expression = @"
(() => {
    const wanted = $labelJson.toUpperCase();
    const normalize = value =>
        String(value || "").replace(/\s+/g, " ").trim().toUpperCase();

    const elements = Array.from(
        document.querySelectorAll(
            "a, button, input[type=submit], input[type=button]"
        )
    );

    const element = elements.find(el => {
        const text = normalize(
            el.innerText || el.value || el.textContent
        );

        return text.includes(wanted);
    });

    if (!element) {
        return {
            found: false,
            enabled: false,
            title: document.title,
            url: location.href,
            preview: normalize(document.body ? document.body.innerText : "")
                .slice(0, 350)
        };
    }

    const style = getComputedStyle(element);
    const rect = element.getBoundingClientRect();

    const visible =
        style.display !== "none" &&
        style.visibility !== "hidden" &&
        rect.width > 0 &&
        rect.height > 0;

    const disabled =
        Boolean(element.disabled) ||
        element.getAttribute("aria-disabled") === "true";

    return {
        found: true,
        enabled: visible && !disabled,
        text: normalize(
            element.innerText || element.value || element.textContent
        ),
        href: element.href || "",
        title: document.title,
        url: location.href
    };
})()
"@

    return Invoke-CdpEvaluate `
        -Socket $Socket `
        -Expression $expression
}

function Wait-CdpAction {
    param(
        [Parameter(Mandatory)]
        [System.Net.WebSockets.ClientWebSocket]$Socket,

        [Parameter(Mandatory)][string]$Label,

        [int]$TimeoutSeconds = 45
    )

    $deadline = (Get-Date).AddSeconds($TimeoutSeconds)
    $lastState = $null

    while ((Get-Date) -lt $deadline) {
        try {
            $lastState = Get-CdpActionState `
                -Socket $Socket `
                -Label $Label

            if (
                $null -ne $lastState -and
                $lastState.found -eq $true -and
                $lastState.enabled -eq $true
            ) {
                return $lastState
            }

            if (
                $null -ne $lastState -and
                $lastState.PSObject.Properties.Name -contains "preview"
            ) {
                $preview = [string]$lastState.preview

                if (
                    $preview -match
                    '(?i)verify you are human|captcha|access denied'
                ) {
                    throw (
                        "The browser reached an anti-bot verification page. " +
                        "Preview: $preview"
                    )
                }
            }
        }
        catch {
            if (
                $_.Exception.Message -match
                'anti-bot verification page'
            ) {
                throw
            }
        }

        Start-Sleep -Milliseconds 500
    }

    $description = if ($null -ne $lastState) {
        $lastState |
            ConvertTo-Json -Depth 5 -Compress
    }
    else {
        "no state"
    }

    throw (
        "Timed out waiting for '$Label'. " +
        "Last browser state: $description"
    )
}

function Invoke-CdpClickAction {
    param(
        [Parameter(Mandatory)]
        [System.Net.WebSockets.ClientWebSocket]$Socket,

        [Parameter(Mandatory)][string]$Label
    )

    $labelJson = $Label |
        ConvertTo-Json -Compress

    $expression = @"
(() => {
    const wanted = $labelJson.toUpperCase();
    const normalize = value =>
        String(value || "").replace(/\s+/g, " ").trim().toUpperCase();

    const elements = Array.from(
        document.querySelectorAll(
            "a, button, input[type=submit], input[type=button]"
        )
    );

    const element = elements.find(el => {
        const text = normalize(
            el.innerText || el.value || el.textContent
        );

        return text.includes(wanted);
    });

    if (!element) {
        return {
            clicked: false,
            reason: "not-found"
        };
    }

    if (
        Boolean(element.disabled) ||
        element.getAttribute("aria-disabled") === "true"
    ) {
        return {
            clicked: false,
            reason: "disabled"
        };
    }

    element.scrollIntoView({
        behavior: "instant",
        block: "center"
    });

    element.click();

    return {
        clicked: true,
        text: normalize(
            element.innerText || element.value || element.textContent
        ),
        href: element.href || ""
    };
})()
"@

    $result = Invoke-CdpEvaluate `
        -Socket $Socket `
        -Expression $expression `
        -UserGesture

    if (
        $null -eq $result -or
        $result.clicked -ne $true
    ) {
        $details = if ($null -ne $result) {
            $result |
                ConvertTo-Json -Depth 5 -Compress
        }
        else {
            "no result"
        }

        throw "Could not click '$Label': $details"
    }

    return $result
}

function Get-CdpPageHtml {
    param(
        [Parameter(Mandatory)]
        [System.Net.WebSockets.ClientWebSocket]$Socket
    )

    return [string](
        Invoke-CdpEvaluate `
            -Socket $Socket `
            -Expression "document.documentElement.outerHTML"
    )
}

function Wait-NewBrowserDownload {
    param(
        [Parameter(Mandatory)][string]$Directory,

        [Parameter(Mandatory)]
        [System.Collections.Generic.HashSet[string]]$BeforeFiles,

        [int]$TimeoutSeconds = 600
    )

    $deadline = (Get-Date).AddSeconds($TimeoutSeconds)
    $lastPath = ""
    $lastLength = -1L
    $stablePolls = 0

    while ((Get-Date) -lt $deadline) {
        $files = @(
            Get-ChildItem `
                -LiteralPath $Directory `
                -File `
                -ErrorAction SilentlyContinue
        )

        $newFiles = @(
            $files |
                Where-Object {
                    -not $BeforeFiles.Contains($_.FullName) -and
                    $_.Extension -ne ".crdownload"
                } |
                Sort-Object LastWriteTimeUtc -Descending
        )

        $partialFiles = @(
            $files |
                Where-Object {
                    $_.Extension -eq ".crdownload"
                }
        )

        if ($newFiles.Count -gt 0) {
            $candidate = $newFiles[0]

            if (
                $candidate.FullName -eq $lastPath -and
                $candidate.Length -eq $lastLength
            ) {
                $stablePolls++
            }
            else {
                $lastPath = $candidate.FullName
                $lastLength = $candidate.Length
                $stablePolls = 0
            }

            if (
                $stablePolls -ge 2 -and
                $partialFiles.Count -eq 0
            ) {
                return $candidate.FullName
            }
        }

        Start-Sleep -Seconds 1
    }

    throw "Timed out waiting for Chrome to finish the archive download."
}

function Save-BrowserHtml {
    param(
        [Parameter(Mandatory)][string]$Html,
        [Parameter(Mandatory)][string]$CachePath
    )

    $parent = Split-Path -Parent $CachePath

    New-Item -ItemType Directory -Path $parent -Force |
        Out-Null

    [System.IO.File]::WriteAllText(
        $CachePath,
        $Html,
        [System.Text.UTF8Encoding]::new($false)
    )
}

function Copy-DirectoryFiles {
    param(
        [Parameter(Mandatory)][string]$SourceDirectory,
        [Parameter(Mandatory)][string]$DestinationDirectory
    )

    if (-not (Test-Path -LiteralPath $SourceDirectory)) {
        return
    }

    New-Item -ItemType Directory -Path $DestinationDirectory -Force |
        Out-Null

    foreach (
        $file in @(
            Get-ChildItem -LiteralPath $SourceDirectory -File
        )
    ) {
        Copy-Item `
            -LiteralPath $file.FullName `
            -Destination (Join-Path $DestinationDirectory $file.Name) `
            -Force
    }
}

function Get-RevisionRecordDirectory {
    param([Parameter(Mandatory)][string]$RevisionKey)

    return Join-Path $RecordDirectory (Get-SafeName $RevisionKey)
}

function Get-RevisionStatePath {
    param([Parameter(Mandatory)][string]$RevisionKey)

    return Join-Path (Get-RevisionRecordDirectory $RevisionKey) "state.json"
}

function Read-RevisionState {
    param([Parameter(Mandatory)][string]$RevisionKey)

    $path = Get-RevisionStatePath $RevisionKey

    if (-not (Test-Path -LiteralPath $path)) {
        return $null
    }

    try {
        return Get-Content -LiteralPath $path -Raw |
            ConvertFrom-Json
    }
    catch {
        return $null
    }
}

function Write-RevisionState {
    param(
        [Parameter(Mandatory)][string]$RevisionKey,
        [Parameter(Mandatory)]$State
    )

    $directory = Get-RevisionRecordDirectory $RevisionKey
    New-Item -ItemType Directory -Path $directory -Force |
        Out-Null

    $path = Join-Path $directory "state.json"

    $json = $State |
        ConvertTo-Json -Depth 10

    [System.IO.File]::WriteAllText(
        $path,
        $json,
        [System.Text.UTF8Encoding]::new($false)
    )
}

function Test-RevisionComplete {
    param([Parameter(Mandatory)][string]$RevisionKey)

    $state = Read-RevisionState $RevisionKey

    return (
        $null -ne $state -and
        (Get-PropertyValue $state "Status") -eq "COMPLETE"
    )
}

function Get-ArchiveOriginPath {
    param([Parameter(Mandatory)][string]$ArchivePath)

    return "$ArchivePath.origin.json"
}

function Write-ArchiveOrigin {
    param(
        [Parameter(Mandatory)][string]$ArchivePath,
        [Parameter(Mandatory)][string]$Source,
        [Parameter(Mandatory)][string]$SourceUrl,
        [Parameter(Mandatory)][string]$RevisionKey
    )

    $origin = [pscustomobject]@{
        RevisionKey = $RevisionKey
        Source = $Source
        SourceUrl = $SourceUrl
        AcquiredAt = (Get-Date).ToString("o")
        ArchiveSha256 = Get-Sha256 $ArchivePath
        ArchiveBytes = (Get-Item -LiteralPath $ArchivePath).Length
    }

    $json = $origin |
        ConvertTo-Json -Depth 5

    [System.IO.File]::WriteAllText(
        (Get-ArchiveOriginPath $ArchivePath),
        $json,
        [System.Text.UTF8Encoding]::new($false)
    )
}

function Read-ArchiveOrigin {
    param([Parameter(Mandatory)][string]$ArchivePath)

    $path = Get-ArchiveOriginPath $ArchivePath

    if (-not (Test-Path -LiteralPath $path)) {
        return $null
    }

    try {
        return Get-Content -LiteralPath $path -Raw |
            ConvertFrom-Json
    }
    catch {
        return $null
    }
}

function Test-Analysis08ArchiveAvailable {
    param([Parameter(Mandatory)][string]$RevisionKey)

    $safe = Get-SafeName $RevisionKey
    $path = Join-Path $Analysis08ArchiveDirectory "$safe.zip"

    return (
        (Test-Path -LiteralPath $path) -and
        (Test-ZipArchive $path)
    )
}

function Import-Analysis08Archive {
    param(
        [Parameter(Mandatory)]$Plan,
        [Parameter(Mandatory)][string]$ArchivePath,
        [Parameter(Mandatory)][string]$PageCacheDirectory
    )

    $safe = Get-SafeName $Plan.SkymodsRevisionKey
    $sourceArchive = Join-Path $Analysis08ArchiveDirectory "$safe.zip"

    if (-not (Test-ZipArchive $sourceArchive)) {
        throw "Analysis 08 cache archive is unavailable or invalid: $sourceArchive"
    }

    Copy-Item `
        -LiteralPath $sourceArchive `
        -Destination $ArchivePath `
        -Force

    $sourcePages = Join-Path $Analysis08BrowserPageDirectory $safe

    if (Test-Path -LiteralPath $sourcePages) {
        Copy-DirectoryFiles `
            -SourceDirectory $sourcePages `
            -DestinationDirectory $PageCacheDirectory
    }

    Write-ArchiveOrigin `
        -ArchivePath $ArchivePath `
        -Source "ANALYSIS08_CACHE" `
        -SourceUrl $Plan.SkymodsDownloadUrl `
        -RevisionKey $Plan.SkymodsRevisionKey
}

function Start-CdpChrome {
    param(
        [Parameter(Mandatory)][string]$DownloadDirectory,
        [Parameter(Mandatory)][ref]$Process,
        [Parameter(Mandatory)][ref]$BrowserSocket,
        [Parameter(Mandatory)][ref]$PageSocket,
        [Parameter(Mandatory)][ref]$ProfileDirectory
    )

    $chromePath = Get-ChromePath
    $debugPort = Get-FreeTcpPort

    $profile = Join-Path $CacheDirectory "chrome-profile-$debugPort"

    New-Item -ItemType Directory -Path $profile -Force |
        Out-Null

    $chromeArguments = @(
        "--remote-debugging-port=$debugPort"
        "--remote-debugging-address=127.0.0.1"
        "--remote-allow-origins=*"
        "--user-data-dir=$profile"
        "--no-first-run"
        "--no-default-browser-check"
        "--disable-sync"
        "--window-size=1280,900"
        "about:blank"
    )

    Write-Host ""
    Write-Host "Launching isolated Chrome for Modsbase downloads..."

    $chromeProcess = Start-Process `
        -FilePath $chromePath `
        -ArgumentList $chromeArguments `
        -PassThru

    $Process.Value = $chromeProcess
    $ProfileDirectory.Value = $profile

    $versionInfo = Wait-DevToolsEndpoint -Port $debugPort
    $pageSocketUrl = Get-CdpPageSocketUrl -Port $debugPort

    $browserSocketUrl = [string](
        $versionInfo.webSocketDebuggerUrl
    )

    if ([string]::IsNullOrWhiteSpace($browserSocketUrl)) {
        throw "Chrome browser WebSocket URL is missing."
    }

    $browser = $null

    New-CdpSocket `
        -WebSocketUrl $browserSocketUrl `
        -Socket ([ref]$browser)

    if (
        $browser -isnot
        [System.Net.WebSockets.ClientWebSocket]
    ) {
        throw "Browser CDP socket initialization failed."
    }

    $BrowserSocket.Value = $browser

    $page = $null

    New-CdpSocket `
        -WebSocketUrl $pageSocketUrl `
        -Socket ([ref]$page)

    if (
        $page -isnot
        [System.Net.WebSockets.ClientWebSocket]
    ) {
        throw "Page CDP socket initialization failed."
    }

    $PageSocket.Value = $page

    $null = Invoke-CdpCommand `
        -Socket $page `
        -Method "Page.enable" `
        -Params @{}

    $null = Invoke-CdpCommand `
        -Socket $page `
        -Method "Runtime.enable" `
        -Params @{}

    $null = Invoke-CdpCommand `
        -Socket $browser `
        -Method "Browser.setDownloadBehavior" `
        -Params @{
            behavior = "allow"
            downloadPath = $DownloadDirectory
            eventsEnabled = $true
        }
}

function Stop-CdpChrome {
    param(
        [AllowNull()]$Process,
        [AllowNull()]$BrowserSocket,
        [AllowNull()]$PageSocket,
        [AllowNull()][string]$ProfileDirectory
    )

    foreach ($socket in @($PageSocket, $BrowserSocket)) {
        if ($null -ne $socket) {
            try {
                $socket.Dispose()
            }
            catch {
            }
        }
    }

    if ($null -ne $Process) {
        try {
            if (-not $Process.HasExited) {
                Stop-Process `
                    -Id $Process.Id `
                    -Force `
                    -ErrorAction SilentlyContinue
            }
        }
        catch {
        }
    }

    if (
        -not [string]::IsNullOrWhiteSpace($ProfileDirectory) -and
        (Test-Path -LiteralPath $ProfileDirectory)
    ) {
        Start-Sleep -Milliseconds 500

        Remove-Item `
            -LiteralPath $ProfileDirectory `
            -Recurse `
            -Force `
            -ErrorAction SilentlyContinue
    }
}

function Download-ModsbaseArchive {
    param(
        [Parameter(Mandatory)]$Plan,
        [Parameter(Mandatory)][string]$ArchivePath,
        [Parameter(Mandatory)][string]$PageCacheDirectory,
        [Parameter(Mandatory)]
        [System.Net.WebSockets.ClientWebSocket]$PageSocket
    )

    if (Test-Path -LiteralPath $ArchivePath) {
        Remove-Item -LiteralPath $ArchivePath -Force
    }

    $originPath = Get-ArchiveOriginPath $ArchivePath

    if (Test-Path -LiteralPath $originPath) {
        Remove-Item -LiteralPath $originPath -Force
    }

    New-Item -ItemType Directory -Path $PageCacheDirectory -Force |
        Out-Null

    Write-Host "Opening Modsbase in isolated Chrome..."

    Invoke-CdpNavigate `
        -Socket $PageSocket `
        -Url $Plan.SkymodsDownloadUrl

    $null = Wait-CdpAction `
        -Socket $PageSocket `
        -Label "CREATE DOWNLOAD LINK" `
        -TimeoutSeconds 60

    $firstHtml = Get-CdpPageHtml -Socket $PageSocket
    $firstPagePath = Join-Path $PageCacheDirectory "01-file-page.html"

    Save-BrowserHtml `
        -Html $firstHtml `
        -CachePath $firstPagePath

    Write-Host "Creating download link..."

    $null = Invoke-CdpClickAction `
        -Socket $PageSocket `
        -Label "CREATE DOWNLOAD LINK"

    Start-Sleep -Seconds 6

    $null = Wait-CdpAction `
        -Socket $PageSocket `
        -Label "DOWNLOAD FILE" `
        -TimeoutSeconds 60

    $secondHtml = Get-CdpPageHtml -Socket $PageSocket
    $secondPagePath = Join-Path $PageCacheDirectory "02-download-page.html"

    Save-BrowserHtml `
        -Html $secondHtml `
        -CachePath $secondPagePath

    $beforeFiles = [System.Collections.Generic.HashSet[string]]::new(
        [System.StringComparer]::OrdinalIgnoreCase
    )

    foreach (
        $existingFile in @(
            Get-ChildItem `
                -LiteralPath $ArchiveDirectory `
                -File `
                -ErrorAction SilentlyContinue
        )
    ) {
        [void]$beforeFiles.Add($existingFile.FullName)
    }

    Write-Host "Downloading archive through Chrome..."

    $null = Invoke-CdpClickAction `
        -Socket $PageSocket `
        -Label "DOWNLOAD FILE"

    $downloadedPath = Wait-NewBrowserDownload `
        -Directory $ArchiveDirectory `
        -BeforeFiles $beforeFiles `
        -TimeoutSeconds 900

    if (-not (Test-ZipArchive $downloadedPath)) {
        throw (
            "Chrome downloaded a file that is not a valid ZIP: " +
            $downloadedPath
        )
    }

    if (
        -not [string]::Equals(
            $downloadedPath,
            $ArchivePath,
            [System.StringComparison]::OrdinalIgnoreCase
        )
    ) {
        Move-Item `
            -LiteralPath $downloadedPath `
            -Destination $ArchivePath `
            -Force
    }

    Write-ArchiveOrigin `
        -ArchivePath $ArchivePath `
        -Source "CHROME_CDP" `
        -SourceUrl $Plan.SkymodsDownloadUrl `
        -RevisionKey $Plan.SkymodsRevisionKey
}

function Save-RevisionRecords {
    param(
        [Parameter(Mandatory)][string]$RevisionKey,
        [Parameter(Mandatory)]$DownloadRow,
        [Parameter(Mandatory)]$DescriptorRow,
        [Parameter(Mandatory)]$ArchiveInventory,
        [Parameter(Mandatory)]$ComparisonRows,
        [Parameter(Mandatory)]$DifferenceRows,
        [Parameter(Mandatory)]$SummaryRow
    )

    $directory = Get-RevisionRecordDirectory $RevisionKey

    New-Item -ItemType Directory -Path $directory -Force |
        Out-Null

    Export-CsvSafe `
        -Rows @($DownloadRow) `
        -Path (Join-Path $directory "archive-download.csv")

    Export-CsvSafe `
        -Rows @($DescriptorRow) `
        -Path (Join-Path $directory "archive-descriptor.csv")

    Export-CsvSafe `
        -Rows $ArchiveInventory `
        -Path (Join-Path $directory "archive-file-inventory.csv")

    Export-CsvSafe `
        -Rows $ComparisonRows `
        -Path (Join-Path $directory "git-content-comparisons.csv")

    Export-CsvSafe `
        -Rows $DifferenceRows `
        -Path (Join-Path $directory "file-differences.csv")

    Export-CsvSafe `
        -Rows @($SummaryRow) `
        -Path (Join-Path $directory "revision-summary.csv")
}

function Invoke-RevisionVerification {
    param(
        [Parameter(Mandatory)]$Plan,
        [Parameter(Mandatory)]$RepoInfo,
        [AllowNull()]
        [System.Net.WebSockets.ClientWebSocket]$PageSocket,
        [Parameter(Mandatory)][ref]$Result
    )

    $revisionKey = [string]$Plan.SkymodsRevisionKey
    $safeRevisionKey = Get-SafeName $revisionKey

    $archivePath = Join-Path $ArchiveDirectory "$safeRevisionKey.zip"
    $extractPath = Join-Path $ExtractDirectory $safeRevisionKey
    $pageCacheDirectory = Join-Path $BrowserPageCacheDirectory $safeRevisionKey
    $revisionRecordDirectory = Get-RevisionRecordDirectory $revisionKey

    $priorState = Read-RevisionState $revisionKey
    $attemptCount = 1

    if ($null -ne $priorState) {
        $attemptCount = (
            [int](Get-PropertyValue $priorState "AttemptCount" 0)
        ) + 1
    }

    if (Test-Path -LiteralPath $revisionRecordDirectory) {
        Remove-Item `
            -LiteralPath $revisionRecordDirectory `
            -Recurse `
            -Force
    }

    New-Item -ItemType Directory -Path $revisionRecordDirectory -Force |
        Out-Null

    $startedAt = Get-Date

    try {
        $oldRepoPath = Join-Path $OldReposRoot $RepoInfo.LocalFolder

        if (-not (Test-Path -LiteralPath $oldRepoPath)) {
            throw "Historical repository path not found: $oldRepoPath"
        }

        if (
            -not (Test-Path -LiteralPath $archivePath) -or
            -not (Test-ZipArchive $archivePath)
        ) {
            if (Test-Analysis08ArchiveAvailable $revisionKey) {
                Write-Host "Importing archive from Analysis 08 cache..."

                Import-Analysis08Archive `
                    -Plan $Plan `
                    -ArchivePath $archivePath `
                    -PageCacheDirectory $pageCacheDirectory
            }
            else {
                if ($null -eq $PageSocket) {
                    throw (
                        "Archive is not cached and Chrome automation " +
                        "is unavailable for $revisionKey."
                    )
                }

                Download-ModsbaseArchive `
                    -Plan $Plan `
                    -ArchivePath $archivePath `
                    -PageCacheDirectory $pageCacheDirectory `
                    -PageSocket $PageSocket
            }
        }
        else {
            Write-Host "Using cached archive."
        }

        if (-not (Test-ZipArchive $archivePath)) {
            throw "Archive cache is not a valid ZIP: $archivePath"
        }

        $origin = Read-ArchiveOrigin $archivePath

        $downloadMethod = if ($null -ne $origin) {
            [string](Get-PropertyValue $origin "Source" "CACHE")
        }
        else {
            "CACHE"
        }

        $archiveSha256 = Get-Sha256 $archivePath
        $archiveBytes = (Get-Item -LiteralPath $archivePath).Length

        Write-Host (
            "Archive: {0:N2} MiB" -f
            ($archiveBytes / 1MB)
        )

        Expand-ZipSafely `
            -ArchivePath $archivePath `
            -Destination $extractPath

        $archiveRootInfo = Find-ArchiveRoot `
            -ExtractedDirectory $extractPath `
            -ExpectedWorkshopId $Plan.WorkshopId

        $descriptorMatchesWorkshopId = (
            $archiveRootInfo.Metadata.RemoteFileId -eq
            $Plan.WorkshopId
        )

        if (-not $descriptorMatchesWorkshopId) {
            throw (
                "descriptor remote_file_id " +
                "'$($archiveRootInfo.Metadata.RemoteFileId)' " +
                "does not match expected '$($Plan.WorkshopId)'."
            )
        }

        $descriptorRelativePath = (
            [System.IO.Path]::GetRelativePath(
                $archiveRootInfo.Root,
                $archiveRootInfo.Descriptor
            )
        ).Replace("\", "/")

        $archiveFiles = Get-ArchiveFilesByRelativePath `
            -ArchiveRoot $archiveRootInfo.Root

        $archiveInventory = [System.Collections.Generic.List[object]]::new()

        foreach (
            $relativePath in @(
                $archiveFiles.Keys |
                    Sort-Object
            )
        ) {
            $file = $archiveFiles[$relativePath]

            $archiveInventory.Add(
                [pscustomobject]@{
                    Repo = $Plan.Repo
                    Abbreviation = $Plan.Abbreviation
                    WorkshopId = $Plan.WorkshopId
                    SkymodsRevisionKey = $revisionKey
                    Path = $relativePath
                    Bytes = $file.Length
                }
            )
        }

        $downloadRow = [pscustomobject]@{
            Repo = $Plan.Repo
            Abbreviation = $Plan.Abbreviation
            WorkshopId = $Plan.WorkshopId
            SkymodsRevisionKey = $revisionKey
            SkymodsRawDisplayedTime = $Plan.SkymodsRawDisplayedTime
            SkymodsNormalizedUtcTime = $Plan.SkymodsNormalizedUtcTime
            ModsbasePageUrl = $Plan.SkymodsDownloadUrl
            DownloadMethod = $downloadMethod
            ArchiveCachePath = (
                [System.IO.Path]::GetRelativePath(
                    $RepoRoot,
                    $archivePath
                )
            ).Replace("\", "/")
            ArchiveBytes = $archiveBytes
            ArchiveMiB = [math]::Round($archiveBytes / 1MB, 3)
            ArchiveSha256 = $archiveSha256
            ArchiveFileCount = $archiveFiles.Count
            ArchiveRootSelection = $archiveRootInfo.Selection
        }

        $descriptorRow = [pscustomobject]@{
            Repo = $Plan.Repo
            Abbreviation = $Plan.Abbreviation
            WorkshopIdExpected = $Plan.WorkshopId
            SkymodsRevisionKey = $revisionKey
            DescriptorPath = $descriptorRelativePath
            DescriptorName = $archiveRootInfo.Metadata.Name
            DescriptorVersion = $archiveRootInfo.Metadata.Version
            DescriptorSupportedVersion = $archiveRootInfo.Metadata.SupportedVersion
            DescriptorRemoteFileId = $archiveRootInfo.Metadata.RemoteFileId
            DescriptorWorkshopIdMatches = $descriptorMatchesWorkshopId
            DescriptorCountInArchive = $archiveRootInfo.DescriptorCount
        }

        $candidateShas = @(
            $Plan.RelatedGitCommitShas -split '\|' |
                Where-Object {
                    -not [string]::IsNullOrWhiteSpace($_)
                } |
                Select-Object -Unique
        )

        if ($candidateShas.Count -eq 0) {
            throw "$revisionKey has no related Git commits in Analysis 07."
        }

        $comparisonRows = [System.Collections.Generic.List[object]]::new()
        $differenceRows = [System.Collections.Generic.List[object]]::new()
        $projectedHashCache = @{}

        foreach ($commitSha in $candidateShas) {
            Write-Host "Comparing Git commit $commitSha"

            $gitTree = @(
                Get-GitTree `
                    -RepositoryPath $oldRepoPath `
                    -CommitSha $commitSha
            )

            $comparableGitRows = @(
                $gitTree |
                    Where-Object {
                        -not (
                            Test-IsRepositoryMetadataPath $_.Path
                        )
                    }
            )

            $excludedMetadataCount = (
                $gitTree.Count -
                $comparableGitRows.Count
            )

            $matching = 0
            $missing = 0
            $mismatched = 0

            $gitComparablePaths = [System.Collections.Generic.HashSet[string]]::new(
                [System.StringComparer]::OrdinalIgnoreCase
            )

            foreach ($gitFile in $comparableGitRows) {
                [void]$gitComparablePaths.Add($gitFile.Path)

                if (-not $archiveFiles.ContainsKey($gitFile.Path)) {
                    $missing++

                    $differenceRows.Add(
                        [pscustomobject]@{
                            Repo = $Plan.Repo
                            WorkshopId = $Plan.WorkshopId
                            SkymodsRevisionKey = $revisionKey
                            GitCommitSha = $commitSha
                            Path = $gitFile.Path
                            Difference = "MISSING_FROM_ARCHIVE"
                            GitBlobSha1 = $gitFile.BlobSha
                            ArchiveBlobSha1 = ""
                        }
                    )

                    continue
                }

                $archiveFile = $archiveFiles[$gitFile.Path]
                $hashCacheKey = $gitFile.Path

                if ($projectedHashCache.ContainsKey($hashCacheKey)) {
                    $archiveBlobSha = [string]$projectedHashCache[$hashCacheKey]
                }
                else {
                    $archiveBlobSha = Get-GitProjectedBlobSha1 `
                        -RepositoryPath $oldRepoPath `
                        -RelativePath $gitFile.Path `
                        -ArchivePath $archiveFile.FullName

                    $projectedHashCache[$hashCacheKey] = $archiveBlobSha
                }

                if ($archiveBlobSha -eq $gitFile.BlobSha) {
                    $matching++
                }
                else {
                    $mismatched++

                    $differenceRows.Add(
                        [pscustomobject]@{
                            Repo = $Plan.Repo
                            WorkshopId = $Plan.WorkshopId
                            SkymodsRevisionKey = $revisionKey
                            GitCommitSha = $commitSha
                            Path = $gitFile.Path
                            Difference = "BLOB_MISMATCH"
                            GitBlobSha1 = $gitFile.BlobSha
                            ArchiveBlobSha1 = $archiveBlobSha
                        }
                    )
                }
            }

            $archiveExtraCount = 0

            foreach ($archiveRelativePath in $archiveFiles.Keys) {
                if (
                    Test-IsRepositoryMetadataPath `
                        $archiveRelativePath
                ) {
                    continue
                }

                if (-not $gitComparablePaths.Contains($archiveRelativePath)) {
                    $archiveExtraCount++
                }
            }

            $projectedExactMatch = (
                $comparableGitRows.Count -gt 0 -and
                $missing -eq 0 -and
                $mismatched -eq 0
            )

            $comparisonRows.Add(
                [pscustomobject]@{
                    Repo = $Plan.Repo
                    Abbreviation = $Plan.Abbreviation
                    WorkshopId = $Plan.WorkshopId
                    SkymodsRevisionKey = $revisionKey
                    GitCommitSha = $commitSha
                    GitTrackedFileCount = $gitTree.Count
                    GitComparableFileCount = $comparableGitRows.Count
                    ExcludedRepositoryMetadataCount = $excludedMetadataCount
                    MatchingTrackedFileCount = $matching
                    MissingFromArchiveCount = $missing
                    BlobMismatchCount = $mismatched
                    ArchiveExtraFileCount = $archiveExtraCount
                    DescriptorWorkshopIdMatches = $descriptorMatchesWorkshopId
                    ProjectedTrackedContentMatch = $projectedExactMatch
                }
            )
        }

        $matches = @(
            $comparisonRows |
                Where-Object {
                    $_.ProjectedTrackedContentMatch -eq $true -and
                    $_.DescriptorWorkshopIdMatches -eq $true
                }
        )

        $verificationStatus = if ($matches.Count -eq 1) {
            "UNIQUE_PROJECTED_GIT_MATCH"
        }
        elseif ($matches.Count -gt 1) {
            "MULTIPLE_PROJECTED_GIT_MATCHES"
        }
        else {
            "NO_PROJECTED_GIT_MATCH"
        }

        $matchedGitCommitShas = @(
            $matches |
                ForEach-Object {
                    $_.GitCommitSha
                } |
                Select-Object -Unique
        )

        $summaryRow = [pscustomobject]@{
            Repo = $Plan.Repo
            Abbreviation = $Plan.Abbreviation
            WorkshopId = $Plan.WorkshopId
            SkymodsRevisionKey = $revisionKey
            RelatedSteamEventCount = $Plan.RelatedSteamEventCount
            RelatedSteamEventKeys = $Plan.RelatedSteamEventKeys
            CandidateGitCommitCount = $comparisonRows.Count
            ExactProjectedGitMatchCount = $matches.Count
            MatchedGitCommitShas = $matchedGitCommitShas -join "|"
            VerificationStatus = $verificationStatus
            Analysis07Reason = $Plan.Reason
        }

        Save-RevisionRecords `
            -RevisionKey $revisionKey `
            -DownloadRow $downloadRow `
            -DescriptorRow $descriptorRow `
            -ArchiveInventory $archiveInventory `
            -ComparisonRows $comparisonRows `
            -DifferenceRows $differenceRows `
            -SummaryRow $summaryRow

        $completedAt = Get-Date

        $state = [pscustomobject]@{
            Status = "COMPLETE"
            RevisionKey = $revisionKey
            Repo = $Plan.Repo
            WorkshopId = $Plan.WorkshopId
            AttemptCount = $attemptCount
            StartedAt = $startedAt.ToString("o")
            CompletedAt = $completedAt.ToString("o")
            VerificationStatus = $verificationStatus
            MatchedGitCommitShas = $matchedGitCommitShas -join "|"
            DownloadMethod = $downloadMethod
            ArchiveSha256 = $archiveSha256
            ErrorMessage = ""
        }

        Write-RevisionState `
            -RevisionKey $revisionKey `
            -State $state

        if (Test-Path -LiteralPath $extractPath) {
            Remove-Item `
                -LiteralPath $extractPath `
                -Recurse `
                -Force `
                -ErrorAction SilentlyContinue
        }

        $Result.Value = [pscustomobject]@{
            Success = $true
            RevisionKey = $revisionKey
            VerificationStatus = $verificationStatus
            DownloadMethod = $downloadMethod
            ErrorMessage = ""
        }

        return
    }
    catch {
        $message = $_.Exception.Message

        $failedState = [pscustomobject]@{
            Status = "ERROR"
            RevisionKey = $revisionKey
            Repo = $Plan.Repo
            WorkshopId = $Plan.WorkshopId
            AttemptCount = $attemptCount
            StartedAt = $startedAt.ToString("o")
            CompletedAt = (Get-Date).ToString("o")
            VerificationStatus = ""
            MatchedGitCommitShas = ""
            DownloadMethod = ""
            ArchiveSha256 = ""
            ErrorMessage = $message
        }

        Write-RevisionState `
            -RevisionKey $revisionKey `
            -State $failedState

        $Result.Value = [pscustomobject]@{
            Success = $false
            RevisionKey = $revisionKey
            VerificationStatus = ""
            DownloadMethod = ""
            ErrorMessage = $message
        }

        return
    }
}

function Rebuild-Results {
    param(
        [Parameter(Mandatory)]$FirstPassRows,
        [Parameter(Mandatory)][string]$RunId,
        [Parameter(Mandatory)][datetime]$RunStartedAt,
        [Parameter(Mandatory)][int]$ProcessedThisRun,
        [Parameter(Mandatory)][int]$FailedThisRun,
        [Parameter(Mandatory)][int]$ImportedFromAnalysis08ThisRun,
        [Parameter(Mandatory)][int]$BrowserDownloadsThisRun,
        [Parameter(Mandatory)][ref]$Result
    )

    if (Test-Path -LiteralPath $OutputDirectory) {
        Remove-Item `
            -LiteralPath $OutputDirectory `
            -Recurse `
            -Force
    }

    New-Item -ItemType Directory -Path $OutputDirectory -Force |
        Out-Null

    New-Item -ItemType Directory -Path $RawPagesDirectory -Force |
        Out-Null

    $downloads = [System.Collections.Generic.List[object]]::new()
    $descriptors = [System.Collections.Generic.List[object]]::new()
    $archiveInventory = [System.Collections.Generic.List[object]]::new()
    $comparisons = [System.Collections.Generic.List[object]]::new()
    $differences = [System.Collections.Generic.List[object]]::new()
    $revisionSummaries = [System.Collections.Generic.List[object]]::new()
    $queueSummary = [System.Collections.Generic.List[object]]::new()
    $errorRows = [System.Collections.Generic.List[object]]::new()
    $rawPageIndex = [System.Collections.Generic.List[object]]::new()

    foreach ($plan in $FirstPassRows) {
        $revisionKey = [string]$plan.SkymodsRevisionKey
        $state = Read-RevisionState $revisionKey
        $stateStatus = [string](Get-PropertyValue $state "Status" "PENDING")

        if ([string]::IsNullOrWhiteSpace($stateStatus)) {
            $stateStatus = "PENDING"
        }

        $queueSummary.Add(
            [pscustomobject]@{
                Repo = $plan.Repo
                Abbreviation = $plan.Abbreviation
                WorkshopId = $plan.WorkshopId
                SkymodsRevisionKey = $revisionKey
                VerificationPriority = $plan.VerificationPriority
                State = $stateStatus
                AttemptCount = [int](Get-PropertyValue $state "AttemptCount" 0)
                CompletedAt = [string](Get-PropertyValue $state "CompletedAt" "")
                VerificationStatus = [string](Get-PropertyValue $state "VerificationStatus" "")
                MatchedGitCommitShas = [string](Get-PropertyValue $state "MatchedGitCommitShas" "")
                DownloadMethod = [string](Get-PropertyValue $state "DownloadMethod" "")
                ErrorMessage = [string](Get-PropertyValue $state "ErrorMessage" "")
            }
        )

        if ($stateStatus -eq "ERROR") {
            $errorRows.Add(
                [pscustomobject]@{
                    Repo = $plan.Repo
                    WorkshopId = $plan.WorkshopId
                    SkymodsRevisionKey = $revisionKey
                    AttemptCount = [int](Get-PropertyValue $state "AttemptCount" 0)
                    ErrorMessage = [string](Get-PropertyValue $state "ErrorMessage" "")
                }
            )
        }

        if ($stateStatus -ne "COMPLETE") {
            continue
        }

        $record = Get-RevisionRecordDirectory $revisionKey

        foreach (
            $row in @(
                Import-CsvSafe (Join-Path $record "archive-download.csv")
            )
        ) {
            $downloads.Add($row)
        }

        foreach (
            $row in @(
                Import-CsvSafe (Join-Path $record "archive-descriptor.csv")
            )
        ) {
            $descriptors.Add($row)
        }

        foreach (
            $row in @(
                Import-CsvSafe (Join-Path $record "archive-file-inventory.csv")
            )
        ) {
            $archiveInventory.Add($row)
        }

        foreach (
            $row in @(
                Import-CsvSafe (Join-Path $record "git-content-comparisons.csv")
            )
        ) {
            $comparisons.Add($row)
        }

        foreach (
            $row in @(
                Import-CsvSafe (Join-Path $record "file-differences.csv")
            )
        ) {
            $differences.Add($row)
        }

        foreach (
            $row in @(
                Import-CsvSafe (Join-Path $record "revision-summary.csv")
            )
        ) {
            $revisionSummaries.Add($row)
        }

        $safe = Get-SafeName $revisionKey
        $cachedPages = Join-Path $BrowserPageCacheDirectory $safe
        $outputPages = Join-Path $RawPagesDirectory $safe

        if (Test-Path -LiteralPath $cachedPages) {
            Copy-DirectoryFiles `
                -SourceDirectory $cachedPages `
                -DestinationDirectory $outputPages

            foreach (
                $pageFile in @(
                    Get-ChildItem -LiteralPath $outputPages -File
                )
            ) {
                $rawPageIndex.Add(
                    [pscustomobject]@{
                        Repo = $plan.Repo
                        WorkshopId = $plan.WorkshopId
                        SkymodsRevisionKey = $revisionKey
                        RawPath = (
                            [System.IO.Path]::GetRelativePath(
                                $RepoRoot,
                                $pageFile.FullName
                            )
                        ).Replace("\", "/")
                        Bytes = $pageFile.Length
                        Sha256 = Get-Sha256 $pageFile.FullName
                    }
                )
            }
        }
    }

    $perRepoSummary = [System.Collections.Generic.List[object]]::new()

    foreach (
        $repo in @(
            $FirstPassRows.Repo |
                Select-Object -Unique
        )
    ) {
        $repoQueue = @(
            $queueSummary |
                Where-Object {
                    $_.Repo -eq $repo
                }
        )

        $repoCompleted = @(
            $repoQueue |
                Where-Object {
                    $_.State -eq "COMPLETE"
                }
        )

        $perRepoSummary.Add(
            [pscustomobject]@{
                Repo = $repo
                FirstPassRevisionCount = $repoQueue.Count
                CompleteCount = $repoCompleted.Count
                PendingCount = @(
                    $repoQueue |
                        Where-Object {
                            $_.State -eq "PENDING"
                        }
                ).Count
                ErrorCount = @(
                    $repoQueue |
                        Where-Object {
                            $_.State -eq "ERROR"
                        }
                ).Count
                UniqueMatchCount = @(
                    $repoCompleted |
                        Where-Object {
                            $_.VerificationStatus -eq
                                "UNIQUE_PROJECTED_GIT_MATCH"
                        }
                ).Count
                MultipleMatchCount = @(
                    $repoCompleted |
                        Where-Object {
                            $_.VerificationStatus -eq
                                "MULTIPLE_PROJECTED_GIT_MATCHES"
                        }
                ).Count
                NoMatchCount = @(
                    $repoCompleted |
                        Where-Object {
                            $_.VerificationStatus -eq
                                "NO_PROJECTED_GIT_MATCH"
                        }
                ).Count
            }
        )
    }

    Export-CsvSafe `
        -Rows $downloads `
        -Path (Join-Path $OutputDirectory "archive-downloads.csv")

    Export-CsvSafe `
        -Rows $descriptors `
        -Path (Join-Path $OutputDirectory "archive-descriptors.csv")

    Export-CsvSafe `
        -Rows $archiveInventory `
        -Path (Join-Path $OutputDirectory "archive-file-inventory.csv")

    Export-CsvSafe `
        -Rows $comparisons `
        -Path (Join-Path $OutputDirectory "git-content-comparisons.csv")

    Export-CsvSafe `
        -Rows $differences `
        -Path (Join-Path $OutputDirectory "file-differences.csv")

    Export-CsvSafe `
        -Rows $revisionSummaries `
        -Path (Join-Path $OutputDirectory "revision-summary.csv")

    Export-CsvSafe `
        -Rows $queueSummary `
        -Path (Join-Path $OutputDirectory "queue-summary.csv")

    Export-CsvSafe `
        -Rows $perRepoSummary `
        -Path (Join-Path $OutputDirectory "summary.csv")

    Export-CsvSafe `
        -Rows $rawPageIndex `
        -Path (Join-Path $OutputDirectory "raw-page-index.csv")

    Export-CsvSafe `
        -Rows $errorRows `
        -Path (Join-Path $OutputDirectory "errors.csv")

    $completedCount = @(
        $queueSummary |
            Where-Object {
                $_.State -eq "COMPLETE"
            }
    ).Count

    $errorCount = @(
        $queueSummary |
            Where-Object {
                $_.State -eq "ERROR"
            }
    ).Count

    $pendingCount = (
        $queueSummary.Count -
        $completedCount -
        $errorCount
    )

    $queueComplete = (
        $completedCount -eq $queueSummary.Count -and
        $errorCount -eq 0
    )

    $runCompletedAt = Get-Date

    $historyRows = @(
        Import-CsvSafe $RunHistoryPath
    )

    $newHistory = [System.Collections.Generic.List[object]]::new()

    foreach ($row in $historyRows) {
        $newHistory.Add($row)
    }

    $newHistory.Add(
        [pscustomobject]@{
            RunId = $RunId
            StartedAt = $RunStartedAt.ToString("o")
            CompletedAt = $runCompletedAt.ToString("o")
            BatchSize = $BatchSize
            ProcessedThisRun = $ProcessedThisRun
            FailedThisRun = $FailedThisRun
            ImportedFromAnalysis08ThisRun = $ImportedFromAnalysis08ThisRun
            BrowserDownloadsThisRun = $BrowserDownloadsThisRun
            QueueCompletedAfterRun = $completedCount
            QueueErrorsAfterRun = $errorCount
            QueuePendingAfterRun = $pendingCount
            QueueComplete = $queueComplete
        }
    )

    Export-CsvSafe `
        -Rows $newHistory `
        -Path $RunHistoryPath

    Export-CsvSafe `
        -Rows $newHistory `
        -Path (Join-Path $OutputDirectory "run-history.csv")

    $warningsPath = Join-Path $OutputDirectory "warnings.txt"

    [System.IO.File]::WriteAllText(
        $warningsPath,
        "",
        [System.Text.UTF8Encoding]::new($false)
    )

    $readmePath = Join-Path $OutputDirectory "README.md"

    $readme = @"
# Analysis 09 - First-Pass Archive Verification

Generated: $($runCompletedAt.ToString("yyyy-MM-dd HH:mm:ss zzz"))

This analysis expands the validated Analysis 08 archive-content pilot across the
full P0 first-pass queue produced by Analysis 07.

## Queue model

The Analysis 07 queue contains $($queueSummary.Count) P0 archive revisions.
Each invocation processes the next batch of up to $BatchSize non-complete
revisions, while any still-unprocessed Analysis 08 pilot archives are seeded
from the existing cache without redownloading them.

Per-revision state is persisted under the ignored analysis/cache directory.
Successful revisions are not reprocessed on later runs. Failed revisions remain
retryable, and already-downloaded ZIPs are reused when possible.

Current queue state:

- complete: $completedCount
- error: $errorCount
- pending: $pendingCount
- queue complete: $queueComplete

## Verification

For every completed revision, the analysis records:

- ZIP SHA-256 provenance and acquisition source
- descriptor metadata and Workshop-ID validation
- archive path/size inventory
- all related historical Git candidate commits from Analysis 07
- Git attribute-aware projected blob comparison
- unique, multiple, or absent projected Git content matches

Archive files are hashed through Git using their historical repository path so
applicable Git clean/text behavior is applied before blob comparison.

Archive-only files are retained as extras rather than treated as mismatches,
because the historical per-mod repositories may have ignored large Workshop
binary content.

This stage verifies archive-to-Git content relationships. It does not by itself
assign final Steam-event KNOWN + EXISTING or KNOWN + RECOVERED statuses.

## Resume behavior

Downloaded ZIPs, browser-page cache, per-revision state, and result fragments are
stored under analysis/cache and are ignored by Git. Extracted working copies are
removed after successful verification to avoid duplicating large archives on
disk.

The committed-style output directory is rebuilt cumulatively from completed
per-revision state after every run, so partial progress can be inspected without
losing previous successful work.

## Outputs

- archive-downloads.csv
- archive-descriptors.csv
- archive-file-inventory.csv
- git-content-comparisons.csv
- file-differences.csv
- revision-summary.csv
- queue-summary.csv
- summary.csv
- raw-page-index.csv
- raw-pages/
- errors.csv
- run-history.csv
- warnings.txt

## Current run

Run ID: $RunId
Processed this run: $ProcessedThisRun
Failed this run: $FailedThisRun
Imported from Analysis 08 cache this run: $ImportedFromAnalysis08ThisRun
Browser downloads this run: $BrowserDownloadsThisRun
"@

    $readme |
        Set-Content `
            -LiteralPath $readmePath `
            -Encoding utf8

    $Result.Value = [pscustomobject]@{
        QueueSummary = @($queueSummary)
        PerRepoSummary = @($perRepoSummary)
        CompletedCount = $completedCount
        ErrorCount = $errorCount
        PendingCount = $pendingCount
        QueueComplete = $queueComplete
        ComparisonCount = $comparisons.Count
        DifferenceCount = $differences.Count
        RawPageCount = $rawPageIndex.Count
    }

    return
}

if (-not (Test-Path -LiteralPath $DownloadPlanPath)) {
    throw "Required input not found: $DownloadPlanPath"
}

if (-not (Test-Path -LiteralPath $RepoSummaryPath)) {
    throw "Required input not found: $RepoSummaryPath"
}

foreach (
    $directory in @(
        $CacheDirectory,
        $ArchiveDirectory,
        $ExtractDirectory,
        $BrowserPageCacheDirectory,
        $RecordDirectory,
        $PackageDirectory
    )
) {
    New-Item -ItemType Directory -Path $directory -Force |
        Out-Null
}

$downloadPlan = @(Import-Csv -LiteralPath $DownloadPlanPath)
$repoSummary = @(Import-Csv -LiteralPath $RepoSummaryPath)

$firstPassRows = @(
    $downloadPlan |
        Where-Object {
            $_.VerificationPriority -eq "P0_AMBIGUOUS" -and
            $_.FirstPassRecommended -eq "True"
        }
)

if ($firstPassRows.Count -ne $ExpectedFirstPassCount) {
    throw (
        "Expected $ExpectedFirstPassCount P0 first-pass revisions " +
        "from Analysis 07, but found $($firstPassRows.Count)."
    )
}

$uniqueRevisionKeys = @(
    $firstPassRows.SkymodsRevisionKey |
        Select-Object -Unique
)

if ($uniqueRevisionKeys.Count -ne $firstPassRows.Count) {
    throw "Analysis 07 first-pass queue contains duplicate revision keys."
}

$repoByName = @{}

foreach ($row in $repoSummary) {
    $repoByName[$row.Repo] = $row
}

foreach ($plan in $firstPassRows) {
    if (-not $repoByName.ContainsKey($plan.Repo)) {
        throw "No repo-summary row exists for $($plan.Repo)."
    }
}

$seedRows = [System.Collections.Generic.List[object]]::new()
$seedKeys = [System.Collections.Generic.HashSet[string]]::new(
    [System.StringComparer]::OrdinalIgnoreCase
)

foreach ($plan in $firstPassRows) {
    $revisionKey = [string]$plan.SkymodsRevisionKey

    if (
        -not (Test-RevisionComplete $revisionKey) -and
        (Test-Analysis08ArchiveAvailable $revisionKey)
    ) {
        $seedRows.Add($plan)
        [void]$seedKeys.Add($revisionKey)
    }
}

$pendingRows = @(
    $firstPassRows |
        Where-Object {
            $revisionKey = [string]$_.SkymodsRevisionKey

            -not (Test-RevisionComplete $revisionKey) -and
            -not $seedKeys.Contains($revisionKey)
        }
)

$batchRows = @(
    $pendingRows |
        Select-Object -First $BatchSize
)

$selectedRows = [System.Collections.Generic.List[object]]::new()

foreach ($row in $seedRows) {
    $selectedRows.Add($row)
}

foreach ($row in $batchRows) {
    $selectedRows.Add($row)
}

$browserNeeded = $false

foreach ($plan in $selectedRows) {
    $safe = Get-SafeName $plan.SkymodsRevisionKey
    $archivePath = Join-Path $ArchiveDirectory "$safe.zip"

    if (
        -not (Test-ZipArchive $archivePath) -and
        -not (Test-Analysis08ArchiveAvailable $plan.SkymodsRevisionKey)
    ) {
        $browserNeeded = $true
        break
    }
}

$runStartedAt = Get-Date
$runId = $runStartedAt.ToString("yyyyMMdd-HHmmssfff")

$chromeProcess = $null
$browserSocket = $null
$pageSocket = $null
$chromeProfileDirectory = ""

$processedThisRun = 0
$failedThisRun = 0
$importedFromAnalysis08ThisRun = 0
$browserDownloadsThisRun = 0
$runErrors = [System.Collections.Generic.List[string]]::new()

try {
    if ($browserNeeded) {
        Start-CdpChrome `
            -DownloadDirectory $ArchiveDirectory `
            -Process ([ref]$chromeProcess) `
            -BrowserSocket ([ref]$browserSocket) `
            -PageSocket ([ref]$pageSocket) `
            -ProfileDirectory ([ref]$chromeProfileDirectory)
    }

    foreach ($plan in $selectedRows) {
        $revisionKey = [string]$plan.SkymodsRevisionKey
        $safe = Get-SafeName $revisionKey
        $archivePath = Join-Path $ArchiveDirectory "$safe.zip"

        Write-Host ""
        Write-Host "============================================================"
        Write-Host "First-pass revision $revisionKey"
        Write-Host "Repo: $($plan.Repo)"
        Write-Host "============================================================"

        $had09ArchiveBefore = (
            (Test-Path -LiteralPath $archivePath) -and
            (Test-ZipArchive $archivePath)
        )

        $had08Archive = Test-Analysis08ArchiveAvailable $revisionKey

        $result = $null

        $null = Invoke-RevisionVerification `
            -Plan $plan `
            -RepoInfo $repoByName[$plan.Repo] `
            -PageSocket $pageSocket `
            -Result ([ref]$result)

        if ($null -eq $result) {
            throw "Revision verification returned no result for $revisionKey."
        }

        $processedThisRun++

        if (-not $result.Success) {
            $failedThisRun++

            $runErrors.Add(
                "$($revisionKey): $($result.ErrorMessage)"
            )

            Write-Warning $result.ErrorMessage
            continue
        }

        if (
            -not $had09ArchiveBefore -and
            $had08Archive -and
            $result.DownloadMethod -eq "ANALYSIS08_CACHE"
        ) {
            $importedFromAnalysis08ThisRun++
        }

        if (
            -not $had09ArchiveBefore -and
            -not $had08Archive -and
            $result.DownloadMethod -eq "CHROME_CDP"
        ) {
            $browserDownloadsThisRun++
            Start-Sleep -Seconds 4
        }

        Write-Host "Verification: $($result.VerificationStatus)"
    }
}
finally {
    Stop-CdpChrome `
        -Process $chromeProcess `
        -BrowserSocket $browserSocket `
        -PageSocket $pageSocket `
        -ProfileDirectory $chromeProfileDirectory
}

$rebuilt = $null

$null = Rebuild-Results `
    -FirstPassRows $firstPassRows `
    -RunId $runId `
    -RunStartedAt $runStartedAt `
    -ProcessedThisRun $processedThisRun `
    -FailedThisRun $failedThisRun `
    -ImportedFromAnalysis08ThisRun $importedFromAnalysis08ThisRun `
    -BrowserDownloadsThisRun $browserDownloadsThisRun `
    -Result ([ref]$rebuilt)

if ($null -eq $rebuilt) {
    throw "Result rebuild returned no summary object."
}

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
Write-Host "================ ANALYSIS 09 RUN COMPLETE ================"
Write-Host ""

$rebuilt.PerRepoSummary |
    Format-Table `
        Repo,
        FirstPassRevisionCount,
        CompleteCount,
        PendingCount,
        ErrorCount,
        UniqueMatchCount,
        MultipleMatchCount,
        NoMatchCount `
        -AutoSize

Write-Host ""
Write-Host "First-pass revisions: $($firstPassRows.Count)"
Write-Host "Processed this run: $processedThisRun"
Write-Host "Failed this run: $failedThisRun"
Write-Host "Imported from Analysis 08 this run: $importedFromAnalysis08ThisRun"
Write-Host "Browser downloads this run: $browserDownloadsThisRun"
Write-Host "Queue completed revisions: $($rebuilt.CompletedCount)"
Write-Host "Queue errors: $($rebuilt.ErrorCount)"
Write-Host "Queue pending: $($rebuilt.PendingCount)"
Write-Host "Git comparison rows: $($rebuilt.ComparisonCount)"
Write-Host "File difference rows: $($rebuilt.DifferenceCount)"
Write-Host "Raw browser pages: $($rebuilt.RawPageCount)"
Write-Host ""

if ($failedThisRun -eq 0) {
    Write-Host "Run validation: PASS"
}
else {
    Write-Host "Run validation: FAIL"

    foreach ($errorMessage in $runErrors) {
        Write-Host "  - $errorMessage"
    }
}

Write-Host ""
Write-Host "Queue complete: $($rebuilt.QueueComplete)"

if (-not $rebuilt.QueueComplete) {
    Write-Host "Run the script again to process the next batch."
}

Write-Host ""
Write-Host "Results:"
Write-Host "  $OutputDirectory"
Write-Host ""
Write-Host "Cache:"
Write-Host "  $CacheDirectory"
Write-Host ""
Write-Host "Package:"
Write-Host "  $PackagePath"
