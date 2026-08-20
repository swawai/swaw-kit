Set-StrictMode -Version 2.0

$script:ProjManagerEntryIdBytes = 32
$script:ProjManagerEntryIdFileBytes = 65

function Initialize-ProjManagerDataRoot {
    param(
        [Parameter(Mandatory = $true)][string]$DataRoot,
        [switch]$MigrateLegacy
    )

    $DataRoot = [IO.Path]::GetFullPath($DataRoot)
    $DataDirectory = Split-Path -Path $DataRoot -Parent
    Assert-ProjManagerDirectory -Path $DataDirectory -Create

    $Item = Get-Item -LiteralPath $DataRoot -Force -ErrorAction SilentlyContinue
    if ($null -eq $Item) {
        return New-ProjManagerDataRoot -DataRoot $DataRoot
    }
    Assert-ProjManagerDirectory -Path $DataRoot

    $EntryIdPath = Join-Path $DataRoot 'entry.id'
    $EntryIdItem = Get-Item `
        -LiteralPath $EntryIdPath `
        -Force `
        -ErrorAction SilentlyContinue
    if ($null -ne $EntryIdItem) {
        return Read-ProjManagerEntryId -Path $EntryIdPath
    }
    if (-not $MigrateLegacy) {
        throw (
            'The existing manager DataRoot has no entry.id. Review the ' +
            'legacy state, then explicitly run bootstrap.ps1 ' +
            "-MigrateLegacyManagerDataRoot: $DataRoot"
        )
    }
    return Add-ProjManagerEntryId -DataRoot $DataRoot
}

function New-ProjManagerDataRoot {
    param([Parameter(Mandatory = $true)][string]$DataRoot)

    $Parent = Split-Path -Path $DataRoot -Parent
    $Stage = Join-Path $Parent (
        ".proj.swawkit.$([Guid]::NewGuid().ToString('N')).tmp"
    )
    [void][IO.Directory]::CreateDirectory($Stage)
    $Committed = $false
    try {
        $EntryId = New-ProjManagerEntryId
        Write-ProjManagerEntryIdCreateNew `
            -Path (Join-Path $Stage 'entry.id') `
            -EntryId $EntryId
        try {
            [IO.Directory]::Move($Stage, $DataRoot)
            $Committed = $true
            return $EntryId
        } catch {
            if (-not [IO.Directory]::Exists($DataRoot)) {
                throw
            }
            Assert-ProjManagerDirectory -Path $DataRoot
            return Read-ProjManagerEntryId -Path (Join-Path $DataRoot 'entry.id')
        }
    } finally {
        if (-not $Committed -and [IO.Directory]::Exists($Stage)) {
            [IO.Directory]::Delete($Stage, $true)
        }
    }
}

function Add-ProjManagerEntryId {
    param([Parameter(Mandatory = $true)][string]$DataRoot)

    $EntryIdPath = Join-Path $DataRoot 'entry.id'
    $Stage = Join-Path $DataRoot (
        ".entry.id.$([Guid]::NewGuid().ToString('N')).tmp"
    )
    $EntryId = New-ProjManagerEntryId
    try {
        Write-ProjManagerEntryIdCreateNew -Path $Stage -EntryId $EntryId
        try {
            [IO.File]::Move($Stage, $EntryIdPath)
            return $EntryId
        } catch {
            if (-not [IO.File]::Exists($EntryIdPath)) {
                throw
            }
            Assert-ProjManagerDirectory -Path $DataRoot
            return Read-ProjManagerEntryId -Path $EntryIdPath
        }
    } finally {
        if ([IO.File]::Exists($Stage)) {
            [IO.File]::Delete($Stage)
        }
    }
}

function New-ProjManagerEntryId {
    [byte[]]$Bytes = New-Object byte[] $script:ProjManagerEntryIdBytes
    $Random = [Security.Cryptography.RandomNumberGenerator]::Create()
    try {
        $Random.GetBytes($Bytes)
    } finally {
        $Random.Dispose()
    }
    return [BitConverter]::ToString($Bytes).Replace('-', '').ToLowerInvariant()
}

function Write-ProjManagerEntryIdCreateNew {
    param(
        [Parameter(Mandatory = $true)][string]$Path,
        [Parameter(Mandatory = $true)][string]$EntryId
    )

    if ($EntryId -cnotmatch '^[a-f0-9]{64}$') {
        throw 'Cannot publish an invalid manager Entry ID.'
    }
    [byte[]]$Bytes = [Text.Encoding]::ASCII.GetBytes($EntryId + "`n")
    $Stream = [IO.File]::Open(
        $Path,
        [IO.FileMode]::CreateNew,
        [IO.FileAccess]::Write,
        [IO.FileShare]::None
    )
    try {
        $Stream.Write($Bytes, 0, $Bytes.Length)
        $Stream.Flush($true)
    } finally {
        $Stream.Dispose()
    }
}

function Read-ProjManagerEntryId {
    param([Parameter(Mandatory = $true)][string]$Path)

    $Item = Get-Item -LiteralPath $Path -Force -ErrorAction SilentlyContinue
    if ($null -eq $Item -or $Item.PSIsContainer -or
        ($Item.Attributes -band [IO.FileAttributes]::ReparsePoint) -ne 0 -or
        $Item.Length -ne $script:ProjManagerEntryIdFileBytes) {
        throw "The manager entry.id is unsafe or invalid: $Path"
    }
    [byte[]]$Bytes = [IO.File]::ReadAllBytes($Path)
    if ($Bytes.Count -ne $script:ProjManagerEntryIdFileBytes -or
        $Bytes[64] -ne 10) {
        throw "The manager entry.id is invalid: $Path"
    }
    for ($Index = 0; $Index -lt 64; $Index++) {
        $Byte = $Bytes[$Index]
        if (-not (($Byte -ge 48 -and $Byte -le 57) -or
            ($Byte -ge 97 -and $Byte -le 102))) {
            throw "The manager entry.id is invalid: $Path"
        }
    }
    return [Text.Encoding]::ASCII.GetString($Bytes, 0, 64)
}

function Assert-ProjManagerDirectory {
    param(
        [Parameter(Mandatory = $true)][string]$Path,
        [switch]$Create
    )

    if ($Create -and -not [IO.Directory]::Exists($Path)) {
        [void][IO.Directory]::CreateDirectory($Path)
    }
    $Item = Get-Item -LiteralPath $Path -Force -ErrorAction SilentlyContinue
    if ($null -eq $Item -or -not $Item.PSIsContainer -or
        ($Item.Attributes -band [IO.FileAttributes]::ReparsePoint) -ne 0) {
        throw "The manager DataRoot directory is unsafe: $Path"
    }
}
