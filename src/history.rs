use std::collections::{BTreeSet, HashMap};
use std::fs::{DirBuilder, File, OpenOptions};
use std::os::unix::fs::{DirBuilderExt, OpenOptionsExt};
use std::path::Path;
use std::time::{SystemTime, UNIX_EPOCH};

use rusqlite::{Connection, OptionalExtension, Transaction, params};
use serde::Serialize;
use sha2::{Digest, Sha256};

use crate::clip::{self, DISK_LIMIT, IMAGE_LIMIT, Part, Summary, Thumbnail};

const MILLIS_PER_DAY: i64 = 86_400_000;

pub(crate) enum Error {
    Storage,
    Full,
    Missing,
    CollectionName,
    CollectionMissing,
    CollectionColor,
    UndoUnavailable,
    UndoFull,
    NotManuallySensitive,
}

impl From<rusqlite::Error> for Error {
    fn from(_: rusqlite::Error) -> Self {
        Self::Storage
    }
}

type Result<T> = std::result::Result<T, Error>;

#[derive(Serialize)]
pub(crate) struct Collection {
    id: i64,
    name: String,
    /// Palette key for the tab dot, or empty for the automatic colour.
    color: String,
}

#[derive(Serialize)]
pub(crate) struct Catalog {
    pub clips: Vec<Summary>,
    pub collections: Vec<Collection>,
    pub usage: usize,
}

struct SessionClip {
    parts: Vec<Part>,
    digest: Vec<u8>,
    summary: Summary,
    restore_color: Option<String>,
}

pub(crate) struct History {
    disk: Connection,
    _owner: Option<File>,
    session: HashMap<i64, SessionClip>,
    deleted_session: Vec<SessionClip>,
    next_session_id: i64,
    limit: usize,
    retention_ms: Option<i64>,
}

impl History {
    pub fn open(path: &Path) -> Result<Self> {
        let directory = path.parent().ok_or(Error::Storage)?;
        DirBuilder::new()
            .recursive(true)
            .mode(0o700)
            .create(directory)
            .map_err(|_| Error::Storage)?;

        let private_file = || {
            let mut options = OpenOptions::new();
            options.write(true).create(true).truncate(false).mode(0o600);
            options
        };
        let owner = private_file()
            .open(directory.join(".history.lock"))
            .map_err(|_| Error::Storage)?;
        owner.try_lock().map_err(|_| Error::Storage)?;
        // Create a private file before allowing SQLite to open it.
        private_file().open(path).map_err(|_| Error::Storage)?;
        let mut history = Self::new(Connection::open(path)?)?;
        history._owner = Some(owner);
        Ok(history)
    }

    fn new(disk: Connection) -> Result<Self> {
        disk.execute_batch(
            "PRAGMA foreign_keys=ON;
             PRAGMA journal_mode=DELETE;
             PRAGMA secure_delete=ON;
             PRAGMA temp_store=MEMORY;
             CREATE TABLE IF NOT EXISTS clips (
                 id INTEGER PRIMARY KEY AUTOINCREMENT,
                 digest BLOB NOT NULL UNIQUE,
                 parts BLOB NOT NULL,
                 bytes INTEGER NOT NULL,
                 kind TEXT NOT NULL,
                 title TEXT NOT NULL,
                 search TEXT NOT NULL,
                 color TEXT NOT NULL,
                 thumbnail BLOB NOT NULL,
                 width INTEGER NOT NULL,
                 height INTEGER NOT NULL,
                 copied INTEGER NOT NULL,
                 pasted INTEGER,
                 pinned INTEGER NOT NULL DEFAULT 0
             );
             CREATE TABLE IF NOT EXISTS collections (
                 id INTEGER PRIMARY KEY AUTOINCREMENT,
                 name TEXT NOT NULL UNIQUE COLLATE NOCASE,
                 color TEXT NOT NULL DEFAULT ''
             );
             CREATE TABLE IF NOT EXISTS memberships (
                 clip INTEGER NOT NULL REFERENCES clips(id) ON DELETE CASCADE,
                 collection INTEGER NOT NULL REFERENCES collections(id) ON DELETE CASCADE,
                 PRIMARY KEY (clip,collection)
             );",
        )?;
        let has_pasted: bool = disk.query_row(
            "SELECT EXISTS(SELECT 1 FROM pragma_table_info('clips') WHERE name='pasted')",
            [],
            |row| row.get(0),
        )?;
        if !has_pasted {
            disk.execute("ALTER TABLE clips ADD COLUMN pasted INTEGER", [])?;
        }
        let has_color: bool = disk.query_row(
            "SELECT EXISTS(SELECT 1 FROM pragma_table_info('collections') WHERE name='color')",
            [],
            |row| row.get(0),
        )?;
        if !has_color {
            disk.execute(
                "ALTER TABLE collections ADD COLUMN color TEXT NOT NULL DEFAULT ''",
                [],
            )?;
        }
        Ok(Self {
            disk,
            _owner: None,
            session: HashMap::new(),
            deleted_session: Vec::new(),
            next_session_id: -1,
            limit: 500,
            retention_ms: None,
        })
    }

