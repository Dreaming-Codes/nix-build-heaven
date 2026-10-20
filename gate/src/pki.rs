//! SSH material for the builder. The host CA key stays on the client host.
//! Every launch gets a fresh host key and a short-lived host certificate in
//! its user-data, plus the client's public key, so the AMI holds no secret.

use std::fs;
use std::io;
use std::os::unix::fs::{DirBuilderExt, OpenOptionsExt};
use std::path::{Path, PathBuf};
use std::time::{Duration, SystemTime};

use serde::Serialize;
use ssh_key::certificate::{Builder, CertType};
use ssh_key::rand_core::OsRng;
use ssh_key::{Algorithm, LineEnding, PrivateKey, PublicKey};

/// The host name the client dials. It resolves to the gate.
pub const BUILDER_NAME: &str = "nbh-builder";

pub const HOST_CERT_TTL: Duration = Duration::from_secs(3 * 3600);

/// What the builder's nbh-keys unit reads from EC2 user-data.
#[derive(Serialize)]
struct UserData {
    nbh: u32,
    ssh_host_key: String,
    ssh_host_cert: String,
    ssh_authorized_keys: String,
}

type Result<T> = std::result::Result<T, Box<dyn std::error::Error + Send + Sync>>;

pub struct Dir(pub PathBuf);

impl Dir {
    fn path(&self, name: &str) -> PathBuf {
        self.0.join(name)
    }

    /// Creates ssh_host_ca, ssh_client and ssh_known_hosts unless they exist.
    pub fn init(&self, comment: &str) -> Result<()> {
        if self.path("ssh_host_ca").exists() {
            return Ok(());
        }
        fs::DirBuilder::new().recursive(true).mode(0o700).create(&self.0)?;
        let mut files = Vec::new();
        for name in ["ssh_host_ca", "ssh_client"] {
            let mut key = PrivateKey::random(&mut OsRng, Algorithm::Ed25519)?;
            key.set_comment(comment);
            files.push((name.to_string(), key.to_openssh(LineEnding::LF)?.to_string()));
            files.push((format!("{name}.pub"), key.public_key().to_openssh()? + "\n"));
        }
        let ca_pub = &files[1].1;
        // The client trusts any host key the CA certified for BUILDER_NAME.
        files.push(("ssh_known_hosts".into(), format!("@cert-authority {BUILDER_NAME} {ca_pub}")));
        for (name, data) in files {
            write_private(&self.path(&name), data.as_bytes())?;
        }
        Ok(())
    }

    pub fn authority(&self) -> Result<Authority> {
        let ca = PrivateKey::read_openssh_file(&self.path("ssh_host_ca"))?;
        let client = PublicKey::read_openssh_file(&self.path("ssh_client.pub"))?;
        Ok(Authority { ca, client_pub: client.to_openssh()? + "\n" })
    }
}

fn write_private(path: &Path, data: &[u8]) -> io::Result<()> {
    use io::Write;
    fs::OpenOptions::new().write(true).create_new(true).mode(0o600).open(path)?.write_all(data)
}

pub struct Authority {
    ca: PrivateKey,
    client_pub: String,
}

pub struct HostIdentity {
    pub key: PrivateKey,
    pub cert: ssh_key::Certificate,
}

impl Authority {
    /// A fresh host key and a host certificate for BUILDER_NAME, valid from
    /// five minutes before `now` (clock skew) for `ttl`.
    pub fn host(&self, now: SystemTime, ttl: Duration) -> Result<HostIdentity> {
        let key = PrivateKey::random(&mut OsRng, Algorithm::Ed25519)?;
        let unix = now.duration_since(SystemTime::UNIX_EPOCH)?;
        let mut b = Builder::new_with_random_nonce(
            &mut OsRng,
            key.public_key().key_data().clone(),
            unix.as_secs().saturating_sub(300),
            (unix + ttl).as_secs(),
        )?;
        b.serial(unix.as_nanos() as u64)?
            .key_id(format!("{BUILDER_NAME} {}", humantime::format_rfc3339_seconds(now)))?
            .cert_type(CertType::Host)?
            .valid_principal(BUILDER_NAME)?;
        let cert = b.sign(&self.ca)?;
        Ok(HostIdentity { key, cert })
    }

