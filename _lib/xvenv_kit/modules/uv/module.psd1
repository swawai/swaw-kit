@{
    Schema = 'xvenv.module.v1'
    Name = 'uv'
    Public = $false
    Order = 25
    Version = '0.10.2'
    Url = 'https://github.com/astral-sh/uv/releases/download/0.10.2/uv-x86_64-pc-windows-msvc.zip'
    UrlTemplate = 'https://github.com/astral-sh/uv/releases/download/{version}/uv-x86_64-pc-windows-msvc.zip'
    Hashes = @{
        '0.10.2' = '493ebbe0e06128d6ee4905e1ed5e2a433fb0f7cfc08b0eaca9fab4ca76778ae1'
    }
    ArchiveSubdir = ''
    RequiredPaths = @('uv.exe')
    Requires = @()
}
