use std::collections::HashMap;
use std::fs::{DirBuilder, File, OpenOptions};
use std::os::unix::fs::{DirBuilderExt, OpenOptionsExt};
use std::path::Path;
use std::time::{SystemTime, UNIX_EPOCH};

use rusqlite::{Connection, OptionalExtension, Transaction, params};
use serde::Serialize;
use sha2::{Digest, Sha256};

use crate::clip::{self, DISK_LIMIT, Part, Summary, Thumbnail};

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
}

pub(crate) struct History {
    disk: Connection,
    _owner: Option<File>,
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

    fn new(mut disk: Connection) -> Result<Self> {
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
                 pinned INTEGER NOT NULL DEFAULT 0,
                 character_count INTEGER
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
        let has_character_count: bool = disk.query_row(
            "SELECT EXISTS(SELECT 1 FROM pragma_table_info('clips') WHERE name='character_count')",
            [],
            |row| row.get(0),
        )?;
        if !has_character_count {
            let transaction = disk.transaction()?;
            transaction.execute("ALTER TABLE clips ADD COLUMN character_count INTEGER", [])?;
            let ids = {
                let mut select =
                    transaction.prepare("SELECT id FROM clips WHERE kind <> 'gambar'")?;
                select
                    .query_map([], |row| row.get::<_, i64>(0))?
                    .collect::<rusqlite::Result<Vec<_>>>()?
            };
            let mut select = transaction.prepare("SELECT parts FROM clips WHERE id=?1")?;
            let mut update =
                transaction.prepare("UPDATE clips SET character_count=?2 WHERE id=?1")?;
            for id in ids {
                let raw: Vec<u8> = select.query_row([id], |row| row.get(0))?;
                if let Ok(parts) = bincode::deserialize::<Vec<Part>>(&raw) {
                    update.execute(params![id, clip::character_count(&parts)])?;
                }
            }
            drop((select, update));
            transaction.commit()?;
        }
        Ok(Self {
            disk,
            _owner: None,
            retention_ms: None,
        })
    }

    pub fn capture(
        &mut self,
        parts: Vec<Part>,
        color: String,
        thumbnail: impl FnOnce(&[Part]) -> Thumbnail,
    ) -> Result<()> {
        let raw = bincode::serialize(&parts).map_err(|_| Error::Storage)?;
        let digest = Sha256::digest(&raw).to_vec();
        let copied = now();
        let existing: Option<i64> = self
            .disk
            .query_row("SELECT id FROM clips WHERE digest = ?1", [&digest], |row| {
                row.get(0)
            })
            .optional()?;

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
        let character_count = if kind == "gambar" {
            None
        } else {
            clip::character_count(&parts)
        };
        let transaction = self.disk.transaction()?;
        transaction.execute(
            "INSERT INTO clips (digest,parts,bytes,kind,title,search,color,thumbnail,width,height,copied,character_count)
             VALUES (?1,?2,?3,?4,?5,?6,?7,?8,?9,?10,?11,?12)",
            params![digest, raw, bytes, kind, title, search, color, thumbnail.bytes,
                thumbnail.width, thumbnail.height, copied, character_count],
        )?;
        let added = transaction.last_insert_rowid();
        trim(&transaction, Some(added))?;
        transaction.commit()?;
        Ok(())
    }

