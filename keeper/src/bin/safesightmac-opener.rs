// SPDX-License-Identifier: Apache-2.0
//! `safesightmac-opener`: the command-line opener (SD-066; chapter 03 section 11).
//!
//! Opens a SafeSight Mac recovery copy (a capsule) once the round of the public time
//! signal it waits for exists, with the owner's Recovery Key, on any computer, with no
//! project server and nobody's help. It is the same core as the page (`opener`).
//!
//! ```text
//! safesightmac-opener <recovery copy> [--round <file>] [--key-file <file>]
//! ```
//!
//! - Without `--round` it says when the copy opens and exactly which address to download
//!   the round from. It fetches nothing itself (see `docs/STEP-2-STATUS.md`, OPEN item 26).
//! - The Recovery Key is never taken from the command line. It is typed at a prompt that
//!   shows nothing, read from a pipe, or read from a file named with `--key-file`.
//! - The admin secret alone goes to standard output, once. Every other word goes to
//!   standard error.
//!
//! Exit status: 0 opened; 1 refused or failed; 2 wrong use; 3 not ready yet (the round is
//! still to come, or still to be downloaded).

#![forbid(unsafe_code)]

use std::ffi::OsString;
use std::fs::File;
use std::io::{IsTerminal, Read, Write};
use std::process::ExitCode;
use std::time::{SystemTime, UNIX_EPOCH};

use safesightmac_keeper::capsule::{OpenError, TimeLayerOpened};
use safesightmac_keeper::frame::RecordError;
use safesightmac_keeper::opener::{
    self, grouped, inspect, open_time, open_with_key, read_recovery_key, read_round, rough_wait_text, round_url,
    round_unix_seconds, utc_date_text, CapsuleInfo, KeyError, RoundInputError, ADMIN_ACCOUNT_NAME, CLAIM_DAYS,
    KEY_OPENING, MIRRORS,
};
use zeroize::Zeroizing;

const OPENED: u8 = 0;
const REFUSED: u8 = 1;
const WRONG_USE: u8 = 2;
const NOT_READY: u8 = 3;

/// One way the run ended without the secret: a status and plain words.
struct Stop {
    status: u8,
    words: String,
}

fn stop(status: u8, words: String) -> Stop {
    Stop { status, words }
}

struct Args {
    copy: OsString,
    round: Option<OsString>,
    key_file: Option<OsString>,
}

const USAGE: &str = "\
Usage:
  safesightmac-opener <recovery copy> [--round <file>] [--key-file <file>]

Opens a SafeSight Mac recovery copy once its time has come, with your Recovery Key.

  <recovery copy>      the recovery copy file saved by SafeSight Mac
  --round <file>       the time signal for the copy's round, as downloaded from the
                       address this tool prints (or just the signature, pasted into a file)
  --key-file <file>    read the Recovery Key from this file instead of asking for it

Without --round, the tool says when the copy opens and which address to download.
Without --key-file, it asks for the Recovery Key and shows nothing as you type, or reads
it from a pipe. Never put your Recovery Key on the command line.

The password goes to standard output; everything else to standard error.
Exit status: 0 opened, 1 refused, 2 wrong use, 3 not ready yet.
";

fn main() -> ExitCode {
    eprintln!("SafeSight Mac opener {}", opener::VERSION);
    eprintln!();
    match run() {
        Ok(()) => ExitCode::from(OPENED),
        Err(s) => {
            if !s.words.is_empty() {
                eprintln!("{}", s.words);
            }
            ExitCode::from(s.status)
        }
    }
}

