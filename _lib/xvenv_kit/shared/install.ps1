Set-StrictMode -Version 2.0

function Get-XvenvInstallRoot {
    param(
        [Parameter(Mandatory = $true)][object]$Context,
        [Parameter(Mandatory = $true)][object]$Definition
    )

    $Name = Get-XvenvSafeSegment -Value ([string]$Definition.Name) -Description 'tool name'
    $Version = Get-XvenvSafeSegment -Value ([string]$Definition.Version) -Description "version for $Name"
    return Join-Path (Join-Path (Join-Path $Context.ProjectDataRoot 'modules') $Name) "installs\$Version"
}

function Get-XvenvInstallMetadataPath {
    param([Parameter(Mandatory = $true)][string]$InstallRoot)

    return Join-Path $InstallRoot '.xvenv-install.json'
}

function Write-XvenvInstallMetadata {
    param(
        [Parameter(Mandatory = $true)][object]$Definition,
        [Parameter(Mandatory = $true)][string]$InstallRoot
    )

    $Metadata = [ordered]@{
        schema = 'xvenv.install.v1'
        name = [string]$Definition.Name
        version = [string]$Definition.Version
        sourceSha256 = if ($Definition.ContainsKey('Sha256')) { [string]$Definition.Sha256 } else { '' }
    }
    Write-XvenvTextAtomic `
        -Path (Get-XvenvInstallMetadataPath $InstallRoot) `
        -Content (ConvertTo-XvenvJsonText $Metadata)
}

function Test-XvenvInstallMetadata {
    param(
        [Parameter(Mandatory = $true)][object]$Definition,
        [Parameter(Mandatory = $true)][string]$InstallRoot
    )

    $MetadataPath = Get-XvenvInstallMetadataPath $InstallRoot
    if (-not [IO.File]::Exists($MetadataPath)) {
        return $false
    }
    try {
        $Metadata = Get-Content -LiteralPath $MetadataPath -Raw -Encoding UTF8 | ConvertFrom-Json
    } catch {
        return $false
    }
    if ([string]$Metadata.schema -ne 'xvenv.install.v1' -or
        [string]$Metadata.name -ne [string]$Definition.Name -or
        [string]$Metadata.version -ne [string]$Definition.Version) {
        return $false
    }
    if ($Definition.ContainsKey('Sha256') -and
        -not [string]::IsNullOrWhiteSpace([string]$Definition.Sha256) -and
        [string]$Metadata.sourceSha256 -ne [string]$Definition.Sha256) {
        return $false
    }
    return $true
}

function Test-XvenvDefinitionPayload {
    param(
        [Parameter(Mandatory = $true)][object]$Context,
        [Parameter(Mandatory = $true)][object]$Definition,
        [Parameter(Mandatory = $true)][string]$InstallRoot
    )

    if (-not (Test-XvenvRequiredPaths `
        -Root $InstallRoot `
        -RelativePaths ([string[]]$Definition.RequiredPaths))) {
        return $false
    }

    $Handlers = $Definition._Handlers
    if ($Handlers.ContainsKey('Validate') -and $null -ne $Handlers.Validate) {
        $Validate = [scriptblock]$Handlers.Validate
        $Result = @(& $Validate $Context $Definition $InstallRoot)
        if ($Result.Count -ne 1 -or $Result[0] -isnot [bool]) {
            throw "The xvenv module '$($Definition.Name)' Validate callback must return exactly one Boolean."
        }
        return [bool]$Result[0]
    }
    return $true
}

function Test-XvenvDefinitionInstalled {
    param(
        [Parameter(Mandatory = $true)][object]$Context,
        [Parameter(Mandatory = $true)][object]$Definition
    )

    $InstallRoot = Get-XvenvInstallRoot -Context $Context -Definition $Definition
    return (Test-XvenvDefinitionPayload `
            -Context $Context `
            -Definition $Definition `
            -InstallRoot $InstallRoot) -and
        (Test-XvenvInstallMetadata -Definition $Definition -InstallRoot $InstallRoot)
}

function Get-XvenvPlanStatuses {
    param(
        [Parameter(Mandatory = $true)][object]$Context,
        [Parameter(Mandatory = $true)][object]$Plan
    )

    foreach ($Entry in @($Plan.tools)) {
        $Definition = Get-XvenvConfiguredDefinition -Context $Context -Entry $Entry
        $InstallRoot = Get-XvenvInstallRoot -Context $Context -Definition $Definition
        $Ready = Test-XvenvDefinitionInstalled -Context $Context -Definition $Definition
        $Details = ''
        $Dependencies = Get-XvenvConfiguredDependencies `
            -Context $Context `
            -Plan $Plan `
            -Definition $Definition
        foreach ($Name in [string[]]@($Definition.Requires)) {
            $Dependency = $Dependencies[$Name]
            if (-not (Test-XvenvDefinitionInstalled `
                -Context $Context `
                -Definition $Dependency)) {
                $Ready = $false
                $Details = "missing $($Dependency.Name) $($Dependency.Version)"
                break
            }
        }

        [pscustomobject]@{
            Tool = [string]$Definition.Name
            Version = [string]$Definition.Version
            State = if ($Ready) { 'ready' } else { 'missing' }
            Ready = $Ready
            Path = Join-Path $InstallRoot ([string[]]$Definition.RequiredPaths)[0]
            Details = $Details
        }
    }
}

