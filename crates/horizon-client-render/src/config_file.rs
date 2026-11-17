//! Publish a complete configuration file without truncating the previous one.

use std::{fs, io, path::Path};

pub(crate) fn write_atomic(path: &Path, bytes: &[u8]) -> io::Result<()> {
    use std::io::Write;
    static NEXT: std::sync::atomic::AtomicU64 = std::sync::atomic::AtomicU64::new(0);
    // Keep an existing user link: publish beside its target, not over the link.
    let mut destination = path.to_path_buf();
    let mut links = 0;
    loop {
        match fs::symlink_metadata(&destination) {
            Ok(meta) if meta.file_type().is_symlink() => {
                if links == 40 {
                    return Err(io::Error::other("Too many configuration symbolic links"));
                }
                links += 1;
                let target = fs::read_link(&destination)?;
                destination = if target.is_absolute() {
                    target
                } else {
                    destination.parent().unwrap_or(Path::new("")).join(target)
                };
            }
            Ok(_) => break,
            Err(error) if error.kind() == io::ErrorKind::NotFound => break,
            Err(error) => return Err(error),
        }
    }
    let permissions = match fs::metadata(&destination) {
        Ok(meta) if meta.is_dir() => return Err(io::ErrorKind::IsADirectory.into()),
        // Non-file destinations (for example /dev/null) have no stored snapshot
        // to replace; retain the ordinary write semantics for those.
        Ok(meta) if !meta.is_file() => return fs::write(&destination, bytes),
        Ok(meta) if meta.permissions().readonly() => {
            return Err(io::ErrorKind::PermissionDenied.into());
        }
        Ok(meta) => Some(meta.permissions()),
        Err(error) if error.kind() == io::ErrorKind::NotFound => None,
        Err(error) => return Err(error),
    };
    let (temporary, mut file) = loop {
        let n = NEXT.fetch_add(1, std::sync::atomic::Ordering::Relaxed);
        let temporary =
            destination.with_file_name(format!(".horizon-config-{}-{n}.tmp", std::process::id()));
        match fs::OpenOptions::new()
            .write(true)
            .create_new(true)
            .open(&temporary)
        {
            Ok(file) => break (temporary, file),
            Err(error) if error.kind() == io::ErrorKind::AlreadyExists => continue,
            Err(error) => return Err(error),
        }
    };
    let written = (|| {
        file.write_all(bytes)?;
        if let Some(permissions) = permissions {
            file.set_permissions(permissions)?;
        }
        file.sync_all()?;
        Ok(())
    })();
    drop(file);
    let result = written.and_then(|()| fs::rename(&temporary, &destination));
    if result.is_err() {
        let _ = fs::remove_file(&temporary);
    }
    result
}
