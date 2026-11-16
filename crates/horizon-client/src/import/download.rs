//! The phone's first door: game files downloaded from a server, with no computer involved. A phone
//! that opens with nothing to load fetches `<base><version>.zip` (the archive `--pack-resources`
//! writes) into its home, then installs it as an archive that came over Wi-Fi or a cable would be
//! (`Pack`), so what arrives is checked the same way. The download runs on its own thread and the
//! screen reads its progress; if it fails, the other doors are still there.

use std::{
    fs::{self, File},
    io::{self, Read, Write},
    path::{Path, PathBuf},
    sync::{
        Arc,
        atomic::{AtomicU64, Ordering},
        mpsc,
    },
    thread,
    time::Duration,
};

use super::{Installed, MAX_PACKED, Pack};

/// The archive's address for this version, from the player's override or the
/// app's registered provider. A plain engine without either uses manual import.
pub fn url(version: &str) -> Option<String> {
    let base = std::env::var("HORIZON_GAME_FILES_URL")
        .ok()
        .filter(|b| !b.is_empty())
        .or_else(|| horizon_hooks::engine::game_files_base().map(str::to_owned))?;
    Some(archive_url(version, &base))
}

fn archive_url(version: &str, base: &str) -> String {
    let base = if base.ends_with('/') {
        base.to_owned()
    } else {
        format!("{base}/")
    };
    format!("{base}{version}.zip")
}

/// What the download is doing now.
#[derive(Debug, Clone, PartialEq, Eq)]
pub enum Stage {
    /// Bytes so far, and the whole size when the server said it (0 when it didn't).
    Downloading { received: u64, total: u64 },
    /// The archive is here and being unpacked.
    Installing,
}

/// A download under way. Dropping it does not stop the thread; the result is simply not read.
pub struct Download {
    received: Arc<AtomicU64>,
    total: Arc<AtomicU64>,
    installing: Arc<AtomicU64>,
    done: mpsc::Receiver<Result<Installed, String>>,
}

impl Download {
    /// Start downloading prepared game files at `url` into `home` and installing them there.
    /// Worlds and resource packs are rejected before installation. A finished archive already in
    /// `home` (an earlier download, or `<version>.zip` copied in by hand) is installed without one.
    pub fn start(url: String, home: PathBuf) -> io::Result<Self> {
        let received = Arc::new(AtomicU64::new(0));
        let total = Arc::new(AtomicU64::new(0));
        let installing = Arc::new(AtomicU64::new(0));
        let (sender, done) = mpsc::channel();
        let (r, t, i) = (received.clone(), total.clone(), installing.clone());
        thread::Builder::new()
            .name("horizon-download".into())
            .spawn(move || {
                let archive = match local_archive(&url, &home) {
                    Some(archive) => {
                        log::info!(
                            "Horizon: installing {} already on this device",
                            archive.display()
                        );
                        Ok(archive)
                    }
                    None => fetch(&url, &home, &r, &t),
                };
                let result = archive.and_then(|archive| {
                    i.store(1, Ordering::Relaxed);
                    let downloaded = archive.file_name() == Some(DOWNLOADED.as_ref());
                    let opened = Pack::open(&archive).and_then(Pack::require_game_files);
                    if opened.is_err() && downloaded {
                        // A download that ends as no archive is downloaded again from the start next time.
                        let _ = fs::remove_file(&archive);
                    }
                    let result = opened
                        .and_then(|pack| pack.install(&home))
                        .map_err(|e| e.to_string());
                    if downloaded && !archive.exists() {
                        let _ = fs::remove_file(home.join(DOWNLOADED_SOURCE));
                    }
                    result
                });
                let _ = sender.send(result);
            })?;
        Ok(Self {
            received,
            total,
            installing,
            done,
        })
    }

    pub fn stage(&self) -> Stage {
        if self.installing.load(Ordering::Relaxed) != 0 {
            Stage::Installing
        } else {
            Stage::Downloading {
                received: self.received.load(Ordering::Relaxed),
                total: self.total.load(Ordering::Relaxed),
            }
        }
    }

    /// The result, once there is one.
    pub fn poll(&self) -> Option<Result<Installed, String>> {
        match self.done.try_recv() {
            Ok(result) => Some(result),
            Err(mpsc::TryRecvError::Empty) => None,
            Err(mpsc::TryRecvError::Disconnected) => Some(Err("the download stopped".into())),
        }
    }
}

