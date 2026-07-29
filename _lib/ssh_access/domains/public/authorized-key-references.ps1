Set-StrictMode -Version 2.0

function Split-SshAccessAuthorizedKeyFields {
    param([Parameter(Mandatory = $true)][string]$Line)

    $Fields = New-Object Collections.Generic.List[string]
    $Builder = New-Object Text.StringBuilder
    $InQuotes = $false
    $Escaped = $false
    foreach ($Character in $Line.ToCharArray()) {
        if ($Escaped) {
            [void]$Builder.Append($Character)
            $Escaped = $false
            continue
        }
        if ($Character -eq '\' -and $InQuotes) {
            $Escaped = $true
            [void]$Builder.Append($Character)
            continue
        }
        if ($Character -eq '"') {
            $InQuotes = -not $InQuotes
            [void]$Builder.Append($Character)
            continue
        }
        if ([char]::IsWhiteSpace($Character) -and -not $InQuotes) {
            if ($Builder.Length -gt 0) {
                $Fields.Add($Builder.ToString())
                [void]$Builder.Clear()
            }
            continue
        }
        [void]$Builder.Append($Character)
    }
    if ($Builder.Length -gt 0) {
        $Fields.Add($Builder.ToString())
    }
    return @($Fields)
}

function Test-SshAccessPublicKeyIdentity {
    param(
        [AllowNull()][pscustomobject]$Candidate,
        [Parameter(Mandatory = $true)][pscustomobject]$Key
    )

    return $null -ne $Candidate -and
        [string]::Equals($Candidate.Type, $Key.Type, [StringComparison]::Ordinal) -and
        [string]::Equals($Candidate.Blob, $Key.Blob, [StringComparison]::Ordinal)
}

function Get-SshAccessAuthorizedKeyLineReferenceKind {
    param(
        [Parameter(Mandatory = $true)]
        [AllowEmptyString()]
        [string]$Line,
        [Parameter(Mandatory = $true)][pscustomobject]$Key
    )

    $Trimmed = $Line.TrimStart()
    if ([string]::IsNullOrWhiteSpace($Trimmed) -or $Trimmed.StartsWith('#')) {
        return $null
    }
    $Fields = @(Split-SshAccessAuthorizedKeyFields -Line $Line)

    if ($Fields.Count -ge 2) {
        $PlainCandidate = ConvertFrom-SshAccessPublicKeyLine `
            -Line "$($Fields[0]) $($Fields[1])"
        if (Test-SshAccessPublicKeyIdentity -Candidate $PlainCandidate -Key $Key) {
            return 'plain'
        }
    }
    if ($Fields.Count -ge 3) {
        $OptionBoundCandidate = ConvertFrom-SshAccessPublicKeyLine `
            -Line "$($Fields[1]) $($Fields[2])"
        if (Test-SshAccessPublicKeyIdentity -Candidate $OptionBoundCandidate -Key $Key) {
            return 'option-bound'
        }
    }
    return $null
}

function Measure-SshAccessAuthorizedKeyReferences {
    param(
        [Parameter(Mandatory = $true)]
        [AllowEmptyCollection()]
        [AllowEmptyString()]
        [string[]]$Lines,
        [Parameter(Mandatory = $true)][pscustomobject]$Key
    )

    $PlainCount = 0
    $OptionBoundCount = 0
    foreach ($Line in $Lines) {
        $Kind = Get-SshAccessAuthorizedKeyLineReferenceKind -Line $Line -Key $Key
        if ($Kind -eq 'plain') {
            $PlainCount++
        } elseif ($Kind -eq 'option-bound') {
            $OptionBoundCount++
        }
    }

    $ReferenceState = if ($PlainCount -gt 0 -and $OptionBoundCount -gt 0) {
        'ambiguous'
    } elseif ($PlainCount -gt 0) {
        'plain'
    } elseif ($OptionBoundCount -gt 0) {
        'option-bound'
    } else {
        'none'
    }
    return [pscustomobject]@{
        State                       = $ReferenceState
        IdentityReferenceCount      = $PlainCount + $OptionBoundCount
        PlainAuthorizationCount     = $PlainCount
        OptionBoundReferenceCount   = $OptionBoundCount
    }
}
