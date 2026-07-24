function Invoke-XvenvLinkTestCommand {
    param(
        [Parameter(Mandatory = $true)][object]$Context,
        [Parameter(Mandatory = $true)][scriptblock]$Command
    )

    $Saved = Save-TestEnvironment
    try {
        return & $Command
    } finally {
        Restore-TestEnvironment $Saved
    }
}

function Test-XvenvLinkContract {
    param(
        [Parameter(Mandatory = $true)][object]$BaseContext,
        [Parameter(Mandatory = $true)][string]$UnicodeSegment
    )

    Write-Host '[TEST] Explicit project link'
    $TestRoot = Split-Path $BaseContext.DataRoot -Parent
    $FakeToolbox = Join-Path $TestRoot "linked toolbox ! & % ($UnicodeSegment)"
    [void][IO.Directory]::CreateDirectory($FakeToolbox)
    $FakeEntry = Join-Path $FakeToolbox 'xvenv.ps1'
    Write-TestFile -Path $FakeEntry -Content @'
$ErrorActionPreference = 'Stop'
[IO.File]::WriteAllText(
    $env:XVENV_LINK_TEST_OUTPUT,
    $env:XVENV_LINK_PROJECT_ROOT,
    [Text.UTF8Encoding]::new($false)
)
[IO.File]::WriteAllText(
    (Join-Path (Get-Location).Path '.xvenv-link-cwd-probe'),
    'ok',
    [Text.UTF8Encoding]::new($false)
)
exit 37
'@

    $Context = New-XvenvContext `
        -WorkingDirectory $BaseContext.InvocationDirectory `
        -ProjectRoot $BaseContext.ProjectRoot `
        -ToolboxRoot $FakeToolbox `
        -DataRoot $BaseContext.DataRoot `
        -Catalog $BaseContext.Catalog

    $UnconfiguredRoot = Join-Path $TestRoot 'unconfigured link project'
    [void][IO.Directory]::CreateDirectory((Join-Path $UnconfiguredRoot '.git'))
    $Unconfigured = New-XvenvContext `
        -WorkingDirectory $UnconfiguredRoot `
        -ToolboxRoot $FakeToolbox `
        -DataRoot $BaseContext.DataRoot `
        -Catalog $BaseContext.Catalog
    Assert-Throws {
        Invoke-XvenvMain @('link') $Unconfigured
    } 'link must require an existing project environment'
    Assert-True `
        (-not [IO.File]::Exists((Join-Path $UnconfiguredRoot 'xvenv.link.cmd'))) `
        'a failed link must not touch an unconfigured project'

    $LinkPath = Join-Path $BaseContext.ProjectRoot 'xvenv.link.cmd'
    Assert-Equal `
        (Invoke-XvenvLinkTestCommand $Context {
            Invoke-XvenvMain @('link') $Context
        }.GetNewClosure()) `
        0 `
        'link must succeed for a configured and ready project'
    Assert-True ([IO.File]::Exists($LinkPath)) 'link must write its script at the project root'
    Assert-Equal `
        (Get-XvenvLinkPath $Context) `
        $LinkPath `
        'link must ignore the invocation subdirectory'

    $Content = [IO.File]::ReadAllText($LinkPath, [Text.Encoding]::UTF8)
    Assert-True `
        $Content.Contains($script:XvenvLinkMarker) `
        'the link script must carry an ownership marker'
    Assert-True `
        $Content.Contains((ConvertTo-XvenvBatchValue $FakeEntry)) `
        'the link script must pin the toolbox that created it'

    $ProbePath = Join-Path $TestRoot 'link-probe.txt'
    $env:XVENV_LINK_TEST_OUTPUT = $ProbePath
    try {
        $Output = @(
            & $env:ComSpec /d /v:off /c "call `"$LinkPath`"" 2>&1
        )
        $ExitCode = $LASTEXITCODE
    } finally {
        Remove-Item Env:XVENV_LINK_TEST_OUTPUT -ErrorAction SilentlyContinue
    }
    Assert-Equal $ExitCode 37 'the link script must forward the xvenv entry exit code'
    Assert-Equal `
        ([IO.File]::ReadAllText($ProbePath)) `
        $BaseContext.ProjectRoot `
        'the link script must preserve the configured project identity'
    Assert-True `
        ([IO.File]::Exists((Join-Path $BaseContext.ProjectRoot '.xvenv-link-cwd-probe'))) `
        'the link script must run from its linked project directory'
    Assert-Equal `
        ([string]::Join("`n", [string[]]$Output)) `
        '' `
        'a successful link script must not add parser noise'

    $LaunchCapture = [pscustomobject]@{
        Count = 0
        ProjectRoot = ''
        EntryWasRemoved = $false
        PowerShellWasRemoved = $false
        LinkRootWasRemoved = $false
    }
    $LaunchTerminal = {
        param($Executable, $Arguments, $WorkingDirectory)
        $LaunchCapture.Count++
        $LaunchCapture.ProjectRoot = [string]$env:XVENV_PROJECT_ROOT
        $LaunchCapture.EntryWasRemoved = $null -eq $env:XVENV_LINK_ENTRY
        $LaunchCapture.PowerShellWasRemoved = $null -eq $env:XVENV_LINK_POWERSHELL
        $LaunchCapture.LinkRootWasRemoved = $null -eq $env:XVENV_LINK_PROJECT_ROOT
        return 41
    }.GetNewClosure()
    $FollowLinkContext = New-XvenvContext `
        -WorkingDirectory $BaseContext.InvocationDirectory `
        -ToolboxRoot $BaseContext.ToolboxRoot `
        -DataRoot $BaseContext.DataRoot `
        -Catalog $BaseContext.Catalog `
        -LaunchTerminal $LaunchTerminal
    $SavedEnvironment = Save-TestEnvironment
    try {
        $env:XVENV_LINK_ENTRY = 'entry'
        $env:XVENV_LINK_POWERSHELL = 'powershell'
        $env:XVENV_LINK_PROJECT_ROOT = $BaseContext.ProjectRoot
        Assert-Equal `
            (Invoke-XvenvMain @('--xvenv-follow-link') $FollowLinkContext) `
            41 `
            'the private linked launch must forward the terminal exit code'
    } finally {
        Restore-TestEnvironment $SavedEnvironment
    }
    Assert-Equal $LaunchCapture.Count 1 'the private linked launch must open one terminal'
    Assert-Equal `
        $LaunchCapture.ProjectRoot `
        $BaseContext.ProjectRoot `
        'the private linked launch must use the pinned project identity'
    Assert-True `
        ($LaunchCapture.EntryWasRemoved -and
            $LaunchCapture.PowerShellWasRemoved -and
            $LaunchCapture.LinkRootWasRemoved) `
        'private link variables must not leak into the interactive terminal'

    $KnownTimestamp = [DateTime]::new(
        2001,
        2,
        3,
        4,
        5,
        6,
        [DateTimeKind]::Utc
    )
    [IO.File]::SetLastWriteTimeUtc($LinkPath, $KnownTimestamp)
    Assert-Equal `
        (Invoke-XvenvLinkTestCommand $Context {
            Invoke-XvenvMain @('link') $Context
        }.GetNewClosure()) `
        0 `
        'an up-to-date link must succeed'
    Assert-Equal `
        ([IO.File]::GetLastWriteTimeUtc($LinkPath)) `
        $KnownTimestamp `
        'an up-to-date link must not rewrite its script'

    $Generated = [IO.File]::ReadAllText($LinkPath, [Text.Encoding]::UTF8)
    Write-TestFile -Path $LinkPath -Content "$Generated`r`nrem obsolete generated content`r`n"
    Assert-Equal `
        (Invoke-XvenvLinkTestCommand $Context {
            Invoke-XvenvMain @('link') $Context
        }.GetNewClosure()) `
        0 `
        'link must refresh an older generated script'
    Assert-Equal `
        ([IO.File]::ReadAllText($LinkPath, [Text.Encoding]::UTF8)) `
        $Generated `
        'refresh must restore the exact current link script'

    Write-TestFile -Path $LinkPath -Content '@echo off'
    Assert-Throws {
        Invoke-XvenvLinkTestCommand $Context {
            Invoke-XvenvMain @('link') $Context
        }.GetNewClosure()
    } 'link must not overwrite a user-owned file'
    Assert-Equal `
        ([IO.File]::ReadAllText($LinkPath, [Text.Encoding]::UTF8)) `
        '@echo off' `
        'a rejected link must preserve the user-owned file'

    $Spoofed = "@echo off`r`necho user file`r`n$script:XvenvLinkMarker`r`n"
    Write-TestFile -Path $LinkPath -Content $Spoofed
    Assert-Throws {
        Invoke-XvenvLinkTestCommand $Context {
            Invoke-XvenvMain @('link') $Context
        }.GetNewClosure()
    } 'an ownership marker outside the generated header must not authorize replacement'
    Assert-Equal `
        ([IO.File]::ReadAllText($LinkPath, [Text.Encoding]::UTF8)) `
        $Spoofed `
        'a marker-spoofing file must be preserved'
}
