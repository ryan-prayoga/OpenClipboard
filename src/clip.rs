use serde::{Deserialize, Serialize};

pub(crate) const TEXT_LIMIT: usize = 1024 * 1024;
pub(crate) const IMAGE_LIMIT: usize = 25 * 1024 * 1024;
pub(crate) const DISK_LIMIT: usize = 256 * 1024 * 1024;

#[derive(Debug, Clone, Serialize, Deserialize, PartialEq, Eq)]
pub(crate) struct Part {
    pub item: usize,
    pub mime: String,
    #[serde(with = "payload_bytes")]
    pub data: Vec<u8>,
}

// Bincode encodes bytes and Vec<u8> identically: a length followed by raw bytes.
mod payload_bytes {
    use serde::{Deserializer, Serializer};

    pub fn serialize<S: Serializer>(bytes: &[u8], serializer: S) -> Result<S::Ok, S::Error> {
        serializer.serialize_bytes(bytes)
    }

    pub fn deserialize<'de, D: Deserializer<'de>>(deserializer: D) -> Result<Vec<u8>, D::Error> {
        deserializer.deserialize_byte_buf(ByteBuffer)
    }

    struct ByteBuffer;

    impl<'de> serde::de::Visitor<'de> for ByteBuffer {
        type Value = Vec<u8>;

        fn expecting(&self, formatter: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
            formatter.write_str("clipboard payload bytes")
        }

        fn visit_bytes<E: serde::de::Error>(self, bytes: &[u8]) -> Result<Self::Value, E> {
            Ok(bytes.to_vec())
        }

        fn visit_byte_buf<E: serde::de::Error>(self, bytes: Vec<u8>) -> Result<Self::Value, E> {
            Ok(bytes)
        }
    }
}

#[derive(Debug, Clone, Serialize)]
pub(crate) struct Summary {
    pub id: i64,
    pub kind: String,
    pub title: String,
    pub copied: i64,
    pub last_used: i64,
    pub pinned: bool,
    pub character_count: Option<usize>,
    pub width: usize,
    pub height: usize,
    pub color: String,
    pub collections: Vec<i64>,
}

#[derive(Default)]
pub(crate) struct Thumbnail {
    pub bytes: Vec<u8>,
    pub width: usize,
    pub height: usize,
}

impl Part {
    pub fn image(&self) -> bool {
        matches!(self.mime.as_str(), "public.png" | "public.tiff")
    }

    pub fn text(&self) -> Option<String> {
        match self.mime.as_str() {
            "public.utf8-plain-text" | "public.url" => String::from_utf8(self.data.clone()).ok(),
            "public.utf16-external-plain-text" | "public.utf16-plain-text" => {
                let (bytes, big_endian) = match self.data.as_slice() {
                    [0xfe, 0xff, rest @ ..] => (rest, true),
                    [0xff, 0xfe, rest @ ..] => (rest, false),
                    bytes => (bytes, false),
                };
                if bytes.len() % 2 != 0 {
                    return None;
                }
                let units: Vec<_> = bytes
                    .chunks_exact(2)
                    .map(|pair| {
                        let pair = [pair[0], pair[1]];
                        if big_endian {
                            u16::from_be_bytes(pair)
                        } else {
                            u16::from_le_bytes(pair)
                        }
                    })
                    .collect();
                String::from_utf16(&units).ok()
            }
            _ => None,
        }
    }
}

unsafe extern "C" {
    fn oc_character_count(data: *const u8, length: usize) -> usize;
}

pub(crate) fn character_count(parts: &[Part]) -> Option<usize> {
    let text = parts.iter().find_map(Part::text)?;
    Some(unsafe { oc_character_count(text.as_ptr(), text.len()) })
}

pub(crate) fn metadata(parts: &[Part], native_color: String) -> (String, String, String, String) {
    let text = parts
        .iter()
        .filter_map(Part::text)
        .collect::<Vec<_>>()
        .join("\n");
    let first_text = parts.iter().find_map(Part::text).unwrap_or_default();
    let url = parts
        .iter()
        .find(|part| part.mime == "public.url")
        .and_then(Part::text);
    let value = first_text.trim();
    let color = if native_color.is_empty() {
        parse_color(value).unwrap_or_default()
    } else {
        native_color
    };
    let (kind, title) = if parts.iter().any(Part::image) {
        ("gambar", "Gambar".to_owned())
    } else if let Some(url) = url.or_else(|| is_url(value).then(|| value.to_owned())) {
        ("url", url)
    } else if !color.is_empty() {
        (
            "warna",
            if value.is_empty() {
                color.clone()
            } else {
                value.to_owned()
            },
        )
    } else if matches!(value.as_bytes().first(), Some(b'{' | b'['))
        && serde_json::from_str::<serde_json::Value>(value).is_ok()
    {
        ("json", value.to_owned())
    } else if looks_like_code(value) {
        ("kode", value.to_owned())
    } else {
        ("teks", first_text)
    };
    let title = title.split_whitespace().collect::<Vec<_>>().join(" ");
    let title: String = title.chars().take(220).collect();
    let combined = format!("{text}\n{color}").to_lowercase();
    (kind.to_owned(), title, combined, color)
}