    pub fn capture(
        &mut self,
        parts: Vec<Part>,
        detect: bool,
        color: String,
        thumbnail: impl FnOnce(&[Part]) -> Thumbnail,
    ) -> Result<()> {
        let raw = bincode::serialize(&parts).map_err(|_| Error::Storage)?;
        let digest = Sha256::digest(&raw).to_vec();
        let copied = now();
        if let Some(clip) = self.session.values_mut().find(|clip| clip.digest == digest) {
            clip.summary.copied = copied;
            clip.summary.last_used = copied;
            return Ok(());
        }
        let existing = self
            .disk
            .query_row("SELECT id FROM clips WHERE digest = ?1", [&digest], |row| {
                row.get(0)
            })
            .optional()?;

        let was_sensitive = self
            .deleted_session
            .iter()
            .any(|clip| clip.digest == digest);
        if was_sensitive || (detect && clip::sensitive(&parts)) {
            if let Some(id) = existing {
                self.move_to_sensitive_session(id, false)?;
                if let Some(clip) = self.session.get_mut(&id) {
                    clip.summary.copied = copied;
                    clip.summary.last_used = copied;
                }
                return Ok(());
            }
            let id = self.next_session_id;
            let bytes = bytes_of(&parts);
            self.ensure_session_space(bytes)?;
            self.session.insert(
                id,
                SessionClip {
                    parts,
                    digest,
                    summary: sensitive_summary(id, copied, copied, false, bytes, Vec::new(), false),
                    restore_color: None,
                },
            );
            self.next_session_id -= 1;
            return Ok(());
        }

        if let Some(id) = existing {
            self.disk.execute(
                "UPDATE clips SET copied=?2,pasted=NULL WHERE id=?1",
                params![id, copied],
            )?;
            return Ok(());
        }

        let thumbnail = thumbnail(&parts);
        // The allowlist alone does not establish whether bytes form a supported image.
        if parts.iter().any(Part::image) && thumbnail.bytes.is_empty() {
            return Ok(());
        }
        let (kind, title, search, color) = clip::metadata(&parts, color);
        let bytes = bytes_of(&parts) + thumbnail.bytes.len();
        let transaction = self.disk.transaction()?;
        transaction.execute(
            "INSERT INTO clips (digest,parts,bytes,kind,title,search,color,thumbnail,width,height,copied)
             VALUES (?1,?2,?3,?4,?5,?6,?7,?8,?9,?10,?11)",
            params![digest, raw, bytes, kind, title, search, color, thumbnail.bytes,
                thumbnail.width, thumbnail.height, copied],
        )?;
        let added = transaction.last_insert_rowid();
        trim(&transaction, self.limit, Some(added))?;
        transaction.commit()?;
        Ok(())
    }

    pub fn catalog(&self, query: &str, kind: &str, collection: i64) -> Result<Catalog> {
        let mut select = self.disk.prepare(
            "SELECT id,kind,title,copied,pinned,bytes,width,height,color,MAX(copied,COALESCE(pasted,copied))
             FROM clips c
             WHERE (?1='' OR instr(c.search,?1)>0) AND (?2='' OR c.kind=?2)
               AND (?3=0 OR EXISTS(SELECT 1 FROM memberships m WHERE m.clip=c.id AND m.collection=?3))",
        )?;
        let clips = select.query_map(params![query.to_lowercase(), kind, collection], |row| {
            Ok(Summary {
                id: row.get(0)?,
                kind: row.get(1)?,
                title: row.get(2)?,
                copied: row.get(3)?,
                last_used: row.get(9)?,
                pinned: row.get(4)?,
                bytes: row.get(5)?,
                width: row.get(6)?,
                height: row.get(7)?,
                color: row.get(8)?,
                sensitive: false,
                manually_sensitive: false,
                collections: Vec::new(),
            })
        })?;
        let mut clips = clips.collect::<rusqlite::Result<Vec<_>>>()?;
        let mut memberships: HashMap<i64, Vec<i64>> = HashMap::new();
        let mut select = self
            .disk
            .prepare("SELECT clip,collection FROM memberships")?;
        for membership in select.query_map([], |row| Ok((row.get(0)?, row.get(1)?)))? {
            let (clip, collection) = membership?;
            memberships.entry(clip).or_default().push(collection);
        }
        for clip in &mut clips {
            clip.collections = memberships.remove(&clip.id).unwrap_or_default();
        }
        if query.is_empty() && (kind.is_empty() || kind == "sensitif") {
            clips.extend(
                self.session
                    .values()
                    .filter(|clip| {
                        collection == 0 || clip.summary.collections.contains(&collection)
                    })
                    .map(|clip| clip.summary.clone()),
            );
        }
        clips.sort_by(|a, b| {
            b.last_used
                .cmp(&a.last_used)
                .then(b.id.unsigned_abs().cmp(&a.id.unsigned_abs()))
        });
        let mut select = self
            .disk
            .prepare("SELECT id,name,color FROM collections ORDER BY id")?;
        let collections = select
            .query_map([], |row| {
                Ok(Collection {
                    id: row.get(0)?,
                    name: row.get(1)?,
                    color: row.get(2)?,
                })
            })?
            .collect::<rusqlite::Result<Vec<_>>>()?;
        Ok(Catalog {
            clips,
            collections,
            usage: disk_usage(&self.disk)?,
        })
    }

    pub fn payload(&self, id: i64) -> Result<(Vec<Part>, bool)> {
        if let Some(clip) = self.session.get(&id) {
            return Ok((clip.parts.clone(), true));
        }
        let raw: Vec<u8> = self
            .disk
            .query_row("SELECT parts FROM clips WHERE id=?1", [id], |row| {
                row.get(0)
            })
            .optional()?
            .ok_or(Error::Missing)?;
        let parts = bincode::deserialize(&raw).map_err(|_| Error::Storage)?;
        Ok((parts, false))
    }

    pub fn thumbnail(&self, id: i64) -> Result<Vec<u8>> {
        self.disk
            .query_row("SELECT thumbnail FROM clips WHERE id=?1", [id], |row| {
                row.get(0)
            })
            .optional()
            .map_err(Into::into)
            .map(|value| value.unwrap_or_default())
    }

    pub fn pin(&mut self, id: i64, pinned: bool) -> Result<()> {
        if let Some(clip) = self.session.get_mut(&id) {
            clip.summary.pinned = pinned;
            return Ok(());
        }
        let transaction = self.disk.transaction()?;
        transaction.execute(
            "UPDATE clips SET pinned=?2 WHERE id=?1",
            params![id, pinned],
        )?;
        trim(&transaction, self.limit, None)?;
        transaction.commit()?;
        Ok(())
    }

