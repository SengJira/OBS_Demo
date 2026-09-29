#!/usr/bin/env python3
"""Generate the ObjectScale demo Postman collection + environment.

Output:
  postman/ObjectScale-Demo.postman_collection.json
  postman/ObjectScale-Lab.postman_environment.json

No credentials are written. Newman/Postman users supply secrets via the
environment file or `newman run --env-var ...`.
"""
import json
import os

HERE = os.path.dirname(os.path.abspath(__file__))


def s3auth(ak="{{access_key}}", sk="{{secret_key}}"):
    return {
        "type": "awsv4",
        "awsv4": [
            {"key": "accessKey", "value": ak},
            {"key": "secretKey", "value": sk},
            {"key": "region", "value": "{{aws_region}}"},
            {"key": "service", "value": "s3"},
        ],
    }


def req(name, method, url, *, desc="", auth=None, headers=None, body=None,
        raw_body=None, tests=None, pre=None):
    """Build a Postman v2.1 request item."""
    r = {
        "name": name,
        "request": {
            "method": method,
            "header": headers or [],
            "url": {"raw": url, "host": [], "path": [], "query": []},
            "description": desc,
        },
    }
    # split raw url into host/path/query for readability
    from urllib.parse import urlsplit, parse_qsl
    u = urlsplit(url.replace("{{", "X_").replace("}}", "")) if False else None
    # keep it simple: store as raw + urlencoded path pieces
    parts = url.split("://", 1)
    if len(parts) == 2:
        r["request"]["url"]["protocol"] = parts[0]
        rest = parts[1]
    else:
        rest = parts[0]
    host, _, pathq = rest.partition("/")
    r["request"]["url"]["host"] = [host]
    path, _, qs = pathq.partition("?")
    r["request"]["url"]["path"] = [p for p in path.split("/") if p]
    if qs:
        r["request"]["url"]["query"] = [
            {"key": k, "value": v} for k, v in parse_qsl(qs, keep_blank_values=True)
        ]
    if auth:
        r["request"]["auth"] = auth
    if raw_body is not None:
        r["request"]["body"] = {"mode": "raw", "raw": raw_body}
        if body == "json":
            r["request"]["body"]["options"] = {"raw": {"language": "json"}}
    if tests or pre:
        r["event"] = []
        if pre:
            r["event"].append({"listen": "prerequest",
                               "script": {"type": "text/javascript", "exec": pre.split("\n")}})
        if tests:
            r["event"].append({"listen": "test",
                               "script": {"type": "text/javascript", "exec": tests.split("\n")}})
    return r


def folder(name, items, desc=""):
    return {"name": name, "item": items, "description": desc}


T_STATUS_2XX = """
pm.test('status 2xx', function () {
  pm.expect(pm.response.code).to.be.oneOf([200,201,204]);
});"""

T_200 = """
pm.test('status 200', function () {
  pm.expect(pm.response.code).to.eql(200);
});"""

T_DENIED = """
pm.test('AccessDenied (expected denial)', function () {
  pm.expect(pm.response.code).to.eql(403);
  pm.expect(pm.response.text()).to.include('AccessDenied');
});"""

T_NO_SUCH_KEY = """
pm.test('NoSuchKey (expected miss)', function () {
  pm.expect(pm.response.code).to.eql(404);
  pm.expect(pm.response.text()).to.include('NoSuchKey');
});"""