fn is_url(value: &str) -> bool {
    ["https://", "http://"].into_iter().any(|prefix| {
        value.strip_prefix(prefix).is_some_and(|rest| {
            !rest.is_empty() && !rest.starts_with('/') && !rest.contains(char::is_whitespace)
        })
    })
}

fn looks_like_code(s: &str) -> bool {
    let keywords = [
        "fn ",
        "def ",
        "function ",
        "class ",
        "import ",
        "const ",
        "let ",
        "#include ",
    ];
    s.lines().take(15).any(|line| {
        let line = line.trim();
        keywords.iter().any(|word| line.starts_with(word))
            && line.contains(['(', '=', '{', ';', '<', ':'])
    })
}

fn parse_color(s: &str) -> Option<String> {
    if let Some(hex) = s.strip_prefix('#')
        && [3, 4, 6, 8].contains(&hex.len())
        && hex.bytes().all(|b| b.is_ascii_hexdigit())
    {
        return Some(s.to_owned());
    }
    let value = s.strip_suffix(')')?;
    if let Some(rgb) = value.strip_prefix("rgb(") {
        let components: Vec<u8> = rgb
            .split(',')
            .map(|component| component.trim().parse())
            .collect::<Result<_, _>>()
            .ok()?;
        let [r, g, b] = components.as_slice() else {
            return None;
        };
        return Some(format!("#{r:02X}{g:02X}{b:02X}"));
    }
    let hsl = value.strip_prefix("hsl(")?;
    let components: Vec<_> = hsl.split(',').map(str::trim).collect();
    let [hue, saturation, lightness] = components.as_slice() else {
        return None;
    };
    let hue = hue.parse::<f64>().ok()?;
    let saturation = saturation.strip_suffix('%')?.parse::<f64>().ok()? / 100.0;
    let lightness = lightness.strip_suffix('%')?.parse::<f64>().ok()? / 100.0;
    if !hue.is_finite() || !(0.0..=1.0).contains(&saturation) || !(0.0..=1.0).contains(&lightness) {
        return None;
    }
    let hue = hue.rem_euclid(360.0) / 60.0;
    let chroma = (1.0 - (2.0 * lightness - 1.0).abs()) * saturation;
    let second = chroma * (1.0 - (hue % 2.0 - 1.0).abs());
    let (r, g, b) = match hue as u8 {
        0 => (chroma, second, 0.0),
        1 => (second, chroma, 0.0),
        2 => (0.0, chroma, second),
        3 => (0.0, second, chroma),
        4 => (second, 0.0, chroma),
        _ => (chroma, 0.0, second),
    };
    let shift = lightness - chroma / 2.0;
    let byte = |component: f64| ((component + shift) * 255.0_f64).round() as u8;
    Some(format!("#{:02X}{:02X}{:02X}", byte(r), byte(g), byte(b)))
}

#[cfg(test)]
mod tests {
    #[test]
    fn clipboard_payload_encoding_matches_existing_history() {
        #[derive(serde::Serialize, serde::Deserialize)]
        struct LegacyPart {
            item: usize,
            mime: String,
            data: Vec<u8>,
        }

        let parts = vec![
            super::Part {
                item: 0,
                mime: "public.png".into(),
                data: (0..=255).collect(),
            },
            super::Part {
                item: 1,
                mime: "public.utf8-plain-text".into(),
                data: vec![],
            },
        ];
        let legacy: Vec<_> = parts
            .iter()
            .map(|part| LegacyPart {
                item: part.item,
                mime: part.mime.clone(),
                data: part.data.clone(),
            })
            .collect();
        let previous = bincode::serialize(&legacy).unwrap();
        assert_eq!(bincode::serialize(&parts).unwrap(), previous);
        assert_eq!(
            bincode::deserialize::<Vec<super::Part>>(&previous).unwrap(),
            parts
        );
    }

    use super::*;

    fn text(value: &str) -> Part {
        Part {
            item: 0,
            mime: "public.utf8-plain-text".into(),
            data: value.as_bytes().to_vec(),
        }
    }

    #[test]
    fn classifies_formats_without_normalizing_payload() {
        let json = text("  {\n \"n\": 7\n}\n");
        assert_eq!(metadata(&[json.clone()], String::new()).0, "json");
        assert_eq!(json.text().unwrap(), "  {\n \"n\": 7\n}\n");
        assert_eq!(
            metadata(&[text("https://example.org/path")], String::new()).0,
            "url"
        );
        assert_eq!(
            metadata(&[text("hsl(0,100%,50%)")], String::new()).3,
            "#FF0000"
        );
    }
}