function Assert-XvenvPlanInstalled {
    param(
        [Parameter(Mandatory = $true)][object]$Context,
        [Parameter(Mandatory = $true)][object]$Plan
    )

    $Missing = @(Get-XvenvPlanStatuses -Context $Context -Plan $Plan |
        Where-Object { -not $_.Ready })
    if ($Missing.Count -eq 0) {
        return
    }
    $Names = [string]::Join(
        ', ',
        [string[]]@($Missing | ForEach-Object { "$($_.Tool) $($_.Version)" })
    )
    throw "xvenv environment is incomplete: $Names"
}

function Copy-XvenvPayload {
    param(
        [Parameter(Mandatory = $true)][string]$Source,
        [Parameter(Mandatory = $true)][string]$Destination
    )

    [void][IO.Directory]::CreateDirectory($Destination)
    foreach ($Item in Get-ChildItem -LiteralPath $Source -Force) {
        Copy-Item -LiteralPath $Item.FullName -Destination $Destination -Recurse -Force
    }
}

function Publish-XvenvInstallDirectory {
    param(
        [Parameter(Mandatory = $true)][object]$Context,
        [Parameter(Mandatory = $true)][string]$StagedPath,
        [Parameter(Mandatory = $true)][string]$TargetPath
    )

    $TargetPath = Get-XvenvFullPath $TargetPath
    $StagedPath = Get-XvenvFullPath $StagedPath
    [void][IO.Directory]::CreateDirectory((Split-Path $TargetPath -Parent))
    $BackupPath = "$TargetPath.backup-$([Guid]::NewGuid().ToString('N'))"
    $BackupKind = ''

    try {
        if ([IO.Directory]::Exists($TargetPath)) {
            [IO.Directory]::Move($TargetPath, $BackupPath)
            $BackupKind = 'directory'
        } elseif ([IO.File]::Exists($TargetPath)) {
            [IO.File]::Move($TargetPath, $BackupPath)
            $BackupKind = 'file'
        }
        [IO.Directory]::Move($StagedPath, $TargetPath)
    } catch {
        if (-not [IO.Directory]::Exists($TargetPath) -and
            -not [IO.File]::Exists($TargetPath)) {
            if ($BackupKind -eq 'directory' -and [IO.Directory]::Exists($BackupPath)) {
                [IO.Directory]::Move($BackupPath, $TargetPath)
                $BackupKind = ''
            } elseif ($BackupKind -eq 'file' -and [IO.File]::Exists($BackupPath)) {
                [IO.File]::Move($BackupPath, $TargetPath)
                $BackupKind = ''
            }
        }
        throw
    } finally {
        if ([IO.Directory]::Exists($StagedPath)) {
            Remove-XvenvControlledPath `
                -Path $StagedPath `
                -Root $Context.DataRoot `
                -Context 'cleaning a staged installation'
        }
    }

    if (-not [string]::IsNullOrWhiteSpace($BackupKind) -and
        ([IO.Directory]::Exists($BackupPath) -or [IO.File]::Exists($BackupPath))) {
        try {
            Remove-XvenvControlledPath `
                -Path $BackupPath `
                -Root $Context.DataRoot `
                -Context 'cleaning a replaced installation'
        } catch {
            Write-Warning "The old xvenv installation could not be removed: $BackupPath"
        }
    }
}

