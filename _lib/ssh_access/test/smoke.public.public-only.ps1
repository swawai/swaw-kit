[CmdletBinding()]
param()

$ErrorActionPreference = 'Stop'
Set-StrictMode -Version 2.0

. (Join-Path $PSScriptRoot 'support.ps1')
. (Join-Path $script:SshAccessTestKitRoot 'runtime\bootstrap.ps1')

$ScratchRoot = New-SshAccessTestScratchRoot

try {
    $PrivatePath = Join-Path $ScratchRoot 'incoming_identity'
    $PublicPath = "$PrivatePath.pub"
    [IO.File]::WriteAllText(
        $PublicPath,
        (New-SshAccessTestPublicKeyLine -Seed 61 -Comment 'remote client'),
        (New-Object Text.UTF8Encoding($false))
    )
    $Context = [pscustomobject]@{
        CommandName    = 'sshaccess.test'
        PrivateKeyPath = $PrivatePath
        PublicKeyPath  = $PublicPath
        KeyType        = 'ed25519'
    }
    $Account = [pscustomobject]@{
        Name               = 'test-user'
        Enabled            = $true
        IsAdministrator    = $false
        IsCurrentUser      = $true
        AuthorizedKeysPath = Join-Path $ScratchRoot 'authorized_keys'
    }

    Write-Host '[TEST] Public-only is a valid key-material state'
    $KeyState = Get-SshAccessKeyState -Context $Context
    Assert-SshAccessTestEqual `
        $KeyState.KeyMaterial `
        'public-only' `
        'A declared public key should be reported as public-only material.'
    $KeyStatus = (Show-SshAccessKeyState -Context $Context -State $KeyState 6>&1 | Out-String)
    Assert-SshAccessTestContains `
        $KeyStatus `
        'Key material:      public-only' `
        'Status should present public-only as the primary material state.'
    Assert-SshAccessTestTrue `
        (-not $KeyStatus.Contains('Pair consistency:')) `
        'Pair consistency is not applicable when no private key exists.'

    function Resolve-SshAccessLocalUser {
        param([pscustomobject]$Context)
        return $Account
    }
    function Assert-SshAccessAuthorizedKeysConfiguration {
        param(
            [pscustomobject]$Context,
            [pscustomobject]$Account,
            [bool]$RequirePublicKeyAuthentication
        )
        return [pscustomobject]@{ Compatible = $true }
    }

    $script:KeyStateCalls = 0
    $script:AuthorizedKeyWrites = 0
    function Get-SshAccessKeyState {
        param([pscustomobject]$Context)
        $script:KeyStateCalls++
        return [pscustomobject]@{
            PairConsistency = 'mismatching'
            Error           = 'test mismatch'
        }
    }
    function Add-SshAccessAuthorizedKey {
        param(
            [pscustomobject]$Account,
            [pscustomobject]$Key
        )
        $script:AuthorizedKeyWrites++
        return [pscustomobject]@{ Changed = $true }
    }

    Write-Host '[TEST] Public grant requires only the declared public key'
    $ExitCode = Invoke-SshAccessPublicMutation `
        -Context $Context `
        -Operation grant `
        -Uac $false
    Assert-SshAccessTestEqual $ExitCode 0 'A public-only inbound key should be granted.'
    Assert-SshAccessTestEqual `
        $script:KeyStateCalls `
        0 `
        'Grant should not inspect a private key that is absent.'
    Assert-SshAccessTestEqual `
        $script:AuthorizedKeyWrites `
        1 `
        'The declared public key should reach authorized_keys storage.'

    Write-Host '[TEST] An existing contradictory private key still fails closed'
    [IO.File]::WriteAllText($PrivatePath, 'test private placeholder')
    Assert-SshAccessTestThrowsLike `
        {
            Invoke-SshAccessPublicMutation `
                -Context $Context `
                -Operation grant `
                -Uac $false
        } `
        '*private and public keys do not match*' `
        'An existing mismatching sibling should not silently split the entry identity.'
    Assert-SshAccessTestEqual `
        $script:KeyStateCalls `
        1 `
        'An existing inferred private key should trigger pair verification.'
    Assert-SshAccessTestEqual `
        $script:AuthorizedKeyWrites `
        1 `
        'A contradictory pair should fail before authorized_keys mutation.'
} finally {
    Remove-SshAccessTestScratchRoot -Path $ScratchRoot
}

Write-Host 'ssh access public-only tests: PASS' -ForegroundColor Green