    pub fn catalog(&self, query: &str, kind: &str, collection: i64) -> Result<Catalog> {
        let mut select = self.disk.prepare(
            "SELECT id,kind,title,copied,pinned,width,height,color,MAX(copied,COALESCE(pasted,copied)),character_count
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
                last_used: row.get(8)?,
                pinned: row.get(4)?,
                character_count: row.get(9)?,
                width: row.get(5)?,
                height: row.get(6)?,
                color: row.get(7)?,
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
        Ok(Catalog { clips, collections })
    }

    pub fn payload(&self, id: i64) -> Result<Vec<Part>> {
        let raw: Vec<u8> = self
            .disk
            .query_row("SELECT parts FROM clips WHERE id=?1", [id], |row| {
                row.get(0)
            })
            .optional()?
            .ok_or(Error::Missing)?;
        let parts = bincode::deserialize(&raw).map_err(|_| Error::Storage)?;
        Ok(parts)
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
        let transaction = self.disk.transaction()?;
        transaction.execute(
            "UPDATE clips SET pinned=?2 WHERE id=?1",
            params![id, pinned],
        )?;
        trim(&transaction, None)?;
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
        Ok(())
    }

    pub fn membership(&mut self, id: i64, collection: i64, add: bool) -> Result<()> {
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
            trim(&transaction, None)?;
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
        if count == 0 {
            return Ok(0); // Roll back the empty request and keep the previous undo.
        }
        transaction.commit()?;
        Ok(count)
    }

    pub fn discard_delete(&mut self) -> Result<()> {
        self.disk.execute_batch(
            "DROP TABLE IF EXISTS temp.deleted_memberships;
             DROP TABLE IF EXISTS temp.deleted_clips;",
        )?;
        Ok(())
    }

    pub fn undo_delete(&mut self) -> Result<()> {
        let transaction = self.disk.transaction()?;
        transaction.execute_batch(
            "INSERT OR IGNORE INTO clips SELECT * FROM deleted_clips;
             UPDATE clips SET pinned=1 WHERE digest IN (SELECT digest FROM deleted_clips WHERE pinned);
             INSERT OR IGNORE INTO memberships
                 SELECT c.id,m.collection FROM deleted_memberships m
                 JOIN deleted_clips d ON d.id=m.clip
                 JOIN clips c ON c.digest=d.digest
                 JOIN collections g ON g.id=m.collection;",
        )?;
        if disk_usage(&transaction)? > DISK_LIMIT {
            return Err(Error::UndoFull);
        }
        transaction.execute_batch("DROP TABLE deleted_memberships; DROP TABLE deleted_clips;")?;
        transaction.commit()?;
        Ok(())
    }

    pub fn mark_pasted(&mut self, id: i64) -> Result<()> {
        let latest_saved: Option<i64> = self.disk.query_row(
            "SELECT MAX(MAX(copied,COALESCE(pasted,copied))) FROM clips",
            [],
            |row| row.get(0),
        )?;
        let pasted = now().max(latest_saved.unwrap_or(0).saturating_add(1));
        self.disk.execute(
            "UPDATE clips SET pasted=?2 WHERE id=?1",
            params![id, pasted],
        )?;
        Ok(())
    }

    pub fn clear(&mut self, all: bool) -> Result<()> {
        if all {
            self.disk.execute("DELETE FROM clips", [])?;
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

        Ok(removed > 0)
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

fn disk_usage(disk: &Connection) -> Result<usize> {
    Ok(
        disk.query_row("SELECT COALESCE(SUM(bytes),0) FROM clips", [], |row| {
            row.get(0)
        })?,
    )
}

fn trim(transaction: &Transaction<'_>, added: Option<i64>) -> Result<()> {
    let mut usage = disk_usage(transaction)?;
    if usage <= DISK_LIMIT {
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
        usage -= bytes;
        if usage <= DISK_LIMIT {
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
                String::new(),
                |_| Thumbnail::default(),
            )
            .ok()
            .unwrap();
        history.catalog("", "", 0).ok().unwrap().clips[0].id
    }

    #[test]
    fn undo_batch_restores_payload_pin_and_membership() {
        let mut history = history();
        let ordinary = add(&mut history, "Brief desain");
        let second = add(&mut history, "Second clip");
        let collection = history.create_collection("Desain").ok().unwrap();
        history.pin(ordinary, true).ok().unwrap();
        history.membership(ordinary, collection, true).ok().unwrap();
        history.membership(second, collection, true).ok().unwrap();
        let before_ordinary = history.payload(ordinary).ok().unwrap();
        let before_second = history.payload(second).ok().unwrap();

        assert_eq!(history.delete(&[ordinary, second]).ok(), Some(2));
        assert_eq!(history.delete(&[ordinary, second]).ok(), Some(0));
        assert!(history.catalog("", "", 0).ok().unwrap().clips.is_empty());

        history.undo_delete().ok().unwrap();
        let restored = history.catalog("", "", collection).ok().unwrap().clips;
        assert_eq!(restored.len(), 2);
        assert!(
            restored
                .iter()
                .any(|clip| clip.id == ordinary && clip.pinned)
        );
        assert!(restored.iter().any(|clip| clip.id == second));
        assert_eq!(
            history.payload(ordinary).ok().unwrap()[0].data,
            before_ordinary[0].data
        );
        assert_eq!(
            history.payload(second).ok().unwrap()[0].data,
            before_second[0].data
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
        let added = add(&mut history, "keep");
        let collection = history.create_collection("Pribadi").ok().unwrap();
        history.membership(added, collection, true).ok().unwrap();
        let old = add(&mut history, "old");
        history
            .disk
            .execute(
                "UPDATE clips SET bytes = ?1 WHERE id = ?2",
                (DISK_LIMIT - 4, old),
            )
            .unwrap();
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
        let newer = add(&mut before, " A👩‍💻\ne\u{301} ");
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
        before
            .disk
            .execute("ALTER TABLE clips DROP COLUMN character_count", [])
            .unwrap();

        let mut history = History::new(before.disk).ok().unwrap();
        let clips = history.catalog("", "", 0).ok().unwrap().clips;
        assert_eq!(clips[0].character_count, Some(6));
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

        history.mark_pasted(newer).ok().unwrap();
        history.mark_pasted(older).ok().unwrap();
        let clips = history.catalog("", "", 0).ok().unwrap().clips;
        assert_eq!(clips[0].id, older);
        assert_eq!(clips[0].copied, older);
        assert_eq!(clips[0].collections, [collection]);
    }

    #[test]
    fn retention_expires_ordinary_clips_only() {
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

        let boundary = MILLIS_PER_DAY + 1;
        assert_eq!(history.expire_at(boundary).ok(), Some(false));
        history.set_retention_days(1);
        assert_eq!(history.expire_at(boundary).ok(), Some(true));
        assert!(matches!(history.payload(old), Err(Error::Missing)));
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
        let second = add(&mut history, "Second clip");
        assert!(saved > 0 && second > 0);
        for id in [saved, second] {
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
    fn repeated_copy_reuses_data() {
        let mut history = history();
        let id = add(&mut history, "example content");
        assert_eq!(add(&mut history, "example content"), id);
        assert_eq!(history.catalog("", "", 0).ok().unwrap().clips.len(), 1);
    }

    #[test]
    fn history_rejects_second_writer_and_preserves_saved_clip() {
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
            add(&mut history, marker);
        }
        assert!(!directory.join("history.sqlite3-journal").exists());
        let result = History::open(&path)
            .ok()
            .unwrap()
            .catalog("", "", 0)
            .ok()
            .unwrap();
        assert_eq!(result.clips[0].title, marker);
        std::fs::remove_dir_all(directory).unwrap();
    }
}
