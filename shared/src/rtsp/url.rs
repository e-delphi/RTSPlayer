//! `rtsp://usuario:senha@host:porta/caminho`

#[derive(Debug, Clone, PartialEq, Eq)]
pub struct RtspUrl {
    pub scheme: String,
    pub user: String,
    pub password: String,
    pub host: String,
    pub port: u16,
    pub path: String,
}

impl RtspUrl {
    pub fn parse(url: &str) -> Option<Self> {
        let s = url.trim();
        let p = s.find("://")?;
        let scheme = s[..p].to_ascii_lowercase();
        if scheme != "rtsp" && scheme != "rtsps" {
            return None;
        }
        let default_port = if scheme == "rtsps" { 322 } else { 554 };
        let rest = &s[p + 3..];
        let (auth_host, path) = match rest.find('/') {
            Some(i) => (&rest[..i], rest[i..].to_owned()),
            None => (rest, "/".to_owned()),
        };
        let (user, password, host_part) = match auth_host.rfind('@') {
            Some(at) => {
                let ui = &auth_host[..at];
                let (u, pw) = match ui.find(':') {
                    Some(c) => (ui[..c].to_owned(), ui[c + 1..].to_owned()),
                    None => (ui.to_owned(), String::new()),
                };
                (u, pw, &auth_host[at + 1..])
            }
            None => (String::new(), String::new(), auth_host),
        };
        let (host, port) = match host_part.find(':') {
            Some(c) => (host_part[..c].to_owned(), host_part[c + 1..].parse().unwrap_or(default_port)),
            None => (host_part.to_owned(), default_port),
        };
        if host.is_empty() {
            return None;
        }
        Some(Self { scheme, user, password, host, port, path })
    }

    pub fn path_or_root(&self) -> &str {
        if self.path.is_empty() {
            "/"
        } else {
            &self.path
        }
    }

    pub fn host_port(&self) -> String {
        format!("{}:{}", self.host, self.port)
    }

    /// Sem credenciais: é a forma que vai na linha do pedido.
    pub fn to_string_plain(&self) -> String {
        format!("{}://{}:{}{}", self.scheme, self.host, self.port, self.path_or_root())
    }

    pub fn to_string_with_credentials(&self) -> String {
        let cred = if self.user.is_empty() {
            String::new()
        } else if self.password.is_empty() {
            format!("{}@", self.user)
        } else {
            format!("{}:{}@", self.user, self.password)
        };
        format!("{}://{}{}:{}{}", self.scheme, cred, self.host, self.port, self.path_or_root())
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn completa() {
        let u = RtspUrl::parse("rtsp://admin:se:nha@192.168.1.2:555/onvif1?x=1").unwrap();
        assert_eq!(u.user, "admin");
        assert_eq!(u.password, "se:nha");
        assert_eq!(u.host, "192.168.1.2");
        assert_eq!(u.port, 555);
        assert_eq!(u.path, "/onvif1?x=1");
        assert_eq!(u.to_string_plain(), "rtsp://192.168.1.2:555/onvif1?x=1");
    }

    #[test]
    fn minima_e_invalidas() {
        let u = RtspUrl::parse("RTSP://cam").unwrap();
        assert_eq!((u.port, u.path.as_str(), u.scheme.as_str()), (554, "/", "rtsp"));
        assert_eq!(RtspUrl::parse("rtsps://h/").unwrap().port, 322);
        assert!(RtspUrl::parse("http://h/").is_none());
        assert!(RtspUrl::parse("rtsp:///x").is_none());
        // Senha com @: vale o último.
        assert_eq!(RtspUrl::parse("rtsp://u:a@b@h/").unwrap().host, "h");
    }
}
