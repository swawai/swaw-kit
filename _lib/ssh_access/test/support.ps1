Set-StrictMode -Version 2.0

$script:SshAccessTestKitRoot = [IO.Path]::GetFullPath(
    (Join-Path $PSScriptRoot '..')
)
$script:SshAccessTestRepoRoot = [IO.Path]::GetFullPath(
    (Join-Path $script:SshAccessTestKitRoot '..\..')
)

function Assert-SshAccessTestTrue {
    param(
        [Parameter(Mandatory = $true)][bool]$Condition,
        [Parameter(Mandatory = $true)][string]$Message
    )

    if (-not $Condition) {
        throw "Assertion failed: $Message"
    }
}

function Assert-SshAccessTestEqual {
    param(
        [AllowNull()][object]$Actual,
        [AllowNull()][object]$Expected,
        [Parameter(Mandatory = $true)][string]$Message
    )

    if ([string]$Actual -cne [string]$Expected) {
        throw "Assertion failed: $Message`nExpected: $Expected`nActual:   $Actual"
    }
}

function Assert-SshAccessTestContains {
    param(
        [Parameter(Mandatory = $true)][string]$Text,
        [Parameter(Mandatory = $true)][string]$Expected,
        [Parameter(Mandatory = $true)][string]$Message
    )

    Assert-SshAccessTestTrue `
        -Condition $Text.Contains($Expected) `
        -Message "$Message. Missing: $Expected"
}

function Assert-SshAccessTestThrowsLike {
    param(
        [Parameter(Mandatory = $true)][scriptblock]$Action,
        [Parameter(Mandatory = $true)][string]$Pattern,
        [Parameter(Mandatory = $true)][string]$Message
    )

    try {
        & $Action
    } catch {
        Assert-SshAccessTestTrue `
            -Condition ($_.Exception.Message -like $Pattern) `
            -Message "$Message. Actual error: $($_.Exception.Message)"
        return
    }
    throw "Assertion failed: $Message. No exception was thrown."
}

function Save-SshAccessTestEnvironment {
    param([Parameter(Mandatory = $true)][string[]]$Names)

    $Saved = @{}
    foreach ($Name in $Names) {
        $Value = [Environment]::GetEnvironmentVariable(
            $Name,
            [EnvironmentVariableTarget]::Process
        )
        $Saved[$Name] = [pscustomobject]@{
            Exists = $null -ne $Value
            Value  = $Value
        }
    }
    return $Saved
}

function Restore-SshAccessTestEnvironment {
    param([Parameter(Mandatory = $true)][hashtable]$Saved)

    foreach ($Name in $Saved.Keys) {
        $Value = if ($Saved[$Name].Exists) {
            [string]$Saved[$Name].Value
        } else {
            $null
        }
        [Environment]::SetEnvironmentVariable(
            $Name,
            $Value,
            [EnvironmentVariableTarget]::Process
        )
    }
}

function Set-SshAccessTestValidEnvironment {
    param(
        [Parameter(Mandatory = $true)][string]$PrivateKeyPath,
        [string]$UserName = 'ssh_access_test_user'
    )

    $env:SSH_ACCESS_PROTOCOL = '1'
    $env:SSH_ACCESS_ENTRY_COMMAND = 'sshaccess.test'
    $env:SSH_ACCESS_ENTRY_FILE = Join-Path $script:SshAccessTestRepoRoot 'sshaccess1.dev.cmd'
    $env:SSH_ACCESS_PRIVATE_KEY_PATH = $PrivateKeyPath
    $env:SSH_ACCESS_USER = $UserName
    $env:SSH_ACCESS_KEY_TYPE = 'ed25519'
    $env:SSH_ACCESS_KEY_COMMENT = 'ssh-access-test'
}

function New-SshAccessTestScratchRoot {
    $Root = Join-Path (
        [IO.Path]::GetTempPath()
    ) ('swaw-kit-ssh-access-test-' + [Guid]::NewGuid().ToString('N'))
    [void][IO.Directory]::CreateDirectory($Root)
    return $Root
}

function Remove-SshAccessTestScratchRoot {
    param([Parameter(Mandatory = $true)][string]$Path)

    $FullPath = [IO.Path]::GetFullPath($Path)
    $TempRoot = [IO.Path]::GetFullPath([IO.Path]::GetTempPath()).
        TrimEnd('\', '/')
    $Parent = [IO.Path]::GetFullPath(
        (Split-Path $FullPath -Parent)
    ).TrimEnd('\', '/')
    $Leaf = Split-Path $FullPath -Leaf
    if (-not $Parent.Equals(
            $TempRoot,
            [StringComparison]::OrdinalIgnoreCase
        ) -or
        -not $Leaf.StartsWith(
            'swaw-kit-ssh-access-test-',
            [StringComparison]::Ordinal
        )) {
        throw "Refusing to remove an unexpected test path: $FullPath"
    }

    if ([IO.Directory]::Exists($FullPath)) {
        Remove-Item -LiteralPath $FullPath -Recurse -Force
    }
}

function New-SshAccessTestPublicKeyLine {
    param(
        [ValidateRange(0, 255)][int]$Seed = 1,
        [string]$Comment = 'ssh-access-test'
    )

    $Type = 'ssh-ed25519'
    [byte[]]$TypeBytes = [Text.Encoding]::ASCII.GetBytes($Type)
    [byte[]]$Bytes = New-Object byte[] (4 + $TypeBytes.Length + 4 + 32)
    $Length = $TypeBytes.Length
    $Bytes[0] = [byte](($Length -shr 24) -band 0xff)
    $Bytes[1] = [byte](($Length -shr 16) -band 0xff)
    $Bytes[2] = [byte](($Length -shr 8) -band 0xff)
    $Bytes[3] = [byte]($Length -band 0xff)
    [Array]::Copy($TypeBytes, 0, $Bytes, 4, $TypeBytes.Length)
    $KeyLengthOffset = 4 + $TypeBytes.Length
    $Bytes[$KeyLengthOffset] = 0
    $Bytes[$KeyLengthOffset + 1] = 0
    $Bytes[$KeyLengthOffset + 2] = 0
    $Bytes[$KeyLengthOffset + 3] = 32
    for ($Index = 0; $Index -lt 32; $Index++) {
        $Bytes[$KeyLengthOffset + 4 + $Index] = [byte](
            ($Seed + $Index) -band 0xff
        )
    }

    $Blob = [Convert]::ToBase64String($Bytes)
    if ([string]::IsNullOrWhiteSpace($Comment)) {
        return "$Type $Blob"
    }
    return "$Type $Blob $Comment"
}

function Assert-SshAccessTestUtf8WithoutBom {
    param(
        [Parameter(Mandatory = $true)][string]$Path,
        [Parameter(Mandatory = $true)][string]$Message
    )

    [byte[]]$Bytes = [IO.File]::ReadAllBytes($Path)
    $HasBom = $Bytes.Length -ge 3 -and
        $Bytes[0] -eq 0xef -and
        $Bytes[1] -eq 0xbb -and
        $Bytes[2] -eq 0xbf
    Assert-SshAccessTestTrue -Condition (-not $HasBom) -Message $Message

    $Utf8 = New-Object Text.UTF8Encoding($false, $true)
    try {
        [void]$Utf8.GetString($Bytes)
    } catch {
        throw "Assertion failed: $Message. File is not valid UTF-8: $($_.Exception.Message)"
    }
}
