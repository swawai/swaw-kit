function Initialize-WslDoctorState {
    $script:WslDoctorStats = [ordered]@{
        OK = 0
        WARN = 0
        FAIL = 0
    }
}


function Get-WslDoctorColor {
    param([string]$Level)

    switch ($Level) {
        "OK" { return "Green" }
        "WARN" { return "Yellow" }
        "FAIL" { return "Red" }
        default { return "Gray" }
    }
}


function Write-WslDoctorSection {
    param([string]$Title)

    Write-Host ""
    Write-Host $Title
}


function Write-WslDoctorDetail {
    param([AllowNull()] [string]$Message)

    if ([string]::IsNullOrWhiteSpace($Message)) {
        return
    }

    foreach ($line in @($Message -split "\r?\n")) {
        if ([string]::IsNullOrWhiteSpace($line)) {
            continue
        }

        Write-Host "       $line" -ForegroundColor DarkGray
    }
}


function Add-WslDoctorResult {
    param(
        [ValidateSet("OK", "WARN", "FAIL")]
        [string]$Level,
        [string]$Label,
        [AllowNull()] [string]$Message,
        [AllowNull()] [string]$Detail
    )

    if ($null -eq $script:WslDoctorStats) {
        Initialize-WslDoctorState
    }

    $script:WslDoctorStats[$Level] = [int]$script:WslDoctorStats[$Level] + 1

    $line = "  [{0}] {1}" -f $Level, $Label
    if (-not [string]::IsNullOrWhiteSpace($Message)) {
        $line = "$line - $Message"
    }

    Write-Host $line -ForegroundColor (Get-WslDoctorColor $Level)
    Write-WslDoctorDetail $Detail
}


function Add-WslDoctorOk {
    param(
        [string]$Label,
        [AllowNull()] [string]$Message,
        [AllowNull()] [string]$Detail
    )

    Add-WslDoctorResult "OK" $Label $Message $Detail
}


function Add-WslDoctorWarn {
    param(
        [string]$Label,
        [AllowNull()] [string]$Message,
        [AllowNull()] [string]$Detail
    )

    Add-WslDoctorResult "WARN" $Label $Message $Detail
}


function Add-WslDoctorFail {
    param(
        [string]$Label,
        [AllowNull()] [string]$Message,
        [AllowNull()] [string]$Detail
    )

    Add-WslDoctorResult "FAIL" $Label $Message $Detail
}


function Format-WslDoctorLines {
    param(
        [string[]]$Lines,
        [int]$MaxLines = 3
    )

    $items = @($Lines | Where-Object { -not [string]::IsNullOrWhiteSpace($_) } | Select-Object -First $MaxLines)
    if ($items.Count -eq 0) {
        return ""
    }

    return ($items -join "`n")
}


function Format-WslDoctorByteSize {
    param([AllowNull()] [object]$Bytes)

    return (Format-WslByteSize $Bytes)
}


function Get-WslDoctorDownloadSpeedAssessment {
    param([double]$BytesPerSecond)

    $oneMb = 1024 * 1024
    $oneHundredKb = 100 * 1024

    if ($BytesPerSecond -ge $oneMb) {
        return [pscustomobject]@{
            Level = "OK"
            Message = "usable"
            Detail = ""
        }
    }

    if ($BytesPerSecond -ge $oneHundredKb) {
        return [pscustomobject]@{
            Level = "WARN"
            Message = "slow; full image download may be fragile"
            Detail = "Network throughput is below 1 MB/s. Large WSL images may time out or take a long time to install."
        }
    }

    return [pscustomobject]@{
        Level = "WARN"
        Message = "very slow; full image download will likely fail or time out"
        Detail = "Network throughput is below 100 KB/s. Use a better network, proxy, or cached/fallback image before installing."
    }
}


function Get-WslDoctorNearestExistingDirectory {
    param([string]$Path)

    if ([string]::IsNullOrWhiteSpace($Path)) {
        return ""
    }

    $candidate = [System.IO.Path]::GetFullPath($Path)
    while (-not [string]::IsNullOrWhiteSpace($candidate)) {
        if (Test-Path -LiteralPath $candidate -PathType Container) {
            return $candidate
        }

        $parent = Split-Path -Parent $candidate
        if ([string]::IsNullOrWhiteSpace($parent) -or $parent -eq $candidate) {
            break
        }

        $candidate = $parent
    }

    return ""
}


