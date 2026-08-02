Set-StrictMode -Version 2.0

function Get-RdpClientHostsMarker {
    param([Parameter(Mandatory = $true)][string]$EntryFile)

    return "# swaw-kit:rdp-client entry=`"$EntryFile`""
}

function ConvertFrom-RdpClientHostsMarker {
    param([Parameter(Mandatory = $true)][AllowEmptyString()][string]$Line)

    $Match = [regex]::Match(
        $Line,
        '(?i)#\s*swaw-kit:rdp-client\s+entry="(?<Entry>[^"]+)"\s*$'
    )
    if (-not $Match.Success) {
        return $null
    }
    return [pscustomobject]@{
        EntryFile = $Match.Groups['Entry'].Value
    }
}

function Get-RdpClientOrphanedHostsEntries {
    param([Parameter(Mandatory = $true)][AllowEmptyString()][string[]]$Lines)

    $Orphans = @()
    for ($Index = 0; $Index -lt $Lines.Count; $Index++) {
        $Ownership = ConvertFrom-RdpClientHostsMarker -Line $Lines[$Index]
        if ($null -eq $Ownership -or $Ownership.EntryFile.Length -eq 0 -or
            [IO.File]::Exists($Ownership.EntryFile)) {
            continue
        }
        $CommentIndex = $Lines[$Index].IndexOf('#')
        $Content = $Lines[$Index].Substring(0, $CommentIndex).Trim()
        $Tokens = @($Content -split '\s+' | Where-Object { $_.Length -gt 0 })
        $MappedAlias = if ($Tokens.Count -ge 2) { $Tokens[1] } else { '' }
        $Orphans += [pscustomobject]@{
            Index     = $Index
            Alias     = $MappedAlias
            EntryFile = $Ownership.EntryFile
            Line      = $Lines[$Index]
        }
    }
    return $Orphans
}

function Get-RdpClientHostsState {
    param(
        [Parameter(Mandatory = $true)][AllowEmptyString()][string[]]$Lines,
        [Parameter(Mandatory = $true)][string]$Alias,
        [Parameter(Mandatory = $true)][string]$EntryFile,
        [AllowNull()][Net.IPAddress]$DesiredAddress
    )

    $Marker = Get-RdpClientHostsMarker -EntryFile $EntryFile
    $OwnedIndexes = @()
    $Mappings = @()

    for ($Index = 0; $Index -lt $Lines.Count; $Index++) {
        $Line = $Lines[$Index]
        $Ownership = ConvertFrom-RdpClientHostsMarker -Line $Line
        $MarkerMatchesEntry = $null -ne $Ownership -and [string]::Equals(
            $Ownership.EntryFile,
            $EntryFile,
            [StringComparison]::OrdinalIgnoreCase
        )
        if ($MarkerMatchesEntry) {
            $OwnedIndexes += $Index
        }

        $CommentIndex = $Line.IndexOf('#')
        $Content = if ($CommentIndex -ge 0) {
            $Line.Substring(0, $CommentIndex)
        } else {
            $Line
        }
        $Tokens = @($Content.Trim() -split '\s+' | Where-Object { $_.Length -gt 0 })
        if ($Tokens.Count -lt 2) {
            continue
        }

        $Address = $null
        $null = [Net.IPAddress]::TryParse($Tokens[0], [ref]$Address)
        $Aliases = [string[]]@($Tokens[1..($Tokens.Count - 1)])
        $MapsAlias = @($Aliases | Where-Object {
            [string]::Equals($_, $Alias, [StringComparison]::OrdinalIgnoreCase)
        }).Count -gt 0
        if ($MapsAlias -or $MarkerMatchesEntry) {
            $Mappings += [pscustomobject]@{
                Index     = $Index
                Line      = $Line
                Address   = $Address
                MapsAlias = $MapsAlias
                IsOwned   = $MarkerMatchesEntry
            }
        }
    }

    $OwnedMappings = @($Mappings | Where-Object { $_.IsOwned })
    $ForeignMappings = @($Mappings | Where-Object {
        $_.MapsAlias -and -not $_.IsOwned
    })
    $StateName = 'Missing'
    $ProblemLines = @()

    if ($OwnedIndexes.Count -gt 1) {
        $StateName = 'Conflict'
        $ProblemLines = $OwnedIndexes
    } elseif ($null -eq $DesiredAddress) {
        $StateName = 'UnsupportedSource'
        $ProblemLines = @($OwnedIndexes + ($ForeignMappings | ForEach-Object Index))
    } elseif ($OwnedIndexes.Count -eq 1) {
        if ($ForeignMappings.Count -gt 0) {
            $StateName = 'Conflict'
            $ProblemLines = @($OwnedIndexes + ($ForeignMappings | ForEach-Object Index))
        } else {
            $Owned = @($OwnedMappings | Where-Object {
                $_.Index -eq $OwnedIndexes[0]
            })
            if ($Owned.Count -eq 1 -and
                $Owned[0].MapsAlias -and
                $null -ne $Owned[0].Address -and
                $Owned[0].Address.Equals($DesiredAddress) -and
                $Owned[0].Line.EndsWith($Marker, [StringComparison]::OrdinalIgnoreCase)) {
                $StateName = 'Ready'
            } else {
                $StateName = 'Drifted'
                $ProblemLines = $OwnedIndexes
            }
        }
    } elseif ($ForeignMappings.Count -gt 0) {
        $BadForeign = @($ForeignMappings | Where-Object {
            $null -eq $_.Address -or -not $_.Address.Equals($DesiredAddress)
        })
        if ($BadForeign.Count -gt 0) {
            $StateName = 'Conflict'
            $ProblemLines = @($ForeignMappings | ForEach-Object Index)
        } else {
            $StateName = 'External'
        }
    }

    return [pscustomobject]@{
        Name           = $StateName
        Marker         = $Marker
        OwnedIndexes   = [int[]]@($OwnedIndexes)
        ProblemLines   = [int[]]@($ProblemLines)
        DesiredLine    = if ($null -eq $DesiredAddress) {
            $null
        } else {
            "$($DesiredAddress.IPAddressToString)`t$Alias`t$Marker"
        }
    }
}

function Add-RdpClientHostsLine {
    param(
        [Parameter(Mandatory = $true)][AllowEmptyString()][string[]]$Lines,
        [Parameter(Mandatory = $true)][string]$Line
    )

    $TrailingEmptyCount = 0
    for ($Index = $Lines.Count - 1; $Index -ge 0; $Index--) {
        if ($Lines[$Index].Length -ne 0) {
            break
        }
        $TrailingEmptyCount++
    }
    $Result = New-Object 'Collections.Generic.List[string]'
    $PrefixCount = $Lines.Count - $TrailingEmptyCount
    for ($Index = 0; $Index -lt $PrefixCount; $Index++) {
        $Result.Add($Lines[$Index])
    }
    $Result.Add($Line)
    for ($Index = 0; $Index -lt [Math]::Max(1, $TrailingEmptyCount); $Index++) {
        $Result.Add('')
    }
    return $Result.ToArray()
}

function Remove-RdpClientHostsLines {
    param(
        [Parameter(Mandatory = $true)][AllowEmptyString()][string[]]$Lines,
        [Parameter(Mandatory = $true)][int[]]$Indexes
    )

    $Remove = @{}
    foreach ($Index in $Indexes) {
        $Remove[$Index] = $true
    }
    return [string[]]@(for ($Index = 0; $Index -lt $Lines.Count; $Index++) {
        if (-not $Remove.ContainsKey($Index)) {
            $Lines[$Index]
        }
    })
}