    pub fn create_collection(&mut self, name: &str) -> Result<i64> {
        let name = validate_collection_name(name)?;
        let updated = self
            .disk
            .execute("INSERT OR IGNORE INTO collections(name) VALUES(?1)", [name])?;
        if updated == 0 {
            return Err(Error::CollectionName);
        }
        Ok(self.disk.last_insert_rowid())
    }

    pub fn rename_collection(&mut self, id: i64, name: &str) -> Result<()> {
        let name = validate_collection_name(name)?;
        match self.disk.execute(
            "UPDATE collections SET name=?2 WHERE id=?1",
            params![id, name],
        ) {
            Ok(0) => Err(Error::CollectionMissing),
            Ok(_) => Ok(()),
            Err(rusqlite::Error::SqliteFailure(error, _))
                if error.code == rusqlite::ErrorCode::ConstraintViolation =>
            {
                Err(Error::CollectionName)
            }
            Err(error) => Err(error.into()),
        }
    }

    pub fn set_collection_color(&mut self, id: i64, color: &str) -> Result<()> {
        if !COLLECTION_COLORS.contains(&color) {
            return Err(Error::CollectionColor);
        }
        match self.disk.execute(
            "UPDATE collections SET color=?2 WHERE id=?1",
            params![id, color],
        )? {
            0 => Err(Error::CollectionMissing),
            _ => Ok(()),
        }
    }

    pub fn delete_collection(&mut self, id: i64) -> Result<()> {
        if self
            .disk
            .execute("DELETE FROM collections WHERE id=?1", [id])?
            == 0
        {
            return Err(Error::CollectionMissing);
        }
        // SQLite removes saved memberships. In-memory clips keep only surviving collections.
        for clip in self.session.values_mut() {
            clip.summary
                .collections
                .retain(|collection| *collection != id);
        }
        Ok(())
    }

    pub fn membership(&mut self, id: i64, collection: i64, add: bool) -> Result<()> {
        if let Some(clip) = self.session.get_mut(&id) {
            let mut collections: BTreeSet<_> = clip.summary.collections.iter().copied().collect();
            if add {
                let valid: bool = self.disk.query_row(
                    "SELECT EXISTS(SELECT 1 FROM collections WHERE id=?1)",
                    [collection],
                    |row| row.get(0),
                )?;
                if valid {
                    collections.insert(collection);
                }
            } else {
                collections.remove(&collection);
            }
            clip.summary.collections = collections.into_iter().collect();
            return Ok(());
        }
        let transaction = self.disk.transaction()?;
        if add {
            transaction.execute(
                "INSERT OR IGNORE INTO memberships(clip,collection) VALUES(?1,?2)",
                [id, collection],
            )?;
        } else {
            transaction.execute(
                "DELETE FROM memberships WHERE clip=?1 AND collection=?2",
                [id, collection],
            )?;
            trim(&transaction, self.limit, None)?;
        }
        transaction.commit()?;
        Ok(())
    }

    pub fn delete(&mut self, ids: &[i64]) -> Result<usize> {
        let transaction = self.disk.transaction()?;
        transaction.execute_batch(
            "CREATE TEMP TABLE IF NOT EXISTS deleted_clips AS SELECT * FROM clips WHERE 0;
             CREATE TEMP TABLE IF NOT EXISTS deleted_memberships AS SELECT * FROM memberships WHERE 0;
             DELETE FROM deleted_clips;
             DELETE FROM deleted_memberships;",
        )?;
        let mut count = 0;
        {
            let mut clip =
                transaction.prepare("INSERT INTO deleted_clips SELECT * FROM clips WHERE id=?1")?;
            let mut memberships = transaction.prepare(
                "INSERT INTO deleted_memberships SELECT * FROM memberships WHERE clip=?1",
            )?;
            let mut delete = transaction.prepare("DELETE FROM clips WHERE id=?1")?;
            for id in ids {
                count += clip.execute([id])?;
                memberships.execute([id])?;
                delete.execute([id])?;
            }
        }
        if count == 0 && !ids.iter().any(|id| self.session.contains_key(id)) {
            return Ok(0); // Roll back the empty request and keep the previous undo.
        }
        transaction.commit()?;
        self.deleted_session = ids
            .iter()
            .filter_map(|id| self.session.remove(id))
            .collect();
        Ok(count + self.deleted_session.len())
    }

    pub fn discard_delete(&mut self) -> Result<()> {
        self.deleted_session.clear();
        self.disk.execute_batch(
            "DROP TABLE IF EXISTS temp.deleted_memberships;
             DROP TABLE IF EXISTS temp.deleted_clips;",
        )?;
        Ok(())
    }

