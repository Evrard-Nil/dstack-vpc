use anyhow::{anyhow, Context, Result};
use x509_parser::der_parser::Oid;
use x509_parser::prelude::X509Certificate;

const PHALA_RATLS_APP_ID: &[u64] = &[1, 3, 6, 1, 4, 1, 62397, 1, 3];

pub fn dstack_agent_address() -> String {
    if let Ok(address) = std::env::var("DSTACK_AGENT_ADDRESS") {
        return address;
    }

    const SOCKET_PATHS: &[&str] = &["/var/run/dstack/dstack.sock", "/var/run/dstack.sock"];
    for path in SOCKET_PATHS {
        if std::path::Path::new(path).exists() {
            return format!("unix:{path}");
        }
    }

    format!("unix:{}", SOCKET_PATHS[0])
}

pub fn get_app_id(cert: &X509Certificate<'_>) -> Result<Option<Vec<u8>>> {
    let oid = Oid::from(PHALA_RATLS_APP_ID).map_err(|_| anyhow!("invalid app id oid"))?;
    let Some(extension) = cert
        .get_extension_unique(&oid)
        .context("failed to decode app id extension")?
    else {
        return Ok(None);
    };

    let app_id = yasna::parse_der(extension.value, |reader| reader.read_bytes())
        .map_err(|err| anyhow!("failed to parse app id extension: {err:?}"))?;
    Ok(Some(app_id))
}
