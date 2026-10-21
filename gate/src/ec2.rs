//! Five EC2 Query API calls and STS GetCallerIdentity, signed here (SigV4) because the AWS SDK's EC2
//! crate alone needs more than 3.4 GB of memory to build.

use std::collections::HashMap;
use std::future::Future;
use std::net::{IpAddr, SocketAddr};
use std::path::Path;
use std::time::{Duration, SystemTime};

use base64ct::{Base64, Encoding};
use hmac::{Hmac, Mac};
use roxmltree::{Document, Node};
use sha2::{Digest, Sha256};

use crate::cloud::{Cloud, Error};
use crate::fleet::{CloudState, InstanceId, Key, Seen};
use crate::pki::Authority;

const TAG_MANAGED: &str = "nbh:managed";
const TAG_OWNER: &str = "nbh:owner";
const TAG_KEY: &str = "nbh:key";
const API_VERSION: &str = "2016-11-15";
const STS_VERSION: &str = "2011-06-15";

#[derive(Clone)]
pub struct Credentials {
    access_key: String,
    secret_key: String,
    session_token: Option<String>,
}

impl Credentials {
    /// Only this file and profile. The environment and ~/.aws are never read,
    /// so an ambient key of another account cannot reach the gate.
    pub fn from_file(file: &Path, profile: &str) -> Result<Self, Error> {
        let shown = file.display();
        let text = std::fs::read_to_string(file).map_err(|e| format!("{shown}: {e}"))?;
        let section = parse_ini_section(&text, profile);
        let get = |k: &str| section.get(k).cloned();
        match (get("aws_access_key_id"), get("aws_secret_access_key")) {
            (Some(access_key), Some(secret_key)) => {
                Ok(Credentials { access_key, secret_key, session_token: get("aws_session_token") })
            }
            _ => Err(format!("{shown}: profile [{profile}] has no access key").into()),
        }
    }
}

fn parse_ini_section(text: &str, name: &str) -> HashMap<String, String> {
    let mut current = None;
    let mut out = HashMap::new();
    for line in text.lines().map(str::trim) {
        if let Some(header) = line.strip_prefix('[').and_then(|l| l.strip_suffix(']')) {
            current = Some(header.trim() == name);
        } else if current == Some(true)
            && let Some((k, v)) = line.split_once('=')
        {
            out.insert(k.trim().to_string(), v.trim().to_string());
        }
    }
    out
}

#[derive(Debug)]
struct ApiError(Option<String>, String);

impl From<ApiError> for Error {
    fn from(e: ApiError) -> Error {
        e.1.into()
    }
}

#[derive(Clone)]
pub struct Api {
    region: String,
    creds: Credentials,
    agent: ureq::Agent,
}

impl Api {
    pub fn new(region: String, creds: Credentials) -> Self {
        let agent = ureq::Agent::config_builder()
            .timeout_global(Some(Duration::from_secs(20)))
            .http_status_as_error(false)
            .build()
            .into();
        Api { region, creds, agent }
    }

    async fn call(&self, action: &str, params: Vec<(String, String)>) -> Result<String, ApiError> {
        self.post("ec2", API_VERSION, action, params).await
    }

    async fn post(
        &self,
        service: &'static str,
        version: &str,
        action: &str,
        mut params: Vec<(String, String)>,
    ) -> Result<String, ApiError> {
        params.insert(0, ("Action".into(), action.into()));
        params.insert(1, ("Version".into(), version.into()));
        let body = form(&params);
        let host = format!("{service}.{}.amazonaws.com", self.region);
        let headers = sign(&self.creds, &self.region, service, &host, &body, SystemTime::now());
        let api = self.clone();
        let response = tokio::task::spawn_blocking(move || {
            let mut req = api.agent.post(format!("https://{host}/"));
            for (k, v) in headers {
                req = req.header(k, v);
            }
            let mut resp = req.send(body.as_str())?;
            let status = resp.status();
            Ok::<_, ureq::Error>((status, resp.body_mut().read_to_string()?))
        })
        .await
        .map_err(|e| ApiError(None, e.to_string()))?;
        let (status, text) = response.map_err(|e| ApiError(None, format!("{action}: {e}")))?;
        if status.is_success() {
            return Ok(text);
        }
        let doc = Document::parse(&text).ok();
        let field = |name| {
            doc.as_ref().and_then(|d| d.descendants().find(|n| n.has_tag_name(name))?.text().map(str::to_string))
        };
        let message = field("Message").unwrap_or_else(|| text.chars().take(200).collect());
        let code = field("Code");
        let shown = code.as_deref().unwrap_or("no code");
        Err(ApiError(code.clone(), format!("{action}: {status} {shown}: {message}")))
    }