    pub fn undo_delete(&mut self) -> Result<()> {
        let new_session: Vec<_> = self
            .deleted_session
            .iter()
            .filter(|deleted| {
                !self
                    .session
                    .values()
                    .any(|clip| clip.digest == deleted.digest)
            })
            .collect();
        let session_bytes: usize = self
            .session
            .values()
            .chain(new_session.iter().copied())
            .map(|clip| clip.summary.bytes)
            .sum();
        if self.session.len() + new_session.len() > 50 || session_bytes > IMAGE_LIMIT {
            return Err(Error::UndoFull);
        }

        let transaction = self.disk.transaction()?;
        // A clip recopied as sensitive during the undo window must stay off disk.
        for clip in self.session.values() {
            transaction.execute("DELETE FROM deleted_clips WHERE digest=?1", [&clip.digest])?;
        }
        transaction.execute_batch(
            "INSERT OR IGNORE INTO clips SELECT * FROM deleted_clips;
             UPDATE clips SET pinned=1 WHERE digest IN (SELECT digest FROM deleted_clips WHERE pinned);
             INSERT OR IGNORE INTO memberships
                 SELECT c.id,m.collection FROM deleted_memberships m
                 JOIN deleted_clips d ON d.id=m.clip
                 JOIN clips c ON c.digest=d.digest
                 JOIN collections g ON g.id=m.collection;",
        )?;
        if ordinary_count(&transaction)? > self.limit || disk_usage(&transaction)? > DISK_LIMIT {
            return Err(Error::UndoFull);
        }
        let collections = {
            let mut select = transaction.prepare("SELECT id FROM collections")?;
            select
                .query_map([], |row| row.get(0))?
                .collect::<rusqlite::Result<BTreeSet<i64>>>()?
        };
        transaction.execute_batch("DROP TABLE deleted_memberships; DROP TABLE deleted_clips;")?;
        transaction.commit()?;
        for mut deleted in self.deleted_session.drain(..) {
            deleted
                .summary
                .collections
                .retain(|id| collections.contains(id));
            if let Some(current) = self
                .session
                .values_mut()
                .find(|clip| clip.digest == deleted.digest)
            {
                current.summary.pinned |= deleted.summary.pinned;
                if current.restore_color.is_none() && deleted.restore_color.is_some() {
                    current.restore_color = deleted.restore_color;
                    current.summary.manually_sensitive = true;
                }
                current
                    .summary
                    .collections
                    .extend(deleted.summary.collections);
                current.summary.collections.sort_unstable();
                current.summary.collections.dedup();
            } else {
                self.session.insert(deleted.summary.id, deleted);
            }
        }
        Ok(())
    }

    pub fn mark_pasted(&mut self, id: i64) -> Result<()> {
        let latest_saved: Option<i64> = self.disk.query_row(
            "SELECT MAX(MAX(copied,COALESCE(pasted,copied))) FROM clips",
            [],
            |row| row.get(0),
        )?;
        let latest = latest_saved
            .into_iter()
            .chain(self.session.values().map(|clip| clip.summary.last_used))
            .max()
            .unwrap_or(0);
        let pasted = now().max(latest.saturating_add(1));

        if let Some(clip) = self.session.get_mut(&id) {
            clip.summary.last_used = pasted;
        } else {
            self.disk.execute(
                "UPDATE clips SET pasted=?2 WHERE id=?1",
                params![id, pasted],
            )?;
        }
        Ok(())
    }

    pub fn clear(&mut self, all: bool) -> Result<()> {
        if all {
            self.disk.execute("DELETE FROM clips", [])?;
            self.session.clear();
        } else {
            self.remove_unprotected(None)?;
        }
        Ok(())
    }

    pub fn set_retention_days(&mut self, days: u16) {
        self.retention_ms = (days != 0).then(|| i64::from(days) * MILLIS_PER_DAY);
    }

    pub fn has_retention_limit(&self) -> bool {
        self.retention_ms.is_some()
    }

    pub fn expire(&mut self) -> Result<bool> {
        self.expire_at(now())
    }

    fn expire_at(&mut self, time: i64) -> Result<bool> {
        match self.retention_ms {
            Some(age) => self.remove_unprotected(Some(time.saturating_sub(age))),
            None => Ok(false),
        }
    }

    fn remove_unprotected(&mut self, cutoff: Option<i64>) -> Result<bool> {
        let removed = self.disk.execute(
            "DELETE FROM clips WHERE NOT pinned AND (?1 IS NULL OR copied <= ?1)
             AND NOT EXISTS(SELECT 1 FROM memberships WHERE clip=clips.id)",
            [cutoff],
        )?;
        let previous = self.session.len();
        self.session.retain(|_, clip| {
            let summary = &clip.summary;
            summary.pinned
                || !summary.collections.is_empty()
                || cutoff.is_some_and(|time| summary.copied > time)
        });
        Ok(removed > 0 || self.session.len() < previous)
    }

    pub fn set_limit(&mut self, limit: usize) -> Result<()> {
        let limit = limit.clamp(50, 2000);
        let transaction = self.disk.transaction()?;
        trim(&transaction, limit, None)?;
        transaction.commit()?;
        self.limit = limit;
        Ok(())
    }

    pub fn mark_sensitive(&mut self, id: i64) -> Result<()> {
        self.move_to_sensitive_session(id, true)
    }

    fn move_to_sensitive_session(&mut self, id: i64, manually_marked: bool) -> Result<()> {
        if self.session.contains_key(&id) {
            return Ok(());
        }
        let (parts, _) = self.payload(id)?;
        let bytes = bytes_of(&parts);
        self.ensure_session_space(bytes)?;
        let (digest, copied, last_used, pinned, color) = self.disk.query_row(
            "SELECT digest,copied,MAX(copied,COALESCE(pasted,copied)),pinned,color FROM clips WHERE id=?1",
            [id],
            |row| Ok((row.get(0)?, row.get(1)?, row.get(2)?, row.get(3)?, row.get(4)?)),
        )?;
        let collections = {
            let mut select = self
                .disk
                .prepare("SELECT collection FROM memberships WHERE clip=?1")?;
            select
                .query_map([id], |row| row.get(0))?
                .collect::<rusqlite::Result<_>>()?
        };
        let transaction = self.disk.transaction()?;
        transaction.execute("DELETE FROM clips WHERE id=?1", [id])?;
        transaction.commit()?;
        self.session.insert(
            id,
            SessionClip {
                parts,
                digest,
                summary: sensitive_summary(
                    id,
                    copied,
                    last_used,
                    pinned,
                    bytes,
                    collections,
                    manually_marked,
                ),
                restore_color: manually_marked.then_some(color),
            },
        );
        Ok(())
    }

