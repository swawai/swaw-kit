[CmdletBinding()]
param()

$ErrorActionPreference = 'Stop'
Set-StrictMode -Version 2.0

. (Join-Path $PSScriptRoot 'support.ps1')
. (Join-Path $script:SshAccessTestKitRoot 'runtime\bootstrap.ps1')

$ScratchRoot = New-SshAccessTestScratchRoot

try {
    Write-Host '[TEST] Public-key parsing and fingerprint'
    $Line = New-SshAccessTestPublicKeyLine -Seed 7 -Comment 'first comment'
    $Parsed = ConvertFrom-SshAccessPublicKeyLine -Line $Line
    Assert-SshAccessTestTrue ($null -ne $Parsed) 'A valid OpenSSH key should parse.'
    Assert-SshAccessTestEqual $Parsed.Type 'ssh-ed25519' 'The key type should parse.'
    Assert-SshAccessTestTrue `
        $Parsed.Fingerprint.StartsWith('SHA256:') `
        'The fingerprint should use the SHA256 OpenSSH form.'
    Assert-SshAccessTestEqual `
        (ConvertFrom-SshAccessPublicKeyLine -Line '# ignored') `
        $null `
        'A comment should not parse as a key.'

    $PublicPath = Join-Path $ScratchRoot 'id_ed25519.pub'
    [IO.File]::WriteAllText(
        $PublicPath,
        "# header`r`n$Line`r`n",
        (New-Object Text.UTF8Encoding($false))
    )
    $FromFile = Read-SshAccessPublicKeyFile -Path $PublicPath
    Assert-SshAccessTestEqual $FromFile.Identity $Parsed.Identity 'File parsing should retain key identity.'
    $PublicDisguisedAsPrivate = Join-Path $ScratchRoot 'not-a-private-key'
    [IO.File]::WriteAllText(
        $PublicDisguisedAsPrivate,
        $Line,
        (New-Object Text.UTF8Encoding($false))
    )
    Assert-SshAccessTestThrowsLike `
        {
            Get-SshAccessPrivateKeyFingerprint -Context ([pscustomobject]@{
                PrivateKeyPath = $PublicDisguisedAsPrivate
            })
        } `
        '*does not contain a supported private-key container*' `
        'A public key copied to the private path must not form a matching pair.'

    Write-Host '[TEST] Key domain owns filesystem path validation'
    $PrivateDirectoryPath = Join-Path $ScratchRoot 'private-directory'
    [void][IO.Directory]::CreateDirectory($PrivateDirectoryPath)
    Assert-SshAccessTestThrowsLike `
        {
            Get-SshAccessKeyState -Context ([pscustomobject]@{
                PrivateKeyPath = $PrivateDirectoryPath
                PublicKeyPath  = "$PrivateDirectoryPath.pub"
                KeyType        = 'ed25519'
            })
        } `
        '*SSH_ACCESS_PRIVATE_KEY_PATH points to a directory*' `
        'The key domain should reject a directory used as the private-key path.'

    $PublicDirectoryPath = Join-Path $ScratchRoot 'public-directory'
    [void][IO.Directory]::CreateDirectory($PublicDirectoryPath)
    Assert-SshAccessTestThrowsLike `
        {
            Get-SshAccessKeyState -Context ([pscustomobject]@{
                PrivateKeyPath = (Join-Path $ScratchRoot 'missing-private')
                PublicKeyPath  = $PublicDirectoryPath
                KeyType        = 'ed25519'
            })
        } `
        '*derived public key path points to a directory*' `
        'The key domain should reject a directory used as the public-key path.'

    Write-Host '[TEST] Pair consistency is explicit'
    $StatePrivatePath = Join-Path $ScratchRoot 'state-private'
    [IO.File]::WriteAllText($StatePrivatePath, 'private')
    $StateContext = [pscustomobject]@{
        PrivateKeyPath = $StatePrivatePath
        PublicKeyPath  = $PublicPath
        KeyType        = 'ed25519'
    }
    $script:PrivateFingerprint = $Parsed.Fingerprint
    function Get-SshAccessPrivateKeyFingerprint {
        param([pscustomobject]$Context)

        return $script:PrivateFingerprint
    }
    $PairState = Get-SshAccessKeyState -Context $StateContext
    Assert-SshAccessTestEqual `
        $PairState.PairConsistency `
        'matching' `
        'Equal private and public fingerprints should form a matching pair.'
    $script:PrivateFingerprint = 'SHA256:different'
    $PairState = Get-SshAccessKeyState -Context $StateContext
    Assert-SshAccessTestEqual `
        $PairState.PairConsistency `
        'mismatched' `
        'Different fingerprints must never be treated as one bound identity.'

    [IO.File]::WriteAllText(
        $PublicPath,
        "no-pty $Line`r`n",
        (New-Object Text.UTF8Encoding($false))
    )
    Assert-SshAccessTestThrowsLike `
        { Read-SshAccessPublicKeyFile -Path $PublicPath } `
        '*No valid OpenSSH public key*' `
        'The bound .pub file should reject authorized_keys options.'

    $SecondLine = New-SshAccessTestPublicKeyLine -Seed 8 -Comment 'second'
    [IO.File]::WriteAllText(
        $PublicPath,
        "$Line`r`n$SecondLine`r`n",
        (New-Object Text.UTF8Encoding($false))
    )
    Assert-SshAccessTestThrowsLike `
        { Read-SshAccessPublicKeyFile -Path $PublicPath } `
        '*must contain exactly one public key*' `
        'A bound public-key file should reject multiple keys.'

    Write-Host '[TEST] Generate refuses partial or existing pairs'
    $PrivatePath = Join-Path $ScratchRoot 'keys\id_ed25519'
    [void][IO.Directory]::CreateDirectory((Split-Path $PrivatePath -Parent))
    [IO.File]::WriteAllText($PrivatePath, 'existing private key')
    $Context = [pscustomobject]@{
        CommandName    = 'sshaccess.test'
        PrivateKeyPath = $PrivatePath
        PublicKeyPath  = "$PrivatePath.pub"
        KeyType        = 'ed25519'
        KeyComment     = 'test'
    }

    $script:KeygenProcessCalls = 0
    function Invoke-SshAccessConsoleProcess {
        param(
            [string]$Executable,
            [string[]]$Arguments,
            [string]$WorkingDirectory
        )

        $script:KeygenProcessCalls++
        return 0
    }

    Assert-SshAccessTestThrowsLike `
        { Invoke-SshAccessKeyGenerate -Context $Context } `
        '*Refusing to overwrite an existing key file*' `
        'Generate should refuse a partial existing pair.'
    Assert-SshAccessTestEqual `
        $script:KeygenProcessCalls `
        0 `
        'Generate should fail before starting ssh-keygen.'

    Write-Host '[TEST] Generate stages before publishing'
    Remove-Item -LiteralPath $PrivatePath -Force
    function Resolve-SshAccessOpenSshExecutable {
        param(
            [pscustomobject]$Context,
            [string]$Name
        )

        return 'mock-ssh-keygen.exe'
    }
    function Invoke-SshAccessConsoleProcess {
        param(
            [string]$Executable,
            [string[]]$Arguments,
            [string]$WorkingDirectory
        )

        $OutputPath = $Arguments[[Array]::IndexOf($Arguments, '-f') + 1]
        [IO.File]::WriteAllText($OutputPath, 'generated-private')
        [IO.File]::WriteAllText(
            "$OutputPath.pub",
            (New-SshAccessTestPublicKeyLine -Seed 31 -Comment 'generated'),
            (New-Object Text.UTF8Encoding($false))
        )
        return 0
    }
    $GenerateCode = Invoke-SshAccessKeyGenerate -Context $Context
    Assert-SshAccessTestEqual $GenerateCode 0 'A staged key pair should publish successfully.'
    Assert-SshAccessTestTrue `
        (Test-Path -LiteralPath $PrivatePath -PathType Leaf) `
        'Generate should publish the final private path.'
    Assert-SshAccessTestTrue `
        (Test-Path -LiteralPath "$PrivatePath.pub" -PathType Leaf) `
        'Generate should publish the derived public path.'
    Assert-SshAccessTestEqual `
        (@(Get-ChildItem -LiteralPath (Split-Path $PrivatePath -Parent) -Filter '.sshaccess-generate-*').Count) `
        0 `
        'Generate should clean its private temporary paths.'

    Remove-Item -LiteralPath $PrivatePath, "$PrivatePath.pub" -Force
    function Invoke-SshAccessConsoleProcess {
        param(
            [string]$Executable,
            [string[]]$Arguments,
            [string]$WorkingDirectory
        )

        [IO.File]::WriteAllText($Context.PrivateKeyPath, 'concurrent-owner')
        return 1
    }
    Assert-SshAccessTestThrowsLike `
        { Invoke-SshAccessKeyGenerate -Context $Context } `
        '*ssh-keygen failed with exit code 1*' `
        'A failed staged generation should report the native exit code.'
    Assert-SshAccessTestEqual `
        ([IO.File]::ReadAllText($PrivatePath)) `
        'concurrent-owner' `
        'Failure cleanup must not delete a target path created concurrently.'

    Write-Host '[TEST] Delete fails closed around authorization'
    Assert-SshAccessTestThrowsLike `
        { Invoke-SshAccessKeyDelete -Context $Context -Uac $false } `
        '*public key file is missing*' `
        'Delete should not remove the last private key when authorization can no longer be identified.'

    $script:DeleteAuthorization = 'unknown'
    $script:DeleteAuthorizationError = 'access denied'
    $script:ElevatedProbeExitCode = 0
    $script:ElevatedProbeCalls = 0
    function Get-SshAccessPublicState {
        param([pscustomobject]$Context)

        return [pscustomobject]@{
            Authorization = $script:DeleteAuthorization
            Error         = $script:DeleteAuthorizationError
        }
    }
    function Test-SshAccessAdministrator {
        return $false
    }
    function Invoke-SshAccessElevatedAuthorizationCheck {
        param([pscustomobject]$Context)

        $script:ElevatedProbeCalls++
        return $script:ElevatedProbeExitCode
    }

    Assert-SshAccessTestThrowsLike `
        { Assert-SshAccessKeyNotAuthorized -Context $Context -Uac $false } `
        '*delete --yes --uac*' `
        'An unreadable authorization should require explicit UAC.'
    Assert-SshAccessTestEqual `
        $script:ElevatedProbeCalls `
        0 `
        'Authorization checks must not elevate implicitly.'

    Assert-SshAccessKeyNotAuthorized -Context $Context -Uac $true
    Assert-SshAccessTestEqual `
        $script:ElevatedProbeCalls `
        1 `
        'Explicit --uac should elevate only the authorization probe.'

    $script:DeleteAuthorization = 'granted'
    Assert-SshAccessTestThrowsLike `
        { Assert-SshAccessKeyNotAuthorized -Context $Context -Uac $true } `
        '*still referenced*' `
        'A known grant should refuse deletion without an unnecessary UAC probe.'
    Assert-SshAccessTestEqual `
        $script:ElevatedProbeCalls `
        1 `
        'A readable grant should not elevate.'
    $script:DeleteAuthorization = 'option-bound'
    Assert-SshAccessTestThrowsLike `
        { Assert-SshAccessKeyNotAuthorized -Context $Context -Uac $true } `
        '*still referenced*' `
        'An option-bound identity reference should refuse deletion without elevation.'
    Assert-SshAccessTestEqual `
        $script:ElevatedProbeCalls `
        1 `
        'A readable option-bound reference should not elevate.'

    Write-Host '[TEST] Key command aliases'
    $script:KeyActionCalls = New-Object Collections.Generic.List[string]
    function Invoke-SshAccessKeyGenerate {
        param([pscustomobject]$Context)

        [void]$script:KeyActionCalls.Add('generate')
        return 31
    }
    function Invoke-SshAccessKeyFingerprint {
        param([pscustomobject]$Context)

        [void]$script:KeyActionCalls.Add('fingerprint')
        return 32
    }

    foreach ($Action in @('gen', 'generate')) {
        $Code = Invoke-SshAccessKeyCommand `
            -Context $Context `
            -Arguments @($Action)
        Assert-SshAccessTestEqual `
            $Code `
            31 `
            "$Action should dispatch to key generation."
    }
    Assert-SshAccessTestEqual `
        ($script:KeyActionCalls -join ',') `
        'generate,generate' `
        'Short and complete generation spellings should share one action.'

    $script:KeyActionCalls.Clear()
    foreach ($Action in @('fp', 'fingerprint')) {
        $Code = Invoke-SshAccessKeyCommand `
            -Context $Context `
            -Arguments @($Action)
        Assert-SshAccessTestEqual `
            $Code `
            32 `
            "$Action should dispatch to key fingerprinting."
    }
    Assert-SshAccessTestEqual `
        ($script:KeyActionCalls -join ',') `
        'fingerprint,fingerprint' `
        'Short and complete fingerprint spellings should share one action.'
    Assert-SshAccessTestThrowsLike `
        {
            Invoke-SshAccessKeyCommand `
                -Context $Context `
                -Arguments @('fing')
        } `
        "*Unknown .key command 'fing'*" `
        'The replaced fing spelling should not remain as a third alias.'

    Assert-SshAccessTestThrowsLike `
        {
            Invoke-SshAccessKeyCommand `
                -Context $Context `
                -Arguments @('generate', 'extra')
        } `
        '*Usage: sshaccess.test .key gen*' `
        'Complete aliases should report the preferred short spelling.'

    Write-Host '[TEST] Destructive command grammar'
    $script:KeyDeleteCalls = 0
    $script:KeyDeleteUac = New-Object Collections.Generic.List[bool]
    function Invoke-SshAccessKeyDelete {
        param(
            [pscustomobject]$Context,
            [bool]$Uac
        )

        $script:KeyDeleteCalls++
        $script:KeyDeleteUac.Add($Uac)
        return 23
    }

    Assert-SshAccessTestThrowsLike `
        { Invoke-SshAccessKeyCommand -Context $Context -Arguments @('delete') } `
        '*Deletion requires --yes*' `
        'Key deletion should require explicit confirmation.'
    Assert-SshAccessTestThrowsLike `
        { Invoke-SshAccessKeyCommand -Context $Context -Arguments @('delete', '--yes', '--force') } `
        "*Unexpected argument '--force'*" `
        'Key deletion should reject unknown switches.'
    Assert-SshAccessTestThrowsLike `
        { Invoke-SshAccessKeyCommand -Context $Context -Arguments @('delete', '--yes', '--yes') } `
        "*Duplicate option '--yes'*" `
        'Key deletion should reject duplicate confirmation.'
    Assert-SshAccessTestEqual `
        $script:KeyDeleteCalls `
        0 `
        'Invalid destructive commands must fail before mutation.'

    $DeleteCode = Invoke-SshAccessKeyCommand `
        -Context $Context `
        -Arguments @('delete', '--yes')
    Assert-SshAccessTestEqual $DeleteCode 23 'A valid delete command should reach its domain action.'
    Assert-SshAccessTestEqual $script:KeyDeleteCalls 1 'Valid deletion should dispatch exactly once.'
    Assert-SshAccessTestEqual `
        $script:KeyDeleteUac[0] `
        $false `
        'Key deletion should not request implicit UAC.'

    $DeleteCode = Invoke-SshAccessKeyCommand `
        -Context $Context `
        -Arguments @('delete', '--yes', '--uac')
    Assert-SshAccessTestEqual $DeleteCode 23 'Delete --uac should reach its domain action.'
    Assert-SshAccessTestEqual `
        $script:KeyDeleteUac[1] `
        $true `
        'Delete --uac should forward explicit elevation consent.'

    Assert-SshAccessTestThrowsLike `
        { Invoke-SshAccessKeyCommand -Context $Context -Arguments @('unknown') } `
        "*Unknown .key command 'unknown'*" `
        'An unknown key command should fail explicitly.'
} finally {
    Remove-SshAccessTestScratchRoot -Path $ScratchRoot
}

Write-Host 'ssh access key tests: PASS' -ForegroundColor Green
