Set-StrictMode -Version 2.0

$script:ProjManagerEntryIdBytes = 32
$script:ProjManagerEntryIdFileBytes = 65
$script:ProjManagerLegacyRecordMaxBytes = 65536

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
    Assert-ProjManagerLegacyRecord -DataRoot $DataRoot
    return Add-ProjManagerEntryId -DataRoot $DataRoot
}

function Assert-ProjManagerLegacyRecord {
    param([Parameter(Mandatory = $true)][string]$DataRoot)

    $Path = Join-Path $DataRoot '_entry.json'
    $Item = Get-Item -LiteralPath $Path -Force -ErrorAction SilentlyContinue
    if ($null -eq $Item -or $Item.PSIsContainer -or
        ($Item.Attributes -band [IO.FileAttributes]::ReparsePoint) -ne 0 -or
        $Item.Length -le 0 -or
        $Item.Length -gt $script:ProjManagerLegacyRecordMaxBytes) {
        throw "The manager legacy identity record is missing, unsafe, or invalid: $Path"
    }

    $Stream = [IO.File]::Open(
        $Path,
        [IO.FileMode]::Open,
        [IO.FileAccess]::Read,
        [IO.FileShare]::Read
    )
    try {
        $Length = $Stream.Length
        if ($Length -le 0 -or
            $Length -gt $script:ProjManagerLegacyRecordMaxBytes) {
            throw "The manager legacy identity record has an invalid length: $Path"
        }
        [byte[]]$Bytes = New-Object byte[] ([int]$Length)
        $Offset = 0
        while ($Offset -lt $Bytes.Length) {
            $Read = $Stream.Read($Bytes, $Offset, $Bytes.Length - $Offset)
            if ($Read -eq 0) {
                throw "The manager legacy identity record changed while being read: $Path"
            }
            $Offset += $Read
        }
        if ($Stream.Length -ne $Length) {
            throw "The manager legacy identity record changed while being read: $Path"
        }
    } finally {
        $Stream.Dispose()
    }

    try {
        $Json = [Text.UTF8Encoding]::new($false, $true).GetString($Bytes)
        $Document = ConvertFrom-Json -InputObject $Json -ErrorAction Stop
    } catch {
        throw "The manager legacy identity record is not valid UTF-8 JSON: $Path"
    }
    if ($null -eq $Document -or $Document -is [Array]) {
        throw "The manager legacy identity record must be one JSON object: $Path"
    }

    $Required = @('schema', 'entryName', 'volumeId', 'fileId')
    $Allowed = @('schema', 'entryName', 'entryFile', 'volumeId', 'fileId')
    $Names = @($Document.PSObject.Properties | ForEach-Object Name)
    foreach ($Name in $Required) {
        if ($Names -cnotcontains $Name) {
            throw "The manager legacy identity record is missing '$Name': $Path"
        }
    }
    foreach ($Name in $Names) {
        if ($Allowed -cnotcontains $Name) {
            throw "The manager legacy identity record contains unsupported property '$Name': $Path"
        }
    }

    if ($Document.schema -isnot [string] -or
        $Document.schema -cne 'swawkit.proj-entry.v0' -or
        $Document.entryName -isnot [string] -or
        $Document.entryName -cne 'swawkit' -or
        $Document.volumeId -isnot [string] -or
        $Document.volumeId -cnotmatch '^\\\\\?\\volume\{[0-9A-Fa-f-]+\}$' -or
        $Document.fileId -isnot [string] -or
        $Document.fileId -cnotmatch '^[0-9a-f]{16,32}$') {
        throw "The manager legacy identity record does not identify swawkit.exe: $Path"
    }
    if ($Names -ccontains 'entryFile' -and
        $null -ne $Document.entryFile -and
        ($Document.entryFile -isnot [string] -or
            $Document.entryFile -ine 'swawkit.exe')) {
        throw "The manager legacy identity record has an invalid entryFile: $Path"
    }
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
