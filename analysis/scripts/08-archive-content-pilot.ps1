Set-StrictMode -Version Latest
$ErrorActionPreference = "Stop"

$AnalysisName = "08-archive-content-pilot"

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

$PackageDirectory = Join-Path $RepoRoot "analysis\packages"
$PackagePath = Join-Path $PackageDirectory "$AnalysisName.zip"

$PilotRevisionKeys = @(
    "3206891770|2"
    "2829397295|3"
    "2996881191|3"
    "2543865921|3"
)

$script:CdpCommandId = 0

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

function Get-GitProjectedBlobSha1 {
    param(
        [Parameter(Mandatory)]
        [string]$RepositoryPath,

        [Parameter(Mandatory)]
        [string]$RelativePath,

        [Parameter(Mandatory)]
        [string]$ArchivePath
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

    return @($rows)
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
        $encodedUrl = [System.Uri]::EscapeDataString(
            "about:blank"
        )

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

                    if (
                        -not [string]::IsNullOrWhiteSpace(
                            $value
                        )
                    ) {
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
        [Parameter(Mandatory)]
        [string]$WebSocketUrl,

        [Parameter(Mandatory)]
        [ref]$Socket
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

        [AllowNull()]
        $Params = $null
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

            if (
                $response.PSObject.Properties.Name -contains "result"
            ) {
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

    if (
        $result.PSObject.Properties.Name -contains "exceptionDetails"
    ) {
        $details = $result.exceptionDetails |
            ConvertTo-Json -Depth 10 -Compress

        throw "JavaScript evaluation failed: $details"
    }

    if (
        -not (
            $result.PSObject.Properties.Name -contains "result"
        )
    ) {
        return $null
    }

    $remote = $result.result

    if (
        $remote.PSObject.Properties.Name -contains "value"
    ) {
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

        [Parameter(Mandatory)]
        [string]$Url
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

        [Parameter(Mandatory)]
        [string]$Label
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

        [Parameter(Mandatory)]
        [string]$Label,

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

        [Parameter(Mandatory)]
        [string]$Label
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

        [int]$TimeoutSeconds = 300
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
        [Parameter(Mandatory)][string]$CachePath,
        [Parameter(Mandatory)][string]$OutputPath
    )

    foreach ($path in @($CachePath, $OutputPath)) {
        $parent = Split-Path -Parent $path

        New-Item -ItemType Directory -Path $parent -Force |
            Out-Null

        [System.IO.File]::WriteAllText(
            $path,
            $Html,
            [System.Text.UTF8Encoding]::new($false)
        )
    }
}

function Copy-CachedBrowserPages {
    param(
        [Parameter(Mandatory)][string]$CacheDirectory,
        [Parameter(Mandatory)][string]$OutputDirectory
    )

    if (-not (Test-Path -LiteralPath $CacheDirectory)) {
        return @()
    }

    New-Item -ItemType Directory -Path $OutputDirectory -Force |
        Out-Null

    $copied = [System.Collections.Generic.List[string]]::new()

    foreach (
        $file in @(
            Get-ChildItem -LiteralPath $CacheDirectory -File
        )
    ) {
        $destination = Join-Path $OutputDirectory $file.Name

        Copy-Item `
            -LiteralPath $file.FullName `
            -Destination $destination `
            -Force

        $copied.Add($destination)
    }

    return @($copied)
}

if (-not (Test-Path -LiteralPath $DownloadPlanPath)) {
    throw "Required input not found: $DownloadPlanPath"
}

if (-not (Test-Path -LiteralPath $RepoSummaryPath)) {
    throw "Required input not found: $RepoSummaryPath"
}

if (Test-Path -LiteralPath $OutputDirectory) {
    Remove-Item -LiteralPath $OutputDirectory -Recurse -Force
}

New-Item -ItemType Directory -Path $OutputDirectory -Force |
    Out-Null

New-Item -ItemType Directory -Path $RawPagesDirectory -Force |
    Out-Null

foreach ($directory in @(
    $CacheDirectory,
    $ArchiveDirectory,
    $ExtractDirectory,
    $BrowserPageCacheDirectory,
    $PackageDirectory
)) {
    New-Item -ItemType Directory -Path $directory -Force |
        Out-Null
}

$downloadPlan = @(Import-Csv -LiteralPath $DownloadPlanPath)
$repoSummary = @(Import-Csv -LiteralPath $RepoSummaryPath)

$planByRevision = @{}

foreach ($row in $downloadPlan) {
    $planByRevision[$row.SkymodsRevisionKey] = $row
}

$repoByName = @{}

foreach ($row in $repoSummary) {
    $repoByName[$row.Repo] = $row
}

$warnings = [System.Collections.Generic.List[string]]::new()
$validationErrors = [System.Collections.Generic.List[string]]::new()

$downloads = [System.Collections.Generic.List[object]]::new()
$descriptors = [System.Collections.Generic.List[object]]::new()
$comparisons = [System.Collections.Generic.List[object]]::new()
$fileDifferences = [System.Collections.Generic.List[object]]::new()
$rawPageIndex = [System.Collections.Generic.List[object]]::new()

$missingArchiveCount = 0

foreach ($revisionKey in $PilotRevisionKeys) {
    $safeRevisionKey = Get-SafeName $revisionKey
    $archivePath = Join-Path $ArchiveDirectory "$safeRevisionKey.zip"

    if (
        -not (Test-Path -LiteralPath $archivePath) -or
        -not (Test-ZipArchive $archivePath)
    ) {
        $missingArchiveCount++
    }
}

$chromeProcess = $null
$browserSocket = $null
$pageSocket = $null
$chromeProfileDirectory = ""

try {
    if ($missingArchiveCount -gt 0) {
        $chromePath = Get-ChromePath
        $debugPort = Get-FreeTcpPort

        $chromeProfileDirectory = Join-Path `
            $CacheDirectory `
            "chrome-profile-$debugPort"

        New-Item `
            -ItemType Directory `
            -Path $chromeProfileDirectory `
            -Force |
            Out-Null

        $chromeArguments = @(
            "--remote-debugging-port=$debugPort"
            "--remote-debugging-address=127.0.0.1"
            "--remote-allow-origins=*"
            "--user-data-dir=$chromeProfileDirectory"
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

        $versionInfo = Wait-DevToolsEndpoint -Port $debugPort
        $pageSocketUrl = Get-CdpPageSocketUrl -Port $debugPort

        $browserSocketUrl = [string](
            $versionInfo.webSocketDebuggerUrl
        )

        if (
            [string]::IsNullOrWhiteSpace(
                $browserSocketUrl
            )
        ) {
            throw "Chrome browser WebSocket URL is missing."
        }

        $browserSocket = $null

        New-CdpSocket `
            -WebSocketUrl $browserSocketUrl `
            -Socket ([ref]$browserSocket)

        if (
            $browserSocket -isnot
            [System.Net.WebSockets.ClientWebSocket]
        ) {
            throw "Browser CDP socket initialization failed."
        }

        $pageSocket = $null

        New-CdpSocket `
            -WebSocketUrl $pageSocketUrl `
            -Socket ([ref]$pageSocket)

        if (
            $pageSocket -isnot
            [System.Net.WebSockets.ClientWebSocket]
        ) {
            throw "Page CDP socket initialization failed."
        }

        $null = Invoke-CdpCommand `
            -Socket $pageSocket `
            -Method "Page.enable" `
            -Params @{}

        $null = Invoke-CdpCommand `
            -Socket $pageSocket `
            -Method "Runtime.enable" `
            -Params @{}

        $null = Invoke-CdpCommand `
            -Socket $browserSocket `
            -Method "Browser.setDownloadBehavior" `
            -Params @{
                behavior = "allow"
                downloadPath = $ArchiveDirectory
                eventsEnabled = $true
            }
    }

    foreach ($revisionKey in $PilotRevisionKeys) {
        Write-Host ""
        Write-Host "============================================================"
        Write-Host "Pilot revision $revisionKey"
        Write-Host "============================================================"

        if (-not $planByRevision.ContainsKey($revisionKey)) {
            $validationErrors.Add(
                "Pilot revision key does not exist in Analysis 07: $revisionKey"
            )
            continue
        }

        $plan = $planByRevision[$revisionKey]

        if (
            $plan.FirstPassRecommended -ne "True" -or
            $plan.VerificationPriority -ne "P0_AMBIGUOUS"
        ) {
            $validationErrors.Add(
                "$revisionKey is not a P0 first-pass candidate."
            )
            continue
        }

        if (-not $repoByName.ContainsKey($plan.Repo)) {
            $validationErrors.Add(
                "No repo-summary row exists for $($plan.Repo)."
            )
            continue
        }

        $repoInfo = $repoByName[$plan.Repo]
        $oldRepoPath = Join-Path $OldReposRoot $repoInfo.LocalFolder

        if (-not (Test-Path -LiteralPath $oldRepoPath)) {
            $validationErrors.Add(
                "Historical repository path not found: $oldRepoPath"
            )
            continue
        }

        $safeRevisionKey = Get-SafeName $revisionKey

        $archivePath = Join-Path `
            $ArchiveDirectory `
            "$safeRevisionKey.zip"

        $extractPath = Join-Path `
            $ExtractDirectory `
            $safeRevisionKey

        $pageCacheDirectory = Join-Path `
            $BrowserPageCacheDirectory `
            $safeRevisionKey

        $rawOutputDirectory = Join-Path `
            $RawPagesDirectory `
            $safeRevisionKey

        $downloadMethod = ""

        try {
            if (
                (Test-Path -LiteralPath $archivePath) -and
                (Test-ZipArchive $archivePath)
            ) {
                $downloadMethod = "CACHE"

                Write-Host "Using cached archive."

                $copiedPages = @(
                    Copy-CachedBrowserPages `
                        -CacheDirectory $pageCacheDirectory `
                        -OutputDirectory $rawOutputDirectory
                )

                foreach ($rawPath in $copiedPages) {
                    $rawPageIndex.Add(
                        [pscustomobject]@{
                            Repo = $plan.Repo
                            WorkshopId = $plan.WorkshopId
                            SkymodsRevisionKey = $revisionKey
                            RawPath = (
                                [System.IO.Path]::GetRelativePath(
                                    $RepoRoot,
                                    $rawPath
                                )
                            ).Replace("\", "/")
                            Bytes = (
                                Get-Item -LiteralPath $rawPath
                            ).Length
                            Sha256 = Get-Sha256 $rawPath
                            Source = "BROWSER_PAGE_CACHE"
                        }
                    )
                }
            }
            else {
                if ($null -eq $pageSocket) {
                    throw "Chrome automation was not initialized."
                }

                if (Test-Path -LiteralPath $archivePath) {
                    Remove-Item -LiteralPath $archivePath -Force
                }

                Write-Host "Opening Modsbase in isolated Chrome..."

                Invoke-CdpNavigate `
                    -Socket $pageSocket `
                    -Url $plan.SkymodsDownloadUrl

                $null = Wait-CdpAction `
                    -Socket $pageSocket `
                    -Label "CREATE DOWNLOAD LINK" `
                    -TimeoutSeconds 60

                $firstHtml = Get-CdpPageHtml -Socket $pageSocket

                $firstCachePath = Join-Path `
                    $pageCacheDirectory `
                    "01-file-page.html"

                $firstOutputPath = Join-Path `
                    $rawOutputDirectory `
                    "01-file-page.html"

                Save-BrowserHtml `
                    -Html $firstHtml `
                    -CachePath $firstCachePath `
                    -OutputPath $firstOutputPath

                $rawPageIndex.Add(
                    [pscustomobject]@{
                        Repo = $plan.Repo
                        WorkshopId = $plan.WorkshopId
                        SkymodsRevisionKey = $revisionKey
                        RawPath = (
                            [System.IO.Path]::GetRelativePath(
                                $RepoRoot,
                                $firstOutputPath
                            )
                        ).Replace("\", "/")
                        Bytes = (
                            Get-Item -LiteralPath $firstOutputPath
                        ).Length
                        Sha256 = Get-Sha256 $firstOutputPath
                        Source = "CHROME_CDP"
                    }
                )

                Write-Host "Creating download link..."

                $null = Invoke-CdpClickAction `
                    -Socket $pageSocket `
                    -Label "CREATE DOWNLOAD LINK"

                Start-Sleep -Seconds 6

                $null = Wait-CdpAction `
                    -Socket $pageSocket `
                    -Label "DOWNLOAD FILE" `
                    -TimeoutSeconds 60

                $secondHtml = Get-CdpPageHtml -Socket $pageSocket

                $secondCachePath = Join-Path `
                    $pageCacheDirectory `
                    "02-download-page.html"

                $secondOutputPath = Join-Path `
                    $rawOutputDirectory `
                    "02-download-page.html"

                Save-BrowserHtml `
                    -Html $secondHtml `
                    -CachePath $secondCachePath `
                    -OutputPath $secondOutputPath

                $rawPageIndex.Add(
                    [pscustomobject]@{
                        Repo = $plan.Repo
                        WorkshopId = $plan.WorkshopId
                        SkymodsRevisionKey = $revisionKey
                        RawPath = (
                            [System.IO.Path]::GetRelativePath(
                                $RepoRoot,
                                $secondOutputPath
                            )
                        ).Replace("\", "/")
                        Bytes = (
                            Get-Item -LiteralPath $secondOutputPath
                        ).Length
                        Sha256 = Get-Sha256 $secondOutputPath
                        Source = "CHROME_CDP"
                    }
                )

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
                    [void]$beforeFiles.Add(
                        $existingFile.FullName
                    )
                }

                Write-Host "Downloading archive through Chrome..."

                $null = Invoke-CdpClickAction `
                    -Socket $pageSocket `
                    -Label "DOWNLOAD FILE"

                $downloadedPath = Wait-NewBrowserDownload `
                    -Directory $ArchiveDirectory `
                    -BeforeFiles $beforeFiles `
                    -TimeoutSeconds 600

                if (-not (Test-ZipArchive $downloadedPath)) {
                    throw (
                        "Chrome downloaded a file that is not a valid ZIP: " +
                        $downloadedPath
                    )
                }

                if (
                    -not [string]::Equals(
                        $downloadedPath,
                        $archivePath,
                        [System.StringComparison]::OrdinalIgnoreCase
                    )
                ) {
                    Move-Item `
                        -LiteralPath $downloadedPath `
                        -Destination $archivePath `
                        -Force
                }

                $downloadMethod = "CHROME_CDP"
            }

            if (-not (Test-ZipArchive $archivePath)) {
                throw "Archive cache is not a valid ZIP: $archivePath"
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
                -ExpectedWorkshopId $plan.WorkshopId

            $descriptorRelativePath = (
                [System.IO.Path]::GetRelativePath(
                    $archiveRootInfo.Root,
                    $archiveRootInfo.Descriptor
                )
            ).Replace("\", "/")

            $descriptorMatchesWorkshopId = (
                $archiveRootInfo.Metadata.RemoteFileId -eq
                $plan.WorkshopId
            )

            $archiveFiles = Get-ArchiveFilesByRelativePath `
                -ArchiveRoot $archiveRootInfo.Root

            $downloads.Add(
                [pscustomobject]@{
                    Repo = $plan.Repo
                    Abbreviation = $plan.Abbreviation
                    WorkshopId = $plan.WorkshopId
                    SkymodsRevisionKey = $revisionKey
                    SkymodsRawDisplayedTime = $plan.SkymodsRawDisplayedTime
                    SkymodsNormalizedUtcTime = $plan.SkymodsNormalizedUtcTime
                    ModsbasePageUrl = $plan.SkymodsDownloadUrl
                    DownloadMethod = $downloadMethod
                    ArchiveCachePath = (
                        [System.IO.Path]::GetRelativePath(
                            $RepoRoot,
                            $archivePath
                        )
                    ).Replace("\", "/")
                    ArchiveBytes = $archiveBytes
                    ArchiveMiB = [math]::Round(
                        $archiveBytes / 1MB,
                        3
                    )
                    ArchiveSha256 = $archiveSha256
                    ArchiveFileCount = $archiveFiles.Count
                    ArchiveRootSelection = $archiveRootInfo.Selection
                    Downloaded = $true
                    Extracted = $true
                }
            )

            $descriptors.Add(
                [pscustomobject]@{
                    Repo = $plan.Repo
                    Abbreviation = $plan.Abbreviation
                    WorkshopIdExpected = $plan.WorkshopId
                    SkymodsRevisionKey = $revisionKey
                    DescriptorPath = $descriptorRelativePath
                    DescriptorName = $archiveRootInfo.Metadata.Name
                    DescriptorVersion = $archiveRootInfo.Metadata.Version
                    DescriptorSupportedVersion = $archiveRootInfo.Metadata.SupportedVersion
                    DescriptorRemoteFileId = $archiveRootInfo.Metadata.RemoteFileId
                    DescriptorWorkshopIdMatches = $descriptorMatchesWorkshopId
                    DescriptorCountInArchive = $archiveRootInfo.DescriptorCount
                }
            )

            if (-not $descriptorMatchesWorkshopId) {
                $warnings.Add(
                    "$($revisionKey): descriptor remote_file_id " +
                    "'$($archiveRootInfo.Metadata.RemoteFileId)' " +
                    "does not match expected '$($plan.WorkshopId)'."
                )
            }

            $candidateShas = @(
                $plan.RelatedGitCommitShas -split '\|' |
                    Where-Object {
                        -not [string]::IsNullOrWhiteSpace($_)
                    } |
                    Select-Object -Unique
            )

            if ($candidateShas.Count -eq 0) {
                $validationErrors.Add(
                    "$revisionKey has no related Git commits in Analysis 07."
                )
                continue
            }

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
                    [void]$gitComparablePaths.Add(
                        $gitFile.Path
                    )

                    if (
                        -not $archiveFiles.ContainsKey(
                            $gitFile.Path
                        )
                    ) {
                        $missing++

                        $fileDifferences.Add(
                            [pscustomobject]@{
                                Repo = $plan.Repo
                                WorkshopId = $plan.WorkshopId
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

                    $archiveBlobSha = Get-GitProjectedBlobSha1 `
                        -RepositoryPath $oldRepoPath `
                        -RelativePath $gitFile.Path `
                        -ArchivePath $archiveFile.FullName

                    if (
                        $archiveBlobSha -eq
                        $gitFile.BlobSha
                    ) {
                        $matching++
                    }
                    else {
                        $mismatched++

                        $fileDifferences.Add(
                            [pscustomobject]@{
                                Repo = $plan.Repo
                                WorkshopId = $plan.WorkshopId
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

                    if (
                        -not $gitComparablePaths.Contains(
                            $archiveRelativePath
                        )
                    ) {
                        $archiveExtraCount++
                    }
                }

                $projectedExactMatch = (
                    $comparableGitRows.Count -gt 0 -and
                    $missing -eq 0 -and
                    $mismatched -eq 0
                )

                $comparisons.Add(
                    [pscustomobject]@{
                        Repo = $plan.Repo
                        Abbreviation = $plan.Abbreviation
                        WorkshopId = $plan.WorkshopId
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
        }
        catch {
            $validationErrors.Add(
                "$($revisionKey): $($_.Exception.Message)"
            )

            Write-Warning $_.Exception.Message
        }
    }
}
finally {
    foreach ($socket in @($pageSocket, $browserSocket)) {
        if ($null -ne $socket) {
            try {
                $socket.Dispose()
            }
            catch {
            }
        }
    }

    if ($null -ne $chromeProcess) {
        try {
            if (-not $chromeProcess.HasExited) {
                Stop-Process `
                    -Id $chromeProcess.Id `
                    -Force `
                    -ErrorAction SilentlyContinue
            }
        }
        catch {
        }
    }

    if (
        -not [string]::IsNullOrWhiteSpace(
            $chromeProfileDirectory
        ) -and
        (Test-Path -LiteralPath $chromeProfileDirectory)
    ) {
        Start-Sleep -Milliseconds 500

        Remove-Item `
            -LiteralPath $chromeProfileDirectory `
            -Recurse `
            -Force `
            -ErrorAction SilentlyContinue
    }
}

$pilotSummary = [System.Collections.Generic.List[object]]::new()

foreach ($revisionKey in $PilotRevisionKeys) {
    $plan = if ($planByRevision.ContainsKey($revisionKey)) {
        $planByRevision[$revisionKey]
    }
    else {
        $null
    }

    $revisionComparisons = @(
        $comparisons |
            Where-Object {
                $_.SkymodsRevisionKey -eq $revisionKey
            }
    )

    $matches = @(
        $revisionComparisons |
            Where-Object {
                $_.ProjectedTrackedContentMatch -eq $true -and
                $_.DescriptorWorkshopIdMatches -eq $true
            }
    )

    $status = if ($matches.Count -eq 1) {
        "UNIQUE_PROJECTED_GIT_MATCH"
    }
    elseif ($matches.Count -gt 1) {
        "MULTIPLE_PROJECTED_GIT_MATCHES"
    }
    elseif ($revisionComparisons.Count -gt 0) {
        "NO_PROJECTED_GIT_MATCH"
    }
    else {
        "NOT_VERIFIED"
    }

    $matchedGitCommitShas = @(
        $matches |
            ForEach-Object {
                $_.GitCommitSha
            } |
            Select-Object -Unique
    )

    $pilotSummary.Add(
        [pscustomobject]@{
            Repo = if ($null -ne $plan) {
                $plan.Repo
            }
            else {
                ""
            }
            WorkshopId = if ($null -ne $plan) {
                $plan.WorkshopId
            }
            else {
                ""
            }
            SkymodsRevisionKey = $revisionKey
            CandidateGitCommitCount = $revisionComparisons.Count
            ExactProjectedGitMatchCount = $matches.Count
            MatchedGitCommitShas = $matchedGitCommitShas -join "|"
            VerificationStatus = $status
        }
    )
}

if ($downloads.Count -ne $PilotRevisionKeys.Count) {
    $validationErrors.Add(
        "Expected $($PilotRevisionKeys.Count) pilot archives but completed $($downloads.Count)."
    )
}

if ($descriptors.Count -ne $downloads.Count) {
    $validationErrors.Add(
        "Descriptor result count does not match completed archive count."
    )
}

$badDescriptors = @(
    $descriptors |
        Where-Object {
            $_.DescriptorWorkshopIdMatches -ne $true
        }
)

if ($badDescriptors.Count -gt 0) {
    $validationErrors.Add(
        "$($badDescriptors.Count) archive descriptor(s) failed Workshop ID validation."
    )
}

$downloadsPath = Join-Path $OutputDirectory "archive-downloads.csv"
$descriptorsPath = Join-Path $OutputDirectory "archive-descriptors.csv"
$comparisonsPath = Join-Path $OutputDirectory "git-content-comparisons.csv"
$fileDifferencesPath = Join-Path $OutputDirectory "file-differences.csv"
$pilotSummaryPath = Join-Path $OutputDirectory "pilot-summary.csv"
$rawPageIndexPath = Join-Path $OutputDirectory "raw-page-index.csv"
$warningsPath = Join-Path $OutputDirectory "warnings.txt"
$readmePath = Join-Path $OutputDirectory "README.md"

$downloads |
    Export-Csv `
        -LiteralPath $downloadsPath `
        -NoTypeInformation `
        -Encoding utf8

$descriptors |
    Export-Csv `
        -LiteralPath $descriptorsPath `
        -NoTypeInformation `
        -Encoding utf8

$comparisons |
    Export-Csv `
        -LiteralPath $comparisonsPath `
        -NoTypeInformation `
        -Encoding utf8

$fileDifferences |
    Export-Csv `
        -LiteralPath $fileDifferencesPath `
        -NoTypeInformation `
        -Encoding utf8

$pilotSummary |
    Export-Csv `
        -LiteralPath $pilotSummaryPath `
        -NoTypeInformation `
        -Encoding utf8

$rawPageIndex |
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
# Analysis 08 - Archive Content Pilot

Generated: $generatedAt

This analysis performs the first archive-content verification pass for a small
set of high-value P0 candidates selected by Analysis 07.

## Pilot revisions

$($PilotRevisionKeys -join "`n")

The full first-pass queue is intentionally not downloaded here.

## Browser retrieval

Missing pilot archives are downloaded through an isolated, visible Chrome
instance controlled over the Chrome DevTools Protocol.

The Chrome instance uses a temporary non-default user-data directory and is
closed after retrieval.

For each browser retrieval, the analysis retains:

- the Modsbase file-page HTML
- the generated download-page HTML
- the downloaded ZIP SHA-256

Browser pages are also cached under analysis/cache so a later cache-only rerun
can reproduce the committed raw-page output without redownloading the archive.

Downloaded ZIPs and extracted working data remain under the ignored
analysis/cache directory and are not part of the committed analysis results.

## Historical Git comparison

The archive contents are projected onto the files tracked by each related
historical Git commit.

Root repository metadata files such as .gitignore and .gitattributes are
excluded from projected content comparison because they are repository
bookkeeping rather than Workshop snapshot content.

Files present in the archive but absent from the historical Git commit are
reported as archive extras rather than mismatches. This is intentional because
the old per-mod repositories frequently ignored large Workshop binaries.

Archive files are hashed through Git using their historical repository path so
applicable Git clean/text filters are applied before blob comparison.

A projected Git match requires:

- at least one comparable tracked file
- every comparable Git-tracked file to exist in the archive
- every comparable Git-tracked file to have the identical Git blob SHA-1
- descriptor remote_file_id to match the expected Workshop ID

This stage validates archive-to-Git content relationships only. It does not yet
assign final KNOWN + EXISTING or KNOWN + RECOVERED Steam-event statuses.

## Validation

Requested pilot revisions: $($PilotRevisionKeys.Count)
Completed archives: $($downloads.Count)
Descriptor records: $($descriptors.Count)
Git comparison rows: $($comparisons.Count)
File difference rows: $($fileDifferences.Count)
Raw browser pages: $($rawPageIndex.Count)
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
Write-Host "================ ANALYSIS 08 COMPLETE ================"
Write-Host ""

$pilotSummary |
    Format-Table `
        Repo,
        SkymodsRevisionKey,
        CandidateGitCommitCount,
        ExactProjectedGitMatchCount,
        VerificationStatus `
        -AutoSize

Write-Host ""
Write-Host "Requested pilot revisions: $($PilotRevisionKeys.Count)"
Write-Host "Completed archives: $($downloads.Count)"
Write-Host "Descriptor records: $($descriptors.Count)"
Write-Host "Git comparison rows: $($comparisons.Count)"
Write-Host "File difference rows: $($fileDifferences.Count)"
Write-Host "Raw browser pages: $($rawPageIndex.Count)"
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
Write-Host "Cache:"
Write-Host "  $CacheDirectory"
Write-Host ""
Write-Host "Package:"
Write-Host "  $PackagePath"
