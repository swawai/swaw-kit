. (Join-Path $PSScriptRoot 'helpers.ps1')
. (Join-Path $PSScriptRoot 'exec-contract.ps1')
. (Join-Path $PSScriptRoot 'link-contract.ps1')

$UnicodeSegment = [string]([char]0x4E2D) + [string]([char]0x6587)
$TempRoot = Join-Path (
    [IO.Path]::GetTempPath()
) ("xvenv smoke ! & ('$UnicodeSegment') " + [Guid]::NewGuid().ToString('N'))
$BatchVerifier = $null
$SavedEnvironment = Save-TestEnvironment

try {
    [void][IO.Directory]::CreateDirectory($TempRoot)
    $FixtureRoot = Join-Path $TempRoot 'fixtures'
    [void][IO.Directory]::CreateDirectory($FixtureRoot)

    $FixtureZips = @{
        bun = Join-Path $FixtureRoot 'bun.zip'
        pwsh = Join-Path $FixtureRoot 'pwsh.zip'
        uv = Join-Path $FixtureRoot 'uv.zip'
        go = Join-Path $FixtureRoot 'go.zip'
    }
    New-TestZip $FixtureRoot $FixtureZips.bun @('bun-windows-x64\bun.exe')
    New-TestZip $FixtureRoot $FixtureZips.pwsh @('pwsh.exe')
    New-TestZip $FixtureRoot $FixtureZips.uv @('uv.exe')
    New-TestZip $FixtureRoot $FixtureZips.go @('go\bin\go.exe')

    $Catalog = Import-XvenvModuleCatalog (Join-Path $KitRoot.FullName 'modules')
    foreach ($Name in @('bun', 'pwsh', 'go')) {
        $Definition = $Catalog.Tools[$Name]
        $Definition.Url = $FixtureZips[$Name]
        $Definition.Hashes[$Definition.Version] = (
            Get-FileHash $FixtureZips[$Name] -Algorithm SHA256
        ).Hash.ToLowerInvariant()
    }
    $Catalog.Components.uv.Url = $FixtureZips.uv
    $Catalog.Components.uv.Hashes[$Catalog.Components.uv.Version] = (
        Get-FileHash $FixtureZips.uv -Algorithm SHA256
    ).Hash.ToLowerInvariant()

    Write-Host '[TEST] Project boundary and read-only unconfigured status'
    $BoundaryRoot = Join-Path $TempRoot 'boundary'
    $ParentProject = Join-Path $BoundaryRoot 'parent'
    $ChildProject = Join-Path $ParentProject 'child'
    $DeepDirectory = Join-Path $ChildProject 'src\deep'
    [void][IO.Directory]::CreateDirectory((Join-Path $ParentProject '.git'))
    [void][IO.Directory]::CreateDirectory($DeepDirectory)
    Write-TestFile (Join-Path $ChildProject '.git') 'gitdir: elsewhere'
    Assert-Equal (Resolve-XvenvProjectRoot $DeepDirectory) $ChildProject 'nearest Git boundary must win'
    Assert-Equal `
        (Get-XvenvProjectId "$ChildProject\.") `
        (Get-XvenvProjectId $ChildProject.ToUpperInvariant()) `
        'project IDs must normalize paths'

    $NoMarker = Join-Path $TempRoot 'no marker\subdir'
    [void][IO.Directory]::CreateDirectory($NoMarker)
    Write-TestFile (Join-Path (Split-Path $NoMarker) 'xvenv.json') '{}'
    Assert-Equal (Resolve-XvenvProjectRoot $NoMarker) $NoMarker 'xvenv.json is not a project marker'
    $Unconfigured = New-XvenvContext `
        -WorkingDirectory $NoMarker `
        -DataRoot (Join-Path $TempRoot 'data') `
        -Catalog $Catalog
    Assert-Equal (Invoke-XvenvStatus $Unconfigured) 0 'unconfigured status must succeed'
    $UnconfiguredReport = Get-XvenvStatusReport $Unconfigured
    Assert-Equal $UnconfiguredReport.schema 'xvenv.status.v1' 'status report must publish its schema'
    Assert-True (-not $UnconfiguredReport.configured) 'status report must mark an untouched project unconfigured'
    Assert-True (-not $UnconfiguredReport.ready) 'an unconfigured environment cannot be ready'
    Assert-Equal @($UnconfiguredReport.tools).Count 0 'an unconfigured environment must report no tools'
    $ToolsReport = Get-XvenvToolsReport $Catalog
    Assert-Equal $ToolsReport.schema 'xvenv.tools.v1' 'tools report must publish its schema'
    Assert-Equal `
        ([string]::Join(',', [string[]]@($ToolsReport.tools | ForEach-Object { $_.name }))) `
        'bun,pwsh,python,go' `
        'tools report must preserve catalog order'
    Assert-True `
        (-not [IO.Directory]::Exists($Unconfigured.ProjectDataRoot)) `
        'unconfigured status must not create project data'

    Write-Host '[TEST] Declarative set compiles central environment scripts'
    $ProjectRoot = Join-Path $TempRoot 'project A'
    $InvocationDirectory = Join-Path $ProjectRoot 'src\feature'
    [void][IO.Directory]::CreateDirectory((Join-Path $ProjectRoot '.git'))
    [void][IO.Directory]::CreateDirectory($InvocationDirectory)

    $RunExternal = {
        param($FilePath, $Arguments, $Environment)
        if ($FilePath -eq 'unused.exe') {
            throw 'fixture external failure'
        }
        $Venv = [string]$Arguments[1]
        $Version = [string]$Arguments[3]
        $Scripts = Join-Path $Venv 'Scripts'
        $PythonHome = Join-Path ([string]$Environment.UV_PYTHON_INSTALL_DIR) "cpython-$Version-fixture"
        [void][IO.Directory]::CreateDirectory($Scripts)
        [void][IO.Directory]::CreateDirectory($PythonHome)
        Write-TestFile (Join-Path $Scripts 'python.exe') 'fixture python launcher'
        Write-TestFile (Join-Path $PythonHome 'python.exe') 'fixture managed python'
        Write-TestFile `
            (Join-Path $Venv 'pyvenv.cfg') `
            "home = $PythonHome`r`nversion_info = $Version.0`r`n"
        return 0
    }.GetNewClosure()
    $Capture = [pscustomobject]@{
        Count = 0
        Executable = ''
        Arguments = [string[]]@()
        WorkingDirectory = ''
    }
    $LaunchTerminal = {
        param($Executable, $Arguments, $WorkingDirectory)
        $Capture.Count++
        $Capture.Executable = [string]$Executable
        $Capture.Arguments = [string[]]$Arguments
        $Capture.WorkingDirectory = [string]$WorkingDirectory
        return 23
    }.GetNewClosure()
    $Context = New-XvenvContext `
        -WorkingDirectory $InvocationDirectory `
        -DataRoot (Join-Path $TempRoot 'data') `
        -Catalog $Catalog `
        -RunExternal $RunExternal `
        -LaunchTerminal $LaunchTerminal
    $CollisionPlan = New-XvenvDesiredPlan -Context $Context -ToolNames @('bun')
    Set-XvenvPlanVariable $CollisionPlan 'XVENV_TEST_COLLISION' 'first'
    Assert-Throws {
        Set-XvenvPlanVariable $CollisionPlan 'XVENV_TEST_COLLISION' 'second'
    } 'duplicate generated environment variables must be rejected'

    $env:XVENV_EXTERNAL_RESTORE_PROBE = 'original'
    try {
        Assert-Throws {
            Invoke-XvenvExternal $Context 'unused.exe' @() @{
                XVENV_EXTERNAL_RESTORE_PROBE = 'changed'
            }
        } 'external failures must propagate'
        Assert-Equal `
            $env:XVENV_EXTERNAL_RESTORE_PROBE `
            'original' `
            'external failures must restore temporary environment changes'
    } finally {
        Remove-Item Env:XVENV_EXTERNAL_RESTORE_PROBE -ErrorAction SilentlyContinue
    }
    Assert-Equal `
        (Invoke-XvenvConsoleProcess `
            -Executable $env:ComSpec `
            -Arguments @('/d', '/c', 'exit /b 17') `
            -WorkingDirectory $InvocationDirectory) `
        17 `
        'the real console runner must return the child shell exit code'

    foreach ($Marker in @('XVENV_PROJECT_ROOT', 'XVENV_PROJECT_HOME', 'XVENV_HOME')) {
        Remove-Item -LiteralPath "Env:$Marker" -ErrorAction SilentlyContinue
    }
    $env:XVENV_HOME = 'D:\legacy-xvenv'
    Assert-Throws { Assert-XvenvNotActive } 'legacy active markers must be rejected'
    Remove-Item Env:XVENV_HOME

    $ProjectTreeBefore = Get-TreeSnapshot $ProjectRoot
    Assert-Equal `
        (Invoke-XvenvMain @('set', 'GO', 'bun', 'python', 'pwsh', 'bun') $Context) `
        0 `
        'set must accept case-insensitive names and duplicates'
    Assert-Equal (Get-TreeSnapshot $ProjectRoot) $ProjectTreeBefore 'set must not touch the user project'
    Assert-True ([IO.File]::Exists($Context.EnvCmdPath)) 'set must publish env.cmd'
    Assert-True ([IO.File]::Exists($Context.EnvPs1Path)) 'set must publish env.ps1'

    $EnvironmentBeforeImport = Save-TestEnvironment
    $Plan = Import-XvenvGeneratedEnvironment $Context
    Assert-Equal $Plan.projectRoot $Context.ProjectRoot 'generated environment must bind to the project'
    Assert-Equal `
        ([string]::Join(',', [string[]]@($Plan.tools | ForEach-Object { $_.name }))) `
        'bun,pwsh,python,go' `
        'generated tools must use canonical order'
    Assert-Equal `
        $Plan.tools[0].sha256 `
        $Catalog.Tools.bun.Hashes[$Catalog.Tools.bun.Version] `
        'generated environment must pin the Bun digest'
    Assert-Equal `
        $Plan.components[0].sha256 `
        $Catalog.Components.uv.Hashes[$Catalog.Components.uv.Version] `
        'generated environment must pin the uv digest'
    Assert-XvenvPlanInstalled $Context $Plan
    Restore-TestEnvironment $EnvironmentBeforeImport

    $BunDefinition = Get-XvenvConfiguredDefinition $Context $Plan.tools[0]
    $BunRoot = Get-XvenvInstallRoot $Context $BunDefinition
    Remove-Item (Join-Path $BunRoot 'bunx.cmd') -Force
    Assert-Equal `
        (Invoke-XvenvMain @('set', 'bun', 'pwsh', 'python', 'go') $Context) `
        0 `
        'set must repair a module-specific missing file'
    Assert-True ([IO.File]::Exists((Join-Path $BunRoot 'bunx.cmd'))) 'Bun repair must restore bunx.cmd'

    Write-Host '[TEST] Generated pair integrity, idempotency, and read-only status'
    $CmdBefore = [IO.File]::ReadAllBytes($Context.EnvCmdPath)
    $Ps1Before = [IO.File]::ReadAllBytes($Context.EnvPs1Path)
    Assert-Equal `
        (Invoke-XvenvMain @('set', 'bun', 'pwsh', 'python', 'go') $Context) `
        0 `
        'same set must succeed'
    Assert-True `
        ([Linq.Enumerable]::SequenceEqual($CmdBefore, [IO.File]::ReadAllBytes($Context.EnvCmdPath))) `
        'idempotent set must not rewrite env.cmd'
    Assert-True `
        ([Linq.Enumerable]::SequenceEqual($Ps1Before, [IO.File]::ReadAllBytes($Context.EnvPs1Path))) `
        'idempotent set must not rewrite env.ps1'

    $TreeBeforeStatus = Get-TreeSnapshot $TempRoot
    $EnvironmentBeforeStatus = Save-TestEnvironment
    Assert-Equal (Invoke-XvenvMain @('status') $Context) 0 'configured status must succeed'
    Restore-TestEnvironment $EnvironmentBeforeStatus
    $EnvironmentBeforeStatusReport = Save-TestEnvironment
    $StatusReport = Get-XvenvStatusReport $Context
    Restore-TestEnvironment $EnvironmentBeforeStatusReport
    Assert-True $StatusReport.configured 'configured status report must be marked configured'
    Assert-True $StatusReport.ready 'installed tools must make the status report ready'
    Assert-Equal @($StatusReport.tools).Count 4 'configured status must report each public tool'
    Assert-Equal (Get-TreeSnapshot $TempRoot) $TreeBeforeStatus 'status must be fully read-only'
    Test-XvenvLinkContract -BaseContext $Context -UnicodeSegment $UnicodeSegment
    Assert-Throws {
        Invoke-XvenvMain @('set', 'bun', 'unknown') $Context
    } 'unknown tools must fail'
    Assert-True `
        ([Linq.Enumerable]::SequenceEqual($Ps1Before, [IO.File]::ReadAllBytes($Context.EnvPs1Path))) `
        'invalid set must preserve generated environment'

    $GoodCmd = [IO.File]::ReadAllText($Context.EnvCmdPath, [Text.UTF8Encoding]::new($false))
    Write-XvenvTextAtomic `
        $Context.EnvCmdPath `
        ($GoodCmd -replace 'XVENV_GENERATION_ID=[a-f0-9]{16}', 'XVENV_GENERATION_ID=0000000000000000') `
        -Encoding ([Text.UTF8Encoding]::new($false))
    $EnvironmentBeforeMismatch = Save-TestEnvironment
    try {
        Assert-Throws {
            Import-XvenvGeneratedEnvironment $Context
        } 'a mismatched env.cmd/env.ps1 pair must fail'
    } finally {
        Restore-TestEnvironment $EnvironmentBeforeMismatch
        Write-XvenvTextAtomic `
            $Context.EnvCmdPath `
            $GoodCmd `
            -Encoding ([Text.UTF8Encoding]::new($false))
    }

    Write-Host '[TEST] Both generated scripts apply the same environment'
    $EnvironmentBeforeTerminal = Save-TestEnvironment
    Assert-Equal (Invoke-XvenvMain @() $Context) 23 'bare xvenv must forward terminal exit code'
    Assert-Equal $Capture.Count 1 'bare xvenv must launch one terminal'
    Assert-True `
        $Capture.Executable.EndsWith('\pwsh.exe', [StringComparison]::OrdinalIgnoreCase) `
        'portable pwsh must be selected'
    Assert-Equal $Capture.WorkingDirectory $InvocationDirectory 'terminal must preserve invocation directory'
    Assert-True ($Capture.Arguments -contains '-NoExit') 'pwsh terminal must stay open'
    Assert-Equal $env:XVENV_PROJECT_ROOT $Context.ProjectRoot 'env.ps1 must apply the project root'
    Assert-Equal $env:GOROOT $env:XVENV_GO_HOME 'env.ps1 must apply Go variables'
    Assert-True `
        $env:Path.StartsWith($env:XVENV_BUN_HOME, [StringComparison]::OrdinalIgnoreCase) `
        'generated tool paths must shadow ambient tools'
    Restore-TestEnvironment $EnvironmentBeforeTerminal

    Test-XvenvExecContract -BaseContext $Context -UnicodeSegment $UnicodeSegment

    $BatchVerifier = Join-Path (
        [IO.Path]::GetTempPath()
    ) ("xvenv-verify-$([Guid]::NewGuid().ToString('N')).cmd")
    Write-XvenvTextAtomic $BatchVerifier @"
@echo off
setlocal DisableDelayedExpansion
if not exist "%XVENV_TEST_ENV_CMD%" exit /b 6
call "%XVENV_TEST_ENV_CMD%"
if errorlevel 1 exit /b 9
if not defined XVENV_PROJECT_ROOT exit /b 10
if not "%XVENV_PROJECT_ROOT%"=="%XVENV_TEST_PROJECT_ROOT%" exit /b 7
if not "%XVENV_SHELL_KIND%"=="pwsh" exit /b 8
exit /b 0
"@ -Encoding ([Text.UTF8Encoding]::new($false))
    $env:XVENV_TEST_ENV_CMD = $Context.EnvCmdPath
    $env:XVENV_TEST_PROJECT_ROOT = $Context.ProjectRoot
    try {
        $BatchOutput = @(
            & $env:ComSpec /d /v:off /c "call `"$BatchVerifier`"" 2>&1
        )
        $BatchExitCode = $LASTEXITCODE
    } finally {
        Remove-Item Env:XVENV_TEST_ENV_CMD -ErrorAction SilentlyContinue
        Remove-Item Env:XVENV_TEST_PROJECT_ROOT -ErrorAction SilentlyContinue
    }
    Assert-Equal $BatchExitCode 0 'env.cmd must apply the same generated contract'
    Assert-Equal `
        ([string]::Join("`n", [string[]]$BatchOutput)) `
        '' `
        'env.cmd verification must not emit command-parser errors'

    Write-Host '[TEST] Failed replacement preserves the previous scripts'
    $ProjectB = Join-Path $TempRoot 'project B'
    [void][IO.Directory]::CreateDirectory((Join-Path $ProjectB '.git'))
    $ContextB = New-XvenvContext `
        -WorkingDirectory $ProjectB `
        -DataRoot (Join-Path $TempRoot 'data') `
        -Catalog $Catalog `
        -RunExternal { param($FilePath, $Arguments, $Environment) return 9 }
    Assert-Equal (Invoke-XvenvMain @('set', 'bun', 'pwsh') $ContextB) 0 'project B initial set must succeed'
    Assert-Equal (Invoke-XvenvMain @('set', 'bun') $ContextB) 0 'set must remove omitted tools'
    $CmdCapture = [pscustomobject]@{
        Count = 0
        Executable = ''
        Arguments = [string[]]@()
        WorkingDirectory = ''
    }
    $LaunchCmdTerminal = {
        param($Executable, $Arguments, $WorkingDirectory)
        $CmdCapture.Count++
        $CmdCapture.Executable = [string]$Executable
        $CmdCapture.Arguments = [string[]]$Arguments
        $CmdCapture.WorkingDirectory = [string]$WorkingDirectory
        return 29
    }.GetNewClosure()
    $CmdContext = New-XvenvContext `
        -WorkingDirectory $ProjectB `
        -DataRoot (Join-Path $TempRoot 'data') `
        -Catalog $Catalog `
        -RunExternal $RunExternal `
        -LaunchTerminal $LaunchCmdTerminal
    $EnvironmentBeforeCmdTerminal = Save-TestEnvironment
    try {
        Assert-Equal `
            (Invoke-XvenvMain @() $CmdContext) `
            29 `
            'bare xvenv without pwsh must forward the cmd terminal exit code'
        Assert-Equal $CmdCapture.Count 1 'bare xvenv without pwsh must launch one terminal'
        Assert-Equal $CmdCapture.Executable $env:ComSpec 'cmd.exe must be the fallback shell'
        Assert-Equal `
            ([string]::Join(',', $CmdCapture.Arguments)) `
            '/d,/v:off,/k' `
            'the fallback cmd terminal must use stable startup options'
        Assert-Equal `
            $CmdCapture.WorkingDirectory `
            $ProjectB `
            'the fallback cmd terminal must preserve the invocation directory'
    } finally {
        Restore-TestEnvironment $EnvironmentBeforeCmdTerminal
    }
    $ProjectBCmd = [IO.File]::ReadAllBytes($ContextB.EnvCmdPath)
    $ProjectBPs1 = [IO.File]::ReadAllBytes($ContextB.EnvPs1Path)
    Assert-Throws {
        Invoke-XvenvMain @('set', 'bun', 'python') $ContextB
    } 'failed Python installation must fail set'
    Assert-True `
        ([Linq.Enumerable]::SequenceEqual($ProjectBCmd, [IO.File]::ReadAllBytes($ContextB.EnvCmdPath))) `
        'failed set must preserve env.cmd'
    Assert-True `
        ([Linq.Enumerable]::SequenceEqual($ProjectBPs1, [IO.File]::ReadAllBytes($ContextB.EnvPs1Path))) `
        'failed set must preserve env.ps1'

    Write-Host '[TEST] Cross-project and nested activation are rejected'
    [IO.File]::Copy($Context.EnvCmdPath, $ContextB.EnvCmdPath, $true)
    [IO.File]::Copy($Context.EnvPs1Path, $ContextB.EnvPs1Path, $true)
    $BeforeForeignImport = Save-TestEnvironment
    try {
        Assert-Throws {
            Import-XvenvGeneratedEnvironment $ContextB
        } 'generated scripts copied to another project must be rejected'
    } finally {
        Restore-TestEnvironment $BeforeForeignImport
        [IO.File]::WriteAllBytes($ContextB.EnvCmdPath, $ProjectBCmd)
        [IO.File]::WriteAllBytes($ContextB.EnvPs1Path, $ProjectBPs1)
    }

    $ActiveEnvironment = Save-TestEnvironment
    [void](Import-XvenvGeneratedEnvironment $Context)
    Assert-Throws {
        Invoke-XvenvMain @('set', 'bun') $ContextB
    } 'set inside an active xvenv must be rejected'
    Assert-Throws {
        Invoke-XvenvMain @() $ContextB
    } 'a nested xvenv terminal must be rejected'
    Restore-TestEnvironment $ActiveEnvironment

    Write-Host '[TEST] Download digest enforcement'
    $ChecksumProject = Join-Path $TempRoot 'checksum project'
    [void][IO.Directory]::CreateDirectory((Join-Path $ChecksumProject '.git'))
    $GoodHash = $Catalog.Tools.bun.Hashes[$Catalog.Tools.bun.Version]
    $Catalog.Tools.bun.Hashes[$Catalog.Tools.bun.Version] = '0' * 64
    try {
        $ChecksumContext = New-XvenvContext `
            -WorkingDirectory $ChecksumProject `
            -DataRoot (Join-Path $TempRoot 'checksum data') `
            -Catalog $Catalog
        Assert-Throws {
            Invoke-XvenvMain @('set', 'bun') $ChecksumContext
        } 'wrong artifact digest must reject installation'
        Assert-True (-not [IO.File]::Exists($ChecksumContext.EnvCmdPath)) 'failed set must not publish env.cmd'
        Assert-True (-not [IO.File]::Exists($ChecksumContext.EnvPs1Path)) 'failed set must not publish env.ps1'
        Assert-Equal (Get-TreeSnapshot $ChecksumProject) '\.git|directory' 'failed set must not touch project files'
    } finally {
        $Catalog.Tools.bun.Hashes[$Catalog.Tools.bun.Version] = $GoodHash
    }

    Write-Host 'xvenv smoke tests: PASS' -ForegroundColor Green
} finally {
    Restore-TestEnvironment $SavedEnvironment
    if (-not [string]::IsNullOrWhiteSpace($BatchVerifier) -and
        [IO.File]::Exists($BatchVerifier)) {
        [IO.File]::Delete($BatchVerifier)
    }
    if ([IO.Directory]::Exists($TempRoot)) {
        Remove-Item -LiteralPath $TempRoot -Recurse -Force
    }
}