    pub fn unmark_sensitive(
        &mut self,
        id: i64,
        thumbnail: impl FnOnce(&[Part]) -> Thumbnail,
    ) -> Result<()> {
        let clip = self.session.get(&id).ok_or(Error::Missing)?;
        let color = clip
            .restore_color
            .clone()
            .ok_or(Error::NotManuallySensitive)?;
        let raw = bincode::serialize(&clip.parts).map_err(|_| Error::Storage)?;
        let thumbnail = thumbnail(&clip.parts);
        if clip.parts.iter().any(Part::image) && thumbnail.bytes.is_empty() {
            return Err(Error::Storage);
        }
        let (kind, title, search, color) = clip::metadata(&clip.parts, color);
        let summary = &clip.summary;
        let pasted = (summary.last_used > summary.copied).then_some(summary.last_used);
        let bytes = summary.bytes + thumbnail.bytes.len();

        let transaction = self.disk.transaction()?;
        transaction.execute(
            "INSERT INTO clips (id,digest,parts,bytes,kind,title,search,color,thumbnail,width,height,copied,pasted,pinned)
             VALUES (?1,?2,?3,?4,?5,?6,?7,?8,?9,?10,?11,?12,?13,?14)",
            params![id, clip.digest, raw, bytes, kind, title, search, color, thumbnail.bytes,
                thumbnail.width, thumbnail.height, summary.copied, pasted, summary.pinned],
        )?;
        {
            let mut add_membership =
                transaction.prepare("INSERT INTO memberships(clip,collection) VALUES(?1,?2)")?;
            for collection in &summary.collections {
                add_membership.execute(params![id, collection])?;
            }
        }
        trim(&transaction, self.limit, Some(id))?;
        transaction.commit()?;
        self.session.remove(&id);
        Ok(())
    }

    fn ensure_session_space(&self, bytes: usize) -> Result<()> {
        let used: usize = self.session.values().map(|clip| clip.summary.bytes).sum();
        if self.session.len() >= 50 || used.saturating_add(bytes) > IMAGE_LIMIT {
            return Err(Error::Full);
        }
        Ok(())
    }
}

fn now() -> i64 {
    SystemTime::now()
        .duration_since(UNIX_EPOCH)
        .unwrap_or_default()
        .as_millis() as i64
}

fn bytes_of(parts: &[Part]) -> usize {
    parts.iter().map(|part| part.data.len()).sum()
}

fn sensitive_summary(
    id: i64,
    copied: i64,
    last_used: i64,
    pinned: bool,
    bytes: usize,
    collections: Vec<i64>,
    manually_sensitive: bool,
) -> Summary {
    Summary {
        id,
        copied,
        last_used,
        pinned,
        sensitive: true,
        manually_sensitive,
        bytes,
        collections,
        kind: "sensitif".into(),
        title: "Item sensitif".into(),
        width: 0,
        height: 0,
        color: String::new(),
    }
}

fn disk_usage(disk: &Connection) -> Result<usize> {
    Ok(
        disk.query_row("SELECT COALESCE(SUM(bytes),0) FROM clips", [], |row| {
            row.get(0)
        })?,
    )
}

fn ordinary_count(disk: &Connection) -> Result<usize> {
    Ok(disk.query_row(
        "SELECT COUNT(*) FROM clips c WHERE NOT c.pinned AND
         NOT EXISTS(SELECT 1 FROM memberships WHERE clip=c.id)",
        [],
        |row| row.get(0),
    )?)
}

fn trim(transaction: &Transaction<'_>, limit: usize, added: Option<i64>) -> Result<()> {
    let mut count = ordinary_count(transaction)?;
    let mut usage = disk_usage(transaction)?;
    if count <= limit && usage <= DISK_LIMIT {
        return Ok(());
    }

    let candidates = {
        let mut select = transaction.prepare(
            "SELECT id,bytes FROM clips c WHERE NOT c.pinned AND (?1 IS NULL OR id<>?1)
             AND NOT EXISTS(SELECT 1 FROM memberships WHERE clip=c.id)
             ORDER BY copied ASC,id ASC",
        )?;
        select
            .query_map([added], |row| {
                Ok((row.get::<_, i64>(0)?, row.get::<_, usize>(1)?))
            })?
            .collect::<rusqlite::Result<Vec<_>>>()?
    };
    for (id, bytes) in candidates {
        transaction.execute("DELETE FROM clips WHERE id=?1", [id])?;
        count -= 1;
        usage -= bytes;
        if count <= limit && usage <= DISK_LIMIT {
            return Ok(());
        }
    }
    Err(Error::Full)
}

/// Palette keys a collection may use for its tab dot. Empty means automatic.
const COLLECTION_COLORS: [&str; 10] = [
    "", "red", "orange", "yellow", "green", "teal", "blue", "purple", "pink", "gray",
];

fn validate_collection_name(name: &str) -> Result<&str> {
    let name = name.trim();
    if name.is_empty() || name.chars().count() > 60 {
        return Err(Error::CollectionName);
    }
    Ok(name)
}

#[cfg(test)]
mod tests {
    use super::*;

    fn history() -> History {
        History::new(Connection::open_in_memory().unwrap())
            .ok()
            .unwrap()
    }

    fn add(history: &mut History, text: &str) -> i64 {
        history
            .capture(
                vec![Part {
                    item: 0,
                    mime: "public.utf8-plain-text".into(),
                    data: text.as_bytes().to_vec(),
                }],
                true,
                String::new(),
                |_| Thumbnail::default(),
            )
            .ok()
            .unwrap();
        history.catalog("", "", 0).ok().unwrap().clips[0].id
    }

