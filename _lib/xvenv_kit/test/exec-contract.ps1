function Test-XvenvExecContract {
    param(
        [Parameter(Mandatory = $true)][object]$BaseContext,
        [Parameter(Mandatory = $true)][string]$UnicodeSegment
    )

    Write-Host '[TEST] Non-interactive exec preserves environment, arguments, and exit codes'
    $Scratch = Join-Path `
        $KitRoot.FullName `
        ("test scratch ! & [literal] " + [Guid]::NewGuid().ToString('N'))
    try {
        [void][IO.Directory]::CreateDirectory($Scratch)
        $Probe = Join-Path $Scratch 'exec probe.ps1'
        $Output = Join-Path $Scratch 'exec output.txt'
        $SpecialArgument = "value ! & (`"$UnicodeSegment`")"
        Write-TestFile $Probe @'
param(
    [Parameter(Mandatory = $true)][string]$OutputPath,
    [Parameter(Mandatory = $true)][string]$Value
)

$Rows = @(
    "project=$env:XVENV_PROJECT_ROOT",
    "cwd=$((Get-Location).Path)",
    "argument=$Value"
)
[IO.File]::WriteAllLines($OutputPath, $Rows, [Text.UTF8Encoding]::new($false))
exit 23
'@
        $Context = New-XvenvContext `
            -WorkingDirectory $Scratch `
            -ProjectRoot $BaseContext.ProjectRoot `
            -DataRoot $BaseContext.DataRoot `
            -Catalog $BaseContext.Catalog

        $EnvironmentBeforeExec = Save-TestEnvironment
        $ProjectTreeBeforeExec = Get-TreeSnapshot $BaseContext.ProjectRoot
        try {
            $ExecExitCode = Invoke-XvenvMain `
                @('exec', $Probe, $Output, $SpecialArgument) `
                $Context
        } finally {
            Restore-TestEnvironment $EnvironmentBeforeExec
        }
        Assert-Equal $ExecExitCode 23 'exec must forward the program exit code exactly'
        $Rows = [IO.File]::ReadAllLines($Output, [Text.Encoding]::UTF8)
        Assert-Equal `
            $Rows[0] `
            "project=$($BaseContext.ProjectRoot)" `
            'exec must apply the generated project environment'
        Assert-Equal $Rows[1] "cwd=$Scratch" 'exec must preserve the invocation directory'
        Assert-Equal $Rows[2] "argument=$SpecialArgument" 'exec must preserve special-character arguments'
        Assert-Equal `
            (Get-TreeSnapshot $BaseContext.ProjectRoot) `
            $ProjectTreeBeforeExec `
            'exec must not touch the user project'

        $NativeOutput = Join-Path $Scratch 'native output.txt'
        $SystemPowerShell = Join-Path `
            $env:SystemRoot `
            'System32\WindowsPowerShell\v1.0\powershell.exe'
        $NativeExitCode = Invoke-XvenvConsoleProcess `
            -Executable $SystemPowerShell `
            -Arguments @(
                '-NoLogo',
                '-NoProfile',
                '-ExecutionPolicy',
                'Bypass',
                '-File',
                $Probe,
                $NativeOutput,
                $SpecialArgument
            ) `
            -WorkingDirectory $Scratch
        Assert-Equal $NativeExitCode 23 'the native process layer must forward exit codes'
        $NativeRows = [IO.File]::ReadAllLines($NativeOutput, [Text.Encoding]::UTF8)
        Assert-Equal `
            $NativeRows[2] `
            "argument=$SpecialArgument" `
            'the native process layer must preserve quotes and metacharacters'

        $Batch = Join-Path $Scratch 'exec exit.cmd'
        Write-TestFile $Batch "@echo off`r`nexit /b 17`r`n"
        $EnvironmentBeforeBatch = Save-TestEnvironment
        try {
            $BatchExitCode = Invoke-XvenvMain @('exec', $Batch) $Context
        } finally {
            Restore-TestEnvironment $EnvironmentBeforeBatch
        }
        Assert-Equal $BatchExitCode 17 'exec must support batch programs'

        $HandledFailure = Join-Path $Scratch 'handled failure.ps1'
        Write-TestFile $HandledFailure @'
& $env:ComSpec /d /c 'exit /b 9'
$Handled = $true
'@
        $EnvironmentBeforeHandled = Save-TestEnvironment
        try {
            $HandledExitCode = Invoke-XvenvMain @('exec', $HandledFailure) $Context
        } finally {
            Restore-TestEnvironment $EnvironmentBeforeHandled
        }
        Assert-Equal `
            $HandledExitCode `
            0 `
            'a PowerShell script may handle an internal native failure'
    } finally {
        if ([IO.Directory]::Exists($Scratch)) {
            Remove-Item -LiteralPath $Scratch -Recurse -Force
        }
    }
}
