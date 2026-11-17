use std::{hash::Hash, path::Path};

pub(super) fn walk(path: &Path, hasher: &mut std::hash::DefaultHasher) -> Option<()> {
    let meta = std::fs::metadata(path).ok()?;
    path.hash(hasher);
    if meta.is_dir() {
        let mut entries: Vec<_> = std::fs::read_dir(path)
            .ok()?
            .flatten()
            .map(|e| e.path())
            .collect();
        entries.sort();
        for entry in entries {
            walk(&entry, hasher)?;
        }
    } else {
        meta.len().hash(hasher);
        meta.modified().ok()?.hash(hasher);
        // Replacing a ZIP can preserve both size and mtime.
        #[cfg(unix)]
        {
            use std::os::unix::fs::MetadataExt;
            meta.dev().hash(hasher);
            meta.ino().hash(hasher);
            meta.ctime().hash(hasher);
            meta.ctime_nsec().hash(hasher);
        }
    }
    Some(())
}

#[cfg(all(test, unix))]
mod tests {
    use super::*;
    use std::{
        fs,
        hash::{DefaultHasher, Hasher},
    };

    #[test]
    fn replacing_a_pack_changes_its_stamp_even_with_the_same_size_and_mtime() {
        let dir = std::env::temp_dir().join(format!("horizon-source-stamp-{}", std::process::id()));
        fs::create_dir(&dir).unwrap();
        let zip = dir.join("shader.zip");
        let replacement = dir.join("replacement.zip");
        let stamp = |path: &Path| {
            let mut hash = DefaultHasher::new();
            walk(path, &mut hash).unwrap();
            hash.finish()
        };
        fs::write(&zip, b"old").unwrap();
        let old = stamp(&zip);
        let mtime = fs::metadata(&zip).unwrap().modified().unwrap();
        fs::write(&replacement, b"new").unwrap();
        fs::File::open(&replacement)
            .unwrap()
            .set_modified(mtime)
            .unwrap();
        fs::rename(replacement, &zip).unwrap();
        assert_eq!(fs::metadata(&zip).unwrap().modified().unwrap(), mtime);
        assert_ne!(stamp(&zip), old);
        fs::remove_dir_all(dir).unwrap();
    }
}