    #[test]
    fn unmark_sensitive_restores_an_image_clip_with_its_metadata() {
        let mut history = history();
        let parts = vec![
            Part {
                item: 0,
                mime: "public.png".into(),
                data: vec![1, 2, 3],
            },
            Part {
                item: 0,
                mime: "public.utf8-plain-text".into(),
                data: b"Gambar referensi".to_vec(),
            },
        ];
        let make_thumbnail = |_: &[Part]| Thumbnail {
            bytes: vec![4, 5],
            width: 80,
            height: 60,
        };
        history
            .capture(parts.clone(), true, "#3355AA".into(), make_thumbnail)
            .ok()
            .unwrap();
        let id = history.catalog("", "", 0).ok().unwrap().clips[0].id;
        let collection = history.create_collection("Desain").ok().unwrap();
        history.pin(id, true).ok().unwrap();
        history.membership(id, collection, true).ok().unwrap();
        history.mark_pasted(id).ok().unwrap();
        let before = history
            .catalog("referensi", "", collection)
            .ok()
            .unwrap()
            .clips
            .remove(0);

        history.mark_sensitive(id).ok().unwrap();
        let hidden = history
            .catalog("", "", collection)
            .ok()
            .unwrap()
            .clips
            .remove(0);
        assert!(hidden.sensitive && hidden.manually_sensitive);
        assert!(
            history
                .catalog("referensi", "", 0)
                .ok()
                .unwrap()
                .clips
                .is_empty()
        );
        assert!(matches!(
            history.unmark_sensitive(id, |_| Thumbnail::default()),
            Err(Error::Storage)
        ));
        assert!(history.payload(id).ok().unwrap().1);

        history.unmark_sensitive(id, make_thumbnail).ok().unwrap();
        let restored = history
            .catalog("referensi", "gambar", collection)
            .ok()
            .unwrap()
            .clips
            .remove(0);
        assert_eq!(restored.id, id);
        assert!(restored.pinned && !restored.sensitive && !restored.manually_sensitive);
        assert_eq!(restored.collections, vec![collection]);
        assert_eq!(restored.last_used, before.last_used);
        assert_eq!(restored.copied, before.copied);
        assert_eq!(restored.color, "#3355AA");
        assert_eq!((restored.width, restored.height), (80, 60));
        assert_eq!(history.thumbnail(id).ok().unwrap(), vec![4, 5]);
        assert_eq!(history.payload(id).ok().unwrap(), (parts, false));
        assert!(!history.session.contains_key(&id));
    }

    #[test]
    fn automatically_detected_clip_cannot_be_unmarked() {
        let mut history = history();
        let parts = vec![Part {
            item: 0,
            mime: "public.utf8-plain-text".into(),
            data: b"-----BEGIN PRIVATE KEY-----\nfixture\n-----END PRIVATE KEY-----".to_vec(),
        }];
        history
            .capture(parts.clone(), false, String::new(), |_| {
                Thumbnail::default()
            })
            .ok()
            .unwrap();
        let id = history.catalog("", "", 0).ok().unwrap().clips[0].id;

        history
            .capture(parts, true, String::new(), |_| Thumbnail::default())
            .ok()
            .unwrap();
        let summary = history.catalog("", "", 0).ok().unwrap().clips.remove(0);
        assert!(summary.sensitive && !summary.manually_sensitive);
        assert!(matches!(
            history.unmark_sensitive(id, |_| Thumbnail::default()),
            Err(Error::NotManuallySensitive)
        ));
        assert_eq!(disk_usage(&history.disk).ok(), Some(0));
    }

    #[test]
    fn undo_batch_restores_payload_pin_and_membership() {
        let mut history = history();
        let ordinary = add(&mut history, "Brief desain");
        add(
            &mut history,
            "-----BEGIN PRIVATE KEY-----\nfixture\n-----END PRIVATE KEY-----",
        );
        let sensitive = history.catalog("", "sensitif", 0).ok().unwrap().clips[0].id;
        let collection = history.create_collection("Desain").ok().unwrap();
        history.pin(ordinary, true).ok().unwrap();
        history.membership(ordinary, collection, true).ok().unwrap();
        history
            .membership(sensitive, collection, true)
            .ok()
            .unwrap();
        let before_ordinary = history.payload(ordinary).ok().unwrap();
        let before_sensitive = history.payload(sensitive).ok().unwrap();

        assert_eq!(history.delete(&[ordinary, sensitive]).ok(), Some(2));
        assert_eq!(history.delete(&[ordinary, sensitive]).ok(), Some(0));
        assert!(history.catalog("", "", 0).ok().unwrap().clips.is_empty());

        history.undo_delete().ok().unwrap();
        let restored = history.catalog("", "", collection).ok().unwrap().clips;
        assert_eq!(restored.len(), 2);
        assert!(
            restored
                .iter()
                .any(|clip| clip.id == ordinary && clip.pinned)
        );
        assert!(
            restored
                .iter()
                .any(|clip| clip.id == sensitive && clip.sensitive)
        );
        assert_eq!(
            history.payload(ordinary).ok().unwrap().0[0].data,
            before_ordinary.0[0].data
        );
        assert_eq!(
            history.payload(sensitive).ok().unwrap().0[0].data,
            before_sensitive.0[0].data
        );
    }

    #[test]
    fn undo_preserves_recaptured_clip_and_ignores_removed_collection() {
        let mut history = history();
        let id = add(&mut history, "Panduan desain");
        let collection = history.create_collection("Desain").ok().unwrap();
        history.membership(id, collection, true).ok().unwrap();
        assert_eq!(history.delete(&[id]).ok(), Some(1));
        let recaptured = add(&mut history, "Panduan desain");
        assert_ne!(id, recaptured);
        history.delete_collection(collection).ok().unwrap();

        history.undo_delete().ok().unwrap();
        let restored = history.catalog("", "", 0).ok().unwrap().clips;
        assert_eq!(restored.len(), 1);
        assert_eq!(restored[0].id, recaptured);
        assert!(restored[0].collections.is_empty());
    }

