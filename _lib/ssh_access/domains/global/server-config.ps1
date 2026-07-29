Set-StrictMode -Version 2.0

function Test-SshAccessListenAddressHasPort {
    param([Parameter(Mandatory = $true)][string]$Value)

    return $Value -match '^\[[^\]]+\]:\d+$' -or
        $Value -match '^[^:]+:\d+$'
}

function Get-SshAccessServerPortConfigurationState {
    param([Parameter(Mandatory = $true)][pscustomobject]$Context)

    $Path = Get-SshAccessSshdConfigPath -Context $Context
    try {
        $Document = Read-SshAccessSshdConfigDocument -Path $Path
    } catch {
        return [pscustomobject]@{
            Status          = if (Test-Path -LiteralPath $Path -PathType Leaf) {
                'Unknown'
            } else {
                'Missing'
            }
            Path            = $Path
            Port            = $null
            Source          = $null
            Ports           = @()
            PortLineIndexes = @()
            Issues          = @($_.Exception.Message)
            Document        = $null
        }
    }

    $Ports = New-Object Collections.Generic.List[int]
    $PortLineIndexes = New-Object Collections.Generic.List[int]
    $Issues = New-Object Collections.Generic.List[string]
    $Scope = 'global'
    for ($Index = 0; $Index -lt $Document.Lines.Count; $Index++) {
        $Content = (
            Remove-SshAccessSshdConfigComment -Line $Document.Lines[$Index]
        ).Trim()
        if ([string]::IsNullOrWhiteSpace($Content)) {
            continue
        }
        $Fields = @(Split-SshAccessSshdConfigFields -Text $Content)
        if ($Fields.Count -eq 0) {
            continue
        }

        $Directive = $Fields[0].ToLowerInvariant()
        if ($Directive -eq 'include') {
            $Issues.Add("Line $($Index + 1): Include is not managed by the port command.")
            continue
        }
        if ($Directive -eq 'match') {
            if ($Fields.Count -eq 2 -and $Fields[1] -ieq 'all') {
                $Scope = 'global'
            } else {
                $Scope = 'match'
            }
            continue
        }
        if ($Directive -eq 'port') {
            if ($Scope -ne 'global') {
                $Issues.Add("Line $($Index + 1): Port is outside the global section.")
                continue
            }
            $Port = 0
            if ($Fields.Count -ne 2 -or
                -not [int]::TryParse($Fields[1], [ref]$Port) -or
                $Port -lt 1 -or
                $Port -gt 65535) {
                $Issues.Add("Line $($Index + 1): invalid Port directive.")
                continue
            }
            $Ports.Add($Port)
            $PortLineIndexes.Add($Index)
            continue
        }
        if ($Directive -eq 'listenaddress' -and $Fields.Count -ge 2) {
            foreach ($Value in @($Fields | Select-Object -Skip 1)) {
                if (Test-SshAccessListenAddressHasPort -Value $Value) {
                    $Issues.Add(
                        "Line $($Index + 1): a port-qualified ListenAddress is not managed."
                    )
                    break
                }
            }
        }
    }

    if ($Ports.Count -gt 1) {
        $Issues.Add('Multiple active Port directives are not managed.')
    }
    $Status = if ($Issues.Count -eq 0) { 'Known' } else { 'Unsupported' }
    $Port = if ($Status -ne 'Known') {
        $null
    } elseif ($Ports.Count -eq 0) {
        22
    } else {
        $Ports[0]
    }
    $Source = if ($Status -ne 'Known') {
        $null
    } elseif ($Ports.Count -eq 0) {
        'Default'
    } else {
        'Explicit'
    }

    return [pscustomobject]@{
        Status          = $Status
        Path            = $Path
        Port            = $Port
        Source          = $Source
        Ports           = [int[]]@($Ports)
        PortLineIndexes = [int[]]@($PortLineIndexes)
        Issues          = [string[]]@($Issues)
        Document        = $Document
    }
}

function Assert-SshAccessManagedServerPortState {
    param([Parameter(Mandatory = $true)][pscustomobject]$State)

    if ($State.Status -eq 'Known') {
        return [int]$State.Port
    }
    $Detail = [string]::Join(' ', [string[]]@($State.Issues))
    throw "Cannot manage the sshd port in '$($State.Path)'. $Detail"
}

function New-SshAccessServerPortConfigBytes {
    param(
        [Parameter(Mandatory = $true)][pscustomobject]$State,
        [Parameter(Mandatory = $true)][ValidateRange(1, 65535)][int]$Port
    )

    $null = Assert-SshAccessManagedServerPortState -State $State
    $Document = $State.Document
    [string[]]$Lines = @($Document.Lines)
    if ($State.PortLineIndexes.Count -eq 1) {
        $Index = $State.PortLineIndexes[0]
        $Original = $Lines[$Index]
        $Indent = [regex]::Match($Original, '^\s*').Value
        $CommentMatch = [regex]::Match($Original, '\s+#.*$')
        $Comment = if ($CommentMatch.Success) { $CommentMatch.Value } else { '' }
        $Lines[$Index] = "${Indent}Port $Port$Comment"
        return ConvertTo-SshAccessSshdConfigBytes -Document $Document -Lines $Lines
    }

    $CommentIndex = -1
    $FirstMatchIndex = $Lines.Count
    for ($Index = 0; $Index -lt $Lines.Count; $Index++) {
        $Trimmed = $Lines[$Index].Trim()
        if ($Trimmed -match '^(?i:Match)\s+' -and
            $Trimmed -notmatch '^(?i:Match)\s+All(?:\s*(?:#.*)?)$') {
            $FirstMatchIndex = $Index
            break
        }
        if ($CommentIndex -lt 0 -and
            $Lines[$Index] -match '^\s*#\s*(?i:Port)\s+\d+\s*(?:#.*)?$') {
            $CommentIndex = $Index
        }
    }
    if ($CommentIndex -ge 0) {
        $Indent = [regex]::Match($Lines[$CommentIndex], '^\s*').Value
        $Lines[$CommentIndex] = "${Indent}Port $Port"
    } else {
        $Before = if ($FirstMatchIndex -eq 0) {
            @()
        } else {
            @($Lines | Select-Object -First $FirstMatchIndex)
        }
        $After = @($Lines | Select-Object -Skip $FirstMatchIndex)
        $Lines = [string[]]@($Before + "Port $Port" + $After)
    }
    return ConvertTo-SshAccessSshdConfigBytes -Document $Document -Lines $Lines
}