fn parse_args() -> Result<Args, Stop> {
    let raw: Vec<OsString> = std::env::args_os().skip(1).collect();
    // A Recovery Key on the command line is in the shell's history: refuse it, and never
    // repeat it back.
    for a in raw.iter() {
        if a.to_string_lossy().to_ascii_lowercase().contains("age-secret-key-") {
            return Err(stop(
                WRONG_USE,
                String::from(
                    "Don't put your Recovery Key on the command line: your shell may have saved it\n\
                     in its history. Nothing was opened and the key was not used.\n\n\
                     To be safe, remove that line from your shell's history (for example, close\n\
                     this terminal window without saving, or edit ~/.zsh_history or\n\
                     ~/.bash_history). Then run the tool again and type the key when it asks.",
                ),
            ));
        }
    }
    let mut copy: Option<OsString> = None;
    let mut round: Option<OsString> = None;
    let mut key_file: Option<OsString> = None;
    let mut i = 0;
    while i < raw.len() {
        let a = raw[i].to_string_lossy().to_string();
        if a == "-h" || a == "--help" {
            return Err(stop(OPENED, String::from(USAGE)));
        }
        if a == "--version" {
            return Err(stop(OPENED, String::new()));
        }
        if a == "--round" || a == "--key-file" {
            let value = match raw.get(i + 1) {
                Some(v) => v.clone(),
                None => return Err(stop(WRONG_USE, format!("{} needs a file name after it.\n\n{}", a, USAGE))),
            };
            let slot = if a == "--round" { &mut round } else { &mut key_file };
            if slot.is_some() {
                return Err(stop(WRONG_USE, format!("{} is given twice.\n\n{}", a, USAGE)));
            }
            *slot = Some(value);
            i += 2;
            continue;
        }
        if let Some(v) = a.strip_prefix("--round=") {
            if round.is_some() {
                return Err(stop(WRONG_USE, format!("--round is given twice.\n\n{}", USAGE)));
            }
            round = Some(OsString::from(v));
            i += 1;
            continue;
        }
        if let Some(v) = a.strip_prefix("--key-file=") {
            if key_file.is_some() {
                return Err(stop(WRONG_USE, format!("--key-file is given twice.\n\n{}", USAGE)));
            }
            key_file = Some(OsString::from(v));
            i += 1;
            continue;
        }
        if a.starts_with('-') && a != "-" {
            return Err(stop(WRONG_USE, format!("Unknown option {}.\n\n{}", a, USAGE)));
        }
        if copy.is_some() {
            return Err(stop(WRONG_USE, format!("Give one recovery copy at a time.\n\n{}", USAGE)));
        }
        copy = Some(raw[i].clone());
        i += 1;
    }
    match copy {
        Some(copy) => Ok(Args { copy, round, key_file }),
        None => Err(stop(WRONG_USE, String::from(USAGE))),
    }
}

/// Reads at most `max` bytes of a file; a longer file is refused with `too_long`.
fn read_limited(path: &OsString, max: usize, what: &str, too_long: &str) -> Result<Vec<u8>, Stop> {
    let file = match File::open(path) {
        Ok(f) => f,
        Err(e) => {
            return Err(stop(REFUSED, format!("Couldn't open the {} {}: {}.", what, shown(path), e)));
        }
    };
    let mut bytes = Vec::with_capacity(max + 1);
    if let Err(e) = file.take(max as u64 + 1).read_to_end(&mut bytes) {
        return Err(stop(REFUSED, format!("Couldn't read the {} {}: {}.", what, shown(path), e)));
    }
    if bytes.len() > max {
        return Err(stop(REFUSED, String::from(too_long)));
    }
    Ok(bytes)
}

fn shown(path: &OsString) -> String {
    let text = path.to_string_lossy().to_string();
    if text.contains(' ') {
        format!("\"{}\"", text)
    } else {
        text
    }
}

fn now_unix_seconds() -> u64 {
    match SystemTime::now().duration_since(UNIX_EPOCH) {
        Ok(d) => d.as_secs(),
        Err(_) => 0,
    }
}

fn when(info: &CapsuleInfo) -> String {
    format!("{} (time signal round {})", utc_date_text(info.target_unix_seconds), grouped(info.target_round))
}

fn download_words(info: &CapsuleInfo, copy: &OsString) -> String {
    let mut w = String::new();
    w.push_str("Download the time signal for it on any device with internet, from either of\n");
    w.push_str("these addresses. They give the same answer:\n\n");
    for m in MIRRORS.iter() {
        w.push_str(&format!("  {}\n", round_url(m, info.target_round)));
    }
    w.push_str("\nFor example:\n");
    w.push_str(&format!("  curl -fsS -o round.json {}\n\n", round_url(MIRRORS[0], info.target_round)));
    w.push_str("Then run:\n");
    w.push_str(&format!("  safesightmac-opener {} --round round.json", shown(copy)));
    w
}

/// What the computer's own clock says about the target. Display only: the clock can be
/// wrong, and only the round's signature opens anything.
fn clock_words(info: &CapsuleInfo) -> Option<String> {
    let now = now_unix_seconds();
    if now == 0 || now >= info.target_unix_seconds {
        return None;
    }
    Some(format!(
        "By this computer's clock that is in {}. Until then the round doesn't exist, and\n\
         nothing can open this copy: not you, not anyone, not the people who made\n\
         SafeSight Mac. Come back after that date.",
        rough_wait_text(info.target_unix_seconds - now)
    ))
}

