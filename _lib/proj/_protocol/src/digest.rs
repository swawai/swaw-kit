use sha2::{Digest, Sha256};

pub const REVISION_PREFIX: &str = "sha256-";

pub fn sha256_hex(bytes: impl AsRef<[u8]>) -> String {
    format!("{:x}", Sha256::digest(bytes.as_ref()))
}

pub fn revision(bytes: impl AsRef<[u8]>) -> String {
    format!("{REVISION_PREFIX}{}", sha256_hex(bytes))
}

pub fn is_sha256(value: &str) -> bool {
    value.len() == 64
        && value
            .bytes()
            .all(|byte| byte.is_ascii_digit() || (b'a'..=b'f').contains(&byte))
}

pub fn is_revision(value: &str) -> bool {
    value.strip_prefix(REVISION_PREFIX).is_some_and(is_sha256)
}

/// Length-frames named inputs so paths and contents cannot produce ambiguous
/// concatenations. Callers must add fields in their canonical order.
pub struct RevisionBuilder {
    digest: Sha256,
}

impl RevisionBuilder {
    pub fn new(domain: &str) -> Self {
        let mut builder = Self {
            digest: Sha256::new(),
        };
        builder.push("domain", domain.as_bytes());
        builder
    }

    pub fn push(&mut self, name: &str, value: &[u8]) {
        push_length(&mut self.digest, name.len());
        self.digest.update(name.as_bytes());
        push_length(&mut self.digest, value.len());
        self.digest.update(value);
    }

    pub fn finish(self) -> String {
        format!("{REVISION_PREFIX}{:x}", self.digest.finalize())
    }
}

fn push_length(digest: &mut Sha256, length: usize) {
    digest.update((length as u64).to_le_bytes());
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn revisions_are_strict_lowercase_sha256_values() {
        let value = revision(b"fixture");
        assert!(is_revision(&value));
        assert!(!is_revision(&value.to_ascii_uppercase()));
        assert!(!is_revision(value.trim_start_matches(REVISION_PREFIX)));
    }

    #[test]
    fn framed_inputs_do_not_alias_concatenations() {
        let mut left = RevisionBuilder::new("fixture");
        left.push("a", b"bc");
        let mut right = RevisionBuilder::new("fixture");
        right.push("ab", b"c");
        assert_ne!(left.finish(), right.finish());
    }
}