    pub fn user_data(&self, now: SystemTime) -> Result<Vec<u8>> {
        let host = self.host(now, HOST_CERT_TTL)?;
        let ud = UserData {
            nbh: 1,
            ssh_host_key: host.key.to_openssh(LineEnding::LF)?.to_string(),
            ssh_host_cert: host.cert.to_openssh()? + "\n",
            ssh_authorized_keys: self.client_pub.clone(),
        };
        Ok(serde_json::to_vec(&ud)?)
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::testutil::TempDir;
    use ssh_key::HashAlg;

    fn now() -> u64 {
        SystemTime::now().duration_since(SystemTime::UNIX_EPOCH).unwrap().as_secs()
    }

    fn pki() -> (TempDir, Authority) {
        let dir = TempDir::new();
        let d = Dir(dir.path().join("pki"));
        d.init("desk").unwrap();
        let a = d.authority().unwrap();
        (dir, a)
    }

    #[test]
    fn host_cert_is_trusted_only_through_our_ca_and_only_while_valid() {
        let (_dir, a) = pki();
        let ours = a.ca.public_key().fingerprint(HashAlg::Sha256);
        let host = a.host(SystemTime::now(), HOST_CERT_TTL).unwrap();
        host.cert.validate_at(now(), &[ours]).expect("our CA");
        assert_eq!(host.cert.cert_type(), CertType::Host);
        assert_eq!(host.cert.valid_principals(), [BUILDER_NAME.to_string()]);
        assert_eq!(host.cert.public_key(), host.key.public_key().key_data());

        let foreign = PrivateKey::random(&mut OsRng, Algorithm::Ed25519).unwrap();
        let foreign = foreign.public_key().fingerprint(HashAlg::Sha256);
        assert!(host.cert.validate_at(now(), &[foreign]).is_err(), "foreign CA");

        let old = a.host(SystemTime::now() - Duration::from_secs(4 * 3600), HOST_CERT_TTL).unwrap();
        assert!(old.cert.validate_at(now(), &[ours]).is_err(), "expired");
    }

    #[test]
    fn init_writes_known_hosts_for_the_ca_and_keeps_existing_keys() {
        let dir = TempDir::new();
        let d = Dir(dir.path().join("pki"));
        d.init("desk").unwrap();
        let kh = fs::read_to_string(d.path("ssh_known_hosts")).unwrap();
        let ca_pub = fs::read_to_string(d.path("ssh_host_ca.pub")).unwrap();
        assert_eq!(kh, format!("@cert-authority nbh-builder {ca_pub}"));
        let ca = fs::read(d.path("ssh_host_ca")).unwrap();
        d.init("desk").unwrap();
        assert_eq!(fs::read(d.path("ssh_host_ca")).unwrap(), ca);
    }

    #[test]
    fn user_data_carries_host_key_cert_and_client_key() {
        let (dir, a) = pki();
        let ud: serde_json::Value = serde_json::from_slice(&a.user_data(SystemTime::now()).unwrap()).unwrap();
        assert_eq!(ud["nbh"], 1);
        let key = PrivateKey::from_openssh(ud["ssh_host_key"].as_str().unwrap()).unwrap();
        let cert = ssh_key::Certificate::from_openssh(ud["ssh_host_cert"].as_str().unwrap().trim()).unwrap();
        assert_eq!(cert.public_key(), key.public_key().key_data());
        let client = fs::read_to_string(dir.path().join("pki/ssh_client.pub")).unwrap();
        assert_eq!(ud["ssh_authorized_keys"], client.as_str());
    }
}
