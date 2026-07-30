[CmdletBinding()]
param()

$ErrorActionPreference = 'Stop'
Set-StrictMode -Version 2.0

. (Join-Path $PSScriptRoot 'support.ps1')
. (Join-Path $script:SshAccessTestKitRoot 'runtime\bootstrap.ps1')

$ScratchRoot = New-SshAccessTestScratchRoot

try {
    $BoundLine = New-SshAccessTestPublicKeyLine `
        -Seed 21 `
        -Comment 'bound-comment'
    $OtherLine = New-SshAccessTestPublicKeyLine `
        -Seed 87 `
        -Comment 'unrelated-comment'
    $BoundParsed = ConvertFrom-SshAccessPublicKeyLine -Line $BoundLine
    $OtherParsed = ConvertFrom-SshAccessPublicKeyLine -Line $OtherLine
    $BoundKey = [pscustomobject]@{
        Type = $BoundParsed.Type
        Blob = $BoundParsed.Blob
        Line = $BoundLine
    }

    Write-Host '[TEST] Authorized-key identity separates plain and option-bound references'
    Assert-SshAccessTestEqual `
        (Get-SshAccessAuthorizedKeyLineReferenceKind `
            -Line "$($BoundParsed.Type) $($BoundParsed.Blob) changed-comment" `
            -Key $BoundKey) `
        'plain' `
        'A direct key line should be classified as a plain authorization.'
    Assert-SshAccessTestEqual `
        (Get-SshAccessAuthorizedKeyLineReferenceKind `
            -Line "from=`"10.0.0.1`",command=`"echo hello world`",no-pty $($BoundParsed.Type) $($BoundParsed.Blob) options-comment" `
            -Key $BoundKey) `
        'option-bound' `
        'A key after an options field should be classified as option-bound.'
    Assert-SshAccessTestTrue `
        ($null -eq (Get-SshAccessAuthorizedKeyLineReferenceKind `
                -Line "# $($BoundParsed.Type) $($BoundParsed.Blob)" `
                -Key $BoundKey)) `
        'A commented-out key should not count as authorization.'
    Assert-SshAccessTestTrue `
        ($null -eq (
            Get-SshAccessAuthorizedKeyLineReferenceKind -Line $OtherLine -Key $BoundKey
        )) `
        'A different key blob should remain unrelated.'

    $OptionOnlyReferences = Measure-SshAccessAuthorizedKeyReferences `
        -Lines @(
            "cert-authority $($BoundParsed.Type) $($BoundParsed.Blob)",
            "future-option $($BoundParsed.Type) $($BoundParsed.Blob)"
        ) `
        -Key $BoundKey
    Assert-SshAccessTestEqual `
        $OptionOnlyReferences.State `
        'option-bound' `
        'Option syntax is not interpreted as a direct login authorization.'
    Assert-SshAccessTestEqual `
        $OptionOnlyReferences.OptionBoundReferenceCount `
        2 `
        'Every option-bound identity reference should remain visible.'

    $MixedReferences = Measure-SshAccessAuthorizedKeyReferences `
        -Lines @(
            $BoundLine,
            "restrict $($BoundParsed.Type) $($BoundParsed.Blob)"
        ) `
        -Key $BoundKey
    Assert-SshAccessTestEqual `
        $MixedReferences.State `
        'ambiguous' `
        'Mixed plain and option-bound references should be surfaced as ambiguous.'

    $EmbeddedOptionLine = "command=`"echo $($BoundParsed.Type) $($BoundParsed.Blob)`" $OtherLine"
    Assert-SshAccessTestTrue `
        ($null -eq (
            Get-SshAccessAuthorizedKeyLineReferenceKind `
                -Line $EmbeddedOptionLine `
                -Key $BoundKey
        )) `
        'Key-shaped text inside a quoted command option must not match the actual line identity.'
    $OtherInsideOptionThenBound = "command=`"echo $($OtherParsed.Type) $($OtherParsed.Blob)`" $BoundLine"
    Assert-SshAccessTestEqual `
        (Get-SshAccessAuthorizedKeyLineReferenceKind `
            -Line $OtherInsideOptionThenBound `
            -Key $BoundKey) `
        'option-bound' `
        'Key-shaped option text must not hide the actual bound key later in the line.'
    $BoundInsideComment = "$OtherLine note $($BoundParsed.Type) $($BoundParsed.Blob)"
    Assert-SshAccessTestTrue `
        ($null -eq (
            Get-SshAccessAuthorizedKeyLineReferenceKind `
                -Line $BoundInsideComment `
                -Key $BoundKey
        )) `
        'Key-shaped text in a comment must not be treated as the authorized identity.'

    Write-Host '[TEST] Public status distinguishes authorization semantics'
    $StatePublicKeyPath = Join-Path $ScratchRoot 'state_key.pub'
    [IO.File]::WriteAllText(
        $StatePublicKeyPath,
        "$BoundLine`r`n",
        (New-Object Text.UTF8Encoding($false))
    )
    $StateContext = [pscustomobject]@{
        AuthorizationUserName = 'test-user'
        AuthorizationUserSid  = 'S-1-5-21-1-2-3-1001'
        PublicKeyPath          = $StatePublicKeyPath
        CommandName            = 'sshaccess.test'
    }
    $script:PublicTestAccount = [pscustomobject]@{
        Name               = 'test-user'
        Sid                = 'S-1-5-21-1-2-3-1001'
        Enabled            = $true
        IsAdministrator    = $false
        IsCurrentUser      = $true
        AuthorizedKeysPath = (Join-Path $ScratchRoot 'authorized_keys')
    }
    $script:PublicTestConfigState = [pscustomobject]@{
        Path                           = (Join-Path $ScratchRoot 'sshd_config')
        Exists                         = $true
        Compatible                     = $true
        AuthorizedKeysCompatible       = $true
        PublicKeyAuthentication        = 'default-enabled'
        PublicKeyAuthenticationEnabled = $true
        AdministratorMappingFound      = $false
        Issues                         = @()
    }
    $script:PublicTestReferences = [pscustomobject]@{
        State                       = 'none'
        IdentityReferenceCount      = 0
        PlainAuthorizationCount     = 0
        OptionBoundReferenceCount   = 0
    }
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
    function Get-SshAccessBoundPublicKey {
        param([pscustomobject]$Context)
        return $BoundKey
    }
    function Get-SshAccessAuthorizedKeyReferenceState {
        param(
            [string]$Path,
            [pscustomobject]$Key
        )
        return $script:PublicTestReferences
    }

    $script:PublicTestReferences = [pscustomobject]@{
        State                       = 'option-bound'
        IdentityReferenceCount      = 2
        PlainAuthorizationCount     = 0
        OptionBoundReferenceCount   = 2
    }
    $OptionBoundState = Get-SshAccessPublicState -Context $StateContext
    Assert-SshAccessTestEqual `
        $OptionBoundState.Authorization `
        'option-bound' `
        'Status should not report an option-bound identity as a plain grant.'
    Assert-SshAccessTestEqual `
        $OptionBoundState.Granted `
        $false `
        'An option-bound identity is not proven to be a direct plain authorization.'
    Assert-SshAccessTestContains `
        $OptionBoundState.Error `
        'still referenced' `
        'Status should explain why an option-bound identity blocks key deletion.'

    $script:PublicTestReferences = [pscustomobject]@{
        State                       = 'ambiguous'
        IdentityReferenceCount      = 2
        PlainAuthorizationCount     = 1
        OptionBoundReferenceCount   = 1
    }
    $AmbiguousState = Get-SshAccessPublicState -Context $StateContext
    Assert-SshAccessTestEqual `
        $AmbiguousState.Authorization `
        'ambiguous' `
        'Status should expose mixed plain and option-bound references.'
    Assert-SshAccessTestEqual `
        $AmbiguousState.MatchCount `
        2 `
        'Status should count every identity reference so key deletion remains fail-closed.'

    Write-Host '[TEST] Disabled key authentication does not hide authorization references'
    $script:PublicTestConfigState.Compatible = $false
    $script:PublicTestConfigState.PublicKeyAuthentication = 'disabled'
    $script:PublicTestConfigState.PublicKeyAuthenticationEnabled = $false
    $script:PublicTestConfigState.Issues = @(
        'Line 4: PubkeyAuthentication is disabled.'
    )
    $script:PublicTestReferences = [pscustomobject]@{
        State                       = 'plain'
        IdentityReferenceCount      = 1
        PlainAuthorizationCount     = 1
        OptionBoundReferenceCount   = 0
    }
    $DisabledAuthenticationState = Get-SshAccessPublicState -Context $StateContext
    Assert-SshAccessTestEqual `
        $DisabledAuthenticationState.Authorization `
        'granted' `
        'Authentication policy should not hide a safely readable authorization reference.'
    Assert-SshAccessTestContains `
        $DisabledAuthenticationState.Error `
        'PubkeyAuthentication is disabled' `
        'Status should still expose the ineffective server authentication policy.'
    $script:PublicTestConfigState.Compatible = $true
    $script:PublicTestConfigState.PublicKeyAuthentication = 'default-enabled'
    $script:PublicTestConfigState.PublicKeyAuthenticationEnabled = $true
    $script:PublicTestConfigState.Issues = @()

    Write-Host '[TEST] Public status summarizes access denial'
    function Test-SshAccessAdministrator {
        return $false
    }
    function Get-SshAccessAuthorizedKeyReferenceState {
        param(
            [string]$Path,
            [pscustomobject]$Key
        )

        throw [UnauthorizedAccessException]::new(
            "Access to the path '$Path' is denied."
        )
    }
    $DeniedState = Get-SshAccessPublicState -Context $StateContext
    Assert-SshAccessTestContains `
        $DeniedState.Error `
        'Access denied while reading SSH authorization.' `
        'Public status should replace wrapper exceptions with a short diagnosis.'
    Assert-SshAccessTestContains `
        $DeniedState.Error `
        $script:PublicTestAccount.AuthorizedKeysPath `
        'The short diagnosis should retain the affected authorization path.'
    Assert-SshAccessTestContains `
        $DeniedState.Error `
        'sshaccess.test .status public --uac' `
        'The short diagnosis should suggest the matching elevated status retry.'
    Assert-SshAccessTestTrue `
        (-not $DeniedState.Error.Contains('Exception calling')) `
        'Public status should hide PowerShell invocation wrapper noise.'
} finally {
    Remove-SshAccessTestScratchRoot -Path $ScratchRoot
}

Write-Host 'ssh access public reference tests: PASS' -ForegroundColor Green
