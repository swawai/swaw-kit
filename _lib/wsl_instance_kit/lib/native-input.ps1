function Invoke-ExternalWithInput {
    param(
        [string]$File,
        [string[]]$CommandArgs,
        [AllowNull()] [string]$StandardInput,
        [switch]$AlwaysShow
    )

    if ($null -eq $StandardInput) {
        return (Invoke-External $File $CommandArgs -AlwaysShow:$AlwaysShow)
    }

    $resolvedFile = Resolve-NativeCommandPath $File
    $nativeCommand = Format-CommandLine $resolvedFile $CommandArgs
    if ($nativeCommand.Contains("%") -or $nativeCommand.Contains("!")) {
        Write-Fail "Native stdin command contains cmd.exe expansion characters and cannot be run safely."
        return 1
    }

    if ($AlwaysShow -or $script:Config.Verbose) {
        Write-Host $nativeCommand -ForegroundColor DarkGray
    }

    $pipeName = "wslkit-stdin-$PID-$([guid]::NewGuid().ToString('N'))"
    $pipePath = "\\.\pipe\$pipeName"
    $pipe = $null
    $process = $null

    try {
        $pipe = [System.IO.Pipes.NamedPipeServerStream]::new(
            $pipeName,
            [System.IO.Pipes.PipeDirection]::Out,
            1,
            [System.IO.Pipes.PipeTransmissionMode]::Byte,
            [System.IO.Pipes.PipeOptions]::Asynchronous
        )

        $startInfo = [System.Diagnostics.ProcessStartInfo]::new()
        $startInfo.FileName = if ([string]::IsNullOrWhiteSpace((Get-EnvOrEmpty "ComSpec"))) { "cmd.exe" } else { Get-EnvOrEmpty "ComSpec" }
        $startInfo.Arguments = "/d /c $nativeCommand < $(Format-Arg $pipePath)"
        $startInfo.UseShellExecute = $false
        $startInfo.CreateNoWindow = $false

        $process = [System.Diagnostics.Process]::Start($startInfo)
        $connect = $pipe.BeginWaitForConnection($null, $null)
        while (-not $connect.AsyncWaitHandle.WaitOne(100)) {
            if ($null -ne $process -and $process.HasExited) {
                return [int]$process.ExitCode
            }
        }
        $pipe.EndWaitForConnection($connect)

        $bytes = [System.Text.UTF8Encoding]::new($false).GetBytes($StandardInput)
        $pipe.Write($bytes, 0, $bytes.Length)
        $pipe.Flush()
        $pipe.Dispose()
        $pipe = $null
        $process.WaitForExit()
    } catch {
        Write-Fail "Failed to write native command input: $File"
        Write-Fail $_.Exception.Message
        try {
            if ($null -ne $process -and -not $process.HasExited) {
                $process.Kill()
            }
        } catch {
        }
        return 1
    } finally {
        if ($null -ne $pipe) {
            $pipe.Dispose()
        }
        if ($null -ne $process) {
            $process.Dispose()
        }
    }

    if ($null -eq $process -or $null -eq $process.ExitCode) {
        return 0
    }

    return [int]$process.ExitCode
}