    /// GetCallerIdentity needs no IAM permission, so the gate's policy stays
    /// EC2 only.
    pub async fn caller_account(&self) -> Result<AccountId, Error> {
        let xml = self.post("sts", STS_VERSION, "GetCallerIdentity", Vec::new()).await?;
        caller_account(&xml)
    }
}

fn caller_account(xml: &str) -> Result<AccountId, Error> {
    let doc = parse(xml)?;
    let account = doc.descendants().find(|n| n.has_tag_name("Account")).and_then(|n| n.text());
    Ok(account.ok_or("GetCallerIdentity returned no Account")?.trim().parse()?)
}

#[derive(Clone, Debug, PartialEq)]
pub struct AccountId(String);

impl std::str::FromStr for AccountId {
    type Err = String;

    fn from_str(s: &str) -> Result<Self, String> {
        match s.len() == 12 && s.bytes().all(|b| b.is_ascii_digit()) {
            true => Ok(AccountId(s.to_string())),
            false => Err(format!("{s:?} is not a 12 digit AWS account id")),
        }
    }
}

impl std::fmt::Display for AccountId {
    fn fmt(&self, f: &mut std::fmt::Formatter) -> std::fmt::Result {
        f.write_str(&self.0)
    }
}

#[derive(Debug, PartialEq)]
pub struct WrongAccount {
    pub expected: AccountId,
    pub actual: AccountId,
}

impl std::fmt::Display for WrongAccount {
    fn fmt(&self, f: &mut std::fmt::Formatter) -> std::fmt::Result {
        let WrongAccount { expected, actual } = self;
        write!(f, "AWS credentials belong to account {actual}, not --aws-account {expected}; refusing to start")
    }
}

impl std::error::Error for WrongAccount {}

pub async fn guard_account<F>(expected: &AccountId, whoami: F) -> Result<AccountId, Error>
where
    F: Future<Output = Result<AccountId, Error>>,
{
    let actual = whoami.await?;
    if actual != *expected {
        return Err(Box::new(WrongAccount { expected: expected.clone(), actual }));
    }
    Ok(actual)
}

/// RFC 3986 encoding, as SigV4 requires for form bodies.
fn encode(s: &str) -> String {
    s.bytes()
        .map(|b| match b {
            b'A'..=b'Z' | b'a'..=b'z' | b'0'..=b'9' | b'-' | b'_' | b'.' | b'~' => (b as char).to_string(),
            _ => format!("%{b:02X}"),
        })
        .collect()
}

fn form(params: &[(String, String)]) -> String {
    params.iter().map(|(k, v)| format!("{}={}", encode(k), encode(v))).collect::<Vec<_>>().join("&")
}

fn hex(bytes: &[u8]) -> String {
    bytes.iter().map(|b| format!("{b:02x}")).collect()
}

fn hmac(key: &[u8], data: &str) -> Vec<u8> {
    let mut mac = Hmac::<Sha256>::new_from_slice(key).expect("HMAC takes any key length");
    mac.update(data.as_bytes());
    mac.finalize().into_bytes().to_vec()
}