def build_collection():
    items = []

    # ------------------------------------------------------------------ #
    # 00 Environment & Setup
    # ------------------------------------------------------------------ #
    setup = []

    setup.append(req(
        "0.1 Get mgmt token (X-SDS-AUTH-TOKEN)",
        "GET", "{{mgmt_url}}/login",
        desc=("Management REST API login (basic auth). Stores the returned "
              "`X-SDS-AUTH-TOKEN` header into `{{mgmt_token}}` for all "
              "management/monitoring requests.\n\n"
              "**Token hygiene**: ObjectScale caps tokens per user — reuse "
              "this cached token; do not re-login per request."),
        auth={"type": "basic", "basic": [
            {"key": "username", "value": "{{mgmt_user}}"},
            {"key": "password", "value": "{{mgmt_password}}"}]},
        tests=T_200 + """
var t = pm.response.headers.get('X-SDS-AUTH-TOKEN');
pm.test('token issued', function(){ pm.expect(t).to.not.be.empty; });
if (t) pm.environment.set('mgmt_token', t);"""))

    setup.append(req(
        "0.2 Portal session - start encrypt session",
        "POST", "{{portal_url}}/startEncryptSession",
        desc=("Step 1 of the portal login handshake: returns a one-time "
              "session key used to AES-encrypt credentials in the next "
              "request (mirrors the UI login). No secrets stored — the "
              "encryption happens in the pre-request script of step 0.3."),
        tests=T_200 + """
pm.environment.set('ui_session_key', pm.response.text());
var c = pm.cookies.get('ECSUI_SESSION');
if (c) pm.environment.set('ui_session_cookie', c);"""))

    setup.append(req(
        "0.3 Portal session - login (AES-credential flow)",
        "GET", "{{portal_url}}/login",
        desc=("Step 2: sends `Authorization: ECS <base64>` where the value is "
              "CryptoJS AES.encrypt('user:pass', sessionKey) — identical to "
              "the ObjectScale UI login. Captures `ECSAuthToken` + "
              "`XSRF-TOKEN` cookies into `{{ui_token}}`/`{{xsrf_token}}` "
              "for portal-API requests (IAM, VDCs, exports, copy policy)."),
        headers=[
            {"key": "Authorization", "value": "ECS {{ecs_b64auth}}"},
            {"key": "Cookie", "value": "ECSUI_SESSION={{ui_session_cookie}}"},
            {"key": "Accept", "value": "application/json"}],
        pre="""var CJS = require('crypto-js');
var k = pm.environment.get('ui_session_key');
var creds = pm.environment.get('mgmt_user') + ':' + pm.environment.get('mgmt_password');
pm.environment.set('ecs_b64auth', CJS.AES.encrypt(creds, k).toString());""",
        tests=T_200 + """
var j = pm.response.json();
pm.test('login success', function(){ pm.expect(j.isSuccess).to.be.true; });
var xs = pm.cookies.get('XSRF-TOKEN');
if (j.data && j.data.authToken) pm.environment.set('ui_token', j.data.authToken);
if (xs) pm.environment.set('xsrf_token', xs);"""))

    setup.append(req(
        "0.4 Create bucket {{pm_bucket}}",
        "PUT", "{{s3_http}}/{{pm_bucket}}",
        desc="Create the main demo bucket via S3 `PUT Bucket` (SigV4). Idempotent.",
        auth=s3auth(),
        tests="""
pm.test('created or already ours', function(){
  pm.expect(pm.response.code).to.be.oneOf([200,409]);
  if (pm.response.code===409) pm.expect(pm.response.text()).to.include('BucketAlreadyOwnedByYou');
});"""))

    setup.append(req(
        "0.5 Create object-lock bucket {{pm_lock_bucket}} (IAM creds)",
        "PUT", "{{s3_http}}/{{pm_lock_bucket}}",
        desc=("Create a bucket with Object Lock enabled. **ObjectScale quirk "
              "(verified on 4.3.0): object-lock operations require IAM user "
              "credentials** — object users get `AccessDenied: Only IAM users "
              "are supported with object lock enabled buckets`. This request "
              "signs with `writer_access_key`/`writer_secret_key` and sends "
              "`x-amz-bucket-object-lock-enabled: true`; versioning is "
              "enabled automatically and cannot be suspended afterward."),
        auth=s3auth("{{writer_access_key}}", "{{writer_secret_key}}"),
        headers=[{"key": "x-amz-bucket-object-lock-enabled", "value": "true"}],
        tests="""
pm.test('created or already ours', function(){
  pm.expect(pm.response.code).to.be.oneOf([200,409]);
});"""))

    setup.append(req(
        "0.6 Create lifecycle bucket {{pm_lifecycle_bucket}}",
        "PUT", "{{s3_http}}/{{pm_lifecycle_bucket}}",
        desc="Disposable bucket used only for the lifecycle scene. Idempotent.",
        auth=s3auth(), tests="""
pm.test('created or already ours', function(){
  pm.expect(pm.response.code).to.be.oneOf([200,409]);
});"""))

    setup.append(req(
        "0.7 Grant demo-reader read-only on {{pm_bucket}} (IAM policy)",
        "POST", "{{portal_url}}/iam",
        desc=("IAM `PutUserPolicy` via the portal `/iam` proxy (needs the "
              "session from step 0.3). Grants `demo-reader` `s3:GetObject` + "
              "`s3:ListBucket` on `{{pm_bucket}}` — the least-privilege "
              "identity used by the allow/deny tests."),
        headers=[
            {"key": "X-SDS-AUTH-TOKEN", "value": "{{ui_token}}"},
            {"key": "X-XSRF-TOKEN", "value": "{{xsrf_token}}"},
            {"key": "Cookie", "value": "XSRF-TOKEN={{xsrf_token}}; ECSAuthToken={{ui_token}}"},
            {"key": "x-emc-namespace", "value": "{{namespace}}"},
            {"key": "Content-Type", "value": "application/x-www-form-urlencoded"}],
        raw_body='Action=PutUserPolicy&UserName=demo-reader&PolicyName=demo-pm-read&Namespace={{namespace}}&PolicyDocument=%7B%22Version%22%3A%222012-10-17%22%2C%22Statement%22%3A%5B%7B%22Effect%22%3A%22Allow%22%2C%22Action%22%3A%5B%22s3%3AGetObject%22%2C%22s3%3AListBucket%22%5D%2C%22Resource%22%3A%5B%22arn%3Aaws%3As3%3A%3A%3Ademo-pm-s3%22%2C%22arn%3Aaws%3As3%3A%3A%3Ademo-pm-s3%2F*%22%5D%7D%5D%7D',
        tests="""
var j = pm.response.json();
pm.test('iam policy applied', function(){
  pm.expect(j.isSuccess).to.be.true;
});"""))

    items.append(folder("00 — Setup (run once)", setup,
        "Creates the demo buckets, caches auth tokens, grants the least-privilege IAM policy."))

    # ------------------------------------------------------------------ #
    # 10 S3 API
    # ------------------------------------------------------------------ #
    s3 = []

    s3.append(req(
        "1.1 PUT object (metadata + tags)",
        "PUT", "{{s3_http}}/{{pm_bucket}}/doc/postman-hello.txt",
        desc=("PutObject with user metadata and object tags. Metadata travels "
              "as `x-amz-meta-*`; tags as `x-amz-tagging` header."),
        auth=s3auth(),
        headers=[
            {"key": "x-amz-meta-project", "value": "objectscale-demo"},
            {"key": "x-amz-tagging", "value": "env=demo&scene=postman"},
            {"key": "Content-Type", "value": "text/plain"}],
        raw_body="Hello from Postman — ObjectScale demo object.\n",
        tests=T_200 + """
pm.test('ETag returned', function(){
  pm.expect(pm.response.headers.get('ETag')).to.not.be.empty;
});"""))

    s3.append(req(
        "1.2 GET object",
        "GET", "{{s3_http}}/{{pm_bucket}}/doc/postman-hello.txt",
        auth=s3auth(),
        tests=T_200 + """
pm.test('body round-trip', function(){
  pm.expect(pm.response.text()).to.include('ObjectScale demo object');
});"""))

    s3.append(req(
        "1.3 HEAD object",
        "HEAD", "{{s3_http}}/{{pm_bucket}}/doc/postman-hello.txt",
        desc="HeadObject — validates metadata returned without the body.",
        auth=s3auth(),
        tests=T_200 + """
pm.test('custom metadata present', function(){
  pm.expect(pm.response.headers.get('x-amz-meta-project')).to.eql('objectscale-demo');
});"""))

    s3.append(req(
        "1.4 LIST objects (prefix)",
        "GET", "{{s3_http}}/{{pm_bucket}}?list-type=2&prefix=doc%2F",
        desc="ListObjectsV2 restricted to prefix `doc/`.",
        auth=s3auth(),
        tests=T_200 + """
pm.test('key listed', function(){
  pm.expect(pm.response.text()).to.include('doc/postman-hello.txt');
});"""))

    s3.append(req(
        "1.5 GET object tagging",
        "GET", "{{s3_http}}/{{pm_bucket}}/doc/postman-hello.txt?tagging",
        auth=s3auth(),
        tests=T_200 + """
pm.test('tag env=demo present', function(){
  pm.expect(pm.response.text()).to.include('env').and.to.include('demo');
});"""))

    s3.append(req(
        "1.6 Multipart upload - create",
        "POST", "{{s3_http}}/{{pm_bucket}}/mp/big-part.bin?uploads",
        desc="InitiateMultipartUpload — captures `UploadId` for the next requests.",
        auth=s3auth(),
        tests=T_200 + """
var m = pm.response.text().match(/<UploadId>([^<]+)<\\/UploadId>/);
pm.test('uploadId returned', function(){ pm.expect(m).to.not.be.null; });
if (m) pm.environment.set('upload_id', m[1]);"""))

    s3.append(req(
        "1.7 Multipart upload - upload part 1",
        "PUT", "{{s3_http}}/{{pm_bucket}}/mp/big-part.bin?partNumber=1&uploadId={{upload_id}}",
        auth=s3auth(),
        headers=[{"key": "Content-Type", "value": "application/octet-stream"}],
        raw_body="part-one-payload-for-multipart-demo",
        tests=T_200 + """
pm.environment.set('mp_etag1', pm.response.headers.get('ETag'));"""))

    s3.append(req(
        "1.8 Multipart upload - upload part 2",
        "PUT", "{{s3_http}}/{{pm_bucket}}/mp/big-part.bin?partNumber=2&uploadId={{upload_id}}",
        auth=s3auth(),
        headers=[{"key": "Content-Type", "value": "application/octet-stream"}],
        raw_body="part-two-payload-for-multipart-demo",
        tests=T_200 + """
pm.environment.set('mp_etag2', pm.response.headers.get('ETag'));"""))

    s3.append(req(
        "1.9 Multipart upload - complete",
        "POST", "{{s3_http}}/{{pm_bucket}}/mp/big-part.bin?uploadId={{upload_id}}",
        auth=s3auth(),
        headers=[{"key": "Content-Type", "value": "application/xml"}],
        raw_body='<CompleteMultipartUpload><Part><PartNumber>1</PartNumber><ETag>{{mp_etag1}}</ETag></Part><Part><PartNumber>2</PartNumber><ETag>{{mp_etag2}}</ETag></Part></CompleteMultipartUpload>',
        tests=T_200 + """
pm.test('multipart ETag formed', function(){
  pm.expect(pm.response.text()).to.include('</ETag>');
});"""))

    s3.append(req(
        "1.10 Presigned GET (SigV2 URL generated in pre-request)",
        "GET", "{{s3_http}}/{{pm_bucket}}/doc/postman-hello.txt?AWSAccessKeyId={{access_key}}&Expires={{ps_exp}}&Signature={{ps_sig}}",
        desc=("Generates a Signature V2 presigned URL in the pre-request "
              "script (HMAC-SHA1 over `GET\\n\\n\\n<exp>\\n/bucket/key`), then "
              "GETs it with no auth. Verified working against this build; "
              "SigV4 presign also works via AWS SDKs/CLI.\n\n"
              "**Expires in 300s** — rerun the collection step if it ages out."),
        pre="""var CJS2 = require('crypto-js');
const exp = Math.floor(Date.now()/1000) + 300;
const bucket = pm.environment.get('pm_bucket');
const key = 'doc/postman-hello.txt';
const sts = 'GET\\n\\n\\n' + exp + '\\n/' + bucket + '/' + key;
const sig = CJS2.enc.Base64.stringify(CJS2.HmacSHA1(sts, pm.environment.get('secret_key')));
pm.environment.set('ps_exp', String(exp));
pm.environment.set('ps_sig', encodeURIComponent(sig));""",
        tests=T_200 + """
pm.test('presigned body ok', function(){
  pm.expect(pm.response.text()).to.include('ObjectScale demo object');
});"""))

    s3.append(req(
        "1.11 Bucket versioning - enable",
        "PUT", "{{s3_http}}/{{pm_bucket}}?versioning",
        auth=s3auth(),
        headers=[{"key": "Content-Type", "value": "application/xml"}],
        raw_body='<VersioningConfiguration><Status>Enabled</Status></VersioningConfiguration>',
        tests=T_200))

    s3.append(req(
        "1.12 Bucket versioning - read back",
        "GET", "{{s3_http}}/{{pm_bucket}}?versioning",
        auth=s3auth(),
        tests=T_200 + """
pm.test('versioning Enabled', function(){
  pm.expect(pm.response.text()).to.include('Enabled');
});"""))

    s3.append(req(
        "1.13 EXPECTED FAILURE - GET missing object",
        "GET", "{{s3_http}}/{{pm_bucket}}/does/not-exist.txt",
        desc="Negative test: must return 404 `NoSuchKey` — proves errors surface correctly.",
        auth=s3auth(), tests=T_NO_SUCH_KEY))

    s3.append(req(
        "1.14 EXPECTED FAILURE - object-lock read with object user",
        "GET", "{{s3_http}}/{{pm_lock_bucket}}?object-lock",
        desc=("ObjectScale behavior note: GetObjectLockConfiguration rejects "
              "legacy object users — expects `403 AccessDenied` with the "
              "'Only IAM users are supported' message. IAM creds (request "
              "3.x) succeed."),
        auth=s3auth(),
        tests="""
pm.test('object user denied for lock ops', function(){
  pm.expect(pm.response.code).to.eql(403);
  pm.expect(pm.response.text()).to.include('Only IAM users');
});"""))

    s3.append(req(
        "1.15 DOCUMENTED GAP - bucket tagging unsupported",
        "PUT", "{{s3_http}}/{{pm_bucket}}?tagging",
        desc=("PutBucketTagging returns `501 NotImplemented` on this build — "
              "kept in the collection to demonstrate the compatibility gap "
              "honestly (object-level tagging works; bucket-level does not)."),
        auth=s3auth(),
        headers=[{"key": "Content-Type", "value": "application/xml"}],
        raw_body='<Tagging><TagSet><Tag><Key>env</Key><Value>demo</Value></Tag></TagSet></Tagging>',
        tests="""
pm.test('bucket tagging NotImplemented (expected gap)', function(){
  pm.expect(pm.response.code).to.eql(501);
  pm.expect(pm.response.text()).to.include('NotImplemented');
});"""))

    items.append(folder("10 — S3 API compatibility", s3,
        "PUT/GET/HEAD/LIST/tagging/multipart/presign/versioning + expected failures."))

    # ------------------------------------------------------------------ #
    # 20 IAM & bucket policy
    # ------------------------------------------------------------------ #
    iam = []

    iam.append(req(
        "2.1 PUT bucket policy (deny delete on protected/*)",
        "PUT", "{{s3_http}}/{{pm_bucket}}?policy",
        desc=("Bucket policy denying `s3:DeleteObject` on `protected/*` for "
              "everyone. Resource ARNs accept standard `arn:aws:s3:::` form "
              "or bare `bucket/key` on this build."),
        auth=s3auth(),
        headers=[{"key": "Content-Type", "value": "application/json"}],
        raw_body='{"Version":"2012-10-17","Statement":[{"Sid":"DenyDeleteProtected","Effect":"Deny","Principal":"*","Action":"s3:DeleteObject","Resource":"{{pm_bucket}}/protected/*"}]}',
        tests=T_STATUS_2XX))

    iam.append(req(
        "2.2 GET bucket policy",
        "GET", "{{s3_http}}/{{pm_bucket}}?policy",
        auth=s3auth(),
        tests=T_200 + """
pm.test('policy shows DenyDeleteProtected', function(){
  pm.expect(pm.response.text()).to.include('DenyDeleteProtected');
});"""))

    iam.append(req(
        "2.3 IAM allow - demo-reader GET object",
        "GET", "{{s3_http}}/{{pm_bucket}}/doc/postman-hello.txt",
        desc=("demo-reader holds only `s3:GetObject`/`s3:ListBucket` on this "
              "bucket (policy applied in setup step 0.7). Expect 200."),
        auth=s3auth("{{reader_access_key}}", "{{reader_secret_key}}"),
        tests=T_200))

    iam.append(req(
        "2.4 EXPECTED DENIAL - demo-reader PUT",
        "PUT", "{{s3_http}}/{{pm_bucket}}/data/should-fail.txt",
        desc="demo-reader has no PutObject permission — must be 403 AccessDenied.",
        auth=s3auth("{{reader_access_key}}", "{{reader_secret_key}}"),
        headers=[{"key": "Content-Type", "value": "text/plain"}],
        raw_body="this must never be written\n",
        tests=T_DENIED))

    iam.append(req(
        "2.5 EXPECTED DENIAL - delete protected/ (bucket policy)",
        "PUT", "{{s3_http}}/{{pm_bucket}}/protected/report.txt",
        desc="First stage: create the protected object (allowed).",
        auth=s3auth(),
        headers=[{"key": "Content-Type", "value": "text/plain"}],
        raw_body="protected content\n",
        tests=T_200))

    iam.append(req(
        "2.6 EXPECTED DENIAL - delete protected/ enforced",
        "DELETE", "{{s3_http}}/{{pm_bucket}}/protected/report.txt",
        desc=("Bucket-policy `Deny` overrides the writer's IAM `Allow` — "
              "deletion of `protected/*` must return 403 AccessDenied even "
              "for an identity with s3:*."),
        auth=s3auth("{{writer_access_key}}", "{{writer_secret_key}}"),
        tests=T_DENIED))

    items.append(folder("20 — IAM & bucket policy", iam,
        "Least-privilege IAM identity tests + bucket-policy deny."))

    # ------------------------------------------------------------------ #
    # 30 Object Lock
    # ------------------------------------------------------------------ #
    lock = []

    lock.append(req(
        "3.1 GET object-lock configuration (IAM creds)",
        "GET", "{{s3_http}}/{{pm_lock_bucket}}?object-lock",
        auth=s3auth("{{writer_access_key}}", "{{writer_secret_key}}"),
        tests=T_200 + """
pm.test('object lock enabled', function(){
  pm.expect(pm.response.text()).to.include('Enabled');
});"""))

    lock.append(req(
        "3.2 PUT object with GOVERNANCE retention (+2h)",
        "PUT", "{{s3_http}}/{{pm_lock_bucket}}/worm/gov-record.txt",
        desc=("Writes an object with `x-amz-object-lock-mode: GOVERNANCE` and "
              "a retain-until 2h out (computed in pre-request). Captures the "
              "returned `x-amz-version-id` for the version-scoped delete "
              "tests."),
        auth=s3auth("{{writer_access_key}}", "{{writer_secret_key}}"),
        pre="""pm.environment.set('lock_retain', new Date(Date.now()+2*3600e3).toISOString());""",
        headers=[
            {"key": "x-amz-object-lock-mode", "value": "GOVERNANCE"},
            {"key": "x-amz-object-lock-retain-until-date", "value": "{{lock_retain}}"},
            {"key": "Content-Type", "value": "text/plain"}],
        raw_body="WORM governance-mode record\n",
        tests=T_200 + """
var vid = pm.response.headers.get('x-amz-version-id');
pm.test('version id returned', function(){ pm.expect(vid).to.not.be.empty; });
pm.environment.set('gov_vid', vid);"""))

    lock.append(req(
        "3.3 GET object retention",
        "GET", "{{s3_http}}/{{pm_lock_bucket}}/worm/gov-record.txt?retention&versionId={{gov_vid}}",
        auth=s3auth("{{writer_access_key}}", "{{writer_secret_key}}"),
        tests=T_200 + """
pm.test('governance retention stored', function(){
  pm.expect(pm.response.text()).to.include('GOVERNANCE');
});"""))

    lock.append(req(
        "3.4 Plain DELETE -> delete marker only (allowed)",
        "DELETE", "{{s3_http}}/{{pm_lock_bucket}}/worm/gov-record.txt",
        desc=("On a versioned bucket a plain DELETE only adds a delete marker "
              "— same as AWS. The retained version is untouched (proven "
              "next)."),
        auth=s3auth("{{writer_access_key}}", "{{writer_secret_key}}"),
        tests=T_STATUS_2XX))

    lock.append(req(
        "3.5 EXPECTED DENIAL - delete retained VERSION",
        "DELETE", "{{s3_http}}/{{pm_lock_bucket}}/worm/gov-record.txt?versionId={{gov_vid}}",
        desc="The actual WORM guarantee: deleting the locked version is denied.",
        auth=s3auth("{{writer_access_key}}", "{{writer_secret_key}}"),
        tests=T_DENIED))

    lock.append(req(
        "3.6 GET retained version still readable",
        "GET", "{{s3_http}}/{{pm_lock_bucket}}/worm/gov-record.txt?versionId={{gov_vid}}",
        auth=s3auth("{{writer_access_key}}", "{{writer_secret_key}}"),
        tests=T_200))

    lock.append(req(
        "3.7 EXPECTED DENIAL - shorten retention",
        "PUT", "{{s3_http}}/{{pm_lock_bucket}}/worm/gov-record.txt?retention&versionId={{gov_vid}}",
        desc=("Retention can be extended but never shortened without "
              "`s3:BypassGovernanceRetention` **and** the "
              "`x-amz-bypass-governance-retention: true` header. This request "
              "sets a still-future but *earlier* date without the bypass "
              "header → must be 403 AccessDenied."),
        auth=s3auth("{{writer_access_key}}", "{{writer_secret_key}}"),
        pre="pm.environment.set('shorten_date', new Date(Date.now()+30*60e3).toISOString());",
        headers=[{"key": "Content-Type", "value": "application/xml"}],
        raw_body='<Retention><Mode>GOVERNANCE</Mode><RetainUntilDate>{{shorten_date}}</RetainUntilDate></Retention>',
        tests=T_DENIED))

    lock.append(req(
        "3.8 PUT object with COMPLIANCE retention (+75m)",
        "PUT", "{{s3_http}}/{{pm_lock_bucket}}/worm/compliance-record.txt",
        auth=s3auth("{{writer_access_key}}", "{{writer_secret_key}}"),
        pre="""pm.environment.set('comp_retain', new Date(Date.now()+75*60e3).toISOString());""",
        headers=[
            {"key": "x-amz-object-lock-mode", "value": "COMPLIANCE"},
            {"key": "x-amz-object-lock-retain-until-date", "value": "{{comp_retain}}"},
            {"key": "Content-Type", "value": "text/plain"}],
        raw_body="WORM compliance-mode record\n",
        tests=T_200 + """
pm.environment.set('comp_vid', pm.response.headers.get('x-amz-version-id'));"""))

    lock.append(req(
        "3.9 EXPECTED DENIAL - compliance delete w/ bypass flag",
        "DELETE", "{{s3_http}}/{{pm_lock_bucket}}/worm/compliance-record.txt?versionId={{comp_vid}}&x-amz-bypass-governance-retention=true",
        desc=("Compliance mode cannot be bypassed — even an identity holding "
              "`s3:BypassGovernanceRetention` gets AccessDenied. Verified on "
              "this build."),
        auth=s3auth("{{writer_access_key}}", "{{writer_secret_key}}"),
        tests=T_DENIED))

    items.append(folder("30 — Object Lock / WORM", lock,
        "Governance vs compliance; deny tests assert exact AccessDenied."))

    # ------------------------------------------------------------------ #
    # 40 Lifecycle
    # ------------------------------------------------------------------ #
    lc = []

    lc.append(req(
        "4.0 Ensure bucket {{pm_lifecycle_bucket}} exists",
        "PUT", "{{s3_http}}/{{pm_lifecycle_bucket}}",
        desc="Idempotent — makes this folder safe to re-run standalone.",
        auth=s3auth(), tests="""
pm.test('created or already ours', function(){
  pm.expect(pm.response.code).to.be.oneOf([200,409]);
});"""))

    lc.append(req(
        "4.1 PUT lifecycle rule (expire tmp/ in 1 day)",
        "PUT", "{{s3_http}}/{{pm_lifecycle_bucket}}?lifecycle",
        auth=s3auth(),
        headers=[{"key": "Content-Type", "value": "application/xml"}],
        raw_body=('<LifecycleConfiguration><Rule><ID>demo-pm-expire-tmp</ID>'
                  '<Status>Enabled</Status><Filter><Prefix>tmp/</Prefix></Filter>'
                  '<Expiration><Days>1</Days></Expiration></Rule></LifecycleConfiguration>'),
        tests=T_200))

    lc.append(req(
        "4.2 GET lifecycle configuration",
        "GET", "{{s3_http}}/{{pm_lifecycle_bucket}}?lifecycle",
        auth=s3auth(),
        tests=T_200 + """
pm.test('rule present', function(){
  pm.expect(pm.response.text()).to.include('demo-pm-expire-tmp');
});"""))

    lc.append(req(
        "4.3 PUT object under tmp/ + HEAD shows expiry",
        "PUT", "{{s3_http}}/{{pm_lifecycle_bucket}}/tmp/scratch.txt",
        desc=("After the PUT, the follow-up HEAD is done by the test of this "
              "request? No — run request 4.4. The rule is live but deletion "
              "happens on the platform's periodic scan (~daily) — "
              "**configured, awaiting observation**, not claimed as expired."),
        auth=s3auth(),
        headers=[{"key": "Content-Type", "value": "text/plain"}],
        raw_body="expires tomorrow\n",
        tests=T_200))

    lc.append(req(
        "4.4 HEAD object - computed Expiration header",
        "HEAD", "{{s3_http}}/{{pm_lifecycle_bucket}}/tmp/scratch.txt",
        desc=("ObjectScale returns `Expiration: expiry-date=\"...\", "
              "rule-id=\"demo-pm-expire-tmp\"` once a matching rule exists — "
              "proof the rule is effective while the data still exists."),
        auth=s3auth(),
        tests=T_200 + """
var e = pm.response.headers.get('Expiration');
pm.test('Expiration header computed by engine', function(){
  pm.expect(e).to.not.be.empty;
  pm.expect(e).to.include('rule-id');
});"""))

    items.append(folder("40 — Lifecycle", lc, ""))

    # ------------------------------------------------------------------ #
    # 50 Management & monitoring
    # ------------------------------------------------------------------ #
    mgmt = []

    mgmt.append(req(
        "5.1 List namespaces",
        "GET", "{{mgmt_url}}/object/namespaces",
        desc="Management API on :4443 using the cached token.",
        headers=[{"key": "X-SDS-AUTH-TOKEN", "value": "{{mgmt_token}}"},
                 {"key": "Accept", "value": "application/json"}],
        tests=T_200 + """
pm.test('ns1 present', function(){ pm.expect(pm.response.text()).to.include('ns1'); });"""))

    mgmt.append(req(
        "5.2 List buckets",
        "GET", "{{mgmt_url}}/object/bucket?namespace={{namespace}}",
        headers=[{"key": "X-SDS-AUTH-TOKEN", "value": "{{mgmt_token}}"},
                 {"key": "Accept", "value": "application/json"}],
        tests=T_200))

    mgmt.append(req(
        "5.3 License features",
        "GET", "{{mgmt_url}}/license",
        headers=[{"key": "X-SDS-AUTH-TOKEN", "value": "{{mgmt_token}}"},
                 {"key": "Accept", "value": "application/json"}],
        tests=T_200 + """
pm.test('ViPR licensed', function(){ pm.expect(pm.response.text()).to.include('ViPR'); });"""))

    mgmt.append(req(
        "5.4 Cluster capacity (dashboard API)",
        "GET", "{{mgmt_url}}/dashboard/zones/localzone",
        desc="Capacity summary used by the portal dashboard.",
        headers=[{"key": "X-SDS-AUTH-TOKEN", "value": "{{mgmt_token}}"},
                 {"key": "Accept", "value": "application/json"}],
        tests=T_200 + """
pm.test('capacity data present', function(){
  pm.expect(pm.response.text()).to.include('diskSpaceTotalSummary');
});"""))

    mgmt.append(req(
        "5.5 Nodes list + capture first node",
        "GET", "{{mgmt_url}}/dashboard/zones/localzone/nodes",
        headers=[{"key": "X-SDS-AUTH-TOKEN", "value": "{{mgmt_token}}"},
                 {"key": "Accept", "value": "application/json"}],
        tests=T_200 + """
var m = pm.response.text().match(/dashboard\\/nodes\\/([a-f0-9-]+)/);
if (m) pm.environment.set('node_id', m[1]);"""))

    mgmt.append(req(
        "5.6 Node health detail",
        "GET", "{{mgmt_url}}/dashboard/nodes/{{node_id}}",
        headers=[{"key": "X-SDS-AUTH-TOKEN", "value": "{{mgmt_token}}"},
                 {"key": "Accept", "value": "application/json"}],
        tests=T_200 + """
pm.test('node health = Good', function(){
  pm.expect(pm.response.text()).to.include('Good');
});"""))

    mgmt.append(req(
        "5.7 VDCs (sites) — portal API",
        "GET", "{{portal_url}}/vdcs",
        desc=("Site topology: this lab returns exactly one VDC (`vdc1`) — the "
              "proof point for 'single site, multisite is documented not "
              "live'."),
        headers=[{"key": "X-SDS-AUTH-TOKEN", "value": "{{ui_token}}"},
                 {"key": "X-XSRF-TOKEN", "value": "{{xsrf_token}}"},
                 {"key": "Cookie", "value": "XSRF-TOKEN={{xsrf_token}}; ECSAuthToken={{ui_token}}"},
                 {"key": "Accept", "value": "application/json"}],
        tests=T_200 + """
var j = pm.response.json();
pm.test('single site (expected in this lab)', function(){
  pm.expect(j.data.length).to.eql(1);
  pm.expect(j.data[0].vdcName).to.eql('vdc1');
});"""))

    mgmt.append(req(
        "5.8 Replication groups — portal API",
        "GET", "{{portal_url}}/replicationgroups",
        headers=[{"key": "X-SDS-AUTH-TOKEN", "value": "{{ui_token}}"},
                 {"key": "X-XSRF-TOKEN", "value": "{{xsrf_token}}"},
                 {"key": "Cookie", "value": "XSRF-TOKEN={{xsrf_token}}; ECSAuthToken={{ui_token}}"},
                 {"key": "Accept", "value": "application/json"}],
        tests=T_200 + """
var j = pm.response.json();
pm.test('rg1 spans 1 zone', function(){
  pm.expect(j.data[0].vdcStoragePools.length).to.eql(1);
});"""))

    mgmt.append(req(
        "5.9 Alert policies — portal API",
        "GET", "{{portal_url}}/alertpolicy/list",
        headers=[{"key": "X-SDS-AUTH-TOKEN", "value": "{{ui_token}}"},
                 {"key": "X-XSRF-TOKEN", "value": "{{xsrf_token}}"},
                 {"key": "Cookie", "value": "XSRF-TOKEN={{xsrf_token}}; ECSAuthToken={{ui_token}}"},
                 {"key": "Accept", "value": "application/json"}],
        tests=T_200 + """
var j = pm.response.json();
pm.test('system alert policies enabled', function(){
  pm.expect(j.data.length).to.be.above(5);
});"""))

    mgmt.append(req(
        "5.10 SNMP targets — portal API",
        "GET", "{{portal_url}}/snmp",
        desc="Empty list is expected — no SNMP target configured in this lab; the API path exists for integration.",
        headers=[{"key": "X-SDS-AUTH-TOKEN", "value": "{{ui_token}}"},
                 {"key": "X-XSRF-TOKEN", "value": "{{xsrf_token}}"},
                 {"key": "Cookie", "value": "XSRF-TOKEN={{xsrf_token}}; ECSAuthToken={{ui_token}}"},
                 {"key": "Accept", "value": "application/json"}],
        tests=T_200))

    mgmt.append(req(
        "5.11 IAM ListUsers — portal /iam proxy",
        "POST", "{{portal_url}}/iam",
        desc=("AWS-style IAM query API. Namespace supplied via "
              "`x-emc-namespace` header + `Namespace` form field."),
        headers=[
            {"key": "X-SDS-AUTH-TOKEN", "value": "{{ui_token}}"},
            {"key": "X-XSRF-TOKEN", "value": "{{xsrf_token}}"},
            {"key": "Cookie", "value": "XSRF-TOKEN={{xsrf_token}}; ECSAuthToken={{ui_token}}"},
            {"key": "x-emc-namespace", "value": "{{namespace}}"},
            {"key": "Content-Type", "value": "application/x-www-form-urlencoded"}],
        raw_body="Action=ListUsers&Namespace={{namespace}}",
        tests=T_200 + """
pm.test('demo-reader listed', function(){
  pm.expect(pm.response.text()).to.include('demo-reader');
});"""))

    items.append(folder("50 — Management & monitoring APIs", mgmt,
        "Capacity, health, topology, alerts, IAM listing."))

    # ------------------------------------------------------------------ #
    # 80 Cleanup
    # ------------------------------------------------------------------ #
    cl = []

    cl.append(req(
        "8.1 Delete bucket policy on {{pm_bucket}}",
        "DELETE", "{{s3_http}}/{{pm_bucket}}?policy",
        desc=("Removed **first** — the DenyDeleteProtected statement would "
              "otherwise block deleting `protected/*`."),
        auth=s3auth(), tests=T_STATUS_2XX))

    cl.append(req(
        "8.2 List object versions (build delete payload)",
        "GET", "{{s3_http}}/{{pm_bucket}}?versions",
        desc=("Bucket has versioning enabled — every object may have versions "
              "and delete markers. The test script parses every "
              "Key/VersionId pair into `{{delete_body}}` for the next "
              "request."),
        auth=s3auth(),
        tests=T_200 + """
var xml = '<Delete>';
var re = /<Key>([^<]+)<\/Key><VersionId>([^<]+)<\/VersionId>/g, m;
while ((m = re.exec(pm.response.text()))) {
  xml += '<Object><Key>'+m[1]+'</Key><VersionId>'+m[2]+'</VersionId></Object>';
}
xml += '</Delete>';
pm.environment.set('delete_body', xml);
pm.test('objects parsed into delete payload', function(){
  pm.expect(xml).to.include('<Object>');
});"""))

    cl.append(req(
        "8.3 Batch-delete all versions + markers",
        "POST", "{{s3_http}}/{{pm_bucket}}?delete",
        auth=s3auth(),
        headers=[{"key": "Content-Type", "value": "application/xml"}],
        raw_body="{{delete_body}}",
        tests=T_200))

    cl.append(req(
        "8.4 Delete lifecycle object + config",
        "DELETE", "{{s3_http}}/{{pm_lifecycle_bucket}}/tmp/scratch.txt",
        auth=s3auth(), tests=T_STATUS_2XX))

    cl.append(req(
        "8.5 Delete lifecycle configuration",
        "DELETE", "{{s3_http}}/{{pm_lifecycle_bucket}}?lifecycle",
        auth=s3auth(), tests=T_STATUS_2XX))

    cl.append(req(
        "8.6 Delete bucket {{pm_bucket}}",
        "DELETE", "{{s3_http}}/{{pm_bucket}}",
        auth=s3auth(), tests=T_STATUS_2XX))

    cl.append(req(
        "8.7 Delete bucket {{pm_lifecycle_bucket}}",
        "DELETE", "{{s3_http}}/{{pm_lifecycle_bucket}}",
        auth=s3auth(), tests=T_STATUS_2XX))

    cl.append(req(
        "8.8 ⚠ BLOCKED-UNTIL-EXPIRY — delete {{pm_lock_bucket}}",
        "DELETE", "{{s3_http}}/{{pm_lock_bucket}}",
        desc=("**Cannot succeed until the Object Lock retentions set in folder "
              "30 expire** (governance +2h, compliance +75m from run time) and "
              "all object versions + delete markers are removed. Until then "
              "this returns `409 BucketNotEmpty` — that is the correct, "
              "expected behavior; the test accepts it. After expiry, remove "
              "versions/markers (8.2/8.3 pattern against this bucket) then "
              "re-send. Governance leftovers need "
              "`x-amz-bypass-governance-retention:true`; compliance objects "
              "cannot be force-deleted — wait for expiry."),
        auth=s3auth("{{writer_access_key}}", "{{writer_secret_key}}"),
        tests="""
pm.test('bucket removed or correctly refused', function(){
  pm.expect(pm.response.code).to.be.oneOf([204, 409]);
  if (pm.response.code === 409) {
    pm.expect(pm.response.text()).to.include('BucketNotEmpty');
  }
});"""))

    items.append(folder("80 — Cleanup", cl,
        "Removes demo-pm-* resources. 8.6 is blocked by design until retention expires."))

    # ------------------------------------------------------------------ #
    # 90 Not-Postman scenes
    # ------------------------------------------------------------------ #
    items.append(folder("90 — Scenes outside Postman's reach", [],
        "## Scenes demonstrated only via CLI/portal (links to runbook)\n\n"
        "- **Scene 2 NFS multiprotocol** — needs a host NFS mount. Runbook: "
        "`scenes/scene2_nfs.sh`; mount `192.168.1.31:/ns1/demo-nfs-share`. "
        "Live-verified bidirectionally in `evidence/scene2_nfs.txt`.\n"
        "- **Scene 7 multisite active-active** — physical two-site behavior; "
        "this lab is single-VDC (see request 5.7). Runnable plan: "
        "`docs/scene7_multisite_plan.md`.\n"
        "- **Scene 9 Copy to Cloud** — requires an authorized external S3 "
        "destination + credentials; policy API exists (`POST /bucket/{b}/{ns}"
        "/copypolicy`, needs metadata-search bucket). BOM + procedure: "
        "`docs/scene9_copy_to_cloud.md`.\n"
        "- **Syslog/SNMP/webhook targets** — none provisioned in lab; APIs "
        "listed in folder 50."))

    collection = {
        "info": {
            "name": "Dell ObjectScale 4.3 — Presales Demo",
            "schema": "https://schema.getpostman.com/json/collection/v2.1.0/collection.json",
            "description": (
                "Repeatable ObjectScale demo. S3 requests use AWS Signature V4 "
                "(region `us-east-1`, service `s3`, path-style URLs — verified "
                "against this install). Management calls use the cached "
                "X-SDS-AUTH-TOKEN; portal calls use the session established in "
                "setup step 0.2/0.3.\n\nRun folders in order. See RUNBOOK.md "
                "and EVIDENCE_MATRIX.md for status and limitations — status "
                "labels here match them exactly."),
        },
        "item": items,
        "variable": [
            {"key": "demo_tag", "value": "postman"},
        ],
    }
    return collection


