use std::ffi::{CStr, CString, c_char};
use std::path::PathBuf;
use std::slice;
use std::sync::{OnceLock, mpsc};
use std::time::{Duration, Instant};

use serde::Deserialize;
use serde_json::{Value, json};

use crate::clip::{IMAGE_LIMIT, Part, TEXT_LIMIT, Thumbnail};
use crate::history::{Error, History};

#[repr(C)]
struct NativePart {
    item: usize,
    mime: *const c_char,
    data: *const u8,
    length: usize,
}

#[repr(C)]
struct NativeThumbnail {
    data: *mut u8,
    length: usize,
    width: usize,
    height: usize,
}

unsafe extern "C" {
    fn oc_event(message: *const c_char);
    fn oc_payload(ticket: u64, id: i64, sensitive: bool, parts: *const NativePart, count: usize);
    fn oc_preview_image(ticket: u64, id: i64, data: *const u8, length: usize);
    fn oc_thumbnail(data: *const u8, length: usize) -> NativeThumbnail;
    fn oc_free_thumbnail(data: *mut u8);
}

enum Work {
    Capture(Vec<Part>, bool, String),
    Request(Request),
}

#[derive(Deserialize)]
#[serde(tag = "action", rename_all = "snake_case")]
enum Request {
    Catalog {
        ticket: u64,
        query: String,
        kind: String,
        collection: i64,
    },
    Payload {
        ticket: u64,
        id: i64,
    },
    Pasted {
        id: i64,
    },
    Thumbnail {
        ticket: u64,
        id: i64,
    },
    Pin {
        id: i64,
        pinned: bool,
    },
    CreateCollection {
        name: String,
    },
    RenameCollection {
        id: i64,
        name: String,
    },
    SetCollectionColor {
        id: i64,
        color: String,
    },
    DeleteCollection {
        id: i64,
    },
    Membership {
        id: i64,
        collection: i64,
        add: bool,
    },
    DeleteMany {
        ids: Vec<i64>,
    },
    UndoDelete {
        ticket: u64,
    },
    Clear {
        all: bool,
    },
    Limit {
        limit: usize,
    },
    Retention {
        days: u16,
    },
    MarkSensitive {
        id: i64,
    },
    UnmarkSensitive {
        id: i64,
    },
}

static WORKER: OnceLock<mpsc::SyncSender<Work>> = OnceLock::new();

#[unsafe(no_mangle)]
unsafe extern "C" fn oc_start_worker(path: *const c_char) -> bool {
    let Some(path) = (unsafe { string(path) }) else {
        return false;
    };
    let (sender, receiver) = mpsc::sync_channel(24);
    if WORKER.set(sender).is_err() {
        return true;
    }
    std::thread::Builder::new()
        .name("openclipboard-history".into())
        .spawn(move || run(PathBuf::from(path), receiver))
        .is_ok()
}

#[unsafe(no_mangle)]
unsafe extern "C" fn oc_send(request: *const c_char) -> bool {
    let Some(request) = (unsafe { string(request) }) else {
        return false;
    };
    let Ok(request) = serde_json::from_str(&request) else {
        return false;
    };
    WORKER
        .get()
        .is_some_and(|worker| worker.try_send(Work::Request(request)).is_ok())
}

#[repr(u8)]
enum CaptureResult {
    Rejected,
    Accepted,
    Busy,
}

#[unsafe(no_mangle)]
unsafe extern "C" fn oc_capture(
    parts: *const NativePart,
    count: usize,
    detect_sensitive: bool,
    color: *const c_char,
) -> CaptureResult {
    if parts.is_null() || count == 0 || count > 1024 {
        return CaptureResult::Rejected;
    }
    let parts = unsafe { slice::from_raw_parts(parts, count) };
    let mut bytes = 0usize;
    let mut image = false;
    let mut accepted = Vec::with_capacity(count);
    for part in parts {
        let Some(mime) = (unsafe { string(part.mime) }) else {
            return CaptureResult::Rejected;
        };
        if part.data.is_null() && part.length != 0 {
            return CaptureResult::Rejected;
        }
        bytes = bytes.saturating_add(part.length);
        if bytes > IMAGE_LIMIT {
            return CaptureResult::Rejected;
        }
        image |= matches!(mime.as_str(), "public.png" | "public.tiff");
        accepted.push((part, mime));
    }
    if !image && bytes > TEXT_LIMIT {
        return CaptureResult::Rejected;
    }
    let mut parts: Vec<_> = accepted
        .into_iter()
        .map(|(part, mime)| Part {
            item: part.item,
            mime,
            data: if part.length == 0 {
                Vec::new()
            } else {
                // The native caller keeps its NSData objects alive until we make these copies.
                unsafe { slice::from_raw_parts(part.data, part.length) }.to_vec()
            },
        })
        .collect();
    parts.sort_by(|a, b| a.item.cmp(&b.item).then(a.mime.cmp(&b.mime)));
    let color = unsafe { string(color) }.unwrap_or_default();
    let Some(worker) = WORKER.get() else {
        return CaptureResult::Rejected;
    };
    match worker.try_send(Work::Capture(parts, detect_sensitive, color)) {
        Ok(()) => CaptureResult::Accepted,
        Err(mpsc::TrySendError::Full(_)) => CaptureResult::Busy,
        Err(mpsc::TrySendError::Disconnected(_)) => CaptureResult::Rejected,
    }
}

