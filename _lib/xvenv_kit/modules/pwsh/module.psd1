@{
    Schema = 'xvenv.module.v1'
    Name = 'pwsh'
    Public = $true
    Order = 20
    Version = '7.5.2'
    Url = 'https://github.com/PowerShell/PowerShell/releases/download/v7.5.2/PowerShell-7.5.2-win-x64.zip'
    UrlTemplate = 'https://github.com/PowerShell/PowerShell/releases/download/v{version}/PowerShell-{version}-win-x64.zip'
    Hashes = @{
        '7.5.2' = '6cdabe52dcc2830929a53a970f689ab42b3819d34274cb2fbdd92aac13f66b92'
    }
    ArchiveSubdir = ''
    RequiredPaths = @('pwsh.exe')
    Requires = @()
}