fn copy_refused(e: OpenError, copy: &OsString) -> Stop {
    let words = match e {
        OpenError::Capsule(RecordError::UpdateNeeded) => format!(
            "{} was made by a newer SafeSight Mac than this opener knows.\n\
             Use the opener saved beside it, or the newest one from the release page.",
            shown(copy)
        ),
        OpenError::Capsule(RecordError::TooShort)
        | OpenError::Capsule(RecordError::BadMagic)
        | OpenError::Capsule(RecordError::WrongType)
        | OpenError::Capsule(RecordError::WrongLength) => format!(
            "{} isn't a SafeSight Mac recovery copy. Check you chose the right file:\n\
             it is saved beside this opener, in the folder you chose for recovery copies.",
            shown(copy)
        ),
        OpenError::OtherChain => format!(
            "{} is tied to another time signal than the one SafeSight Mac uses, so this\n\
             opener can't open it. It may come from a test build.",
            shown(copy)
        ),
        _ => format!(
            "{} is damaged: part of it has changed since SafeSight Mac saved it.\n\
             Try another copy of it, for example from a backup.",
            shown(copy)
        ),
    };
    stop(REFUSED, words)
}

fn round_refused(e: RoundInputError, info: &CapsuleInfo, round_path: &OsString) -> Stop {
    let url = round_url(MIRRORS[0], info.target_round);
    match e {
        RoundInputError::Inconsistent => stop(
            REFUSED,
            format!(
                "{} has been changed: its parts don't match each other.\nDownload it again from:\n  {}",
                shown(round_path),
                url
            ),
        ),
        RoundInputError::TooLarge | RoundInputError::NotARound => {
            let mut w = format!("{} isn't the time signal.\n", shown(round_path));
            w.push_str(&format!(
                "If the address said \"Requested future beacon\" or showed an empty page, the round\n\
                 doesn't exist yet: this copy opens no earlier than {}.\n",
                when(info)
            ));
            let status = match clock_words(info) {
                Some(c) => {
                    w.push_str(&c);
                    w.push('\n');
                    NOT_READY
                }
                None => REFUSED,
            };
            w.push_str(&format!("Otherwise, download it again from:\n  {}", url));
            stop(status, w)
        }
    }
}

fn time_refused(e: OpenError, info: &CapsuleInfo, given_round: u64, named: bool, copy: &OsString) -> Stop {
    let url = round_url(MIRRORS[0], info.target_round);
    let given_when = match round_unix_seconds(given_round) {
        Some(t) => utc_date_text(t),
        None => String::from("an unknown time"),
    };
    match e {
        OpenError::NotYet { .. } => {
            let mut w = format!(
                "Not yet. That time signal is round {}, from {}.\nThis copy opens no earlier than {}.\n",
                grouped(given_round),
                given_when,
                when(info)
            );
            match clock_words(info) {
                Some(c) => w.push_str(&c),
                None => w.push_str("Until then nothing can open it."),
            }
            w.push_str(&format!("\nWhen that time has come, download:\n  {}", url));
            stop(NOT_READY, w)
        }
        OpenError::WrongRound => stop(
            REFUSED,
            format!(
                "That time signal is round {}, from {}.\nThis copy needs round {} exactly. Download it from:\n  {}",
                grouped(given_round),
                given_when,
                grouped(info.target_round),
                url
            ),
        ),
        OpenError::BadRoundSignature => {
            let what = if named {
                format!("That time signal (round {}) doesn't check out", grouped(given_round))
            } else {
                format!("That isn't the time signal's signature for round {}", grouped(info.target_round))
            };
            stop(
                REFUSED,
                format!(
                    "{}: it isn't signed by the public time signal.\n\
                     The file may be damaged or not genuine. Download it again from:\n  {}",
                    what, url
                ),
            )
        }
        OpenError::OtherChain => stop(
            REFUSED,
            format!("That round is from another time signal. Download the right one from:\n  {}", url),
        ),
        OpenError::Round(_) => stop(REFUSED, format!("That isn't the time signal. Download it from:\n  {}", url)),
        other => copy_refused(other, copy),
    }
}

fn key_refused(e: KeyError) -> Stop {
    let words = match e {
        KeyError::Empty => String::from("No Recovery Key was given. Nothing was opened."),
        KeyError::PublicHalf => format!(
            "That is the public half of a key (it starts with age1). Your Recovery Key starts\n\
             with {}. Look for the entry named \"SafeSight Mac Recovery Key\" in your\n\
             password manager.",
            KEY_OPENING
        ),
        KeyError::NotAKey => format!(
            "That isn't a Recovery Key. A Recovery Key is one line of 74 characters that starts\n\
             with {}. It is saved in your password manager as\n\
             \"SafeSight Mac Recovery Key\" and your Mac's name.",
            KEY_OPENING
        ),
        KeyError::Typo => String::from(
            "That Recovery Key has a typing mistake: a character is wrong, missing or extra.\n\
             Copy it again from your password manager and try again.",
        ),
    };
    stop(REFUSED, words)
}

