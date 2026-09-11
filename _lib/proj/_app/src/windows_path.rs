use std::ffi::OsString;
use std::os::windows::ffi::{OsStrExt, OsStringExt};
use std::path::{Component, Path, PathBuf, Prefix};

pub(crate) fn dos_absolute(path: &Path) -> Result<PathBuf, &'static str> {
    if !path.is_absolute() {
        return Err("path is not absolute");
    }
    let Some(Component::Prefix(prefix)) = path.components().next() else {
        return Err("path has no Windows volume prefix");
    };
    match prefix.kind() {
        Prefix::Disk(_) | Prefix::UNC(_, _) => Ok(path.to_path_buf()),
        Prefix::VerbatimDisk(_) => strip_verbatim(path, 4, &[]),
        Prefix::VerbatimUNC(_, _) => strip_verbatim(path, 8, &[b'\\' as u16, b'\\' as u16]),
        Prefix::Verbatim(_) | Prefix::DeviceNS(_) => {
            Err("device and volume paths are not supported")
        }
    }
}

fn strip_verbatim(
    path: &Path,
    prefix_units: usize,
    replacement: &[u16],
) -> Result<PathBuf, &'static str> {
    let units = path.as_os_str().encode_wide().collect::<Vec<_>>();
    if units.len() <= prefix_units {
        return Err("verbatim path is incomplete");
    }
    let mut normalized = Vec::with_capacity(replacement.len() + units.len() - prefix_units);
    normalized.extend_from_slice(replacement);
    normalized.extend_from_slice(&units[prefix_units..]);
    let normalized = PathBuf::from(OsString::from_wide(&normalized));
    if !normalized.is_absolute() {
        return Err("verbatim path has no DOS absolute equivalent");
    }
    Ok(normalized)
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn converts_verbatim_disk_without_lossy_text_conversion() {
        assert_eq!(
            dos_absolute(Path::new(r"\\?\C:\工作区\entry.exe")).unwrap(),
            PathBuf::from(r"C:\工作区\entry.exe")
        );
    }

    #[test]
    fn converts_verbatim_unc_without_lossy_text_conversion() {
        assert_eq!(
            dos_absolute(Path::new(r"\\?\UNC\server\共享\entry.exe")).unwrap(),
            PathBuf::from(r"\\server\共享\entry.exe")
        );
    }

    #[test]
    fn preserves_dos_absolute_paths_and_rejects_device_namespaces() {
        assert_eq!(
            dos_absolute(Path::new(r"D:\kit\entry.exe")).unwrap(),
            PathBuf::from(r"D:\kit\entry.exe")
        );
        assert!(dos_absolute(Path::new(r"\\?\Volume{fixture}\entry.exe")).is_err());
        assert!(dos_absolute(Path::new(r"\\.\PIPE\fixture")).is_err());
    }
}