/// The finished download's name in `home`, and the partial one's.
const DOWNLOADED: &str = "horizon-download.zip";
/// A completed cache is reusable only for this requested URL's SHA-256. Never
/// persist URLs themselves: a custom source may contain an access token.
const DOWNLOADED_SOURCE: &str = "horizon-download.zip.source";
const PARTIAL: &str = "horizon-download.zip.part";
/// The requested/final URL hashes and strong `ETag` of the partial download. ETags identify
/// a representation only within its resource, so another source or redirect target must restart.
const PARTIAL_TAG: &str = "horizon-download.zip.etag";

#[derive(serde::Serialize, serde::Deserialize)]
struct ResumeTag {
    source: String,
    target: String,
    etag: String,
}

fn source_hash(url: &str) -> String {
    use sha2::Digest;
    format!("{:x}", sha2::Sha256::digest(url.as_bytes()))
}

/// A whole archive of game files already in `home`: a download that finished but was not installed,
/// or the archive itself (`26.3.zip`) put there by hand.
fn local_archive(url: &str, home: &Path) -> Option<PathBuf> {
    let name = url.rsplit('/').next().filter(|n| n.ends_with(".zip"));
    let cached = fs::read_to_string(home.join(DOWNLOADED_SOURCE))
        .is_ok_and(|source| source == source_hash(url))
        .then_some(DOWNLOADED);
    [cached, name.filter(|name| *name != DOWNLOADED)]
        .into_iter()
        .flatten()
        .map(|name| home.join(name))
        .find(|path| {
            path.is_file() && Pack::open(path).is_ok_and(|pack| pack.kind == super::Kind::Resources)
        })
}

/// How many times a download that broke off is picked up again, and the pause before each try.
const RETRIES: u32 = 6;
#[cfg(not(test))]
const PAUSE: Duration = Duration::from_secs(2);
#[cfg(test)]
const PAUSE: Duration = Duration::from_millis(10);

/// What stopped one request.
enum Stop {
    /// The connection broke: try again from where it stopped.
    Broke(String),
    /// The server refused, or the file can't be kept: trying again won't help.
    Failed(String),
}

/// Download `url` to `home/horizon-download.zip`, through a `.part` file so a cut download is
/// never taken for an archive. A connection that breaks (on a phone: the screen locked, the network
/// changed) is picked up where it stopped with a `Range` request; the `.part` file stays between runs
/// for the same reason.
fn fetch(
    url: &str,
    home: &Path,
    received: &AtomicU64,
    total: &AtomicU64,
) -> Result<PathBuf, String> {
    let agent = ureq::AgentBuilder::new()
        .timeout_connect(Duration::from_secs(20))
        .timeout_read(Duration::from_secs(60))
        .build();
    fs::create_dir_all(home).map_err(|e| e.to_string())?;
    let part = home.join(PARTIAL);
    let archive = home.join(DOWNLOADED);
    let mut tries = 0;
    loop {
        match fetch_once(&agent, url, &part, received, total) {
            Ok(()) => break,
            Err(Stop::Failed(e)) => {
                let _ = fs::remove_file(&part);
                let _ = fs::remove_file(home.join(PARTIAL_TAG));
                return Err(e);
            }
            Err(Stop::Broke(e)) => {
                tries += 1;
                if tries > RETRIES {
                    return Err(format!("the download was cut: {e}"));
                }
                log::warn!(
                    "Horizon: the download broke off ({e}); picking it up again ({tries}/{RETRIES})"
                );
                thread::sleep(PAUSE * tries);
            }
        }
    }
    // Invalidate the old cache's identity before replacing its bytes. A crash
    // between the rename and recording the new source leaves an unidentified
    // cache, never new bytes falsely labelled as an older source.
    match fs::remove_file(home.join(DOWNLOADED_SOURCE)) {
        Ok(()) => {}
        Err(error) if error.kind() == io::ErrorKind::NotFound => {}
        Err(error) => return Err(error.to_string()),
    }
    fs::rename(&part, &archive).map_err(|e| e.to_string())?;
    fs::write(home.join(DOWNLOADED_SOURCE), source_hash(url)).map_err(|e| e.to_string())?;
    let _ = fs::remove_file(home.join(PARTIAL_TAG));
    Ok(archive)
}