/// Reads up to `KEY_INPUT_MAX` bytes from `source` into a buffer that is wiped when
/// dropped, never growing it. With `one_line`, stops at the first line break. None if
/// there is more than a key could be.
fn read_secret(source: &mut dyn Read, one_line: bool) -> std::io::Result<Option<Zeroizing<Vec<u8>>>> {
    let mut out = Zeroizing::new(Vec::with_capacity(opener::KEY_INPUT_MAX));
    let mut chunk = Zeroizing::new([0u8; 64]);
    loop {
        let n = source.read(&mut chunk[..])?;
        if n == 0 {
            break;
        }
        let mut end = n;
        let mut done = false;
        if one_line {
            if let Some(p) = chunk[..n].iter().position(|c| *c == b'\n') {
                end = p;
                done = true;
            }
        }
        if out.len() + end > opener::KEY_INPUT_MAX {
            return Ok(None);
        }
        out.extend_from_slice(&chunk[..end]);
        if done {
            break;
        }
    }
    Ok(Some(out))
}

fn too_long_or(read: std::io::Result<Option<Zeroizing<Vec<u8>>>>, from: &str) -> Result<Zeroizing<Vec<u8>>, Stop> {
    match read {
        Ok(Some(k)) => Ok(k),
        Ok(None) => Err(key_refused(KeyError::NotAKey)),
        Err(e) => Err(stop(REFUSED, format!("Couldn't read the Recovery Key from {}: {}.", from, e))),
    }
}

/// Asks for the key on the terminal with typing hidden. Refuses rather than show it.
#[cfg(unix)]
fn prompt_for_key() -> Result<Zeroizing<Vec<u8>>, Stop> {
    use std::fs::OpenOptions;
    use std::process::{Command, Stdio};

    fn stty(tty: &File, setting: &str) -> bool {
        let input = match tty.try_clone() {
            Ok(t) => t,
            Err(_) => return false,
        };
        let program = if std::path::Path::new("/bin/stty").exists() { "/bin/stty" } else { "stty" };
        match Command::new(program).arg(setting).stdin(Stdio::from(input)).stderr(Stdio::null()).status() {
            Ok(s) => s.success(),
            Err(_) => false,
        }
    }

    /// Turns typing back on however the prompt ends.
    struct EchoBack<'a>(&'a File);
    impl Drop for EchoBack<'_> {
        fn drop(&mut self) {
            let _ = stty(self.0, "echo");
        }
    }

    let cant_hide = || {
        stop(
            REFUSED,
            String::from(
                "This terminal can't hide what you type, so the tool won't ask for the key here.\n\
                 Give it through a pipe, or with --key-file <file>.",
            ),
        )
    };
    let tty = match OpenOptions::new().read(true).write(true).open("/dev/tty") {
        Ok(t) => t,
        Err(_) => return Err(cant_hide()),
    };
    if !stty(&tty, "-echo") {
        return Err(cant_hide());
    }
    let restore = EchoBack(&tty);
    let mut screen: &File = &tty;
    let _ = screen.write_all(b"Recovery Key (nothing shows as you type or paste; press Return): ");
    let _ = screen.flush();
    let mut reader: &File = &tty;
    let key = read_secret(&mut reader, true);
    drop(restore);
    let _ = screen.write_all(b"\n");
    too_long_or(key, "the terminal")
}

#[cfg(not(unix))]
fn prompt_for_key() -> Result<Zeroizing<Vec<u8>>, Stop> {
    Err(stop(
        REFUSED,
        String::from(
            "On this system the tool can't hide what you type, so it won't ask for the key.\n\
             Give it through a pipe, or with --key-file <file>.",
        ),
    ))
}

fn get_key(args: &Args) -> Result<Zeroizing<Vec<u8>>, Stop> {
    if let Some(path) = &args.key_file {
        let mut file = match File::open(path) {
            Ok(f) => f,
            Err(e) => return Err(stop(REFUSED, format!("Couldn't open the key file {}: {}.", shown(path), e))),
        };
        return too_long_or(read_secret(&mut file, false), "the key file");
    }
    if std::io::stdin().is_terminal() {
        return prompt_for_key();
    }
    // Read the pipe without the standard input's own buffer, which would keep a copy.
    #[cfg(unix)]
    {
        if let Ok(mut direct) = File::open("/dev/stdin") {
            return too_long_or(read_secret(&mut direct, false), "the pipe");
        }
    }
    let mut stdin = std::io::stdin().lock();
    too_long_or(read_secret(&mut stdin, false), "the pipe")
}