unsafe fn string(value: *const c_char) -> Option<String> {
    if value.is_null() {
        return None;
    }
    Some(unsafe { CStr::from_ptr(value) }.to_str().ok()?.into())
}

fn run(path: PathBuf, receiver: mpsc::Receiver<Work>) {
    let Ok(mut history) = History::open(&path) else {
        emit(json!({"kind": "error", "reason": "storage"}));
        return;
    };
    const EXPIRY_INTERVAL: Duration = Duration::from_secs(60);
    const UNDO_WINDOW: Duration = Duration::from_secs(10);
    let mut next_expiry = Instant::now() + EXPIRY_INTERVAL;
    let mut undo: Option<(u64, Instant)> = None;
    let mut delete_ticket = 0u64;
    loop {
        let now = Instant::now();
        if let Some((ticket, deadline)) = undo
            && now >= deadline
        {
            undo = None;
            if let Err(error) = history.discard_delete() {
                emit_error(error);
            }
            emit(json!({"kind":"undo_expired", "ticket":ticket}));
        }
        if history.has_retention_limit() && now >= next_expiry {
            match history.expire() {
                Ok(true) => emit(json!({"kind":"changed"})),
                Ok(false) => (),
                Err(error) => emit_error(error),
            }
            next_expiry = now + EXPIRY_INTERVAL;
        }
        let deadline = undo
            .map(|(_, deadline)| deadline)
            .into_iter()
            .chain(history.has_retention_limit().then_some(next_expiry))
            .min();
        let work = match deadline {
            Some(deadline) => {
                match receiver.recv_timeout(deadline.saturating_duration_since(now)) {
                    Ok(work) => work,
                    Err(mpsc::RecvTimeoutError::Timeout) => continue,
                    Err(mpsc::RecvTimeoutError::Disconnected) => break,
                }
            }
            None => {
                let Ok(work) = receiver.recv() else { break };
                work
            }
        };
        let result = match work {
            Work::Capture(parts, detect, color) => history
                .capture(parts, detect, color, create_thumbnail)
                .map(|_| emit(json!({"kind":"changed"}))),
            Work::Request(Request::DeleteMany { ids }) => history.delete(&ids).map(|count| {
                if count > 0 {
                    delete_ticket += 1;
                    undo = Some((delete_ticket, Instant::now() + UNDO_WINDOW));
                    emit(json!({"kind":"deleted", "ticket":delete_ticket, "count":count}));
                    emit(json!({"kind":"changed"}));
                }
            }),
            Work::Request(Request::UndoDelete { ticket }) => {
                let restored = if undo
                    .is_some_and(|(active, deadline)| active == ticket && Instant::now() < deadline)
                {
                    history.undo_delete()
                } else {
                    Err(Error::UndoUnavailable)
                };
                match restored {
                    Ok(()) => {
                        undo = None;
                        emit(json!({"kind":"delete_undone", "ticket":ticket}));
                        emit(json!({"kind":"changed"}));
                    }
                    Err(error) => {
                        emit(
                            json!({"kind":"undo_failed", "ticket":ticket, "reason":error_reason(error)}),
                        );
                    }
                }
                Ok(())
            }
            Work::Request(Request::Clear { all }) => history.clear(all).and_then(|()| {
                if let Some((ticket, _)) = undo.take() {
                    history.discard_delete()?;
                    emit(json!({"kind":"undo_expired", "ticket":ticket}));
                }
                emit(json!({"kind":"changed"}));
                Ok(())
            }),
            Work::Request(request) => handle_request(&mut history, request),
        };
        if let Err(error) = result {
            emit_error(error);
        }
    }
}