function Test-WslDoctorDirectoryWritable {
    param([string]$Path)

    if ([string]::IsNullOrWhiteSpace($Path) -or -not (Test-Path -LiteralPath $Path -PathType Container)) {
        return $false
    }

    $probe = Join-Path $Path (".wslkit-doctor-{0}.tmp" -f ([guid]::NewGuid().ToString("N")))
    try {
        [System.IO.File]::WriteAllText($probe, "ok", [System.Text.UTF8Encoding]::new($false))
        return $true
    } catch {
        return $false
    } finally {
        if (Test-Path -LiteralPath $probe -PathType Leaf) {
            Remove-Item -LiteralPath $probe -Force -ErrorAction SilentlyContinue
        }
    }
}


function Get-WslDoctorDriveFreeSpace {
    param([string]$Path)

    try {
        $root = [System.IO.Path]::GetPathRoot([System.IO.Path]::GetFullPath($Path))
        if ([string]::IsNullOrWhiteSpace($root)) {
            return $null
        }

        $drive = [System.IO.DriveInfo]::new($root)
        if (-not $drive.IsReady) {
            return $null
        }

        return [int64]$drive.AvailableFreeSpace
    } catch {
        return $null
    }
}


function Test-WslDoctorCurrentUserIsAdmin {
    try {
        $identity = [Security.Principal.WindowsIdentity]::GetCurrent()
        $principal = [Security.Principal.WindowsPrincipal]::new($identity)
        return $principal.IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)
    } catch {
        return $false
    }
}


function Get-WslDoctorFeatureState {
    param([string]$Name)

    if (-not (Get-Command Get-WindowsOptionalFeature -ErrorAction SilentlyContinue)) {
        return [pscustomobject]@{
            State = ""
            Reason = "Get-WindowsOptionalFeature is unavailable."
            NeedsElevation = $false
        }
    }

    try {
        $feature = Get-WindowsOptionalFeature -Online -FeatureName $Name -ErrorAction Stop
        if ($null -ne $feature -and $null -ne $feature.State) {
            return [pscustomobject]@{
                State = [string]$feature.State
                Reason = ""
                NeedsElevation = $false
            }
        }
    } catch {
        $message = $_.Exception.Message
        $needsElevation = ((-not (Test-WslDoctorCurrentUserIsAdmin)) -or $message -match 'requires elevation|elevated permissions|error:\s*740|error 740')
        return [pscustomobject]@{
            State = ""
            Reason = $message
            NeedsElevation = $needsElevation
        }
    }

    return [pscustomobject]@{
        State = ""
        Reason = "Feature state was not returned."
        NeedsElevation = $false
    }
}


function Test-WslDoctorRebootPending {
    return ((Get-WslDoctorRebootPendingSignals).Count -gt 0)
}


function Get-WslDoctorRebootPendingSignals {
    $signals = New-Object System.Collections.ArrayList
    try {
        if (Test-Path "HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Component Based Servicing\RebootPending") {
            [void]$signals.Add("Component Based Servicing\\RebootPending")
        }
        if (Test-Path "HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\WindowsUpdate\Auto Update\RebootRequired") {
            [void]$signals.Add("WindowsUpdate\\Auto Update\\RebootRequired")
        }

        $sessionManager = Get-ItemProperty -Path "HKLM:\SYSTEM\CurrentControlSet\Control\Session Manager" -ErrorAction SilentlyContinue
        if ($null -ne $sessionManager -and $null -ne $sessionManager.PendingFileRenameOperations) {
            $pendingRenames = @($sessionManager.PendingFileRenameOperations | Where-Object { -not [string]::IsNullOrWhiteSpace($_) })
            $renameDetail = "Session Manager\\PendingFileRenameOperations ($($pendingRenames.Count) item(s))"
            $sample = @($pendingRenames | Select-Object -First 5)
            if ($sample.Count -gt 0) {
                $renameDetail = "$renameDetail`n" + (($sample | ForEach-Object { "  $_" }) -join "`n")
                if ($pendingRenames.Count -gt $sample.Count) {
                    $renameDetail = "$renameDetail`n  ... $($pendingRenames.Count - $sample.Count) more item(s)"
                }
            }

            [void]$signals.Add($renameDetail)
        }
    } catch {
    }

    return @($signals)
}


function Read-WslDoctorDistributionInfo {
    $path = $script:WslDistributionInfoPath
    try {
        if (-not (Test-Path -LiteralPath $path -PathType Leaf)) {
            return $null
        }

        return ([System.IO.File]::ReadAllText($path, [System.Text.Encoding]::UTF8) | ConvertFrom-Json)
    } catch {
        return $null
    }
}


