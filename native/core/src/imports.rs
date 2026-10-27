use super::*;

fn uuid(s: &str) -> bool {
    s.len() == 36
        && s.bytes().enumerate().all(|(i, b)| {
            if matches!(i, 8 | 13 | 18 | 23) {
                b == b'-'
            } else {
                b.is_ascii_hexdigit()
            }
        })
}
fn source(raw: &str) -> Result<(&str, &'static str)> {
    if raw.len() > 4096 {
        return Err("invalid_import_url");
    }
    let text = raw.trim();
    for (i, b) in text.bytes().enumerate() {
        if b == b'%'
            && !text
                .as_bytes()
                .get(i + 1..i + 3)
                .is_some_and(|s| s.iter().all(u8::is_ascii_hexdigit))
        {
            return Err("invalid_import_url");
        }
    }
    if text.is_empty()
        || text.chars().any(|c| c.is_control() || c.is_whitespace())
        || text.contains('\\')
    {
        return Err("invalid_import_url");
    }
    let u = reqwest::Url::parse(text).map_err(|_| "invalid_import_url")?;
    let authority = text
        .split_once("://")
        .map(|(_, s)| s.split(['/', '?', '#']).next().unwrap_or(""))
        .ok_or("invalid_import_url")?;
    if u.scheme() != "https" || authority.contains('@') || u.port().is_some() {
        return Err("invalid_import_url");
    }
    let host = u.host_str().ok_or("invalid_import_url")?;
    let video = |s: &str| {
        s.len() == 11
            && s.bytes()
                .all(|c| c.is_ascii_alphanumeric() || c == b'_' || c == b'-')
    };
    let youtube = host == "youtube.com" || host.ends_with(".youtube.com");
    if youtube && u.path() == "/watch" {
        let ids: Vec<_> = u.query_pairs().filter(|(k, _)| k == "v").collect();
        if ids.len() == 1 && video(&ids[0].1) {
            return Ok((text, "youtube"));
        }
    }
    if host == "youtu.be" && video(u.path().strip_prefix('/').unwrap_or("")) {
        return Ok((text, "youtube"));
    }
    if matches!(
        host,
        "soundcloud.com" | "www.soundcloud.com" | "m.soundcloud.com"
    ) {
        let parts: Vec<_> = u.path().trim_end_matches('/').split('/').skip(1).collect();
        if parts.len() == 2
            && parts.iter().all(|s| {
                !s.is_empty()
                    && s.bytes()
                        .all(|b| b.is_ascii_alphanumeric() || matches!(b, b'-' | b'_'))
            })
            && ![
                "sets", "discover", "search", "you", "charts", "stream", "upload", "pages",
                "terms", "privacy", "imprint",
            ]
            .contains(&parts[0])
            && parts[1] != "sets"
        {
            return Ok((text, "soundcloud"));
        }
    }
    Err("invalid_import_url")
}
fn timestamp(s: &str) -> bool {
    let b = s.as_bytes();
    b.len() == 20
        && b[4] == b'-'
        && b[7] == b'-'
        && b[10] == b'T'
        && b[13] == b':'
        && b[16] == b':'
        && b[19] == b'Z'
        && b.iter()
            .enumerate()
            .all(|(i, c)| matches!(i, 4 | 7 | 10 | 13 | 16 | 19) || c.is_ascii_digit())
        && ("01"..="12").contains(&&s[5..7])
        && ("01"..="31").contains(&&s[8..10])
        && &s[11..13] <= "23"
        && &s[14..16] <= "59"
        && &s[17..19] <= "59"
}
fn decode_job(value: Value) -> Result<ImportJob> {
    let j: ImportJob = serde_json::from_value(value).map_err(|_| "invalid_import_job")?;
    if !uuid(&j.job_id)
        || j.progress > 100
        || j.track_id.is_some_and(|n| n <= 0)
        || j.error.as_ref().is_some_and(|s| {
            s.len() > 4096
                || s.chars()
                    .any(|c| c.is_control() && !matches!(c, '\n' | '\t'))
        })
        || j.url.len() > 4096
        || j.url.chars().any(char::is_control)
        || !matches!(j.source_type.as_str(), "youtube" | "soundcloud")
        || !timestamp(&j.created_at)
        || [&j.started_at, &j.completed_at]
            .iter()
            .any(|t| t.as_ref().is_some_and(|s| !timestamp(s)))
    {
        return Err("invalid_import_job");
    }
    Ok(j)
}
impl Core {
    pub(super) fn read_import_job(&self, s: &mut State, id: &str, epoch: u64) -> Result<ImportJob> {
        if !uuid(id) {
            return Err("invalid_import_job");
        }
        let job =
            decode_job(self.request(s, "GET", &format!("/downloads/{id}"), None, epoch, true)?)?;
        if job.job_id != id {
            return Err("invalid_import_job");
        }
        Ok(job)
    }
    pub(super) fn read_import_jobs(&self, s: &mut State, epoch: u64) -> Result<Vec<ImportJob>> {
        let value = self.request(s, "GET", "/downloads", None, epoch, true)?;
        let rows = value
            .get("jobs")
            .and_then(Value::as_array)
            .ok_or("invalid_import_job")?;
        if rows.len() > 4096 {
            return Err("response_too_large");
        }
        let mut seen = HashSet::new();
        let mut jobs = Vec::new();
        for row in rows {
            let job = decode_job(row.clone())?;
            if !seen.insert(job.job_id.clone()) {
                return Err("invalid_import_job");
            }
            jobs.push(job)
        }
        jobs.sort_by(|a, b| {
            b.created_at
                .cmp(&a.created_at)
                .then(a.job_id.cmp(&b.job_id))
        });
        Ok(jobs)
    }
    pub(super) fn submit_import(
        &self,
        s: &mut State,
        operation_id: u64,
        url: &str,
        epoch: u64,
    ) -> Result<()> {
        if operation_id == 0
            || s.import_receipt
                .as_ref()
                .is_some_and(|r| operation_id <= r.operation_id)
        {
            return Err("import_duplicate");
        }
        s.import_receipt = Some(SubmissionReceipt {
            operation_id,
            outcome: "not_sent",
            ack: None,
        });
        let (url, kind) = source(url)?;
        let mut dispatched = false;
        let response = self.request_response(
            s,
            "POST",
            "/downloads",
            Some(json!({"url":url,"source_type":kind})),
            epoch,
            false,
            &mut dispatched,
        );
        if dispatched {
            s.import_receipt.as_mut().unwrap().outcome = "uncertain"
        }
        let response = response?;
        let status = response.status().as_u16();
        if (400..500).contains(&status) {
            s.import_receipt.as_mut().unwrap().outcome = "rejected";
            return Err(Self::api_error(status));
        }
        if status != 201 {
            return Err("import_uncertain");
        }
        let ack: CreateImportAck = serde_json::from_value(self.read_json(response, epoch)?)
            .map_err(|_| "import_uncertain")?;
        if !uuid(&ack.job_id) || !uuid(&ack.source_decision_id) {
            return Err("import_uncertain");
        }
        s.import_receipt = Some(SubmissionReceipt {
            operation_id,
            outcome: "accepted",
            ack: Some(ack),
        });
        Ok(())
    }
}
