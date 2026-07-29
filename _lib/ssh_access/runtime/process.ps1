Set-StrictMode -Version 2.0

function ConvertTo-SshAccessWindowsArgument {
    param(
        [Parameter(Mandatory = $true)]
        [AllowEmptyString()]
        [string]$Value
    )

    if ($Value.Length -gt 0 -and $Value -notmatch '[\s"]') {
        return $Value
    }

    $Builder = New-Object Text.StringBuilder
    [void]$Builder.Append('"')
    $Backslashes = 0
    foreach ($Character in $Value.ToCharArray()) {
        if ($Character -eq [char]'\') {
            $Backslashes++
            continue
        }
        if ($Character -eq [char]'"') {
            [void]$Builder.Append([char]'\', $Backslashes * 2 + 1)
            [void]$Builder.Append('"')
            $Backslashes = 0
            continue
        }
        if ($Backslashes -gt 0) {
            [void]$Builder.Append([char]'\', $Backslashes)
            $Backslashes = 0
        }
        [void]$Builder.Append($Character)
    }
    if ($Backslashes -gt 0) {
        [void]$Builder.Append([char]'\', $Backslashes * 2)
    }
    [void]$Builder.Append('"')
    return $Builder.ToString()
}

function ConvertTo-SshAccessWindowsArguments {
    param(
        [Parameter(Mandatory = $true)]
        [AllowEmptyCollection()]
        [AllowEmptyString()]
        [string[]]$Arguments
    )

    $Encoded = foreach ($Argument in @($Arguments)) {
        ConvertTo-SshAccessWindowsArgument -Value ([string]$Argument)
    }
    return [string]::Join(' ', [string[]]@($Encoded))
}

function Resolve-SshAccessOpenSshExecutable {
    param(
        [Parameter(Mandatory = $true)][pscustomobject]$Context,
        [Parameter(Mandatory = $true)]
        [ValidateSet('ssh.exe', 'sshd.exe', 'ssh-add.exe', 'ssh-keygen.exe')]
        [string]$Name
    )

    $Path = Join-Path (Join-Path $Context.WindowsRoot 'System32\OpenSSH') $Name
    if (-not (Test-Path -LiteralPath $Path -PathType Leaf)) {
        $Feature = if ($Name -eq 'sshd.exe') { 'Server' } else { 'Client' }
        throw "Windows OpenSSH executable not found: $Path. Install the Windows OpenSSH $Feature first."
    }
    return $Path
}

function Invoke-SshAccessConsoleProcess {
    param(
        [Parameter(Mandatory = $true)][string]$Executable,
        [Parameter(Mandatory = $true)]
        [AllowEmptyCollection()]
        [AllowEmptyString()]
        [string[]]$Arguments,
        [string]$WorkingDirectory = (Get-Location).Path
    )

    $StartInfo = New-Object Diagnostics.ProcessStartInfo
    $StartInfo.FileName = $Executable
    $StartInfo.Arguments = ConvertTo-SshAccessWindowsArguments -Arguments $Arguments
    if ($StartInfo.Arguments.Length -gt 32000) {
        throw 'The child process arguments exceed the Windows command-line limit.'
    }
    $StartInfo.WorkingDirectory = $WorkingDirectory
    $StartInfo.UseShellExecute = $false
    $StartInfo.CreateNoWindow = $false

    $Process = [Diagnostics.Process]::Start($StartInfo)
    if ($null -eq $Process) {
        throw "Failed to start: $Executable"
    }
    try {
        $Process.WaitForExit()
        return [int]$Process.ExitCode
    } finally {
        $Process.Dispose()
    }
}

function Invoke-SshAccessCapturedProcess {
    param(
        [Parameter(Mandatory = $true)][string]$Executable,
        [Parameter(Mandatory = $true)]
        [AllowEmptyCollection()]
        [AllowEmptyString()]
        [string[]]$Arguments,
        [string]$WorkingDirectory = (Get-Location).Path
    )

    $StartInfo = New-Object Diagnostics.ProcessStartInfo
    $StartInfo.FileName = $Executable
    $StartInfo.Arguments = ConvertTo-SshAccessWindowsArguments -Arguments $Arguments
    if ($StartInfo.Arguments.Length -gt 32000) {
        throw 'The child process arguments exceed the Windows command-line limit.'
    }
    $StartInfo.WorkingDirectory = $WorkingDirectory
    $StartInfo.UseShellExecute = $false
    $StartInfo.CreateNoWindow = $true
    $StartInfo.RedirectStandardOutput = $true
    $StartInfo.RedirectStandardError = $true
    $StartInfo.StandardOutputEncoding = [Text.Encoding]::UTF8
    $StartInfo.StandardErrorEncoding = [Text.Encoding]::UTF8

    $Process = [Diagnostics.Process]::Start($StartInfo)
    if ($null -eq $Process) {
        throw "Failed to start: $Executable"
    }
    try {
        $StdOutTask = $Process.StandardOutput.ReadToEndAsync()
        $StdErrTask = $Process.StandardError.ReadToEndAsync()
        $Process.WaitForExit()
        return [pscustomobject]@{
            ExitCode = [int]$Process.ExitCode
            StdOut   = $StdOutTask.Result
            StdErr   = $StdErrTask.Result
        }
    } finally {
        $Process.Dispose()
    }
}