function Get-WslDoctorInstallArchitectureKey {
    $arch = [System.Runtime.InteropServices.RuntimeInformation]::OSArchitecture.ToString().ToLowerInvariant()
    switch ($arch) {
        { $_ -in @("x64", "x86_64", "amd64") } { return "Amd64Url" }
        { $_ -in @("arm64", "aarch64") } { return "Arm64Url" }
        default { return "" }
    }
}


function Get-WslDoctorFallbackDownload {
    param(
        [pscustomobject]$DistributionInfo,
        [string]$DistroName
    )

    if ($null -eq $DistributionInfo -or [string]::IsNullOrWhiteSpace($DistroName)) {
        return $null
    }

    $modernKey = Get-WslDoctorInstallArchitectureKey
    if ([string]::IsNullOrWhiteSpace($modernKey)) {
        return $null
    }

    $modern = Find-WslModernDistribution $DistributionInfo $DistroName
    if ($null -ne $modern) {
        $urlInfo = $modern.$modernKey
        if ($null -eq $urlInfo -or [string]::IsNullOrWhiteSpace($urlInfo.Url)) {
            return $null
        }

        return [pscustomobject]@{
            Name = $modern.Name
            FriendlyName = $modern.FriendlyName
            Url = $urlInfo.Url
            Sha256 = $urlInfo.Sha256
        }
    }

    $legacy = Find-WslLegacyDistribution $DistributionInfo $DistroName
    if ($null -eq $legacy) {
        return $null
    }

    $legacyUrl = if ($modernKey -eq "Arm64Url") { $legacy.Arm64PackageUrl } else { $legacy.Amd64PackageUrl }
    if ([string]::IsNullOrWhiteSpace($legacyUrl)) {
        return $null
    }

    return [pscustomobject]@{
        Name = $legacy.Name
        FriendlyName = $legacy.FriendlyName
        Url = $legacyUrl
        Sha256 = ""
    }
}


function Test-WslDoctorOnlineListContainsSource {
    param(
        [string[]]$Lines,
        [string]$Source
    )

    if ([string]::IsNullOrWhiteSpace($Source)) {
        return $false
    }

    foreach ($line in @($Lines)) {
        $text = ([string]$line).Trim()
        if ([string]::IsNullOrWhiteSpace($text)) {
            continue
        }

        if ($text.Equals($Source, [System.StringComparison]::OrdinalIgnoreCase)) {
            return $true
        }

        if ($text.StartsWith("$Source ", [System.StringComparison]::OrdinalIgnoreCase)) {
            return $true
        }

        if ($text.IndexOf($Source, [System.StringComparison]::OrdinalIgnoreCase) -ge 0) {
            return $true
        }
    }

    return $false
}


function Invoke-WslDoctorUrlProbe {
    param(
        [string]$Url,
        [int]$TimeoutSeconds = 12
    )

    try {
        Add-Type -AssemblyName System.Net.Http -ErrorAction SilentlyContinue
        try {
            [Net.ServicePointManager]::SecurityProtocol = [Net.ServicePointManager]::SecurityProtocol -bor [Net.SecurityProtocolType]::Tls12
        } catch {
        }

        $handler = [System.Net.Http.HttpClientHandler]::new()
        $handler.AllowAutoRedirect = $true
        $client = [System.Net.Http.HttpClient]::new($handler)
        $client.Timeout = [TimeSpan]::FromSeconds($TimeoutSeconds)

        try {
            foreach ($method in @("HEAD", "GET")) {
                $request = [System.Net.Http.HttpRequestMessage]::new([System.Net.Http.HttpMethod]::new($method), $Url)
                if ($method -eq "GET") {
                    $request.Headers.Range = [System.Net.Http.Headers.RangeHeaderValue]::new(0, 0)
                }

                try {
                    $response = $client.SendAsync($request, [System.Net.Http.HttpCompletionOption]::ResponseHeadersRead).GetAwaiter().GetResult()
                    try {
                        $code = [int]$response.StatusCode
                        if ($code -ge 200 -and $code -lt 400) {
                            return [pscustomobject]@{
                                Success = $true
                                StatusCode = $code
                                Reason = $response.ReasonPhrase
                                Method = $method
                                Error = ""
                            }
                        }

                        if ($method -eq "GET" -or $code -notin @(403, 405, 501)) {
                            return [pscustomobject]@{
                                Success = $false
                                StatusCode = $code
                                Reason = $response.ReasonPhrase
                                Method = $method
                                Error = ""
                            }
                        }
                    } finally {
                        $response.Dispose()
                    }
                } catch {
                    if ($method -eq "GET") {
                        return [pscustomobject]@{
                            Success = $false
                            StatusCode = 0
                            Reason = ""
                            Method = $method
                            Error = $_.Exception.Message
                        }
                    }
                } finally {
                    $request.Dispose()
                }
            }
        } finally {
            $client.Dispose()
            $handler.Dispose()
        }
    } catch {
        return [pscustomobject]@{
            Success = $false
            StatusCode = 0
            Reason = ""
            Method = ""
            Error = $_.Exception.Message
        }
    }

    return [pscustomobject]@{
        Success = $false
        StatusCode = 0
        Reason = ""
        Method = ""
        Error = "No HTTP response."
    }
}


