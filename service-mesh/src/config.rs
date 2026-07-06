use figment::{
    providers::{Data, Format, Json, Toml},
    Figment,
};
use serde::{Deserialize, Serialize};
use std::net::IpAddr;
use tracing::info;

#[derive(Debug, Clone, Deserialize, Serialize)]
pub struct Config {
    pub auth: AuthConfig,
    pub client: ClientConfig,
    pub dstack: DstackConfig,
    pub tls: TlsConfig,
}

#[derive(Debug, Clone, Deserialize, Serialize)]
pub struct AuthConfig {
    pub enabled: bool,
    pub address: IpAddr,
    pub port: u16,
}

#[derive(Debug, Clone, Deserialize, Serialize)]
pub struct ClientConfig {
    pub enabled: bool,
    pub address: IpAddr,
    pub port: u16,
}

#[derive(Debug, Clone, Deserialize, Serialize)]
pub struct DstackConfig {
    pub gateway_domain: String,
}

#[derive(Debug, Clone, Deserialize, Serialize)]
pub struct TlsConfig {
    pub cert_file: String,
    pub key_file: String,
    pub ca_file: String,
}

/// Target information extracted from headers
#[derive(Debug, Clone)]
pub struct TargetInfo {
    pub app_id: String,
    pub instance_id: String,
    pub port: u16,
}

pub const DEFAULT_CONFIG: &str = include_str!("../dstack-mesh.toml");

trait MaybeNested {
    fn maybe_nested(self, nested: bool) -> Self;
}

impl<T: Format> MaybeNested for Data<T> {
    fn maybe_nested(self, nested: bool) -> Self {
        if nested {
            self.nested()
        } else {
            self
        }
    }
}

fn load_config_file(path: &str, nested: bool, figment: Figment) -> Figment {
    if path.ends_with(".toml") {
        return figment.merge(Toml::file(path).maybe_nested(nested));
    }
    figment.merge(Json::file(path).maybe_nested(nested))
}

fn load_config_in_dir(name: &str, path: &str, nested: bool, mut figment: Figment) -> Figment {
    for ext in ["toml", "json"] {
        let filename = format!("{path}/{name}.{ext}");
        if std::path::Path::new(&filename).exists() {
            info!("Loading config file: {filename}");
            figment = load_config_file(&filename, nested, figment);
        }
    }
    figment
}

pub fn load_config_figment(config_file: Option<&str>) -> Figment {
    let figment = Figment::from(rocket::Config::default()).merge(Toml::string(DEFAULT_CONFIG));
    let figment = load_config_in_dir("mesh-proxy", "/etc/mesh-proxy", false, figment);
    let figment = load_config_in_dir("mesh-proxy", ".", false, figment);
    match config_file {
        Some(path) => load_config_file(path, false, figment),
        None => figment,
    }
}