fn open_with_the_key(opened: &TimeLayerOpened, args: &Args) -> Result<(), Stop> {
    eprintln!("The time lock is open. One lock is left: your Recovery Key.");
    eprintln!("It is in your password manager, in the entry named \"SafeSight Mac Recovery Key\".");
    eprintln!();
    let typed = get_key(args)?;
    let identity = match read_recovery_key(&typed) {
        Ok(i) => i,
        Err(e) => return Err(key_refused(e)),
    };
    drop(typed);
    let secret = match open_with_key(opened, &identity) {
        Ok(s) => s,
        Err(OpenError::NotForThisKey) => {
            return Err(stop(
                REFUSED,
                String::from(
                    "This Recovery Key doesn't open this copy. Check it is the key for this Mac.\n\
                     If you ever replaced your Recovery Key, try the other one: a copy saved\n\
                     before the change opens with the old key.",
                ),
            ))
        }
        Err(_) => {
            return Err(stop(
                REFUSED,
                String::from(
                    "This copy is damaged inside: it doesn't open even with the right key.\n\
                     Try another copy of it, for example from a backup.",
                ),
            ))
        }
    };
    drop(identity);

    eprintln!(
        "Opened. This is the password of the account \"{}\" on your Mac.\n\
         It is shown once. This tool keeps no copy.\n",
        ADMIN_ACCOUNT_NAME
    );
    let _ = std::io::stderr().flush();
    {
        let mut out = std::io::stdout().lock();
        let mut line = Zeroizing::new(Vec::with_capacity(secret.reveal().len() + 1));
        line.extend_from_slice(secret.reveal());
        line.push(b'\n');
        if out.write_all(&line).and_then(|_| out.flush()).is_err() {
            return Err(stop(REFUSED, String::from("Couldn't write the password to standard output.")));
        }
    }
    let length = secret.reveal().len();
    drop(secret);
    if !std::io::stdout().is_terminal() {
        eprintln!("(The password went to standard output, which isn't this screen.)");
    }
    eprintln!(
        "\n\
         It is {} characters long and has no spaces. Keep it private: whoever has it can\n\
         use that Mac as an administrator until SafeSight Mac replaces it.\n\
         \n\
         What to do next:\n  \
         1. Start the Mac.\n  \
         2. At the login window, choose the account \"{}\" and type this password.\n     \
            If that account isn't in the list, choose \"Other...\" and type its name.\n  \
         3. The SafeSight Mac app will offer \"Finish leaving\" and \"Stay\".\n  \
         4. You have {} days from the Mac's first start to choose. After that this password\n     \
            stops working, and SafeSight Mac goes on protecting the Mac.",
        length, ADMIN_ACCOUNT_NAME, CLAIM_DAYS
    );
    Ok(())
}

fn run() -> Result<(), Stop> {
    let args = parse_args()?;

    // Step 1: the copy.
    let too_big = format!(
        "{} isn't a SafeSight Mac recovery copy: it is too big to be one.",
        shown(&args.copy)
    );
    let copy_bytes = read_limited(&args.copy, opener::CAPSULE_INPUT_MAX, "recovery copy", &too_big)?;
    let info = match inspect(&copy_bytes) {
        Ok(i) => i,
        Err(e) => return Err(copy_refused(e, &args.copy)),
    };
    eprintln!("This recovery copy holds version {} of its Mac's admin password.", info.generation);
    eprintln!("It opens no earlier than {}.", when(&info));
    eprintln!();

    // Step 2: the round.
    let round_path = match &args.round {
        Some(p) => p,
        None => {
            let mut w = String::new();
            if let Some(c) = clock_words(&info) {
                w.push_str(&c);
                w.push_str("\n\n");
            }
            w.push_str(&download_words(&info, &args.copy));
            return Err(stop(NOT_READY, w));
        }
    };
    let too_big = format!("{} isn't the time signal: it is too big to be one.", shown(round_path));
    let round_bytes = read_limited(round_path, opener::ROUND_INPUT_MAX, "time signal file", &too_big)?;
    let round = match read_round(&round_bytes, info.target_round) {
        Ok(r) => r,
        Err(e) => return Err(round_refused(e, &info, round_path)),
    };

    // Steps 3 to 5: the round's signature, not before the target, the time layer.
    let opened = match open_time(&copy_bytes, &round) {
        Ok(o) => o,
        Err(e) => return Err(time_refused(e, &info, round.round, round.round_named, &args.copy)),
    };

    // Steps 6 and 7: the Recovery Key, the secret and the next steps.
    open_with_the_key(&opened, &args)
}