function Invoke-WslDoctorDownloadSample {
    param(
        [string]$Url,
        [int]$Seconds = 15
    )

    $bytesRead = [int64]0
    $elapsedSeconds = 0.0
    $completed = $false
    $statusCode = 0
    $reason = ""

    try {
        Add-Type -AssemblyName System.Net.Http -ErrorAction SilentlyContinue
        try {
            [Net.ServicePointManager]::SecurityProtocol = [Net.ServicePointManager]::SecurityProtocol -bor [Net.SecurityProtocolType]::Tls12
        } catch {
        }

        $handler = [System.Net.Http.HttpClientHandler]::new()
        $handler.AllowAutoRedirect = $true
        $client = [System.Net.Http.HttpClient]::new($handler)
        $client.Timeout = [TimeSpan]::FromSeconds($Seconds + 20)

        $request = [System.Net.Http.HttpRequestMessage]::new([System.Net.Http.HttpMethod]::Get, $Url)
        $response = $null
        $stream = $null
        $timer = [System.Diagnostics.Stopwatch]::StartNew()
        $cts = [System.Threading.CancellationTokenSource]::new([TimeSpan]::FromSeconds($Seconds))
        try {
            $response = $client.SendAsync($request, [System.Net.Http.HttpCompletionOption]::ResponseHeadersRead).GetAwaiter().GetResult()
            $statusCode = [int]$response.StatusCode
            $reason = $response.ReasonPhrase
            if ($statusCode -lt 200 -or $statusCode -ge 400) {
                $timer.Stop()
                return [pscustomobject]@{
                    Success = $false
                    Bytes = [int64]0
                    Seconds = [double]$timer.Elapsed.TotalSeconds
                    BytesPerSecond = [double]0
                    Completed = $false
                    StatusCode = $statusCode
                    Reason = $reason
                    Error = ""
                }
            }

            $stream = $response.Content.ReadAsStreamAsync().GetAwaiter().GetResult()
            $buffer = New-Object byte[] 65536
            while ($true) {
                try {
                    $read = $stream.ReadAsync($buffer, 0, $buffer.Length, $cts.Token).GetAwaiter().GetResult()
                } catch [System.OperationCanceledException] {
                    break
                }

                if ($read -le 0) {
                    $completed = $true
                    break
                }

                $bytesRead += [int64]$read
            }
        } finally {
            $timer.Stop()
            $elapsedSeconds = [double]$timer.Elapsed.TotalSeconds
            if ($null -ne $cts) {
                $cts.Dispose()
            }
            if ($null -ne $stream) {
                $stream.Dispose()
            }
            if ($null -ne $response) {
                $response.Dispose()
            }
            $request.Dispose()
            $client.Dispose()
            $handler.Dispose()
        }
    } catch {
        $secondsValue = if ($elapsedSeconds -gt 0) { $elapsedSeconds } else { 0.0 }
        return [pscustomobject]@{
            Success = $false
            Bytes = $bytesRead
            Seconds = $secondsValue
            BytesPerSecond = [double]0
            Completed = $completed
            StatusCode = $statusCode
            Reason = $reason
            Error = $_.Exception.Message
        }
    }

    $secondsForRate = [Math]::Max(0.001, $elapsedSeconds)
    return [pscustomobject]@{
        Success = ($bytesRead -gt 0 -or $completed)
        Bytes = $bytesRead
        Seconds = $elapsedSeconds
        BytesPerSecond = ([double]$bytesRead / $secondsForRate)
        Completed = $completed
        StatusCode = $statusCode
        Reason = $reason
        Error = ""
    }
}
