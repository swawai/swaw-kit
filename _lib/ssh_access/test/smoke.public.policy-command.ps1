[CmdletBinding()]
param()

$ErrorActionPreference = 'Stop'
Set-StrictMode -Version 2.0

. (Join-Path $PSScriptRoot 'support.ps1')
. (Join-Path $script:SshAccessTestKitRoot 'runtime\bootstrap.ps1')

$ScratchRoot = New-SshAccessTestScratchRoot

try {
    Write-Host '[TEST] sshd_config path policy'
    $ProgramData = Join-Path $ScratchRoot 'program-data'
    $SshdDirectory = Join-Path $ProgramData 'ssh'
    [void][IO.Directory]::CreateDirectory($SshdDirectory)
    $SshdConfigPath = Join-Path $SshdDirectory 'sshd_config'
    $ConfigContext = [pscustomobject]@{ ProgramData = $ProgramData }
    $AdminAccount = [pscustomobject]@{ IsAdministrator = $true }
    $MissingAdminConfig = Get-SshAccessSshdConfigState `
        -Context $ConfigContext `
        -Account $AdminAccount
    Assert-SshAccessTestEqual `
        $MissingAdminConfig.Compatible `
        $false `
        'A missing sshd_config cannot prove the shared Administrators mapping.'
    Assert-SshAccessTestContains `
        ([string]::Join(' ', [string[]]@($MissingAdminConfig.Issues))) `
        'mapping cannot be verified' `
        'A missing administrator mapping should explain why mutation must fail closed.'
    $MissingUserConfig = Get-SshAccessSshdConfigState `
        -Context $ConfigContext `
        -Account ([pscustomobject]@{ IsAdministrator = $false })
    Assert-SshAccessTestEqual `
        $MissingUserConfig.Compatible `
        $true `
        'A missing sshd_config does not change the default per-user authorized_keys path.'

    [IO.File]::WriteAllText(
        $SshdConfigPath,
        "AuthorizedKeysFile .ssh/authorized_keys`r`nMatch Group administrators`r`n  AuthorizedKeysFile __PROGRAMDATA__/ssh/administrators_authorized_keys`r`n",
        (New-Object Text.UTF8Encoding($false))
    )
    $ConfigState = Get-SshAccessSshdConfigState `
        -Context $ConfigContext `
        -Account $AdminAccount
    Assert-SshAccessTestEqual `
        $ConfigState.Compatible `
        $true `
        'The standard Windows OpenSSH authorization layout should be accepted.'

    [IO.File]::WriteAllText(
        $SshdConfigPath,
        "AuthorizedKeysFile .ssh/authorized_keys`r`nMatch Group S-1-5-32-544`r`n  AuthorizedKeysFile __PROGRAMDATA__/ssh/administrators_authorized_keys`r`n",
        (New-Object Text.UTF8Encoding($false))
    )
    $SidConfigState = Get-SshAccessSshdConfigState `
        -Context $ConfigContext `
        -Account $AdminAccount
    Assert-SshAccessTestEqual `
        $SidConfigState.Compatible `
        $true `
        'The built-in Administrators SID should be accepted independent of OS language.'

    try {
        $AdministratorsSid = New-Object Security.Principal.SecurityIdentifier('S-1-5-32-544')
        $LocalizedAccount = $AdministratorsSid.Translate(
            [Security.Principal.NTAccount]
        ).Value
        $LocalizedGroup = $LocalizedAccount.Substring(
            $LocalizedAccount.LastIndexOf('\') + 1
        )
        Assert-SshAccessTestTrue `
            (Test-SshAccessAdministratorMatch `
                -Fields @('Match', 'Group', $LocalizedGroup)) `
            'The OS-localized built-in Administrators name should be accepted.'
    } catch [Security.Principal.IdentityNotMappedException] {
        Write-Host '[SKIP] Built-in Administrators SID translation is unavailable.'
    }

    [IO.File]::WriteAllText(
        $SshdConfigPath,
        "Include extra.conf`r`n",
        (New-Object Text.UTF8Encoding($false))
    )
    $ConfigState = Get-SshAccessSshdConfigState `
        -Context $ConfigContext `
        -Account $AdminAccount
    Assert-SshAccessTestEqual `
        $ConfigState.Compatible `
        $false `
        'Include should fail closed because the effective authorization path cannot be proven.'

    [IO.File]::WriteAllText(
        $SshdConfigPath,
        "AuthorizedKeysFile D:/custom/authorized_keys`r`n",
        (New-Object Text.UTF8Encoding($false))
    )
    $ConfigState = Get-SshAccessSshdConfigState `
        -Context $ConfigContext `
        -Account ([pscustomobject]@{ IsAdministrator = $false })
    Assert-SshAccessTestEqual `
        $ConfigState.Compatible `
        $false `
        'A custom AuthorizedKeysFile should be rejected instead of writing the wrong file.'

    Write-Host '[TEST] Public-key authentication defaults on and explicit disable fails grant closed'
    [IO.File]::WriteAllText(
        $SshdConfigPath,
        "PubkeyAuthentication no`r`nAuthorizedKeysFile .ssh/authorized_keys`r`nMatch Group administrators`r`n  AuthorizedKeysFile __PROGRAMDATA__/ssh/administrators_authorized_keys`r`n",
        (New-Object Text.UTF8Encoding($false))
    )
    $DisabledAuthenticationState = Get-SshAccessSshdConfigState `
        -Context $ConfigContext `
        -Account $AdminAccount
    Assert-SshAccessTestEqual `
        $DisabledAuthenticationState.AuthorizedKeysCompatible `
        $true `
        'An authentication policy should not make the known authorization path unsafe to revoke.'
    Assert-SshAccessTestEqual `
        $DisabledAuthenticationState.PublicKeyAuthentication `
        'disabled' `
        'An explicit global PubkeyAuthentication no should be detected.'
    Assert-SshAccessTestThrowsLike `
        {
            Assert-SshAccessAuthorizedKeysConfiguration `
                -Context $ConfigContext `
                -Account $AdminAccount `
                -RequirePublicKeyAuthentication $true
        } `
        '*PubkeyAuthentication is disabled*' `
        'Grant should refuse to install an ineffective public key.'
    $null = Assert-SshAccessAuthorizedKeysConfiguration `
        -Context $ConfigContext `
        -Account $AdminAccount

    [IO.File]::WriteAllText(
        $SshdConfigPath,
        "AuthorizedKeysFile .ssh/authorized_keys`r`nMatch Group administrators`r`n  AuthorizedKeysFile __PROGRAMDATA__/ssh/administrators_authorized_keys`r`n  PubkeyAuthentication yes`r`n",
        (New-Object Text.UTF8Encoding($false))
    )
    $ConditionalAuthenticationState = Get-SshAccessSshdConfigState `
        -Context $ConfigContext `
        -Account $AdminAccount
    Assert-SshAccessTestEqual `
        $ConditionalAuthenticationState.PublicKeyAuthentication `
        'unknown' `
        'Conditional authentication policy should fail closed when effective behavior cannot be proven.'

    Write-Host '[TEST] Public mutation scope and administrator configuration fail closed'
    $StateContext = [pscustomobject]@{
        CommandName = 'sshaccess.test'
    }
    $AuthPath = Join-Path $ScratchRoot 'authorized_keys'
    $script:PublicTestAccount = $null
    $script:PublicTestConfigState = $null
    function Resolve-SshAccessLocalUser {
        param([pscustomobject]$Context)
        return $script:PublicTestAccount
    }
    function Get-SshAccessSshdConfigState {
        param(
            [pscustomobject]$Context,
            [pscustomobject]$Account
        )
        return $script:PublicTestConfigState
    }

    $script:AdminCommandCalls = 0
    $script:AdminCommandResult = 23
    function Invoke-SshAccessAdminCommand {
        param(
            [pscustomobject]$Context,
            [string[]]$Arguments,
            [bool]$Uac
        )
        $script:AdminCommandCalls++
        return $script:AdminCommandResult
    }

    $script:PublicTestAccount = [pscustomobject]@{
        Name               = 'other-user'
        Sid                = 'S-1-5-21-1-2-3-1002'
        Enabled            = $true
        IsAdministrator    = $false
        IsCurrentUser      = $false
        AuthorizedKeysPath = 'C:\Users\other-user\.ssh\authorized_keys'
    }
    Assert-SshAccessTestThrowsLike `
        {
            Invoke-SshAccessPublicMutation `
                -Context $StateContext `
                -Operation grant `
                -Uac $true
        } `
        "*refuses to modify another ordinary user's profile*" `
        'UAC consent must not permit cross-user ordinary-profile mutation.'
    Assert-SshAccessTestEqual `
        $script:AdminCommandCalls `
        0 `
        'A forbidden cross-user mutation must fail before attempting elevation.'

    $script:PublicTestAccount = [pscustomobject]@{
        Name               = 'test-user'
        Sid                = 'S-1-5-21-1-2-3-1001'
        Enabled            = $true
        IsAdministrator    = $false
        IsCurrentUser      = $true
        AuthorizedKeysPath = $AuthPath
    }
    $script:PublicTestConfigState = [pscustomobject]@{
        Path                           = $SshdConfigPath
        Exists                         = $true
        Compatible                     = $false
        AuthorizedKeysCompatible       = $false
        PublicKeyAuthentication        = 'default-enabled'
        PublicKeyAuthenticationEnabled = $true
        AdministratorMappingFound      = $false
        Issues                         = @('test stop')
    }
    Assert-SshAccessTestThrowsLike `
        {
            Invoke-SshAccessPublicMutation `
                -Context $StateContext `
                -Operation grant `
                -Uac $true
        } `
        '*Unsupported sshd public-key authorization configuration*' `
        '--uac should permit elevation when needed rather than force it unconditionally.'
    Assert-SshAccessTestEqual `
        $script:AdminCommandCalls `
        0 `
        'A current ordinary-user operation should not elevate merely because --uac was supplied.'

    $script:PublicTestAccount = [pscustomobject]@{
        Name               = 'admin-user'
        Sid                = 'S-1-5-21-1-2-3-1003'
        Enabled            = $true
        IsAdministrator    = $true
        IsCurrentUser      = $false
        AuthorizedKeysPath = (Join-Path $SshdDirectory 'administrators_authorized_keys')
    }
    $script:AdminCommandResult = 23
    $AdminRouteResult = Invoke-SshAccessPublicMutation `
        -Context $StateContext `
        -Operation grant `
        -Uac $false
    Assert-SshAccessTestEqual `
        $AdminRouteResult `
        23 `
        'Administrator targets should continue through the shared-file elevation route.'

    $script:AdminCommandResult = $null
    $script:PublicTestConfigState = [pscustomobject]@{
        Path                           = $SshdConfigPath
        Exists                         = $false
        Compatible                     = $false
        AuthorizedKeysCompatible       = $false
        PublicKeyAuthentication        = 'default-enabled'
        PublicKeyAuthenticationEnabled = $true
        AdministratorMappingFound      = $false
        Issues                         = @(
            'sshd_config is missing, so the Administrators AuthorizedKeysFile mapping cannot be verified.'
        )
    }
    Assert-SshAccessTestThrowsLike `
        {
            Invoke-SshAccessPublicMutation `
                -Context $StateContext `
                -Operation grant `
                -Uac $true
        } `
        '*mapping cannot be verified*' `
        'An elevated administrator mutation should fail closed when sshd_config is absent.'

    Write-Host '[TEST] Public command grammar rejects before mutation'
    $CommandContext = [pscustomobject]@{
        CommandName = 'sshaccess.test'
    }
    $script:PublicMutationUac = New-Object Collections.Generic.List[bool]
    function Invoke-SshAccessPublicMutation {
        param(
            [pscustomobject]$Context,
            [string]$Operation,
            [bool]$Uac
        )

        $script:PublicMutationUac.Add($Uac)
        return 0
    }

    $null = Invoke-SshAccessPublicCommand `
        -Context $CommandContext `
        -Arguments @('grant')
    $null = Invoke-SshAccessPublicCommand `
        -Context $CommandContext `
        -Arguments @('revoke', '--uac')
    Assert-SshAccessTestEqual `
        $script:PublicMutationUac[0] `
        $false `
        'Public grant should not request implicit UAC.'
    Assert-SshAccessTestEqual `
        $script:PublicMutationUac[1] `
        $true `
        'Public revoke --uac should forward explicit consent.'

    Assert-SshAccessTestThrowsLike `
        { Invoke-SshAccessPublicCommand -Context $CommandContext -Arguments @('grant', '--yes') } `
        "*Unexpected argument '--yes'*" `
        'Public mutation should reject unknown options.'
    Assert-SshAccessTestThrowsLike `
        { Invoke-SshAccessPublicCommand -Context $CommandContext -Arguments @('grant', '--uac', '--uac') } `
        "*Duplicate option '--uac'*" `
        'Public mutation should reject duplicate options.'
    Assert-SshAccessTestEqual `
        $script:PublicMutationUac.Count `
        2 `
        'Invalid public commands must fail before mutation.'
} finally {
    Remove-SshAccessTestScratchRoot -Path $ScratchRoot
}

Write-Host 'ssh access public policy and command tests: PASS' -ForegroundColor Green