    #[test]
    fn protects_members_from_pruning_and_clears_only_ordinary_history() {
        let mut history = history();
        history.limit = 1;
        let added = add(&mut history, "keep");
        let collection = history.create_collection("Pribadi").ok().unwrap();
        history.membership(added, collection, true).ok().unwrap();
        add(&mut history, "old");
        add(&mut history, "new");
        assert!(history.catalog("old", "", 0).ok().unwrap().clips.is_empty());
        history.clear(false).ok().unwrap();
        let result = history.catalog("", "", 0).ok().unwrap();
        assert_eq!(result.clips.len(), 1);
        assert_eq!(result.clips[0].id, added);
        history.clear(true).ok().unwrap();
        let result = history.catalog("", "", 0).ok().unwrap();
        assert!(result.clips.is_empty());
        assert_eq!(result.collections.len(), 1);
    }

    #[test]
    fn pinned_clips_keep_copy_order_and_survive_clearing_history() {
        let mut history = history();
        let pinned = add(&mut history, "older pinned clip");
        let newer = add(&mut history, "newer ordinary clip");
        history
            .disk
            .execute("UPDATE clips SET copied=id", [])
            .unwrap();
        history.pin(pinned, true).ok().unwrap();

        let clips = history.catalog("", "", 0).ok().unwrap().clips;
        assert_eq!(
            clips.iter().map(|clip| clip.id).collect::<Vec<_>>(),
            [newer, pinned]
        );
        assert!(clips[1].pinned);

        history.clear(false).ok().unwrap();
        let clips = history.catalog("", "", 0).ok().unwrap().clips;
        assert_eq!(clips.len(), 1);
        assert_eq!(clips[0].id, pinned);
        assert!(clips[0].pinned);
    }

    #[test]
    fn upgrading_history_preserves_clips_and_tracks_pastes_without_changing_copy_time() {
        let mut before = history();
        let older = add(&mut before, "older clip");
        let newer = add(&mut before, "newer clip");
        let collection = before.create_collection("Work").ok().unwrap();
        before.membership(older, collection, true).ok().unwrap();
        before
            .disk
            .execute("UPDATE clips SET copied=id", [])
            .unwrap();
        before
            .disk
            .execute("ALTER TABLE clips DROP COLUMN pasted", [])
            .unwrap();

        let mut history = History::new(before.disk).ok().unwrap();
        let clips = history.catalog("", "", 0).ok().unwrap().clips;
        assert_eq!(
            clips.iter().map(|clip| clip.id).collect::<Vec<_>>(),
            [newer, older]
        );
        assert!(clips.iter().all(|clip| clip.last_used == clip.copied));
        history.mark_pasted(older).ok().unwrap();
        let clips = history.catalog("", "", 0).ok().unwrap().clips;
        assert_eq!(clips[0].id, older);
        assert_eq!(clips[0].copied, older);
        assert_eq!(clips[0].collections, [collection]);
        assert_eq!(clips.len(), 2);

        history.mark_sensitive(older).ok().unwrap();
        history.mark_pasted(newer).ok().unwrap();
        history.mark_pasted(older).ok().unwrap();
        let clips = history.catalog("", "", 0).ok().unwrap().clips;
        assert_eq!(clips[0].id, older);
        assert!(clips[0].sensitive);
        assert_eq!(clips[0].copied, older);
        assert_eq!(clips[0].collections, [collection]);
    }

    #[test]
    fn retention_expires_ordinary_disk_and_session_clips_only() {
        let mut history = history();
        let old = add(&mut history, "old ordinary");
        let recent = add(&mut history, "recent ordinary");
        let pinned = add(&mut history, "old pinned");
        let member = add(&mut history, "old collection member");
        let collection = history.create_collection("Keep").ok().unwrap();
        history.pin(pinned, true).ok().unwrap();
        history.membership(member, collection, true).ok().unwrap();
        history
            .disk
            .execute(
                "UPDATE clips SET copied=CASE WHEN id=?1 THEN 2 ELSE 1 END",
                [recent],
            )
            .unwrap();

        add(
            &mut history,
            "-----BEGIN PRIVATE KEY-----\nfixture\n-----END PRIVATE KEY-----",
        );
        let session = history.session.values_mut().next().unwrap();
        let session_id = session.summary.id;
        session.summary.copied = 1;

        let boundary = MILLIS_PER_DAY + 1;
        assert_eq!(history.expire_at(boundary).ok(), Some(false));
        history.set_retention_days(1);
        assert_eq!(history.expire_at(boundary).ok(), Some(true));
        assert!(matches!(history.payload(old), Err(Error::Missing)));
        assert!(matches!(history.payload(session_id), Err(Error::Missing)));
        assert!(history.payload(recent).is_ok());
        assert!(history.payload(pinned).is_ok());
        assert!(history.payload(member).is_ok());
        assert_eq!(history.expire_at(boundary).ok(), Some(false));
    }

