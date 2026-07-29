Set-StrictMode -Version 2.0

function Invoke-SshAccessStatusSection {
    param(
        [Parameter(Mandatory = $true)][string]$Name,
        [Parameter(Mandatory = $true)][scriptblock]$Action,
        [Parameter(Mandatory = $true)][bool]$OfferElevation,
        [Parameter(Mandatory = $true)][pscustomobject]$Context,
        [Parameter(Mandatory = $true)][string[]]$RetryArguments
    )

    try {
        & $Action
    } catch {
        Write-SshAccessHeading $Name
        Write-SshAccessField 'State' 'unknown'
        Write-SshAccessField 'Problem' (
            Get-SshAccessErrorSummary -ErrorRecord $_
        )
        if ($OfferElevation -and
            (Test-SshAccessAccessDeniedError -ErrorRecord $_)) {
            $Retry = Format-SshAccessCommand `
                -CommandName $Context.CommandName `
                -Arguments $RetryArguments
            Write-SshAccessWarning "Retry with UAC: $Retry"
        }
    }
}

function Get-SshAccessCurrentProcessIdentity {
    try {
        $Identity = [Security.Principal.WindowsIdentity]::GetCurrent()
        try {
            if ($null -eq $Identity -or $null -eq $Identity.User) {
                throw 'The current Windows process identity has no user SID.'
            }
            $Name = [string]$Identity.Name
            if ([string]::IsNullOrWhiteSpace($Name)) {
                $Name = $Identity.User.Value
            }
            return [pscustomobject]@{
                Name  = $Name
                Sid   = $Identity.User.Value
                Error = ''
            }
        } finally {
            if ($null -ne $Identity) {
                $Identity.Dispose()
            }
        }
    } catch {
        return [pscustomobject]@{
            Name  = 'unknown'
            Sid   = 'unknown'
            Error = $_.Exception.Message
        }
    }
}

function Invoke-SshAccessStatusCommand {
    param(
        [Parameter(Mandatory = $true)][pscustomobject]$Context,
        [Parameter(Mandatory = $true)]
        [AllowEmptyCollection()]
        [string[]]$Arguments
    )

    $Usage = "$($Context.CommandName) .status [key|private|public|ssh] [--uac]"
    $Domain = 'all'
    $DomainSpecified = $false
    $Uac = $false
    foreach ($Argument in $Arguments) {
        if ($Argument -eq '--uac') {
            if ($Uac) {
                throw "Duplicate option '--uac'. Usage: $Usage"
            }
            $Uac = $true
            continue
        }
        if ($DomainSpecified) {
            throw "Status accepts at most one domain. Usage: $Usage"
        }
        $Domain = $Argument.ToLowerInvariant()
        if (@('key', 'private', 'public', 'ssh') -notcontains $Domain) {
            throw "Unknown .status domain '$Argument'. Usage: $Usage"
        }
        $DomainSpecified = $true
    }

    $IsAdministrator = Test-SshAccessAdministrator
    if ($Uac -and -not $IsAdministrator) {
        [string[]]$ElevatedArguments = @('.status')
        if ($Domain -ne 'all') {
            $ElevatedArguments += $Domain
        }
        return Invoke-SshAccessElevatedCommand `
            -Context $Context `
            -Arguments $ElevatedArguments
    }

    [string[]]$RetryArguments = @('.status')
    if ($Domain -ne 'all') {
        $RetryArguments += $Domain
    }
    $RetryArguments += '--uac'
    $OfferElevation = -not $IsAdministrator

    Write-Host "SSH Access status: $($Context.CommandName)" -ForegroundColor Cyan
    if (@('all', 'public') -contains $Domain) {
        Write-SshAccessField 'SSH login target' $Context.UserName
    }
    if (@('all', 'private') -contains $Domain) {
        $ProcessIdentity = Get-SshAccessCurrentProcessIdentity
        Write-SshAccessField 'Agent/process user' $ProcessIdentity.Name
        Write-SshAccessField 'Agent/process SID' $ProcessIdentity.Sid
        if (-not [string]::IsNullOrWhiteSpace($ProcessIdentity.Error)) {
            Write-SshAccessWarning "Current process identity: $($ProcessIdentity.Error)"
        }
    }

    if (@('all', 'key') -contains $Domain) {
        Invoke-SshAccessStatusSection `
            -Name 'Bound key' `
            -Context $Context `
            -OfferElevation $OfferElevation `
            -RetryArguments $RetryArguments `
            -Action { Show-SshAccessKeyState -Context $Context }
    }
    if (@('all', 'private') -contains $Domain) {
        Invoke-SshAccessStatusSection `
            -Name 'Private key application' `
            -Context $Context `
            -OfferElevation $OfferElevation `
            -RetryArguments $RetryArguments `
            -Action { Show-SshAccessPrivateState -Context $Context }
    }
    if (@('all', 'public') -contains $Domain) {
        Invoke-SshAccessStatusSection `
            -Name 'Public key authorization' `
            -Context $Context `
            -OfferElevation $OfferElevation `
            -RetryArguments $RetryArguments `
            -Action { Show-SshAccessPublicState -Context $Context }
    }
    if (@('all', 'ssh') -contains $Domain) {
        Invoke-SshAccessStatusSection `
            -Name 'OpenSSH Client' `
            -Context $Context `
            -OfferElevation $OfferElevation `
            -RetryArguments $RetryArguments `
            -Action { Show-SshAccessClientState -Context $Context }
        Invoke-SshAccessStatusSection `
            -Name 'OpenSSH Server' `
            -Context $Context `
            -OfferElevation $OfferElevation `
            -RetryArguments $RetryArguments `
            -Action { Show-SshAccessServerState -Context $Context }
        if ($OfferElevation) {
            $Retry = Format-SshAccessCommand `
                -CommandName $Context.CommandName `
                -Arguments $RetryArguments
            Write-SshAccessWarning (
                "If protected SSH details show unknown, retry: $Retry"
            )
        }
    }
    return 0
}