fn emit_error(error: Error) {
    emit(json!({"kind": "error", "reason": error_reason(error)}));
}

fn error_reason(error: Error) -> &'static str {
    match error {
        Error::Full => "full",
        Error::Missing => "missing",
        Error::CollectionName => "collection_name",
        Error::CollectionMissing => "collection_missing",
        Error::CollectionColor => "collection_color",
        Error::Storage => "storage",
        Error::UndoUnavailable => "undo_unavailable",
        Error::UndoFull => "undo_full",
        Error::NotManuallySensitive => "not_manually_sensitive",
    }
}

fn handle_request(history: &mut History, request: Request) -> Result<(), Error> {
    match request {
        Request::Catalog {
            ticket,
            query,
            kind,
            collection,
        } => {
            match history
                .expire()
                .and_then(|_| history.catalog(&query, &kind, collection))
            {
                Ok(catalog) => emit(json!({"kind":"catalog", "ticket":ticket, "catalog":catalog})),
                Err(error) => emit(
                    json!({"kind":"catalog_failed", "ticket":ticket, "reason":error_reason(error)}),
                ),
            }
            return Ok(());
        }
        Request::Payload { ticket, id } => {
            history.expire()?;
            let (parts, sensitive) = history.payload(id)?;
            let types: Vec<_> = parts
                .iter()
                .map(|part| CString::new(part.mime.as_str()))
                .collect::<Result<_, _>>()
                .map_err(|_| Error::Storage)?;
            let native: Vec<_> = parts
                .iter()
                .zip(&types)
                .map(|(part, mime)| NativePart {
                    item: part.item,
                    mime: mime.as_ptr(),
                    data: part.data.as_ptr(),
                    length: part.data.len(),
                })
                .collect();
            unsafe { oc_payload(ticket, id, sensitive, native.as_ptr(), native.len()) };
            return Ok(());
        }
        Request::Thumbnail { ticket, id } => {
            let bytes = history.thumbnail(id)?;
            unsafe { oc_preview_image(ticket, id, bytes.as_ptr(), bytes.len()) };
            return Ok(());
        }
        Request::Pin { id, pinned } => history.pin(id, pinned)?,
        Request::CreateCollection { name } => {
            let id = history.create_collection(&name)?;
            emit(json!({"kind":"created", "id":id}));
            return Ok(());
        }
        Request::RenameCollection { id, name } => history.rename_collection(id, &name)?,
        Request::SetCollectionColor { id, color } => history.set_collection_color(id, &color)?,
        Request::DeleteCollection { id } => history.delete_collection(id)?,
        Request::Membership {
            id,
            collection,
            add,
        } => history.membership(id, collection, add)?,
        Request::Pasted { id } => history.mark_pasted(id)?,
        Request::DeleteMany { .. } | Request::UndoDelete { .. } | Request::Clear { .. } => {
            unreachable!("handled with the undo state")
        }
        Request::Limit { limit } => {
            history.set_limit(limit)?;
            emit(json!({"kind":"limit", "value":limit.clamp(50, 2000)}));
        }
        Request::Retention { days } => {
            history.set_retention_days(days);
            history.expire()?;
        }
        Request::MarkSensitive { id } => history.mark_sensitive(id)?,
        Request::UnmarkSensitive { id } => history.unmark_sensitive(id, create_thumbnail)?,
    }
    emit(json!({"kind":"changed"}));
    Ok(())
}

fn create_thumbnail(parts: &[Part]) -> Thumbnail {
    for part in parts.iter().filter(|part| part.image()) {
        let native = unsafe { oc_thumbnail(part.data.as_ptr(), part.data.len()) };
        if native.data.is_null() {
            continue;
        }
        let bytes = unsafe { slice::from_raw_parts(native.data, native.length) }.to_vec();
        unsafe { oc_free_thumbnail(native.data) };
        return Thumbnail {
            bytes,
            width: native.width,
            height: native.height,
        };
    }
    Thumbnail::default()
}

fn emit(message: Value) {
    if let Ok(text) = CString::new(message.to_string()) {
        unsafe { oc_event(text.as_ptr()) };
    }
}