    #[test]
    fn renaming_and_deleting_collections_preserves_clips_and_other_memberships() {
        let mut history = history();
        let primary = history.create_collection("Pribadi").ok().unwrap();
        let secondary = history.create_collection("Kerja").ok().unwrap();
        let saved = add(&mut history, "saved clip");
        add(
            &mut history,
            "-----BEGIN PRIVATE KEY-----\nfixture\n-----END PRIVATE KEY-----",
        );
        let sensitive = history.catalog("", "sensitif", 0).ok().unwrap().clips[0].id;
        assert!(saved > 0 && sensitive < 0);
        for id in [saved, sensitive] {
            history.membership(id, primary, true).ok().unwrap();
            history.membership(id, secondary, true).ok().unwrap();
        }
        assert!(matches!(
            history.rename_collection(primary, "KERJA"),
            Err(Error::CollectionName)
        ));
        assert!(matches!(
            history.rename_collection(primary, " "),
            Err(Error::CollectionName)
        ));
        assert!(matches!(
            history.rename_collection(primary, &"x".repeat(61)),
            Err(Error::CollectionName)
        ));
        history.rename_collection(primary, " Arsip ").ok().unwrap();
        let result = history.catalog("", "", primary).ok().unwrap();
        assert_eq!(result.collections[0].name, "Arsip");
        assert_eq!(result.clips.len(), 2);

        history.delete_collection(primary).ok().unwrap();
        let history_rows = history.catalog("", "", 0).ok().unwrap().clips;
        assert_eq!(history_rows.len(), 2);
        assert!(
            history_rows
                .iter()
                .all(|clip| clip.collections == [secondary])
        );
        assert!(
            history
                .catalog("", "", primary)
                .ok()
                .unwrap()
                .clips
                .is_empty()
        );
        assert!(matches!(
            history.rename_collection(primary, "Bekas"),
            Err(Error::CollectionMissing)
        ));
    }

    #[test]
    fn collection_color_is_automatic_until_set_and_can_be_cleared() {
        let mut history = history();
        let id = history.create_collection("Tautan").ok().unwrap();
        let color = |history: &History| {
            history.catalog("", "", 0).ok().unwrap().collections[0]
                .color
                .clone()
        };
        assert_eq!(color(&history), "");
        history.set_collection_color(id, "green").ok().unwrap();
        assert_eq!(color(&history), "green");
        history
            .rename_collection(id, "Tautan penting")
            .ok()
            .unwrap();
        assert_eq!(color(&history), "green");
        history.set_collection_color(id, "").ok().unwrap();
        assert_eq!(color(&history), "");
    }

    #[test]
    fn collection_color_rejects_unknown_names_and_missing_collections() {
        let mut history = history();
        let id = history.create_collection("Tautan").ok().unwrap();
        history.set_collection_color(id, "red").ok().unwrap();
        assert!(matches!(
            history.set_collection_color(id, "chartreuse"),
            Err(Error::CollectionColor)
        ));
        assert!(matches!(
            history.set_collection_color(id, "RED"),
            Err(Error::CollectionColor)
        ));
        assert!(matches!(
            history.set_collection_color(id + 100, "red"),
            Err(Error::CollectionMissing)
        ));
        let collections = history.catalog("", "", 0).ok().unwrap().collections;
        assert_eq!(collections[0].color, "red");
    }

    #[test]
    fn upgrading_history_adds_the_collection_color_column() {
        let mut before = history();
        let id = before.create_collection("Kerja").ok().unwrap();
        before
            .disk
            .execute("ALTER TABLE collections DROP COLUMN color", [])
            .unwrap();
        let mut history = History::new(before.disk).ok().unwrap();
        history.set_collection_color(id, "blue").ok().unwrap();
        let collections = history.catalog("", "", 0).ok().unwrap().collections;
        assert_eq!(collections[0].name, "Kerja");
        assert_eq!(collections[0].color, "blue");
    }

    #[test]
    fn repeated_copy_reuses_data_and_manual_sensitivity_removes_database_record() {
        let mut history = history();
        let id = add(&mut history, "example content");
        assert_eq!(add(&mut history, "example content"), id);
        history.mark_sensitive(id).ok().unwrap();
        assert_eq!(disk_usage(&history.disk).ok().unwrap(), 0);
        assert!(
            history
                .catalog("example", "", 0)
                .ok()
                .unwrap()
                .clips
                .is_empty()
        );
        assert!(history.payload(id).ok().unwrap().1);
        assert_eq!(add(&mut history, "example content"), id);
        assert_eq!(history.catalog("", "", 0).ok().unwrap().clips.len(), 1);
        assert_eq!(disk_usage(&history.disk).ok().unwrap(), 0);
    }

    #[test]
    fn marking_sensitive_removes_payload_from_the_closed_database_file() {
        let directory = std::env::temp_dir().join(format!(
            "openclipboard-private-test-{}-{}",
            std::process::id(),
            SystemTime::now()
                .duration_since(UNIX_EPOCH)
                .unwrap()
                .as_nanos(),
        ));
        let path = directory.join("history.sqlite3");
        let marker = "fixture_manual_redaction_XB82Z1";
        {
            let mut history = History::open(&path).ok().unwrap();
            assert!(
                History::open(&path).is_err(),
                "a second writer acquired the lock"
            );
            let id = add(&mut history, marker);
            assert!(file_contains(&path, marker));
            history.mark_sensitive(id).ok().unwrap();
            assert!(history.payload(id).ok().unwrap().1);
        }
        assert!(!file_contains(&path, marker));
        assert!(!directory.join("history.sqlite3-journal").exists());
        let result = History::open(&path)
            .ok()
            .unwrap()
            .catalog("", "", 0)
            .ok()
            .unwrap();
        assert!(result.clips.is_empty());
        std::fs::remove_dir_all(directory).unwrap();
    }

    fn file_contains(path: &Path, text: &str) -> bool {
        std::fs::read(path)
            .unwrap()
            .windows(text.len())
            .any(|value| value == text.as_bytes())
    }

    #[test]
    fn sensitive_content_stays_out_of_persistent_schema() {
        let mut history = history();
        let text = "-----BEGIN PRIVATE KEY-----\nfixture\n-----END PRIVATE KEY-----";
        let id = add(&mut history, text);
        assert!(id < 0);
        assert_eq!(disk_usage(&history.disk).ok().unwrap(), 0);
        assert_eq!(
            history.catalog("", "", 0).ok().unwrap().clips[0].title,
            "Item sensitif"
        );
    }
}