fn sign(
    creds: &Credentials,
    region: &str,
    service: &str,
    host: &str,
    body: &str,
    now: SystemTime,
) -> Vec<(String, String)> {
    let amz_date: String =
        humantime::format_rfc3339_seconds(now).to_string().chars().filter(|c| *c != '-' && *c != ':').collect();
    let date = &amz_date[..8];
    let mut headers = vec![
        ("content-type".to_string(), "application/x-www-form-urlencoded; charset=utf-8".to_string()),
        ("host".into(), host.into()),
        ("x-amz-date".into(), amz_date.clone()),
    ];
    if let Some(token) = &creds.session_token {
        headers.push(("x-amz-security-token".into(), token.clone()));
    }
    let signed: Vec<&str> = headers.iter().map(|(k, _)| k.as_str()).collect();
    let signed = signed.join(";");
    let canonical_headers: String = headers.iter().map(|(k, v)| format!("{k}:{v}\n")).collect();
    let canonical = format!("POST\n/\n\n{canonical_headers}\n{signed}\n{}", hex(&Sha256::digest(body)));
    let scope = format!("{date}/{region}/{service}/aws4_request");
    let to_sign = format!("AWS4-HMAC-SHA256\n{amz_date}\n{scope}\n{}", hex(&Sha256::digest(&canonical)));
    let mut key = hmac(format!("AWS4{}", creds.secret_key).as_bytes(), date);
    for part in [region, service, "aws4_request"] {
        key = hmac(&key, part);
    }
    let signature = hex(&hmac(&key, &to_sign));
    let auth = format!(
        "AWS4-HMAC-SHA256 Credential={}/{scope}, SignedHeaders={signed}, Signature={signature}",
        creds.access_key
    );
    headers.retain(|(k, _)| k != "host");
    headers.push(("authorization".into(), auth));
    headers
}

fn child<'a>(n: Node<'a, 'a>, name: &str) -> Option<Node<'a, 'a>> {
    n.children().find(|c| c.has_tag_name(name))
}

fn text<'a>(n: Node<'a, 'a>, name: &str) -> Option<&'a str> {
    child(n, name)?.text()
}

fn items<'a>(n: Node<'a, 'a>, name: &str) -> impl Iterator<Item = Node<'a, 'a>> {
    child(n, name).into_iter().flat_map(|s| s.children().filter(|c| c.has_tag_name("item")))
}

fn parse(xml: &str) -> Result<Document<'_>, Error> {
    Ok(Document::parse(xml)?)
}

fn filters(params: &mut Vec<(String, String)>, filters: &[(&str, &str)]) {
    for (i, (name, value)) in filters.iter().enumerate() {
        params.push((format!("Filter.{}.Name", i + 1), name.to_string()));
        params.push((format!("Filter.{}.Value.1", i + 1), value.to_string()));
    }
}

pub struct Ec2 {
    pub api: Api,
    pub launch_template: String,
    pub instance_types: Vec<String>,
    pub owner: String,
    pub port: u16,
    pub max_price: Option<String>,
    pub authority: Authority,
}

#[derive(Clone, Debug, PartialEq)]
struct Placement {
    itype: String,
    subnet: String,
    az: String,
    price: Option<f64>,
}

/// A type with no Spot price in an AZ is not offered as Spot there.
fn plan(
    types: &[String],
    subnets: &[(String, String)],
    prices: Option<&HashMap<(String, String), f64>>,
) -> Vec<Placement> {
    let mut out = Vec::new();
    for t in types {
        let mut row: Vec<Placement> = subnets
            .iter()
            .filter_map(|(subnet, az)| {
                let price = prices.map(|p| p.get(&(t.clone(), az.clone())).copied());
                if price == Some(None) {
                    return None;
                }
                Some(Placement { itype: t.clone(), subnet: subnet.clone(), az: az.clone(), price: price.flatten() })
            })
            .collect();
        row.sort_by(|a, b| a.price.partial_cmp(&b.price).unwrap_or(std::cmp::Ordering::Equal));
        out.extend(row);
    }
    out
}

fn retry_elsewhere(code: Option<&str>) -> bool {
    matches!(
        code,
        Some(
            "InsufficientInstanceCapacity"
                | "SpotMaxPriceTooLow"
                | "InsufficientCapacity"
                | "Unsupported"
                | "InstanceLimitExceeded"
                | "MaxSpotInstanceCountExceeded"
                | "VcpuLimitExceeded"
                | "InvalidParameterCombination"
        )
    )
}

