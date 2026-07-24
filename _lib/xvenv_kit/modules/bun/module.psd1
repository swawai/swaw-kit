@{
    Schema = 'xvenv.module.v1'
    Name = 'bun'
    Public = $true
    Order = 10
    Version = '1.2.15'
    Url = 'https://github.com/oven-sh/bun/releases/download/bun-v1.2.15/bun-windows-x64.zip'
    UrlTemplate = 'https://github.com/oven-sh/bun/releases/download/bun-v{version}/bun-windows-x64.zip'
    Hashes = @{
        '1.2.15' = '3cbfc2668aebd86718b9414fd4a4b4b1ec34a21ca544517310833563a937272f'
    }
    ArchiveSubdir = 'bun-windows-x64'
    RequiredPaths = @('bun.exe')
    Requires = @()
}