def build_environment():
    vals = [
        ("obs_host", "192.168.1.31", "default"),
        ("mgmt_url", "https://192.168.1.31:4443", "default"),
        ("portal_url", "https://192.168.1.31", "default"),
        ("s3_http", "http://192.168.1.31:9020", "default"),
        ("s3_https", "https://192.168.1.31:9021", "default"),
        ("namespace", "ns1", "default"),
        ("aws_region", "us-east-1", "default"),
        ("pm_bucket", "demo-pm-s3", "default"),
        ("pm_lock_bucket", "demo-pm-lock", "default"),
        ("pm_lifecycle_bucket", "demo-pm-lifecycle", "default"),
        ("mgmt_user", "root", "default"),
        ("mgmt_password", "", "secret"),
        ("access_key", "", "secret"),
        ("secret_key", "", "secret"),
        ("reader_access_key", "", "secret"),
        ("reader_secret_key", "", "secret"),
        ("writer_access_key", "", "secret"),
        ("writer_secret_key", "", "secret"),
        ("mgmt_token", "", "secret"),
        ("ui_token", "", "secret"),
        ("xsrf_token", "", "secret"),
        ("ui_session_key", "", "secret"),
        ("ui_session_cookie", "", "secret"),
        ("ecs_b64auth", "", "secret"),
        ("upload_id", "", "default"),
        ("mp_etag1", "", "default"),
        ("mp_etag2", "", "default"),
        ("presign_url", "", "default"),
        ("gov_vid", "", "default"),
        ("comp_vid", "", "default"),
        ("lock_retain", "", "default"),
        ("comp_retain", "", "default"),
        ("node_id", "", "default"),
    ]
    return {
        "name": "ObjectScale Lab",
        "values": [{"key": k, "value": v, "type": t, "enabled": True} for k, v, t in vals],
        "_postman_variable_scope": "environment",
        "_postman_exported_using": "OBS_Demo build_collection.py",
    }


if __name__ == "__main__":
    col = build_collection()
    env = build_environment()
    with open(os.path.join(HERE, "ObjectScale-Demo.postman_collection.json"), "w") as f:
        json.dump(col, f, indent=2)
    with open(os.path.join(HERE, "ObjectScale-Lab.postman_environment.json"), "w") as f:
        json.dump(env, f, indent=2)
    n_req = sum(len(fld.get("item", [])) for fld in col["item"])
    print(f"wrote collection ({len(col['item'])} folders, {n_req} requests) + environment")
