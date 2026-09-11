[CmdletBinding()]
param(
    [Parameter(ValueFromRemainingArguments = $true)]
    [string[]]$ForwardedArguments = @()
)

$ErrorActionPreference = 'Stop'
. "$PSScriptRoot\identity.ps1"

try {
    if ($ForwardedArguments.Count -lt 2 -or
        $ForwardedArguments[0] -ine 'auth' -or
        $ForwardedArguments[1] -ine 'login') {
        throw 'Internal auth login dispatch is invalid.'
    }

    $userArguments = @($ForwardedArguments | Select-Object -Skip 2)
    foreach ($argument in $userArguments) {
        if ($argument -ieq '-h' -or
            $argument -imatch '^-h.+' -or
            $argument -ieq '--hostname' -or
            $argument -imatch '^--hostname=') {
            throw "This entry is bound to GH_HOST=$($env:GH_HOST). Do not pass -h or --hostname."
        }
        if ($argument -ieq '-p' -or
            $argument -imatch '^-p.+' -or
            $argument -ieq '--git-protocol' -or
            $argument -imatch '^--git-protocol=') {
            throw "This entry is bound to GH_ID_GIT_PROTOCOL=$($env:GH_ID_GIT_PROTOCOL). Do not pass -p or --git-protocol."
        }
        if ($argument -ieq '--skip-ssh-key' -or
            $argument -imatch '^--skip-ssh-key=') {
            throw 'SSH key discovery/upload policy is managed by this entry. Do not pass --skip-ssh-key.'
        }
    }
} catch {
    Write-Host "[ERROR] Unable to start GitHub login: $($_.Exception.Message)"
    exit 1
}

$boundArguments = @(
    'auth',
    'login',
    '--hostname',
    $env:GH_HOST,
    '--git-protocol',
    $env:GH_ID_GIT_PROTOCOL
)
if ($env:GH_ID_GIT_PROTOCOL -eq 'ssh') {
    $boundArguments += '--skip-ssh-key'
}

Remove-Item Env:GH_PROMPT_DISABLED -ErrorAction SilentlyContinue
& $env:GH_ID_GH_EXE @boundArguments @userArguments
$loginExitCode = $LASTEXITCODE
if ($loginExitCode -ne 0) {
    exit $loginExitCode
}
if ($userArguments -icontains '--help') {
    exit 0
}

try {
    $identity = Get-GithubCliActiveAccount `
        -Executable $env:GH_ID_GH_EXE `
        -HostName $env:GH_HOST
    if (-not (Test-GithubCliExpectedAccount `
        -Identity $identity `
        -ExpectedAccount $env:GH_ID_ACCOUNT)) {
        $actual = if ($identity.Account) { $identity.Account } else { '<none>' }
        throw "Expected GitHub account '$($env:GH_ID_ACCOUNT)', but the authenticated account is '$actual'."
    }
    Write-Host "[OK] Active GitHub account: $($identity.Account)"
    exit 0
} catch {
    Write-Host "[ERROR] GitHub account validation failed: $($_.Exception.Message)"
    exit 1
}