function Install-XvenvArchiveDefinition {
    param(
        [Parameter(Mandatory = $true)][object]$Context,
        [Parameter(Mandatory = $true)][object]$Definition,
        [AllowNull()][scriptblock]$Prepare = $null
    )

    if (Test-XvenvDefinitionInstalled -Context $Context -Definition $Definition) {
        return
    }

    Write-Host "[STEP] Installing $($Definition.Name) $($Definition.Version)..." -ForegroundColor Cyan
    $Payload = Get-XvenvCachedPayload -Context $Context -Definition $Definition
    $Target = Get-XvenvInstallRoot -Context $Context -Definition $Definition
    $Parent = Split-Path $Target -Parent
    [void][IO.Directory]::CreateDirectory($Parent)
    $Staged = Join-Path $Parent (".partial-$([Guid]::NewGuid().ToString('N'))")

    try {
        Copy-XvenvPayload -Source $Payload -Destination $Staged
        if ($null -ne $Prepare) {
            [void](& $Prepare $Staged)
        }
        if (-not (Test-XvenvDefinitionPayload `
            -Context $Context `
            -Definition $Definition `
            -InstallRoot $Staged)) {
            throw "Installation did not produce the required files for $($Definition.Name) $($Definition.Version)."
        }
        Write-XvenvInstallMetadata -Definition $Definition -InstallRoot $Staged
        Publish-XvenvInstallDirectory `
            -Context $Context `
            -StagedPath $Staged `
            -TargetPath $Target
        if (-not (Test-XvenvDefinitionInstalled -Context $Context -Definition $Definition)) {
            throw "Installation did not complete cleanly for $($Definition.Name) $($Definition.Version)."
        }
    } finally {
        if ([IO.Directory]::Exists($Staged)) {
            Remove-XvenvControlledPath `
                -Path $Staged `
                -Root $Context.DataRoot `
                -Context 'cleaning a failed installation'
        }
    }
}

function Install-XvenvCustomDefinition {
    param(
        [Parameter(Mandatory = $true)][object]$Context,
        [Parameter(Mandatory = $true)][object]$Definition,
        [Parameter(Mandatory = $true)][string]$Activity,
        [Parameter(Mandatory = $true)][scriptblock]$Build
    )

    if (Test-XvenvDefinitionInstalled -Context $Context -Definition $Definition) {
        return
    }

    Write-Host "[STEP] $Activity..." -ForegroundColor Cyan
    $Target = Get-XvenvInstallRoot -Context $Context -Definition $Definition
    if ([IO.Directory]::Exists($Target) -or [IO.File]::Exists($Target)) {
        Remove-XvenvControlledPath `
            -Path $Target `
            -Root $Context.DataRoot `
            -Context "repairing an incomplete $($Definition.Name) installation"
    }
    [void][IO.Directory]::CreateDirectory($Target)

    try {
        [void](& $Build $Target)
        if (-not (Test-XvenvDefinitionPayload `
            -Context $Context `
            -Definition $Definition `
            -InstallRoot $Target)) {
            throw "$($Definition.Name) installation did not produce the required files."
        }
        Write-XvenvInstallMetadata `
            -Definition $Definition `
            -InstallRoot $Target
        if (-not (Test-XvenvDefinitionInstalled `
            -Context $Context `
            -Definition $Definition)) {
            throw "$($Definition.Name) installation did not complete cleanly."
        }
    } catch {
        if ([IO.Directory]::Exists($Target)) {
            Remove-XvenvControlledPath `
                -Path $Target `
                -Root $Context.DataRoot `
                -Context "cleaning a failed $($Definition.Name) installation"
        }
        throw
    }
}

function Invoke-XvenvExternal {
    param(
        [Parameter(Mandatory = $true)][object]$Context,
        [Parameter(Mandatory = $true)][string]$FilePath,
        [Parameter(Mandatory = $true)]
        [AllowEmptyCollection()]
        [string[]]$Arguments,
        [Parameter(Mandatory = $true)][hashtable]$Environment
    )

    $SavedEnvironment = @{}
    try {
        foreach ($Name in $Environment.Keys) {
            $Value = [Environment]::GetEnvironmentVariable(
                $Name,
                [EnvironmentVariableTarget]::Process
            )
            $SavedEnvironment[$Name] = if ($null -eq $Value) {
                [pscustomobject]@{ Exists = $false; Value = $null }
            } else {
                [pscustomobject]@{ Exists = $true; Value = [string]$Value }
            }
            [Environment]::SetEnvironmentVariable(
                $Name,
                [string]$Environment[$Name],
                [EnvironmentVariableTarget]::Process
            )
        }

        if ($null -ne $Context.RunExternal) {
            return [int](& $Context.RunExternal $FilePath $Arguments $Environment)
        }
        & $FilePath @Arguments
        return [int]$LASTEXITCODE
    } finally {
        foreach ($Name in $SavedEnvironment.Keys) {
            if ($SavedEnvironment[$Name].Exists) {
                [Environment]::SetEnvironmentVariable(
                    $Name,
                    $SavedEnvironment[$Name].Value,
                    [EnvironmentVariableTarget]::Process
                )
            } else {
                [Environment]::SetEnvironmentVariable(
                    $Name,
                    $null,
                    [EnvironmentVariableTarget]::Process
                )
            }
        }
    }
}