/// One request: the rest of `part`, or all of it when there is none or the server can't send a part.
fn fetch_once(
    agent: &ureq::Agent,
    url: &str,
    part: &Path,
    received: &AtomicU64,
    total: &AtomicU64,
) -> Result<(), Stop> {
    let tag_file = part.with_file_name(PARTIAL_TAG);
    let source = source_hash(url);
    let saved = fs::read(&tag_file)
        .ok()
        .and_then(|bytes| serde_json::from_slice::<ResumeTag>(&bytes).ok())
        .filter(|saved| saved.source == source && !saved.etag.is_empty());
    let tag = saved.as_ref().map(|saved| saved.etag.as_str());
    // A part whose file can't be named is not resumed: it could be the start of another file.
    let have = match &tag {
        Some(_) => fs::metadata(part).map(|m| m.len()).unwrap_or(0),
        None => 0,
    };
    let mut request = agent.get(url);
    if let (true, Some(tag)) = (have > 0, &tag) {
        request = request
            .set("Range", &format!("bytes={have}-"))
            .set("If-Range", tag);
    }
    // Never splice an unverified range onto a previous archive. Clearing the
    // validator also makes the bounded retry loop request the whole file.
    let restart = || {
        let _ = fs::remove_file(&tag_file);
        let _ = fs::remove_file(part);
        Stop::Broke("the server could not resume this archive; restarting".into())
    };
    let response = match request.call() {
        Ok(response) => response,
        // A 416 can also mean the remote file shrank or the local part is stale.
        // It is not proof that our partial archive is complete.
        Err(ureq::Error::Status(416, _)) if have > 0 => return Err(restart()),
        Err(ureq::Error::Status(status, _)) => {
            return Err(Stop::Failed(format!(
                "the server answered {status} for {url}"
            )));
        }
        Err(other) => return Err(Stop::Broke(format!("could not reach {url}: {other}"))),
    };
    let target = source_hash(response.get_url());
    // 206: the rest of the same file. 200: all of it, the file having changed or the server not doing ranges.
    let resumed = have > 0 && response.status() == 206;
    let range = if response.status() == 206 {
        let parsed = response.header("Content-Range").and_then(|header| {
            let (span, total) = header.strip_prefix("bytes ")?.split_once('/')?;
            let (first, last) = span.split_once('-')?;
            Some((
                first.parse::<u64>().ok()?,
                last.parse::<u64>().ok()?,
                total.parse::<u64>().ok()?,
            ))
        });
        let Some((first, last, length)) = parsed.filter(|&(first, last, length)| {
            resumed && first == have && first <= last && last < length
        }) else {
            return Err(restart());
        };
        if response
            .header("ETag")
            .is_some_and(|value| Some(value) != tag)
            || saved.as_ref().is_none_or(|saved| saved.target != target)
        {
            return Err(restart());
        }
        Some((last + 1, length, last - first + 1))
    } else {
        None
    };
    let start = if resumed { have } else { 0 };
    let rest = response
        .header("Content-Length")
        .and_then(|l| l.parse::<u64>().ok())
        .unwrap_or(0);
    if range.is_some_and(|(_, _, expected)| rest != 0 && rest != expected) {
        return Err(restart());
    }
    let size = match range {
        Some((end, _, _)) => end,
        None => rest,
    };
    let whole = range.map_or(size, |(_, length, _)| length);
    if whole > MAX_PACKED {
        return Err(Stop::Failed(
            "the archive is larger than this will unpack".into(),
        ));
    }
    total.store(whole, Ordering::Relaxed);
    let file = if resumed {
        fs::OpenOptions::new().append(true).open(part)
    } else {
        File::create(part)
    };
    let mut file = file.map_err(|e| Stop::Failed(format!("could not save the download: {e}")))?;
    if !resumed {
        // Truncate the old bytes before replacing their validator. If creation fails,
        // its old validator still belongs to the old bytes. Never persist URL secrets.
        let _ = fs::remove_file(&tag_file);
        if let Some(etag) = response.header("ETag").filter(|tag| !tag.starts_with("W/"))
            && let Ok(saved) = serde_json::to_vec(&ResumeTag {
                source,
                target,
                etag: etag.to_owned(),
            })
        {
            let _ = fs::write(&tag_file, saved);
        }
    }
    let mut reader = response.into_reader();
    let mut buffer = vec![0; 1 << 16];
    let mut so_far = start;
    received.store(so_far, Ordering::Relaxed);
    loop {
        // Stop at the size the server announced: on iOS a read past the end of a connection the server
        // closed fails ("Socket is not connected", os error 57) instead of saying the body ended.
        if size != 0 && so_far >= size {
            break;
        }
        let capacity = if size == 0 {
            buffer.len()
        } else {
            (size - so_far).min(buffer.len() as u64) as usize
        };
        let n = match reader.read(&mut buffer[..capacity]) {
            Ok(0) => break,
            Ok(n) => n,
            Err(e) if e.kind() == io::ErrorKind::Interrupted => continue,
            Err(e) => {
                // Keep what arrived for the next request.
                let _ = file.sync_all();
                return Err(Stop::Broke(e.to_string()));
            }
        };
        so_far += n as u64;
        if so_far > MAX_PACKED {
            return Err(Stop::Failed(
                "the archive is larger than this will unpack".into(),
            ));
        }
        file.write_all(&buffer[..n])
            .map_err(|e| Stop::Failed(format!("could not save the download: {e}")))?;
        received.store(so_far, Ordering::Relaxed);
    }
    file.sync_all()
        .map_err(|e| Stop::Failed(format!("could not save the download: {e}")))?;
    if whole != 0 && so_far < whole {
        return Err(Stop::Broke(format!(
            "the connection closed at {so_far} of {whole} bytes"
        )));
    }
    Ok(())
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn the_archive_is_named_for_the_version() {
        for base in ["https://example.org/game", "https://example.org/game/"] {
            assert_eq!(
                archive_url("26.3", base),
                "https://example.org/game/26.3.zip"
            );
        }
    }

    #[test]
    fn the_plain_engine_has_no_implicit_download_service() {
        assert_eq!(horizon_hooks::engine::game_files_base(), None);
        let explicit = std::env::var("HORIZON_GAME_FILES_URL")
            .ok()
            .filter(|base| !base.is_empty());
        assert_eq!(url("26.3"), explicit.map(|base| archive_url("26.3", &base)));
    }

    #[test]
    fn resume_rejects_wrong_ranges_without_appending_or_completing() {
        for (name, status, headers, complete, retained) in [
            (
                "wrong-start",
                "206 Partial Content",
                "Content-Range: bytes 0-1/6\r\n",
                false,
                false,
            ),
            ("missing-range", "206 Partial Content", "", false, false),
            (
                "false-complete",
                "416 Range Not Satisfiable",
                "Content-Range: bytes */8\r\n",
                false,
                false,
            ),
            (
                "valid",
                "206 Partial Content",
                "Content-Range: bytes 4-5/6\r\n",
                true,
                true,
            ),
            (
                "more-remains",
                "206 Partial Content",
                "Content-Range: bytes 4-5/8\r\n",
                false,
                true,
            ),
            (
                "changed-validator",
                "206 Partial Content",
                "Content-Range: bytes 4-5/6\r\nETag: \"two\"\r\n",
                false,
                false,
            ),
            (
                "wrong-length",
                "206 Partial Content",
                "Content-Range: bytes 4-6/7\r\n",
                false,
                false,
            ),
        ] {
            let home = home(name);
            fs::create_dir_all(&home).unwrap();
            let part = home.join(PARTIAL);
            fs::write(&part, b"abcd").unwrap();
            let listener = std::net::TcpListener::bind("127.0.0.1:0").unwrap();
            let address = listener.local_addr().unwrap();
            fs::write(
                home.join(PARTIAL_TAG),
                serde_json::to_vec(&ResumeTag {
                    source: source_hash(&format!("http://{address}/game.zip")),
                    target: source_hash(&format!("http://{address}/game.zip")),
                    etag: "\"one\"".into(),
                })
                .unwrap(),
            )
            .unwrap();
            let server = thread::spawn(move || {
                let (mut stream, _) = listener.accept().unwrap();
                let mut request = [0; 1024];
                let n = stream.read(&mut request).unwrap();
                assert!(
                    String::from_utf8_lossy(&request[..n])
                        .to_lowercase()
                        .contains("range: bytes=4-")
                );
                write!(
                    stream,
                    "HTTP/1.1 {status}\r\n{headers}Content-Length: 2\r\nConnection: close\r\n\r\nef"
                )
                .unwrap();
            });
            let result = fetch_once(
                &ureq::AgentBuilder::new().build(),
                &format!("http://{address}/game.zip"),
                &part,
                &AtomicU64::new(0),
                &AtomicU64::new(0),
            );
            server.join().unwrap();
            assert_eq!(result.is_ok(), complete, "{name}: incorrect completion");
            if retained {
                assert_eq!(fs::read(&part).unwrap(), b"abcdef", "{name}");
                assert!(home.join(PARTIAL_TAG).exists());
            } else {
                assert!(!part.exists(), "{name}: incompatible bytes retained");
                assert!(!home.join(PARTIAL_TAG).exists());
            }
            fs::remove_dir_all(home).unwrap();
        }
    }

    /// One HTTP answer from a local socket: `length` in the header, `body` sent.
    fn serve(body: Vec<u8>, length: usize) -> String {
        let listener = std::net::TcpListener::bind("127.0.0.1:0").unwrap();
        let address = listener.local_addr().unwrap();
        thread::spawn(move || {
            let (mut stream, _) = listener.accept().unwrap();
            let mut request = [0u8; 1024];
            let _ = stream.read(&mut request);
            let head =
                format!("HTTP/1.1 200 OK\r\nContent-Length: {length}\r\nConnection: close\r\n\r\n");
            let _ = stream.write_all(head.as_bytes());
            let _ = stream.write_all(&body);
        });
        format!("http://{address}/26.3.zip")
    }

    fn prepared() -> Vec<u8> {
        prepared_with_facts("{}")
    }

    fn prepared_with_facts(facts: &str) -> Vec<u8> {
        use zip::{CompressionMethod, write::SimpleFileOptions, write::ZipWriter};
        let mut zip = ZipWriter::new(std::io::Cursor::new(Vec::new()));
        let options = SimpleFileOptions::default().compression_method(CompressionMethod::Stored);
        for (name, body) in [
            ("horizon-resources.json", r#"{"schema":7}"#),
            ("facts.json", facts),
        ] {
            zip.start_file(name, options).unwrap();
            zip.write_all(body.as_bytes()).unwrap();
        }
        zip.finish().unwrap().into_inner()
    }

    #[test]
    fn automatic_setup_never_installs_a_world_or_resource_pack() {
        use zip::{write::SimpleFileOptions, write::ZipWriter};
        for (kind, marker) in [("world", "level.dat"), ("pack", "pack.mcmeta")] {
            let home = home(&format!("wrong-kind-{kind}"));
            let mut zip = ZipWriter::new(std::io::Cursor::new(Vec::new()));
            zip.start_file(marker, SimpleFileOptions::default())
                .unwrap();
            zip.write_all(b"{}").unwrap();
            let body = zip.finish().unwrap().into_inner();
            let size = body.len();
            let result = wait(&Download::start(serve(body, size), home.clone()).unwrap());
            assert!(
                result.is_err(),
                "automatic setup installed {kind}: {result:?}"
            );
            for folder in ["saves", "resourcepacks", "resources"] {
                assert!(
                    !home.join(folder).exists(),
                    "automatic setup created {folder}"
                );
            }
            assert!(!home.join(DOWNLOADED).exists());
            assert!(!home.join(DOWNLOADED_SOURCE).exists());
            fs::remove_dir_all(home).unwrap();
        }
    }

    #[test]
    fn a_completed_download_is_only_reused_for_its_source() {
        let body = prepared();
        let size = body.len();
        let url = format!("{}?token=fixture-secret", serve(body, size));
        let home = home("completed-source");
        let archive = fetch(&url, &home, &AtomicU64::new(0), &AtomicU64::new(0)).unwrap();
        assert_eq!(local_archive(&url, &home), Some(archive));
        assert_eq!(
            fs::read_to_string(home.join(DOWNLOADED_SOURCE)).unwrap(),
            source_hash(&url)
        );
        assert_eq!(
            local_archive("https://example.org/new-version.zip", &home),
            None
        );
        // The reserved cache filename must not bypass the source check through
        // the separate path for a versioned archive supplied by the player.
        assert_eq!(
            local_archive("https://example.org/horizon-download.zip", &home),
            None
        );
        // The original server has already closed: retrying installation should
        // consume its matching completed cache without another HTTP request.
        wait(&Download::start(url, home.clone()).unwrap()).unwrap();
        assert!(!home.join(DOWNLOADED).exists());
        assert!(!home.join(DOWNLOADED_SOURCE).exists());
        fs::remove_dir_all(home).unwrap();
    }

    #[test]
    fn switching_sources_after_a_completed_download_installs_the_new_archive() {
        let home = home("completed-switch");
        let old = prepared_with_facts(r#"{"source":"old"}"#);
        fetch(
            &serve(old.clone(), old.len()),
            &home,
            &AtomicU64::new(0),
            &AtomicU64::new(0),
        )
        .unwrap();
        let new = prepared_with_facts(r#"{"source":"new"}"#);
        wait(&Download::start(serve(new.clone(), new.len()), home.clone()).unwrap()).unwrap();
        assert_eq!(
            fs::read_to_string(home.join("resources/facts.json")).unwrap(),
            r#"{"source":"new"}"#
        );
        assert!(!home.join(DOWNLOADED_SOURCE).exists());
        fs::remove_dir_all(home).unwrap();
    }

    #[test]
    fn an_unidentified_cache_is_skipped_but_a_manual_version_archive_is_used() {
        let home = home("unidentified-cache");
        fs::create_dir_all(&home).unwrap();
        fs::write(home.join(DOWNLOADED), prepared()).unwrap();
        let url = "https://example.org/26.3.zip";
        assert_eq!(local_archive(url, &home), None);
        let manual = home.join("26.3.zip");
        fs::write(&manual, prepared()).unwrap();
        assert_eq!(local_archive(url, &home), Some(manual));
        fs::remove_dir_all(home).unwrap();
    }

    fn home(tag: &str) -> PathBuf {
        let dir = std::env::temp_dir().join(format!(
            "horizon-download-test-{}-{tag}",
            std::process::id()
        ));
        let _ = fs::remove_dir_all(&dir);
        dir
    }

    fn wait(download: &Download) -> Result<Installed, String> {
        for _ in 0..500 {
            if let Some(result) = download.poll() {
                return result;
            }
            thread::sleep(Duration::from_millis(10));
        }
        panic!("the download never finished");
    }

    #[test]
    fn downloaded_game_files_are_installed_where_the_game_reads_them() {
        let body = prepared();
        let size = body.len();
        let home = home("ok");
        let download = Download::start(serve(body, size), home.clone()).unwrap();
        let installed = wait(&download).unwrap();
        assert_eq!(installed.kind, super::super::Kind::Resources);
        assert!(home.join("resources/horizon-resources.json").is_file());
        assert_eq!(download.stage(), Stage::Installing);
        // The archive is consumed, and no partial file is left.
        assert!(!home.join("horizon-download.zip").exists());
        assert!(!home.join("horizon-download.zip.part").exists());
        fs::remove_dir_all(home).unwrap();
    }

    /// The body, then the connection held open: the download must end at the announced size, not wait
    /// for the server to close (or, on iOS, fail when it does).
    #[test]
    fn the_download_ends_at_the_announced_size() {
        let body = prepared();
        let size = body.len();
        let listener = std::net::TcpListener::bind("127.0.0.1:0").unwrap();
        let address = listener.local_addr().unwrap();
        let (done, held) = mpsc::channel::<()>();
        thread::spawn(move || {
            let (mut stream, _) = listener.accept().unwrap();
            let mut request = [0u8; 1024];
            let _ = stream.read(&mut request);
            let head = format!("HTTP/1.1 200 OK\r\nContent-Length: {size}\r\n\r\n");
            let _ = stream.write_all(head.as_bytes());
            let _ = stream.write_all(&body);
            // Keep the socket open until the test is over.
            let _ = held.recv_timeout(Duration::from_secs(10));
        });
        let home = home("held");
        let download = Download::start(format!("http://{address}/26.3.zip"), home.clone()).unwrap();
        let installed = wait(&download).unwrap();
        assert_eq!(installed.kind, super::super::Kind::Resources);
        let _ = done.send(());
        fs::remove_dir_all(home).unwrap();
    }

    #[test]
    fn a_download_that_stays_cut_keeps_its_part_for_the_next_run() {
        let body = prepared();
        let size = body.len();
        let home = home("cut");
        let download =
            Download::start(serve(body[..size / 2].to_vec(), size), home.clone()).unwrap();
        let error = wait(&download).unwrap_err();
        assert!(error.contains("cut"), "{error}");
        assert!(!home.join("resources").exists());
        assert_eq!(
            fs::metadata(home.join(PARTIAL)).unwrap().len(),
            (size / 2) as u64
        );
        let _ = fs::remove_dir_all(home);
    }

    /// ETags can collide across resources: switching URL starts a whole new download.
    #[test]
    fn changing_source_never_resumes_another_urls_bytes() {
        let listener = std::net::TcpListener::bind("127.0.0.1:0").unwrap();
        let address = listener.local_addr().unwrap();
        let server = thread::spawn(move || {
            let (mut stream, _) = listener.accept().unwrap();
            let mut request = [0; 2048];
            stream.read(&mut request).unwrap();
            stream.write_all(b"HTTP/1.1 200 OK\r\nContent-Length: 8\r\nETag: \"one\"\r\nConnection: close\r\n\r\nAAAA").unwrap();
            drop(stream);
            let (mut stream, _) = listener.accept().unwrap();
            let n = stream.read(&mut request).unwrap();
            let request = String::from_utf8_lossy(&request[..n]).to_lowercase();
            if request.contains("range: bytes=4-") {
                stream.write_all(b"HTTP/1.1 206 Partial Content\r\nContent-Length: 4\r\nContent-Range: bytes 4-7/8\r\nETag: \"one\"\r\nConnection: close\r\n\r\nBBBB").unwrap();
            } else {
                stream.write_all(b"HTTP/1.1 200 OK\r\nContent-Length: 8\r\nETag: \"one\"\r\nConnection: close\r\n\r\nBBBBBBBB").unwrap();
            }
            request
        });
        let home = home("source-boundary");
        fs::create_dir_all(&home).unwrap();
        let part = home.join(PARTIAL);
        let agent = ureq::AgentBuilder::new().build();
        let received = AtomicU64::new(0);
        let total = AtomicU64::new(0);
        assert!(matches!(
            fetch_once(
                &agent,
                &format!("http://{address}/a.zip"),
                &part,
                &received,
                &total
            ),
            Err(Stop::Broke(_))
        ));
        assert!(
            fetch_once(
                &agent,
                &format!("http://{address}/b.zip?access=fixture-secret"),
                &part,
                &received,
                &total
            )
            .is_ok()
        );
        let request = server.join().unwrap();
        assert_eq!(fs::read(&part).unwrap(), b"BBBBBBBB");
        assert!(!request.contains("range:"), "{request}");
        assert!(
            !fs::read_to_string(home.join(PARTIAL_TAG))
                .unwrap()
                .contains("fixture-secret")
        );
        fs::remove_dir_all(home).unwrap();
    }

    #[test]
    fn a_changed_redirect_target_cannot_reuse_the_previous_targets_etag() {
        let listener = std::net::TcpListener::bind("127.0.0.1:0").unwrap();
        let address = listener.local_addr().unwrap();
        let server = thread::spawn(move || {
            for step in 0..4 {
                let (mut stream, _) = listener.accept().unwrap();
                let mut request = [0; 2048];
                stream.read(&mut request).unwrap();
                let response = match step {
                    0 => {
                        "HTTP/1.1 302 Found\r\nLocation: /a.zip\r\nContent-Length: 0\r\nConnection: close\r\n\r\n"
                    }
                    1 => {
                        "HTTP/1.1 200 OK\r\nContent-Length: 8\r\nETag: \"one\"\r\nConnection: close\r\n\r\nAAAA"
                    }
                    2 => {
                        "HTTP/1.1 302 Found\r\nLocation: /b.zip\r\nContent-Length: 0\r\nConnection: close\r\n\r\n"
                    }
                    _ => {
                        "HTTP/1.1 206 Partial Content\r\nContent-Length: 4\r\nContent-Range: bytes 4-7/8\r\nETag: \"one\"\r\nConnection: close\r\n\r\nBBBB"
                    }
                };
                stream.write_all(response.as_bytes()).unwrap();
            }
        });
        let home = home("redirect-boundary");
        fs::create_dir_all(&home).unwrap();
        let part = home.join(PARTIAL);
        let agent = ureq::AgentBuilder::new().build();
        let url = format!("http://{address}/start");
        let received = AtomicU64::new(0);
        let total = AtomicU64::new(0);
        assert!(matches!(
            fetch_once(&agent, &url, &part, &received, &total),
            Err(Stop::Broke(_))
        ));
        let result = fetch_once(&agent, &url, &part, &received, &total);
        server.join().unwrap();
        assert!(
            matches!(result, Err(Stop::Broke(_))),
            "changed target must restart"
        );
        assert!(!part.exists());
        assert!(!home.join(PARTIAL_TAG).exists());
        fs::remove_dir_all(home).unwrap();
    }

    /// The connection breaks halfway; the next request asks for the rest and gets it.
    #[test]
    fn a_broken_download_is_picked_up_where_it_stopped() {
        let body = prepared();
        let size = body.len();
        let half = size / 2;
        let listener = std::net::TcpListener::bind("127.0.0.1:0").unwrap();
        let address = listener.local_addr().unwrap();
        let (ranges, asked) = mpsc::channel::<String>();
        thread::spawn(move || {
            // The first answer announces everything and sends half.
            let (mut stream, _) = listener.accept().unwrap();
            let mut request = [0u8; 1024];
            let _ = stream.read(&mut request);
            let head = format!(
                "HTTP/1.1 200 OK\r\nContent-Length: {size}\r\nETag: \"one\"\r\nConnection: close\r\n\r\n"
            );
            let _ = stream.write_all(head.as_bytes());
            let _ = stream.write_all(&body[..half]);
            drop(stream);
            // The second sends the rest of the range it is asked for.
            let (mut stream, _) = listener.accept().unwrap();
            let n = stream.read(&mut request).unwrap();
            let text = String::from_utf8_lossy(&request[..n]).to_lowercase();
            let range = text
                .lines()
                .find_map(|l| l.strip_prefix("range: bytes="))
                .unwrap_or("")
                .to_owned();
            assert!(text.contains("if-range: \"one\""), "{text}");
            let _ = ranges.send(range.clone());
            let from: usize = range.trim_end_matches('-').parse().unwrap();
            let rest = &body[from..];
            let head = format!(
                "HTTP/1.1 206 Partial Content\r\nContent-Length: {}\r\nContent-Range: bytes {from}-{}/{size}\r\nConnection: close\r\n\r\n",
                rest.len(),
                size - 1
            );
            let _ = stream.write_all(head.as_bytes());
            let _ = stream.write_all(rest);
        });
        let home = home("resumed");
        let download = Download::start(format!("http://{address}/26.3.zip"), home.clone()).unwrap();
        let installed = wait(&download).unwrap();
        assert_eq!(installed.kind, super::super::Kind::Resources);
        assert_eq!(asked.recv().unwrap(), format!("{half}-"));
        assert!(home.join("resources/horizon-resources.json").is_file());
        assert!(!home.join(PARTIAL).exists());
        fs::remove_dir_all(home).unwrap();
    }

    /// The archive copied into the home by hand installs with no server at all.
    #[test]
    fn an_archive_already_in_the_home_is_installed_without_downloading() {
        let home = home("local");
        fs::create_dir_all(&home).unwrap();
        fs::write(home.join("26.3.zip"), prepared()).unwrap();
        // Nothing listens on port 9: the download would fail.
        let download = Download::start("http://127.0.0.1:9/26.3.zip".into(), home.clone()).unwrap();
        let installed = wait(&download).unwrap();
        assert_eq!(installed.kind, super::super::Kind::Resources);
        assert!(home.join("resources/horizon-resources.json").is_file());
        assert!(!home.join("26.3.zip").exists());
        fs::remove_dir_all(home).unwrap();
    }

    /// The file changed on the server between two tries: the second request gets it whole, not a part of it.
    #[test]
    fn a_file_that_changed_on_the_server_starts_over() {
        use zip::{CompressionMethod, write::SimpleFileOptions, write::ZipWriter};
        let old = prepared();
        let mut zip = ZipWriter::new(std::io::Cursor::new(Vec::new()));
        let options = SimpleFileOptions::default().compression_method(CompressionMethod::Stored);
        for (name, body) in [
            ("horizon-resources.json", r#"{"schema":7}"#),
            ("facts.json", r#"{"new":true}"#),
        ] {
            zip.start_file(name, options).unwrap();
            zip.write_all(body.as_bytes()).unwrap();
        }
        let new = zip.finish().unwrap().into_inner();
        let listener = std::net::TcpListener::bind("127.0.0.1:0").unwrap();
        let address = listener.local_addr().unwrap();
        thread::spawn(move || {
            let (mut stream, _) = listener.accept().unwrap();
            let mut request = [0u8; 1024];
            let _ = stream.read(&mut request);
            let head = format!(
                "HTTP/1.1 200 OK\r\nContent-Length: {}\r\nETag: \"old\"\r\nConnection: close\r\n\r\n",
                old.len()
            );
            let _ = stream.write_all(head.as_bytes());
            let _ = stream.write_all(&old[..old.len() / 2]);
            drop(stream);
            // If-Range names the old file: the new one comes whole, with 200.
            let (mut stream, _) = listener.accept().unwrap();
            let _ = stream.read(&mut request);
            let head = format!(
                "HTTP/1.1 200 OK\r\nContent-Length: {}\r\nETag: \"new\"\r\nConnection: close\r\n\r\n",
                new.len()
            );
            let _ = stream.write_all(head.as_bytes());
            let _ = stream.write_all(&new);
        });
        let home = home("changed");
        let download = Download::start(format!("http://{address}/26.3.zip"), home.clone()).unwrap();
        wait(&download).unwrap();
        assert_eq!(
            fs::read_to_string(home.join("resources/facts.json")).unwrap(),
            r#"{"new":true}"#
        );
        assert!(!home.join(PARTIAL_TAG).exists());
        fs::remove_dir_all(home).unwrap();
    }
}
