//! Bounded, privacy-filtered mobile diagnostics. Desktop logging is unchanged.
use std::{
    fs::{self, File},
    io::{self, Read, Seek, SeekFrom, Write},
    path::Path,
};
pub const LIMIT: usize = 1024 * 1024;

fn begins_entry(line: &str) -> bool {
    line.as_bytes().get(..10).is_some_and(|p| {
        p[0] == b'['
            && p[3] == b':'
            && p[6] == b':'
            && p[9] == b']'
            && [1, 2, 4, 5, 7, 8]
                .into_iter()
                .all(|i| p[i].is_ascii_digit())
    })
}

/// A bounded read may start anywhere inside a multiline message. Its label could
/// have been cut off, so retain nothing until the next timestamped entry.
fn complete_tail(text: &str) -> &str {
    let Some((_, tail)) = text.split_once('\n') else {
        return "";
    };
    let mut offset = 0;
    for line in tail.split_inclusive('\n') {
        if begins_entry(line) {
            return &tail[offset..];
        }
        offset += line.len();
    }
    ""
}
/// Fail closed for authentication messages rather than guessing where a secret ends.
pub fn redact(text: &str) -> String {
    let lower = text.to_ascii_lowercase();
    if [
        "accesstoken",
        "refreshtoken",
        "idtoken",
        "token =",
        "token :",
        "user code",
        "access_token",
        "refresh_token",
        "id_token",
        "token:",
        "token=",
        "token\"",
        "authorization",
        "bearer",
        "password",
        "secret",
        "cookie",
        "xbl3.0",
        "device_code",
        "user_code",
        "sessionid",
        "session_id",
        "accesskey",
        "api_key",
    ]
    .iter()
    .any(|s| lower.contains(s))
    {
        return "[redacted sensitive log message]".to_owned();
    }
    text.lines()
        .map(|line| {
            line.split_whitespace()
                .map(|word| {
                    if word.len() > 128
                        || word.contains('@')
                        || word.contains("http://")
                        || word.contains("https://")
                        || word.contains("/Users/")
                        || word.contains("/var/mobile/")
                        || word.starts_with("eyJ")
                    {
                        "[redacted]".to_owned()
                    } else {
                        word.to_owned()
                    }
                })
                .collect::<Vec<_>>()
                .join(" ")
        })
        .collect::<Vec<_>>()
        .join("\n")
}
pub fn rotate(file: &mut File, dir: &Path) -> io::Result<()> {
    if file.metadata()?.len() > 0 {
        // A pre-upgrade file can be huge. Only read a bounded tail, then scrub it.
        let len = file.metadata()?.len();
        file.seek(SeekFrom::Start(len.saturating_sub(LIMIT as u64)))?;
        let mut bytes = Vec::new();
        file.take(LIMIT as u64).read_to_end(&mut bytes)?;
        let text = String::from_utf8_lossy(&bytes);
        // A whole leading partial message can contain unlabeled secrets.
        let text = if len > LIMIT as u64 {
            complete_tail(&text)
        } else {
            &text
        };
        let mut safe = redact(text);
        if safe.len() > LIMIT {
            let mut end = LIMIT;
            while !safe.is_char_boundary(end) {
                end -= 1;
            }
            safe.truncate(end);
        }
        fs::write(dir.join("previous.log"), safe)?;
    }
    file.set_len(0)?;
    file.seek(SeekFrom::Start(0))?;
    Ok(())
}
pub fn append(file: &mut File, dir: &Path, text: &str) -> io::Result<()> {
    let mut safe = redact(text);
    if safe.len() > 32 * 1024 {
        let mut end = 32 * 1024;
        while !safe.is_char_boundary(end) {
            end -= 1;
        }
        safe.truncate(end);
        safe.push_str("\n[message truncated]");
    }
    if file.metadata()?.len() + safe.len() as u64 + 1 > LIMIT as u64 {
        rotate(file, dir)?;
    }
    writeln!(file, "{safe}")
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn rotating_a_bounded_tail_drops_the_whole_partial_message() {
        let dir = std::env::temp_dir().join(format!(
            "horizon-log-tail-{}-{}",
            std::process::id(),
            std::time::SystemTime::now()
                .duration_since(std::time::UNIX_EPOCH)
                .unwrap()
                .as_nanos()
        ));
        fs::create_dir(&dir).unwrap();
        let path = dir.join("latest.log");
        let text = "[12:00:00] [Render thread/INFO]: access_token:\n".to_owned()
            + &"A".repeat(LIMIT)
            + "\nopaque-fixture-value\n[12:00:01] [Render thread/INFO]: shader ready\n";
        fs::write(&path, text).unwrap();
        let mut file = File::options().read(true).write(true).open(&path).unwrap();
        rotate(&mut file, &dir).unwrap();
        let previous = fs::read_to_string(dir.join("previous.log")).unwrap();
        assert!(!previous.contains("opaque-fixture-value"));
        assert!(previous.contains("shader ready"));
        drop(file);
        fs::remove_dir_all(dir).unwrap();
    }
}
