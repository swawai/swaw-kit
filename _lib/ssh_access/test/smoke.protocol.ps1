[CmdletBinding()]
param()

$ErrorActionPreference = 'Stop'
Set-StrictMode -Version 2.0

. (Join-Path $PSScriptRoot 'support.ps1')
. (Join-Path $script:SshAccessTestKitRoot 'runtime\bootstrap.ps1')

$EnvironmentNames = @(
    'SSH_ACCESS_PROTOCOL',
    'SSH_ACCESS_ENTRY_COMMAND',
    'SSH_ACCESS_ENTRY_FILE',
    'SSH_ACCESS_PRIVATE_KEY_PATH',
    'SSH_ACCESS_USER',
    'SSH_ACCESS_KEY_TYPE',
    'SSH_ACCESS_KEY_COMMENT'
)
$SavedEnvironment = Save-SshAccessTestEnvironment -Names $EnvironmentNames
$ScratchRoot = New-SshAccessTestScratchRoot

try {
    Write-Host '[TEST] PowerShell parser'
    foreach ($File in Get-ChildItem -LiteralPath $script:SshAccessTestKitRoot -Recurse -Filter '*.ps1') {
        $Tokens = $null
        $Errors = $null
        [void][Management.Automation.Language.Parser]::ParseFile(
            $File.FullName,
            [ref]$Tokens,
            [ref]$Errors
        )
        Assert-SshAccessTestTrue `
            -Condition ($Errors.Count -eq 0) `
            -Message "$($File.FullName) should parse. $($Errors -join '; ')"
    }

    Write-Host '[TEST] Valid entry context'
    $PrivatePath = Join-Path $ScratchRoot 'identity\id_ed25519'
    Set-SshAccessTestValidEnvironment -PrivateKeyPath $PrivatePath
    $Context = New-SshAccessContext -KitRoot $script:SshAccessTestKitRoot
    Assert-SshAccessTestEqual $Context.Protocol 1 'Protocol should resolve to version 1.'
    Assert-SshAccessTestEqual $Context.PrivateKeyPath $PrivatePath 'Private key path should be canonical.'
    Assert-SshAccessTestEqual $Context.PublicKeyPath "$PrivatePath.pub" 'Public key path should be derived.'
    Assert-SshAccessTestEqual $Context.UserName 'ssh_access_test_user' 'The local user should come from the entry.'
    Assert-SshAccessTestEqual $Context.KeyType 'ed25519' 'The configured key type should be retained.'
    Assert-SshAccessTestEqual `
        $Context.WindowsRoot `
        ([IO.Path]::GetFullPath(
            [Environment]::GetFolderPath([Environment+SpecialFolder]::Windows)
        )) `
        'The Windows root should come from the trusted Windows API.'
    Assert-SshAccessTestEqual `
        $Context.SystemDirectory `
        ([IO.Path]::GetFullPath([Environment]::SystemDirectory)) `
        'The system directory should come from the trusted Windows API.'

    Write-Host '[TEST] Status identity boundary'
    function Get-SshAccessCurrentProcessIdentity {
        return [pscustomobject]@{
            Name  = 'TESTBOX\agent-user'
            Sid   = 'S-1-5-21-1-2-3-1001'
            Error = ''
        }
    }
    $script:StatusCalls = New-Object Collections.Generic.List[string]
    function Show-SshAccessKeyState {
        param([pscustomobject]$Context)
        [void]$script:StatusCalls.Add('key')
    }
    function Show-SshAccessPrivateState {
        param([pscustomobject]$Context)
        [void]$script:StatusCalls.Add('private')
    }
    function Show-SshAccessPublicState {
        param([pscustomobject]$Context)
        [void]$script:StatusCalls.Add('public')
    }
    function Show-SshAccessClientState {
        param([pscustomobject]$Context)
        [void]$script:StatusCalls.Add('client')
    }
    function Show-SshAccessServerState {
        param([pscustomobject]$Context)
        [void]$script:StatusCalls.Add('server')
    }
    $StatusOutput = (
        & {
            Invoke-SshAccessStatusCommand -Context $Context -Arguments @()
        } 6>&1 |
            Out-String
    )
    Assert-SshAccessTestEqual `
        ($script:StatusCalls -join ',') `
        'key,private,public,client,server' `
        'Bare status should compose every status domain in protocol order.'
    Assert-SshAccessTestContains `
        $StatusOutput `
        'SSH login target:' `
        'Status should label the configured inbound SSH user explicitly.'
    Assert-SshAccessTestContains `
        $StatusOutput `
        'ssh_access_test_user' `
        'Status should show the configured inbound SSH user.'
    Assert-SshAccessTestContains `
        $StatusOutput `
        'Agent/process user:' `
        'Status should label the current private-agent identity explicitly.'
    Assert-SshAccessTestContains `
        $StatusOutput `
        'TESTBOX\agent-user' `
        'Status should show the current process identity name.'
    Assert-SshAccessTestContains `
        $StatusOutput `
        'S-1-5-21-1-2-3-1001' `
        'Status should show the current process identity SID.'

    Write-Host '[TEST] Focused status domains'
    $script:StatusCalls.Clear()
    $KeyStatusOutput = (
        & {
            Invoke-SshAccessStatusCommand `
                -Context $Context `
                -Arguments @('key')
        } 6>&1 |
            Out-String
    )
    Assert-SshAccessTestEqual `
        ($script:StatusCalls -join ',') `
        'key' `
        'Key status should query only the key domain.'
    Assert-SshAccessTestTrue `
        (-not $KeyStatusOutput.Contains('SSH login target:')) `
        'Key status should omit unrelated login identity.'
    Assert-SshAccessTestTrue `
        (-not $KeyStatusOutput.Contains('Agent/process user:')) `
        'Key status should omit unrelated process identity.'

    $script:StatusCalls.Clear()
    $PrivateStatusOutput = (
        & {
            Invoke-SshAccessStatusCommand `
                -Context $Context `
                -Arguments @('private')
        } 6>&1 |
            Out-String
    )
    Assert-SshAccessTestEqual `
        ($script:StatusCalls -join ',') `
        'private' `
        'Private status should query only the private-key application domain.'
    Assert-SshAccessTestContains `
        $PrivateStatusOutput `
        'Agent/process user:' `
        'Private status should identify the agent/process user.'
    Assert-SshAccessTestTrue `
        (-not $PrivateStatusOutput.Contains('SSH login target:')) `
        'Private status should omit the unrelated SSH login target.'

    $script:StatusCalls.Clear()
    $PublicStatusOutput = (
        & {
            Invoke-SshAccessStatusCommand `
                -Context $Context `
                -Arguments @('public')
        } 6>&1 |
            Out-String
    )
    Assert-SshAccessTestEqual `
        ($script:StatusCalls -join ',') `
        'public' `
        'Public status should query only the public-key authorization domain.'
    Assert-SshAccessTestContains `
        $PublicStatusOutput `
        'SSH login target:' `
        'Public status should identify the inbound SSH user.'
    Assert-SshAccessTestTrue `
        (-not $PublicStatusOutput.Contains('Agent/process user:')) `
        'Public status should omit the unrelated process identity.'

    $script:StatusCalls.Clear()
    $SshStatusOutput = (
        & {
            Invoke-SshAccessStatusCommand `
                -Context $Context `
                -Arguments @('SSH')
        } 6>&1 |
            Out-String
    )
    Assert-SshAccessTestEqual `
        ($script:StatusCalls -join ',') `
        'client,server' `
        'SSH status should query client and the aggregate server state.'
    Assert-SshAccessTestTrue `
        (-not $SshStatusOutput.Contains('SSH login target:')) `
        'SSH status should omit entry-bound login identity.'
    Assert-SshAccessTestTrue `
        (-not $SshStatusOutput.Contains('Agent/process user:')) `
        'SSH status should omit process identity.'

    $script:StatusCalls.Clear()
    $DispatchCode = Invoke-SshAccessMain -Arguments @('.status', 'key')
    Assert-SshAccessTestEqual `
        $DispatchCode `
        0 `
        'Top-level dispatch should accept a focused status domain.'
    Assert-SshAccessTestEqual `
        ($script:StatusCalls -join ',') `
        'key' `
        'Top-level dispatch should pass the status domain through unchanged.'

    Assert-SshAccessTestThrowsLike `
        {
            Invoke-SshAccessStatusCommand `
                -Context $Context `
                -Arguments @('unknown')
        } `
        "*Unknown .status domain 'unknown'*" `
        'Status should reject an unknown domain.'
    Assert-SshAccessTestThrowsLike `
        {
            Invoke-SshAccessStatusCommand `
                -Context $Context `
                -Arguments @('key', 'extra')
        } `
        '*Status accepts at most one domain*' `
        'Status should reject extra arguments.'
    Assert-SshAccessTestThrowsLike `
        {
            Invoke-SshAccessStatusCommand `
                -Context $Context `
                -Arguments @('all')
        } `
        "*Unknown .status domain 'all'*" `
        'Bare status should remain the only all-domains spelling.'

    Write-Host '[TEST] Status UAC grammar and transport'
    $script:ElevatedStatusCalls = New-Object Collections.Generic.List[string]
    function Test-SshAccessAdministrator {
        return $false
    }
    function Invoke-SshAccessElevatedCommand {
        param(
            [pscustomobject]$Context,
            [string[]]$Arguments
        )

        [void]$script:ElevatedStatusCalls.Add($Arguments -join ' ')
        return 47
    }

    $ElevatedStatusCode = Invoke-SshAccessStatusCommand `
        -Context $Context `
        -Arguments @('--uac')
    Assert-SshAccessTestEqual `
        $ElevatedStatusCode `
        47 `
        'Bare status --uac should return the elevated child result.'
    $ElevatedStatusCode = Invoke-SshAccessStatusCommand `
        -Context $Context `
        -Arguments @('public', '--uac')
    Assert-SshAccessTestEqual `
        $ElevatedStatusCode `
        47 `
        'A focused status command should inherit explicit UAC.'
    $ElevatedStatusCode = Invoke-SshAccessStatusCommand `
        -Context $Context `
        -Arguments @('--uac', 'ssh')
    Assert-SshAccessTestEqual `
        $ElevatedStatusCode `
        47 `
        'Status should accept the UAC option before or after its domain.'
    Assert-SshAccessTestEqual `
        ($script:ElevatedStatusCalls -join ',') `
        '.status,.status public,.status ssh' `
        'Elevated status transport should omit --uac to prevent recursion.'
    Assert-SshAccessTestThrowsLike `
        {
            Invoke-SshAccessStatusCommand `
                -Context $Context `
                -Arguments @('--uac', '--uac')
        } `
        "*Duplicate option '--uac'*" `
        'Status should reject duplicate elevation options.'

    function Show-SshAccessKeyState {
        param([pscustomobject]$Context)

        throw [UnauthorizedAccessException]::new('Access is denied.')
    }
    $DeniedStatusOutput = (
        & {
            Invoke-SshAccessStatusCommand `
                -Context $Context `
                -Arguments @('key')
        } 6>&1 |
            Out-String
    )
    Assert-SshAccessTestContains `
        $DeniedStatusOutput `
        'Problem:           Access denied.' `
        'Status should shorten access-denied exception noise.'
    Assert-SshAccessTestContains `
        $DeniedStatusOutput `
        'sshaccess.test .status key --uac' `
        'Restricted status should suggest the matching UAC retry.'
    Assert-SshAccessTestTrue `
        (-not $DeniedStatusOutput.Contains('Exception calling')) `
        'Status should not expose PowerShell wrapper noise for access denial.'

    function Test-SshAccessAdministrator {
        return $true
    }
    $script:StatusCalls.Clear()
    $AdminStatusCode = Invoke-SshAccessStatusCommand `
        -Context $Context `
        -Arguments @('public', '--uac')
    Assert-SshAccessTestEqual `
        $AdminStatusCode `
        0 `
        'Status --uac should not spawn again when already elevated.'
    Assert-SshAccessTestEqual `
        ($script:StatusCalls -join ',') `
        'public' `
        'An already elevated status should execute its selected domain locally.'

    Write-Host '[TEST] Native argument encoding'
    Assert-SshAccessTestEqual `
        (ConvertTo-SshAccessWindowsArguments -Arguments @('-N', '')) `
        '-N ""' `
        'Native process transport should preserve an explicit empty argument.'

    Write-Host '[TEST] Configuration validation'
    $env:SSH_ACCESS_PROTOCOL = $null
    Assert-SshAccessTestThrowsLike `
        { Assert-SshAccessEntryProtocol } `
        '*Unsupported or missing SSH_ACCESS_PROTOCOL*' `
        'A missing protocol should fail.'

    Set-SshAccessTestValidEnvironment -PrivateKeyPath $PrivatePath
    $env:SSH_ACCESS_PRIVATE_KEY_PATH = 'relative\id_ed25519'
    Assert-SshAccessTestThrowsLike `
        { New-SshAccessContext -KitRoot $script:SshAccessTestKitRoot } `
        '*must be an absolute path*' `
        'A relative private-key path should fail.'

    Set-SshAccessTestValidEnvironment -PrivateKeyPath "$PrivatePath.pub"
    Assert-SshAccessTestThrowsLike `
        { New-SshAccessContext -KitRoot $script:SshAccessTestKitRoot } `
        '*must name the private key*' `
        'A public-key path should not be accepted as the private-key path.'

    Set-SshAccessTestValidEnvironment -PrivateKeyPath $PrivatePath
    $env:SSH_ACCESS_USER = 'DOMAIN\alice'
    Assert-SshAccessTestThrowsLike `
        { New-SshAccessContext -KitRoot $script:SshAccessTestKitRoot } `
        '*unqualified local Windows user name*' `
        'A qualified user name should fail.'

    Set-SshAccessTestValidEnvironment -PrivateKeyPath $PrivatePath
    $env:SSH_ACCESS_USER = 'ssh*'
    Assert-SshAccessTestThrowsLike `
        { New-SshAccessContext -KitRoot $script:SshAccessTestKitRoot } `
        '*not a wildcard pattern*' `
        'A wildcard user name should fail instead of selecting a different local account.'

    Set-SshAccessTestValidEnvironment -PrivateKeyPath $PrivatePath
    $env:SSH_ACCESS_KEY_TYPE = 'dsa'
    Assert-SshAccessTestThrowsLike `
        { New-SshAccessContext -KitRoot $script:SshAccessTestKitRoot } `
        '*Unsupported SSH_ACCESS_KEY_TYPE*' `
        'An unsupported key type should fail.'

    Set-SshAccessTestValidEnvironment -PrivateKeyPath $PrivatePath
    $env:SSH_ACCESS_KEY_COMMENT = "first`nsecond"
    Assert-SshAccessTestThrowsLike `
        { New-SshAccessContext -KitRoot $script:SshAccessTestKitRoot } `
        '*must be a single line*' `
        'A multiline public-key comment should fail.'

    Write-Host '[TEST] Unknown top-level commands'
    Set-SshAccessTestValidEnvironment -PrivateKeyPath $PrivatePath
    Assert-SshAccessTestThrowsLike `
        { Invoke-SshAccessMain -Arguments @('/?') } `
        "*Unknown SSH Access command '/?'*" `
        'The legacy slash-question alias should stay unsupported.'
    Assert-SshAccessTestThrowsLike `
        { Invoke-SshAccessMain -Arguments @('.unknown') } `
        "*Unknown SSH Access command '.unknown'*" `
        'An unknown custom command should fail explicitly.'
} finally {
    Restore-SshAccessTestEnvironment -Saved $SavedEnvironment
    Remove-SshAccessTestScratchRoot -Path $ScratchRoot
}

Write-Host 'ssh access protocol tests: PASS' -ForegroundColor Green
