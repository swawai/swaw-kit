Set-StrictMode -Version 2.0

$script:ProjEntryIdentitySchema = 'swawkit.proj-entry.v0'

function Invoke-ProjIdentitySystemCommand {
    param(
        [Parameter(Mandatory = $true)][string]$Executable,
        [Parameter(Mandatory = $true)][string[]]$Arguments,
        [Parameter(Mandatory = $true)][string]$Description
    )

    $PreviousErrorActionPreference = $ErrorActionPreference
    try {
        $ErrorActionPreference = 'Continue'
        $Output = @(& $Executable @Arguments 2>&1)
        $ExitCode = $LASTEXITCODE
    } finally {
        $ErrorActionPreference = $PreviousErrorActionPreference
    }
    if ($ExitCode -ne 0) {
        throw (
            "$Description failed with exit code ${ExitCode}: " +
            [string]::Join(' ', [string[]]@(
                $Output | ForEach-Object { [string]$_ }
            ))
        )
    }
    return [string]::Join(
        [Environment]::NewLine,
        [string[]]@($Output | ForEach-Object { [string]$_ })
    )
}

function Get-ProjEntryFileIdentity {
    param([Parameter(Mandatory = $true)][string]$EntryFile)

    $EntryPath = [IO.Path]::GetFullPath($EntryFile)
    if (-not [IO.File]::Exists($EntryPath)) {
        throw "Project entry file does not exist: $EntryPath"
    }
    $EntryItem = Get-Item -LiteralPath $EntryPath -Force
    if (($EntryItem.Attributes -band
        [IO.FileAttributes]::ReparsePoint) -ne 0) {
        throw "Project entry file cannot be a reparse point: $EntryPath"
    }
    if ([string]::IsNullOrWhiteSpace([string]$env:SystemRoot)) {
        throw 'SystemRoot is unavailable; cannot identify the project entry.'
    }

    $Fsutil = Join-Path $env:SystemRoot 'System32\fsutil.exe'
    $Mountvol = Join-Path $env:SystemRoot 'System32\mountvol.exe'
    foreach ($Tool in @($Fsutil, $Mountvol)) {
        if (-not [IO.File]::Exists($Tool)) {
            throw "Required Windows identity tool is unavailable: $Tool"
        }
    }

    $FileOutput = Invoke-ProjIdentitySystemCommand `
        -Executable $Fsutil `
        -Arguments @('file', 'queryfileid', $EntryPath) `
        -Description 'Entry File ID query'
    $FileMatch = [regex]::Match(
        $FileOutput,
        '(?i)\b0x([0-9a-f]{16,32})\b'
    )
    if (-not $FileMatch.Success) {
        throw "Windows returned an unrecognized File ID: $FileOutput"
    }

    $VolumeRoot = [IO.Path]::GetPathRoot($EntryPath)
    $VolumeOutput = Invoke-ProjIdentitySystemCommand `
        -Executable $Mountvol `
        -Arguments @($VolumeRoot, '/L') `
        -Description 'Entry volume identity query'
    $VolumeMatch = [regex]::Match(
        $VolumeOutput,
        '(?i)\\\\\?\\Volume\{[0-9a-f-]+\}\\'
    )
    if (-not $VolumeMatch.Success) {
        throw "Windows returned an unrecognized volume identity: $VolumeOutput"
    }

    $VolumeId = $VolumeMatch.Value.TrimEnd('\').ToLowerInvariant()
    $FileId = $FileMatch.Groups[1].Value.ToLowerInvariant()
    return [pscustomobject][ordered]@{
        VolumeId = $VolumeId
        FileId = $FileId
        Key = "$VolumeId|$FileId"
    }
}

function Read-ProjEntryIdentityRecord {
    param([Parameter(Mandatory = $true)][string]$DataRoot)

    $RecordPath = Join-Path $DataRoot '_entry.json'
    if (-not [IO.File]::Exists($RecordPath)) {
        return [pscustomobject]@{
            Valid = $false
            Path = $RecordPath
            Error = 'identity record is missing'
            Value = $null
        }
    }

    try {
        $Value = [IO.File]::ReadAllText($RecordPath) |
            ConvertFrom-Json -ErrorAction Stop
        foreach ($Name in @(
            'schema',
            'entryName',
            'volumeId',
            'fileId'
        )) {
            if ([string]::IsNullOrWhiteSpace([string]$Value.$Name)) {
                throw "required property '$Name' is missing"
            }
        }
        if ([string]$Value.schema -cne $script:ProjEntryIdentitySchema) {
            throw "unsupported schema '$([string]$Value.schema)'"
        }
        if ([string]$Value.volumeId -cnotmatch
            '(?i)^\\\\\?\\volume\{[0-9a-f-]+\}$') {
            throw 'volumeId is invalid'
        }
        if ([string]$Value.fileId -cnotmatch '^[0-9a-f]{16,32}$') {
            throw 'fileId is invalid'
        }
        return [pscustomobject]@{
            Valid = $true
            Path = $RecordPath
            Error = ''
            Value = $Value
        }
    } catch {
        return [pscustomobject]@{
            Valid = $false
            Path = $RecordPath
            Error = $_.Exception.Message
            Value = $null
        }
    }
}

function Test-ProjEntryIdentityEqual {
    param(
        [Parameter(Mandatory = $true)][object]$Record,
        [Parameter(Mandatory = $true)][object]$Identity
    )

    return (
        [string]$Record.volumeId -ceq [string]$Identity.VolumeId -and
        [string]$Record.fileId -ceq [string]$Identity.FileId
    )
}

function Write-ProjEntryIdentityRecord {
    param(
        [Parameter(Mandatory = $true)][string]$DataRoot,
        [Parameter(Mandatory = $true)][string]$EntryName,
        [Parameter(Mandatory = $true)][string]$EntryFile,
        [Parameter(Mandatory = $true)][object]$Identity
    )

    if (-not [IO.Directory]::Exists($DataRoot)) {
        throw "Cannot publish identity for a missing DataRoot: $DataRoot"
    }
    $RecordPath = Join-Path $DataRoot '_entry.json'
    $TemporaryPath = Join-Path $DataRoot (
        "._entry.$([Guid]::NewGuid().ToString('N')).tmp"
    )
    $BackupPath = Join-Path $DataRoot (
        "._entry.$([Guid]::NewGuid().ToString('N')).backup"
    )
    $Record = [ordered]@{
        schema = $script:ProjEntryIdentitySchema
        entryName = $EntryName
        entryFile = [IO.Path]::GetFileName($EntryFile)
        volumeId = [string]$Identity.VolumeId
        fileId = [string]$Identity.FileId
    }
    $Content = ($Record | ConvertTo-Json -Depth 3) + [Environment]::NewLine
    try {
        [IO.File]::WriteAllText(
            $TemporaryPath,
            $Content,
            [Text.UTF8Encoding]::new($false)
        )
        if ([IO.File]::Exists($RecordPath)) {
            [IO.File]::Replace(
                $TemporaryPath,
                $RecordPath,
                $BackupPath,
                $true
            )
        } else {
            [IO.File]::Move($TemporaryPath, $RecordPath)
        }
    } finally {
        foreach ($Path in @($TemporaryPath, $BackupPath)) {
            if ([IO.File]::Exists($Path)) {
                [IO.File]::Delete($Path)
            }
        }
    }
}