async fn launch_first<'a, F, Fut>(plan: &'a [Placement], mut run: F) -> Result<InstanceId, Error>
where
    F: FnMut(&'a Placement) -> Fut,
    Fut: Future<Output = Result<InstanceId, ApiError>>,
{
    let mut last = String::from("no placement");
    for p in plan {
        match run(p).await {
            Ok(id) => return Ok(id),
            Err(ApiError(code, msg)) if retry_elsewhere(code.as_deref()) => {
                log!("no {} in {}: {msg}", p.itype, p.az);
                last = msg;
            }
            Err(e) => return Err(e.into()),
        }
    }
    Err(format!("every type and AZ failed, last: {last}").into())
}

fn seen(i: Node, port: u16) -> Option<Seen> {
    let id = InstanceId(text(i, "instanceId")?.to_string());
    let key = items(i, "tagSet").find(|t| text(*t, "key") == Some(TAG_KEY)).and_then(|t| text(t, "value"));
    let state = match text(child(i, "instanceState")?, "name")? {
        "pending" => CloudState::Pending,
        "running" => CloudState::Running,
        "shutting-down" => CloudState::ShuttingDown,
        "stopping" => CloudState::Stopping,
        "stopped" => CloudState::Stopped,
        "terminated" => CloudState::Terminated,
        _ => return None,
    };
    let ip = text(i, "ipAddress").and_then(|ip| ip.parse::<IpAddr>().ok());
    let launched_at = text(i, "launchTime").and_then(|t| humantime::parse_rfc3339_weak(t.trim_end_matches('Z')).ok());
    Some(Seen {
        key: Key(key.unwrap_or(&id.0).to_string()),
        addr: ip.filter(|_| state == CloudState::Running).map(|ip| SocketAddr::new(ip, port)),
        launched_at: launched_at.unwrap_or(SystemTime::UNIX_EPOCH),
        state,
        id,
    })
}

impl Ec2 {
    async fn plan(&self) -> Result<Vec<Placement>, Error> {
        let mut params = Vec::new();
        filters(&mut params, &[(&format!("tag:{TAG_MANAGED}"), "true")]);
        let xml = self.api.call("DescribeSubnets", params).await?;
        let doc = parse(&xml)?;
        let subnets: Vec<(String, String)> = items(doc.root_element(), "subnetSet")
            .filter_map(|s| Some((text(s, "subnetId")?.to_string(), text(s, "availabilityZone")?.to_string())))
            .collect();
        if subnets.is_empty() {
            return Err(format!("no subnet tagged {TAG_MANAGED}=true").into());
        }
        let mut params: Vec<(String, String)> = self
            .instance_types
            .iter()
            .enumerate()
            .map(|(i, t)| (format!("InstanceType.{}", i + 1), t.clone()))
            .collect();
        params.push(("ProductDescription.1".into(), "Linux/UNIX".into()));
        params.push(("StartTime".into(), humantime::format_rfc3339_seconds(SystemTime::now()).to_string()));
        let prices = match self.api.call("DescribeSpotPriceHistory", params).await {
            Ok(xml) => {
                let doc = parse(&xml)?;
                let prices: HashMap<_, _> = items(doc.root_element(), "spotPriceHistorySet")
                    .filter_map(|p| {
                        let key = (text(p, "instanceType")?.to_string(), text(p, "availabilityZone")?.to_string());
                        Some((key, text(p, "spotPrice")?.parse().ok()?))
                    })
                    .collect();
                Some(prices)
            }
            Err(e) => {
                log!("spot price lookup failed, keeping configured order: {}", e.1);
                None
            }
        };
        let plan = plan(&self.instance_types, &subnets, prices.as_ref());
        if plan.is_empty() {
            return Err(format!("no Spot offer for {:?} in the tagged subnets", self.instance_types).into());
        }
        Ok(plan)
    }

    async fn run(&self, p: &Placement, key: &Key, user_data: &str) -> Result<InstanceId, ApiError> {
        let mut params: Vec<(String, String)> = [
            ("MinCount", "1"),
            ("MaxCount", "1"),
            ("InstanceType", &p.itype),
            ("LaunchTemplate.LaunchTemplateName", &self.launch_template),
            ("LaunchTemplate.Version", "$Default"),
            ("SubnetId", &p.subnet),
            ("InstanceMarketOptions.MarketType", "spot"),
            ("InstanceMarketOptions.SpotOptions.SpotInstanceType", "one-time"),
            ("InstanceMarketOptions.SpotOptions.InstanceInterruptionBehavior", "terminate"),
            ("UserData", user_data),
        ]
        .into_iter()
        .map(|(k, v)| (k.to_string(), v.to_string()))
        .collect();
        if let Some(max) = &self.max_price {
            params.push(("InstanceMarketOptions.SpotOptions.MaxPrice".into(), max.clone()));
        }
        let name = format!("nbh-builder {key}");
        let tags =
            [(TAG_MANAGED, "true"), (TAG_OWNER, self.owner.as_str()), (TAG_KEY, key.0.as_str()), ("Name", &name)];
        for (i, rt) in ["instance", "volume", "network-interface", "spot-instances-request"].iter().enumerate() {
            params.push((format!("TagSpecification.{}.ResourceType", i + 1), rt.to_string()));
            for (j, (k, v)) in tags.iter().enumerate() {
                params.push((format!("TagSpecification.{}.Tag.{}.Key", i + 1, j + 1), k.to_string()));
                params.push((format!("TagSpecification.{}.Tag.{}.Value", i + 1, j + 1), v.to_string()));
            }
        }
        let xml = self.api.call("RunInstances", params).await?;
        let doc = Document::parse(&xml).map_err(|e| ApiError(None, e.to_string()))?;
        let id = items(doc.root_element(), "instancesSet").find_map(|i| text(i, "instanceId"));
        let id = id.ok_or_else(|| ApiError(None, "RunInstances returned no instance".into()))?;
        log!("launched {id} {} in {} at spot ${:.4}/h", p.itype, p.az, p.price.unwrap_or(f64::NAN));
        Ok(InstanceId(id.to_string()))
    }
}

impl Cloud for Ec2 {
    async fn launch(&self, key: &Key) -> Result<InstanceId, Error> {
        let user_data = Base64::encode_string(&self.authority.user_data(SystemTime::now())?);
        let plan = self.plan().await?;
        launch_first(&plan, |p| self.run(p, key, &user_data)).await
    }

    async fn list(&self) -> Result<Vec<Seen>, Error> {
        let mut out = Vec::new();
        let mut token = None;
        loop {
            let mut params = Vec::new();
            filters(
                &mut params,
                &[(&format!("tag:{TAG_MANAGED}"), "true"), (&format!("tag:{TAG_OWNER}"), &self.owner)],
            );
            if let Some(t) = token.take() {
                params.push(("NextToken".into(), t));
            }
            let xml = self.api.call("DescribeInstances", params).await?;
            let doc = parse(&xml)?;
            let root = doc.root_element();
            for r in items(root, "reservationSet") {
                out.extend(items(r, "instancesSet").filter_map(|i| seen(i, self.port)));
            }
            match text(root, "nextToken") {
                Some(t) => token = Some(t.to_string()),
                None => return Ok(out),
            }
        }
    }

    async fn terminate(&self, id: &InstanceId) -> Result<(), Error> {
        let params = vec![("InstanceId.1".into(), id.0.clone())];
        match self.api.call("TerminateInstances", params).await {
            Err(ApiError(Some(code), _)) if code.starts_with("InvalidInstanceID") => Ok(()),
            r => r.map(drop).map_err(Error::from),
        }
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use std::cell::RefCell;

    fn s(v: &str) -> String {
        v.to_string()
    }

    fn subnets() -> Vec<(String, String)> {
        vec![(s("s-a"), s("az-a")), (s("s-b"), s("az-b"))]
    }

    fn prices() -> HashMap<(String, String), f64> {
        // big.2 is not offered in az-a.
        [(("big.1", "az-a"), 0.90), (("big.1", "az-b"), 0.80), (("big.2", "az-b"), 0.50)]
            .into_iter()
            .map(|((t, az), p)| ((s(t), s(az)), p))
            .collect()
    }

    fn order(plan: &[Placement]) -> Vec<String> {
        plan.iter().map(|p| format!("{}/{}", p.itype, p.subnet)).collect()
    }

    #[tokio::test]
    async fn launch_prefers_type_order_then_cheapest_az_and_moves_on_for_capacity() {
        let plan = plan(&[s("big.1"), s("big.2")], &subnets(), Some(&prices()));
        let tried = RefCell::new(Vec::new());
        let id = launch_first(&plan, |p| {
            tried.borrow_mut().push(format!("{}/{}", p.itype, p.subnet));
            let r = if p.itype == "big.1" {
                Err(ApiError(Some(s("InsufficientInstanceCapacity")), s("no capacity")))
            } else {
                Ok(InstanceId(s("i-1")))
            };
            async move { r }
        })
        .await
        .unwrap();
        assert_eq!(id, InstanceId(s("i-1")));
        assert_eq!(tried.into_inner(), ["big.1/s-b", "big.1/s-a", "big.2/s-b"]);
    }

    #[tokio::test]
    async fn launch_stops_on_an_error_no_placement_avoids() {
        let plan = plan(&[s("big.1"), s("big.2")], &subnets(), Some(&prices()));
        let mut tries = 0;
        let r = launch_first(&plan, |_| {
            tries += 1;
            async { Err(ApiError(Some(s("UnauthorizedOperation")), s("denied"))) }
        })
        .await;
        assert!(r.is_err());
        assert_eq!(tries, 1);
    }

    #[test]
    fn without_prices_every_subnet_is_tried_in_order() {
        let plan = plan(&[s("big.1"), s("big.2")], &subnets(), None);
        assert_eq!(order(&plan), ["big.1/s-a", "big.1/s-b", "big.2/s-a", "big.2/s-b"]);
    }

    #[test]
    fn list_maps_tags_state_and_address() {
        let xml = r#"<DescribeInstancesResponse xmlns="http://ec2.amazonaws.com/doc/2016-11-15/">
          <reservationSet><item><instancesSet><item>
            <instanceId>i-9</instanceId>
            <instanceState><code>16</code><name>running</name></instanceState>
            <launchTime>2026-10-20T21:07:00.000Z</launchTime>
            <ipAddress>203.0.113.7</ipAddress>
            <tagSet><item><key>Name</key><value>nbh-builder k1</value></item><item><key>nbh:key</key><value>k1</value></item></tagSet>
          </item></instancesSet></item></reservationSet></DescribeInstancesResponse>"#;
        let doc = Document::parse(xml).unwrap();
        let i = items(doc.root_element(), "reservationSet").flat_map(|r| items(r, "instancesSet")).next().unwrap();
        let want = Seen {
            key: Key(s("k1")),
            id: InstanceId(s("i-9")),
            state: CloudState::Running,
            addr: Some("203.0.113.7:22".parse().unwrap()),
            launched_at: humantime::parse_rfc3339("2026-10-20T21:07:00Z").unwrap(),
        };
        assert_eq!(seen(i, 22), Some(want));
    }

    #[test]
    fn list_keeps_a_terminated_instance_without_an_address() {
        let xml = r#"<DescribeInstancesResponse xmlns="http://ec2.amazonaws.com/doc/2016-11-15/">
          <reservationSet><item><instancesSet><item>
            <instanceId>i-8</instanceId>
            <instanceState><code>48</code><name>terminated</name></instanceState>
            <launchTime>2026-10-20T21:07:00.000Z</launchTime>
            <ipAddress>203.0.113.8</ipAddress>
            <tagSet><item><key>nbh:key</key><value>k2</value></item></tagSet>
          </item></instancesSet></item></reservationSet></DescribeInstancesResponse>"#;
        let doc = Document::parse(xml).unwrap();
        let i = items(doc.root_element(), "reservationSet").flat_map(|r| items(r, "instancesSet")).next().unwrap();
        let want = Seen {
            key: Key(s("k2")),
            id: InstanceId(s("i-8")),
            state: CloudState::Terminated,
            addr: None,
            launched_at: humantime::parse_rfc3339("2026-10-20T21:07:00Z").unwrap(),
        };
        assert_eq!(seen(i, 22), Some(want));
    }

    #[test]
    fn credentials_come_from_the_named_profile() {
        let ini = "[default]\naws_access_key_id = A\naws_secret_access_key = B\n\n[nbh-gate]\naws_access_key_id = AK\naws_secret_access_key = SK\nregion = eu-north-1\n";
        let p = parse_ini_section(ini, "nbh-gate");
        assert_eq!((p["aws_access_key_id"].as_str(), p["aws_secret_access_key"].as_str()), ("AK", "SK"));
    }

    #[test]
    fn credentials_read_only_the_given_file_and_profile() {
        let dir = crate::testutil::TempDir::new();
        let file = dir.path().join("creds");
        std::fs::write(&file, "[default]\naws_access_key_id = A\naws_secret_access_key = B\n").unwrap();
        let err = Credentials::from_file(&file, "nbh-gate").err().unwrap().to_string();
        assert!(err.contains("profile [nbh-gate] has no access key"), "{err}");
        assert!(Credentials::from_file(&dir.path().join("missing"), "default").is_err());
    }

    fn id(v: &str) -> AccountId {
        v.parse().unwrap()
    }

    #[test]
    fn account_id_is_twelve_digits() {
        assert_eq!(id("845087560967").to_string(), "845087560967");
        for bad in ["84508756096", "8450875609671", "84508756096x", ""] {
            assert!(bad.parse::<AccountId>().is_err(), "{bad:?} accepted");
        }
    }

    #[test]
    fn caller_account_reads_the_sts_response() {
        let xml = r#"<GetCallerIdentityResponse xmlns="https://sts.amazonaws.com/doc/2011-06-15/">
          <GetCallerIdentityResult><Arn>arn:aws:iam::845087560967:user/nbh-gate</Arn>
          <UserId>AIDAEXAMPLE</UserId><Account>845087560967</Account></GetCallerIdentityResult>
          <ResponseMetadata><RequestId>r</RequestId></ResponseMetadata></GetCallerIdentityResponse>"#;
        assert_eq!(caller_account(xml).unwrap(), id("845087560967"));
        assert!(caller_account("<GetCallerIdentityResponse/>").is_err());
    }

    #[tokio::test]
    async fn guard_refuses_credentials_of_another_account() {
        let mine = id("845087560967");
        let err = guard_account(&mine, async { Ok::<_, Error>(id("111122223333")) }).await.unwrap_err();
        let wrong = err.downcast_ref::<WrongAccount>().expect("a WrongAccount error");
        assert_eq!(wrong, &WrongAccount { expected: mine.clone(), actual: id("111122223333") });
        let ok = guard_account(&mine, async { Ok::<_, Error>(id("845087560967")) }).await;
        assert_eq!(ok.unwrap(), mine);
        let down = guard_account(&mine, async { Err::<AccountId, Error>("sts unreachable".into()) }).await;
        assert!(down.unwrap_err().downcast_ref::<WrongAccount>().is_none());
    }

    #[test]
    fn sts_signature_scope_names_the_service() {
        let creds = Credentials { access_key: s("AKID"), secret_key: s("SK"), session_token: None };
        let now = humantime::parse_rfc3339("2026-10-21T00:00:00Z").unwrap();
        let headers =
            sign(&creds, "eu-north-1", "sts", "sts.eu-north-1.amazonaws.com", "Action=GetCallerIdentity", now);
        let auth = &headers.iter().find(|(k, _)| k == "authorization").unwrap().1;
        assert!(auth.contains("Credential=AKID/20261021/eu-north-1/sts/aws4_request"), "{auth}");
    }

    /// Expected value computed by botocore's SigV4Auth for the same request.
    #[test]
    fn signature_matches_botocore() {
        let creds = Credentials {
            access_key: s("AKIDEXAMPLE"),
            secret_key: s("wJalrXUtnFEMI/K7MDENG+bPxRfiCYEXAMPLEKEY"),
            session_token: None,
        };
        let now = humantime::parse_rfc3339("2026-10-20T22:10:41Z").unwrap();
        let body = "Action=DescribeRegions&Version=2016-11-15";
        let headers = sign(&creds, "us-east-1", "ec2", "ec2.us-east-1.amazonaws.com", body, now);
        let auth = headers.iter().find(|(k, _)| k == "authorization").map(|(_, v)| v.as_str());
        assert_eq!(
            auth,
            Some(
                "AWS4-HMAC-SHA256 Credential=AKIDEXAMPLE/20261020/us-east-1/ec2/aws4_request, \
                 SignedHeaders=content-type;host;x-amz-date, \
                 Signature=2601fa2cc719a37cd1874bf74967714fdf96aec2c51b467c3fd0d02bfd0b78a6"
            )
        );
    }

    #[test]
    fn form_encodes_reserved_characters() {
        let body = form(&[(s("Filter.1.Name"), s("tag:nbh:managed")), (s("LaunchTemplate.Version"), s("$Default"))]);
        assert_eq!(body, "Filter.1.Name=tag%3Anbh%3Amanaged&LaunchTemplate.Version=%24Default");
    }
}
