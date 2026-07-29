[CmdletBinding()]
param()

$ErrorActionPreference = 'Stop'
Set-StrictMode -Version 2.0

. (Join-Path $PSScriptRoot 'support.ps1')
. (Join-Path $script:SshAccessTestKitRoot 'runtime\bootstrap.ps1')

$ScratchRoot = New-SshAccessTestScratchRoot

try {
    $BoundLine = New-SshAccessTestPublicKeyLine `
        -Seed 21 `
        -Comment 'bound-comment'
    $OtherLine = New-SshAccessTestPublicKeyLine `
        -Seed 87 `
        -Comment 'unrelated-comment'
    $BoundParsed = ConvertFrom-SshAccessPublicKeyLine -Line $BoundLine
    $OtherParsed = ConvertFrom-SshAccessPublicKeyLine -Line $OtherLine
    $BoundKey = [pscustomobject]@{
        Type = $BoundParsed.Type
        Blob = $BoundParsed.Blob
        Line = $BoundLine
    }

    Write-Host '[TEST] Add and revoke preserve unrelated authorized_keys text'
    $AuthDirectory = Join-Path $ScratchRoot '.ssh'
    [void][IO.Directory]::CreateDirectory($AuthDirectory)
    $AuthPath = Join-Path $AuthDirectory 'authorized_keys'
    $RetainedComment = '# ' + (-join ([char[]]@(
        0x4fdd,
        0x7559,
        0x8fd9,
        0x6761,
        0x6ce8,
        0x91ca
    )))
    $InitialText = [string]::Join(
        "`r`n",
        [string[]]@(
            $RetainedComment,
            $OtherLine,
            ''
        )
    ) + "`r`n"
    [IO.File]::WriteAllText(
        $AuthPath,
        $InitialText,
        (New-Object Text.UTF8Encoding($true))
    )

    $Account = [pscustomobject]@{
        Name               = 'test-user'
        Sid                = 'S-1-5-21-1-2-3-1001'
        IsAdministrator    = $false
        IsCurrentUser      = $true
        ProfilePath        = $ScratchRoot
        AuthorizedKeysPath = $AuthPath
    }

    $script:AclCalls = New-Object Collections.Generic.List[string]
    function Set-SshAccessAuthorizedKeysAcl {
        param(
            [string]$Path,
            [pscustomobject]$Account
        )

        $script:AclCalls.Add($Path)
    }

    $Added = Add-SshAccessAuthorizedKey -Account $Account -Key $BoundKey
    Assert-SshAccessTestEqual $Added.Changed $true 'The first add should change the file.'
    Assert-SshAccessTestEqual $Added.MatchCount 1 'The first add should report one identity.'
    $AfterAdd = [IO.File]::ReadAllText($AuthPath, [Text.Encoding]::UTF8)
    Assert-SshAccessTestContains $AfterAdd $RetainedComment 'Add should preserve comments.'
    Assert-SshAccessTestContains $AfterAdd $OtherLine 'Add should preserve unrelated keys.'
    Assert-SshAccessTestContains $AfterAdd $BoundLine 'Add should append the bound key.'
    Assert-SshAccessTestTrue `
        ($AfterAdd.Contains("`r`n")) `
        'Add should preserve the document newline style.'
    Assert-SshAccessTestUtf8WithoutBom `
        -Path $AuthPath `
        -Message 'Authorized keys should be UTF-8 without BOM after add.'

    $BeforeDuplicateAdd = [IO.File]::ReadAllBytes($AuthPath)
    $BoundWithNewComment = [pscustomobject]@{
        Type = $BoundParsed.Type
        Blob = $BoundParsed.Blob
        Line = "$($BoundParsed.Type) $($BoundParsed.Blob) replacement-comment"
    }
    $Duplicate = Add-SshAccessAuthorizedKey `
        -Account $Account `
        -Key $BoundWithNewComment
    Assert-SshAccessTestEqual `
        $Duplicate.Changed `
        $false `
        'The same key with a different comment should be idempotent.'
    Assert-SshAccessTestTrue `
        ([Linq.Enumerable]::SequenceEqual(
            [byte[]]$BeforeDuplicateAdd,
            [byte[]][IO.File]::ReadAllBytes($AuthPath)
        )) `
        'An idempotent add should not rewrite authorized_keys content.'

    $OptionOnlyPath = Join-Path $AuthDirectory 'option_only_authorized_keys'
    $OptionOnlyLine = "restrict,command=`"echo constrained`" $($BoundParsed.Type) $($BoundParsed.Blob) constrained"
    [IO.File]::WriteAllText(
        $OptionOnlyPath,
        "$OptionOnlyLine`r`n",
        (New-Object Text.UTF8Encoding($false))
    )
    $OptionOnlyAccount = [pscustomobject]@{
        Name               = 'test-user'
        Sid                = 'S-1-5-21-1-2-3-1001'
        IsAdministrator    = $false
        IsCurrentUser      = $true
        ProfilePath        = $ScratchRoot
        AuthorizedKeysPath = $OptionOnlyPath
    }
    $BeforeRejectedGrant = [IO.File]::ReadAllBytes($OptionOnlyPath)
    Assert-SshAccessTestThrowsLike `
        { Add-SshAccessAuthorizedKey -Account $OptionOnlyAccount -Key $BoundKey } `
        '*option-bound*Refusing to add a plain authorization*' `
        'Grant should not weaken an existing option-bound identity reference.'
    Assert-SshAccessTestTrue `
        ([Linq.Enumerable]::SequenceEqual(
            [byte[]]$BeforeRejectedGrant,
            [byte[]][IO.File]::ReadAllBytes($OptionOnlyPath)
        )) `
        'A rejected grant should leave the option-bound line byte-for-byte unchanged.'

    $DuplicateOptionLine = "restrict,command=`"echo duplicate`" $($BoundParsed.Type) $($BoundParsed.Blob) duplicate-comment"
    $WithDuplicate = $AfterAdd.TrimEnd([char[]]@("`r", "`n")) +
        "`r`n$DuplicateOptionLine`r`n"
    [IO.File]::WriteAllText(
        $AuthPath,
        $WithDuplicate,
        (New-Object Text.UTF8Encoding($false))
    )
    $Removed = Remove-SshAccessAuthorizedKey -Account $Account -Key $BoundKey
    Assert-SshAccessTestEqual $Removed.Changed $true 'Revoke should change a granted file.'
    Assert-SshAccessTestEqual `
        $Removed.MatchCount `
        2 `
        'Revoke should remove every line with the bound key identity.'
    Assert-SshAccessTestEqual `
        $Removed.PlainMatchCount `
        1 `
        'Revoke should report the removed plain authorization.'
    Assert-SshAccessTestEqual `
        $Removed.OptionBoundMatchCount `
        1 `
        'Revoke should report every removed option-bound reference.'

    $AfterRemove = [IO.File]::ReadAllText($AuthPath, [Text.Encoding]::UTF8)
    Assert-SshAccessTestContains $AfterRemove $RetainedComment 'Revoke should preserve comments.'
    Assert-SshAccessTestContains $AfterRemove $OtherLine 'Revoke should preserve unrelated keys.'
    Assert-SshAccessTestTrue `
        (-not $AfterRemove.Contains($BoundParsed.Blob)) `
        'Revoke should remove bound-key variants regardless of options or comments.'
    Assert-SshAccessTestContains `
        $AfterRemove `
        $OtherParsed.Blob `
        'Revoke should retain the unrelated key blob.'
    Assert-SshAccessTestUtf8WithoutBom `
        -Path $AuthPath `
        -Message 'Authorized keys should be UTF-8 without BOM after revoke.'
    Assert-SshAccessTestTrue `
        (@(Get-ChildItem -LiteralPath $AuthDirectory -Force |
            Where-Object { $_.Name -like '.authorized_keys.*' }).Count -eq 0) `
        'Atomic writes should clean temporary and backup files.'
    Assert-SshAccessTestTrue `
        ($script:AclCalls.Count -ge 4) `
        'Atomic mutations should request ACL application without using real ACLs in tests.'

    Write-Host '[TEST] Invalid text encoding fails closed'
    $InvalidPath = Join-Path $AuthDirectory 'invalid_authorized_keys'
    [IO.File]::WriteAllBytes($InvalidPath, [byte[]]@(0xff, 0xfe, 0x41, 0x00))
    Assert-SshAccessTestThrowsLike `
        { Read-SshAccessAuthorizedKeysDocument -Path $InvalidPath } `
        '*must be UTF-8*' `
        'A UTF-16 authorization file should be rejected instead of silently rewritten.'

    Write-Host '[TEST] Concurrent edits are not overwritten'
    [IO.File]::WriteAllText(
        $AuthPath,
        "# external edit`r`n$OtherLine`r`n",
        (New-Object Text.UTF8Encoding($false))
    )
    Assert-SshAccessTestThrowsLike `
        {
            Write-SshAccessAuthorizedKeysAtomic `
                -Path $AuthPath `
                -Text "$BoundLine`r`n" `
                -ExpectedText '# stale snapshot' `
                -ExpectedExists $true `
                -Account $Account
        } `
        '*changed while this operation*' `
        'An external edit should abort an optimistic authorized_keys update.'
    Assert-SshAccessTestContains `
        ([IO.File]::ReadAllText($AuthPath, [Text.Encoding]::UTF8)) `
        '# external edit' `
        'An aborted update must preserve the external edit.'
} finally {
    Remove-SshAccessTestScratchRoot -Path $ScratchRoot
}

Write-Host 'ssh access public storage and atomicity tests: PASS' -ForegroundColor Green
