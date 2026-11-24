#!/usr/bin/env python3
"""App Store Connect automation for MoonCode (KimiCode).

Subcommands:
  fetch-profile  Find or create an active IOS_APP_STORE provisioning profile
                 matching the bundle ID and distribution certificate serial,
                 and install it into ~/Library/MobileDevice/Provisioning Profiles.
  submit         Wait for an uploaded build to finish processing, create/reuse
                 the target App Store version (AFTER_APPROVAL), write zh-Hans
                 What's New release notes, attach the build, and submit for
                 App Store review via the Review Submissions API.

Environment variables (authentication):
  ASC_ISSUER_ID         App Store Connect API Issuer ID (UUID)
  ASC_KEY_ID            App Store Connect API Key ID (10 chars)
  ASC_PRIVATE_KEY_PATH  Path to AuthKey_<KEY_ID>.p8 (preferred)
  ASC_PRIVATE_KEY       Raw PEM content of the .p8 private key (fallback)
"""

from __future__ import annotations

import argparse
import base64
import json
import os
import pathlib
import sys
import time
import urllib.error
import urllib.parse
import urllib.request
from typing import Any

import jwt

API_BASE = "https://api.appstoreconnect.apple.com/v1"
EDITABLE_VERSION_STATES = {
    "PREPARE_FOR_SUBMISSION",
    "DEVELOPER_REJECTED",
    "REJECTED",
    "METADATA_REJECTED",
    "INVALID_BINARY",
}
ACTIVE_LOCKED_VERSION_STATES = {
    "WAITING_FOR_REVIEW",
    "IN_REVIEW",
    "PENDING_DEVELOPER_RELEASE",
    "PENDING_APPLE_RELEASE",
    "PROCESSING_FOR_APP_STORE",
    "READY_FOR_SALE",
    "READY_FOR_DISTRIBUTION",
}


class ASCError(RuntimeError):
    """Error raised when App Store Connect API returns a failure."""

    def __init__(self, status: int, message: str, payload: Any = None) -> None:
        super().__init__(message)
        self.status = status
        self.payload = payload


def normalize_hex_serial(serial: str) -> str:
    cleaned = serial.strip().replace(":", "").replace(" ", "").lower()
    if cleaned.startswith("0x"):
        cleaned = cleaned[2:]
    if not cleaned:
        raise ValueError("Empty certificate serial number")
    return hex(int(cleaned, 16))[2:].upper()


def format_api_errors(status: int, body_text: str) -> str:
    try:
        data = json.loads(body_text)
    except json.JSONDecodeError:
        return f"HTTP {status}: {body_text.strip() or '(empty body)'}"

    errors = data.get("errors")
    if not isinstance(errors, list) or not errors:
        return f"HTTP {status}: {body_text.strip()}"

    lines = [f"HTTP {status} from App Store Connect API:"]
    for err in errors:
        code = err.get("code", "")
        title = err.get("title", "")
        detail = err.get("detail", "")
        source = err.get("source") or {}
        pointer = source.get("pointer") or source.get("parameter") or ""
        suffix = f" ({pointer})" if pointer else ""
        lines.append(f"  - [{code}] {title}: {detail}{suffix}")
    return "\n".join(lines)


class ASCClient:
    def __init__(
        self,
        issuer_id: str,
        key_id: str,
        private_key_pem: str,
        *,
        timeout: int = 30,
    ) -> None:
        self.issuer_id = issuer_id
        self.key_id = key_id
        self.private_key_pem = private_key_pem
        self.timeout = timeout
        self._token: str | None = None
        self._token_exp: float = 0.0

    @classmethod
    def from_env(cls) -> "ASCClient":
        issuer_id = os.environ.get("ASC_ISSUER_ID", "").strip()
        key_id = os.environ.get("ASC_KEY_ID", "").strip()
        key_path = os.environ.get("ASC_PRIVATE_KEY_PATH", "").strip()
        key_raw = os.environ.get("ASC_PRIVATE_KEY", "").strip()

        if key_path:
            private_key_pem = pathlib.Path(key_path).read_text(encoding="utf-8")
        elif key_raw:
            private_key_pem = key_raw.replace("\\n", "\n")
        else:
            raise SystemExit(
                "Missing ASC_PRIVATE_KEY_PATH or ASC_PRIVATE_KEY environment variable."
            )

        if not issuer_id or not key_id:
            raise SystemExit(
                "Missing ASC_ISSUER_ID or ASC_KEY_ID environment variable."
            )

        return cls(issuer_id=issuer_id, key_id=key_id, private_key_pem=private_key_pem)

    def _get_token(self) -> str:
        now = time.time()
        # Refresh proactively whenever less than 5 minutes remain (tokens live 20 min max).
        if self._token and now < self._token_exp - 300:
            return self._token

        exp = int(now) + 15 * 60
        payload = {
            "iss": self.issuer_id,
            "iat": int(now) - 10,
            "exp": exp,
            "aud": "appstoreconnect-v1",
        }
        headers = {"alg": "ES256", "kid": self.key_id, "typ": "JWT"}
        token = jwt.encode(payload, self.private_key_pem, algorithm="ES256", headers=headers)
        if isinstance(token, bytes):
            token = token.decode("utf-8")
        self._token = token
        self._token_exp = float(exp)
        return token

    def request(
        self,
        method: str,
        path_or_url: str,
        *,
        params: dict[str, Any] | None = None,
        body: dict[str, Any] | None = None,
        max_retries: int = 4,
    ) -> dict[str, Any]:
        if path_or_url.startswith("https://") or path_or_url.startswith("http://"):
            url = path_or_url
        else:
            url = f"{API_BASE}/{path_or_url.lstrip('/')}"

        if params:
            query = urllib.parse.urlencode(params, doseq=True)
            sep = "&" if "?" in url else "?"
            url = f"{url}{sep}{query}"

        data_bytes = None
        if body is not None:
            data_bytes = json.dumps(body).encode("utf-8")

        for attempt in range(max_retries + 1):
            req = urllib.request.Request(url, data=data_bytes, method=method.upper())
            req.add_header("Authorization", f"Bearer {self._get_token()}")
            req.add_header("Accept", "application/json")
            if data_bytes is not None:
                req.add_header("Content-Type", "application/json")

            try:
                with urllib.request.urlopen(req, timeout=self.timeout) as resp:
                    raw = resp.read().decode("utf-8")
                    if not raw:
                        return {}
                    return json.loads(raw)
            except urllib.error.HTTPError as exc:
                raw_err = exc.read().decode("utf-8", errors="replace")
                if exc.code in (429, 500, 502, 503, 504) and attempt < max_retries:
                    retry_after = exc.headers.get("Retry-After")
                    delay = float(retry_after) if retry_after and retry_after.isdigit() else (2**attempt) * 2
                    print(
                        f"[ASC] Transient HTTP {exc.code} on {method} {url}, retrying in {delay:.0f}s...",
                        file=sys.stderr,
                    )
                    time.sleep(delay)
                    continue
                raise ASCError(exc.code, format_api_errors(exc.code, raw_err), raw_err) from exc
            except urllib.error.URLError as exc:
                if attempt < max_retries:
                    delay = (2**attempt) * 2
                    print(
                        f"[ASC] Network error ({exc.reason}) on {method} {url}, retrying in {delay:.0f}s...",
                        file=sys.stderr,
                    )
                    time.sleep(delay)
                    continue
                raise ASCError(0, f"Network error calling {method} {url}: {exc.reason}") from exc

        raise ASCError(0, f"Exhausted retries calling {method} {url}")

    def paginate(
        self, path: str, *, params: dict[str, Any] | None = None
    ) -> tuple[list[dict[str, Any]], list[dict[str, Any]]]:
        items: list[dict[str, Any]] = []
        included: list[dict[str, Any]] = []
        resp = self.request("GET", path, params=params)
        items.extend(resp.get("data") or [])
        included.extend(resp.get("included") or [])
        next_url = (resp.get("links") or {}).get("next")
        while next_url:
            resp = self.request("GET", next_url)
            items.extend(resp.get("data") or [])
            included.extend(resp.get("included") or [])
            next_url = (resp.get("links") or {}).get("next")
        return items, included


# ---------------------------------------------------------------------------
# Subcommand: fetch-profile
# ---------------------------------------------------------------------------


def find_bundle_id_resource(client: ASCClient, bundle_id: str) -> dict[str, Any]:
    items, _ = client.paginate(
        "bundleIds",
        params={"filter[identifier]": bundle_id, "filter[platform]": "IOS", "limit": 200},
    )
    for item in items:
        if (item.get("attributes") or {}).get("identifier") == bundle_id:
            return item
    raise SystemExit(
        f"Bundle ID '{bundle_id}' (iOS) not found in App Store Connect."
    )


def find_certificate_by_serial(client: ASCClient, cert_serial: str) -> dict[str, Any]:
    target = normalize_hex_serial(cert_serial)
    items, _ = client.paginate(
        "certificates",
        params={
            "filter[certificateType]": "DISTRIBUTION,IOS_DISTRIBUTION",
            "limit": 200,
        },
    )
    for item in items:
        raw_serial = (item.get("attributes") or {}).get("serialNumber") or ""
        if raw_serial and normalize_hex_serial(raw_serial) == target:
            return item
    available = [
        f"{(i.get('attributes') or {}).get('name')} (serial={(i.get('attributes') or {}).get('serialNumber')})"
        for i in items
    ]
    raise SystemExit(
        f"Distribution certificate with serial {target} not found in App Store Connect.\n"
        f"Available distribution certificates: {available or '(none)'}"
    )


def fetch_or_create_profile(
    client: ASCClient,
    *,
    bundle_id: str,
    cert_serial: str,
    profile_name: str,
    install_dir: pathlib.Path,
    dry_run: bool = False,
) -> tuple[str, str, pathlib.Path]:
    bundle_res = find_bundle_id_resource(client, bundle_id)
    bundle_res_id = bundle_res["id"]
    cert_res = find_certificate_by_serial(client, cert_serial)
    cert_res_id = cert_res["id"]
    print(
        f"[Profile] Matched Bundle ID {bundle_id} ({bundle_res_id}) "
        f"and Certificate {(cert_res.get('attributes') or {}).get('name')} ({cert_res_id})"
    )

    profiles, _ = client.paginate(
        "profiles",
        params={
            "filter[profileType]": "IOS_APP_STORE",
            "include": "bundleId,certificates",
            "limit": 200,
        },
    )

    matching_active: list[dict[str, Any]] = []
    same_name_stale: list[dict[str, Any]] = []

    for prof in profiles:
        attrs = prof.get("attributes") or {}
        rels = prof.get("relationships") or {}
        p_bundle = ((rels.get("bundleId") or {}).get("data") or {}).get("id")
        p_certs = {c.get("id") for c in ((rels.get("certificates") or {}).get("data") or [])}
        p_name = attrs.get("name") or ""
        p_state = attrs.get("profileState") or ""

        if p_bundle == bundle_res_id and cert_res_id in p_certs and p_state == "ACTIVE":
            matching_active.append(prof)
        elif p_name == profile_name:
            same_name_stale.append(prof)

    chosen: dict[str, Any] | None = None
    if matching_active:
        # Prefer the dedicated CI profile name if present, else any active matching profile.
        matching_active.sort(
            key=lambda p: (0 if (p.get("attributes") or {}).get("name") == profile_name else 1)
        )
        chosen = matching_active[0]
        chosen_attrs = chosen["attributes"]
        print(
            f"[Profile] Reusing active IOS_APP_STORE profile "
            f"'{chosen_attrs['name']}' (UUID={chosen_attrs['uuid']})"
        )
    else:
        if dry_run:
            print(
                f"[Profile][dry-run] Would delete {len(same_name_stale)} stale profile(s) named '{profile_name}' "
                f"and create a new IOS_APP_STORE profile for {bundle_id}."
            )
            return "DRY-RUN-UUID", profile_name, install_dir / "DRY-RUN-UUID.mobileprovision"

        for stale in same_name_stale:
            stale_id = stale["id"]
            print(f"[Profile] Deleting stale profile '{profile_name}' ({stale_id})...")
            client.request("DELETE", f"profiles/{stale_id}")

        print(f"[Profile] Creating IOS_APP_STORE profile '{profile_name}'...")
        resp = client.request(
            "POST",
            "profiles",
            body={
                "data": {
                    "type": "profiles",
                    "attributes": {
                        "name": profile_name,
                        "profileType": "IOS_APP_STORE",
                    },
                    "relationships": {
                        "bundleId": {"data": {"type": "bundleIds", "id": bundle_res_id}},
                        "certificates": {"data": [{"type": "certificates", "id": cert_res_id}]},
                    },
                }
            },
        )
        chosen = resp["data"]
        print(
            f"[Profile] Created profile '{chosen['attributes']['name']}' "
            f"(UUID={chosen['attributes']['uuid']})"
        )

    attrs = chosen["attributes"]
    uuid = attrs["uuid"]
    name = attrs["name"]
    content_b64 = attrs["profileContent"]

    out_path = install_dir / f"{uuid}.mobileprovision"
    if not dry_run:
        install_dir.mkdir(parents=True, exist_ok=True)
        out_path.write_bytes(base64.b64decode(content_b64))
        print(f"[Profile] Installed provisioning profile to {out_path}")

    return uuid, name, out_path


# ---------------------------------------------------------------------------
# Subcommand: submit
# ---------------------------------------------------------------------------


def find_app(client: ASCClient, bundle_id: str) -> dict[str, Any]:
    items, _ = client.paginate("apps", params={"filter[bundleId]": bundle_id, "limit": 50})
    for item in items:
        if (item.get("attributes") or {}).get("bundleId") == bundle_id:
            return item
    raise SystemExit(f"App with bundle ID '{bundle_id}' not found in App Store Connect.")


def wait_for_build(
    client: ASCClient,
    *,
    app_id: str,
    version: str,
    build_number: str,
    timeout_seconds: int,
    poll_interval: int,
) -> dict[str, Any]:
    deadline = time.monotonic() + timeout_seconds
    attempt = 0

    while True:
        attempt += 1
        resp = client.request(
            "GET",
            "builds",
            params={
                "filter[app]": app_id,
                "filter[preReleaseVersion.version]": version,
                "filter[version]": build_number,
                "limit": 10,
            },
        )
        builds = resp.get("data") or []
        if builds:
            # Prefer newest uploadedDate if multiple records ever exist.
            builds.sort(
                key=lambda b: (b.get("attributes") or {}).get("uploadedDate") or "",
                reverse=True,
            )
            build = builds[0]
            attrs = build.get("attributes") or {}
            state = attrs.get("processingState") or "UNKNOWN"
            expired = bool(attrs.get("expired"))
            print(
                f"[Build] Poll #{attempt}: id={build['id']} version={version} ({build_number}) "
                f"state={state} expired={expired}"
            )
            if expired:
                raise SystemExit(f"Build {version} ({build_number}) is marked expired.")
            if state == "VALID":
                return build
            if state in ("FAILED", "INVALID"):
                raise SystemExit(
                    f"Build {version} ({build_number}) failed App Store Connect processing (state={state})."
                )
        else:
            print(
                f"[Build] Poll #{attempt}: build {version} ({build_number}) not visible in ASC yet..."
            )

        if time.monotonic() >= deadline:
            raise SystemExit(
                f"Timed out after {timeout_seconds}s waiting for build {version} ({build_number}) to become VALID."
            )
        time.sleep(poll_interval)


def ensure_app_store_version(
    client: ASCClient,
    *,
    app_id: str,
    version: str,
    release_type: str,
    dry_run: bool,
) -> dict[str, Any]:
    versions, _ = client.paginate(
        f"apps/{app_id}/appStoreVersions",
        params={"filter[platform]": "IOS", "limit": 50},
    )

    existing_exact: dict[str, Any] | None = None
    other_editable: list[dict[str, Any]] = []

    for ver in versions:
        attrs = ver.get("attributes") or {}
        v_str = attrs.get("versionString") or ""
        state = attrs.get("appStoreState") or attrs.get("appVersionState") or ""
        if v_str == version:
            existing_exact = ver
            break
        if state in EDITABLE_VERSION_STATES:
            other_editable.append(ver)

    if existing_exact is not None:
        attrs = existing_exact.get("attributes") or {}
        state = attrs.get("appStoreState") or attrs.get("appVersionState") or ""
        if state in ACTIVE_LOCKED_VERSION_STATES:
            raise SystemExit(
                f"App Store version {version} already exists in locked state '{state}'. "
                "Aborting to avoid disrupting an active review or live release."
            )
        if state not in EDITABLE_VERSION_STATES:
            raise SystemExit(
                f"App Store version {version} is in unexpected state '{state}'."
            )

        print(
            f"[Version] Reusing existing App Store version {version} "
            f"(id={existing_exact['id']}, state={state})"
        )
        if attrs.get("releaseType") != release_type:
            if dry_run:
                print(
                    f"[Version][dry-run] Would PATCH releaseType from {attrs.get('releaseType')} to {release_type}"
                )
            else:
                client.request(
                    "PATCH",
                    f"appStoreVersions/{existing_exact['id']}",
                    body={
                        "data": {
                            "type": "appStoreVersions",
                            "id": existing_exact["id"],
                            "attributes": {"releaseType": release_type},
                        }
                    },
                )
                print(f"[Version] Updated releaseType to {release_type}")
        return existing_exact

    if other_editable:
        blocking = [
            f"{(v.get('attributes') or {}).get('versionString')} "
            f"({(v.get('attributes') or {}).get('appStoreState') or (v.get('attributes') or {}).get('appVersionState')})"
            for v in other_editable
        ]
        raise SystemExit(
            f"Cannot create version {version} because another editable iOS version already exists: {', '.join(blocking)}. "
            "Please delete/rename it in App Store Connect or push the matching version tag."
        )

    if dry_run:
        print(
            f"[Version][dry-run] Would create iOS App Store version {version} with releaseType={release_type}"
        )
        return {"id": "DRY-RUN-VERSION-ID", "attributes": {"versionString": version}}

    resp = client.request(
        "POST",
        "appStoreVersions",
        body={
            "data": {
                "type": "appStoreVersions",
                "attributes": {
                    "platform": "IOS",
                    "versionString": version,
                    "releaseType": release_type,
                },
                "relationships": {
                    "app": {"data": {"type": "apps", "id": app_id}},
                },
            }
        },
    )
    created = resp["data"]
    print(
        f"[Version] Created iOS App Store version {version} "
        f"(id={created['id']}, releaseType={release_type})"
    )
    return created


def update_whats_new(
    client: ASCClient,
    *,
    version_id: str,
    locale: str,
    whats_new: str,
    dry_run: bool,
) -> None:
    text = whats_new.strip()
    if not text:
        raise SystemExit("Release notes (whatsNew) cannot be empty.")
    if len(text) > 4000:
        raise SystemExit(
            f"Release notes length ({len(text)}) exceeds Apple's 4000-character limit."
        )

    if dry_run and version_id == "DRY-RUN-VERSION-ID":
        print(f"[Locale][dry-run] Would set {locale} whatsNew ({len(text)} chars):\n{text}")
        return

    locs, _ = client.paginate(
        f"appStoreVersions/{version_id}/appStoreVersionLocalizations",
        params={"limit": 50},
    )
    target_loc = next(
        (loc for loc in locs if (loc.get("attributes") or {}).get("locale") == locale),
        None,
    )

    if target_loc is not None:
        loc_id = target_loc["id"]
        if dry_run:
            print(
                f"[Locale][dry-run] Would PATCH localization {locale} ({loc_id}) whatsNew ({len(text)} chars)."
            )
            return
        client.request(
            "PATCH",
            f"appStoreVersionLocalizations/{loc_id}",
            body={
                "data": {
                    "type": "appStoreVersionLocalizations",
                    "id": loc_id,
                    "attributes": {"whatsNew": text},
                }
            },
        )
        print(f"[Locale] Updated {locale} whatsNew ({len(text)} chars).")
    else:
        if dry_run:
            print(
                f"[Locale][dry-run] Would POST new localization {locale} with whatsNew ({len(text)} chars)."
            )
            return
        client.request(
            "POST",
            "appStoreVersionLocalizations",
            body={
                "data": {
                    "type": "appStoreVersionLocalizations",
                    "attributes": {"locale": locale, "whatsNew": text},
                    "relationships": {
                        "appStoreVersion": {
                            "data": {"type": "appStoreVersions", "id": version_id}
                        }
                    },
                }
            },
        )
        print(f"[Locale] Created localization {locale} with whatsNew ({len(text)} chars).")


def attach_build(
    client: ASCClient,
    *,
    version_id: str,
    build_id: str,
    dry_run: bool,
) -> None:
    if dry_run:
        print(f"[Build][dry-run] Would attach build {build_id} to version {version_id}.")
        return
    client.request(
        "PATCH",
        f"appStoreVersions/{version_id}/relationships/build",
        body={"data": {"type": "builds", "id": build_id}},
    )
    print(f"[Build] Attached build {build_id} to App Store version {version_id}.")


def submit_version_for_review(
    client: ASCClient,
    *,
    app_id: str,
    version_id: str,
    dry_run: bool,
) -> None:
    existing_subs, _ = client.paginate(
        f"apps/{app_id}/reviewSubmissions",
        params={
            "filter[platform]": "IOS",
            "filter[state]": "READY_FOR_REVIEW,WAITING_FOR_REVIEW,IN_REVIEW,UNRESOLVED_ISSUES",
            "limit": 20,
        },
    )

    reusable_sub_id: str | None = None
    for sub in existing_subs:
        state = (sub.get("attributes") or {}).get("state") or ""
        if state in ("WAITING_FOR_REVIEW", "IN_REVIEW"):
            raise SystemExit(
                f"An iOS review submission ({sub['id']}) is already in state '{state}'. "
                "Aborting to avoid disturbing the active review queue."
            )
        if state == "READY_FOR_REVIEW" and reusable_sub_id is None:
            reusable_sub_id = sub["id"]

    if dry_run:
        action = (
            f"reuse READY_FOR_REVIEW submission {reusable_sub_id}"
            if reusable_sub_id
            else "create a new reviewSubmission"
        )
        print(
            f"[Review][dry-run] Would {action}, attach version {version_id}, and PATCH submitted=true."
        )
        return

    if reusable_sub_id is None:
        resp = client.request(
            "POST",
            "reviewSubmissions",
            body={
                "data": {
                    "type": "reviewSubmissions",
                    "attributes": {"platform": "IOS"},
                    "relationships": {
                        "app": {"data": {"type": "apps", "id": app_id}},
                    },
                }
            },
        )
        submission_id = resp["data"]["id"]
        print(f"[Review] Created reviewSubmission {submission_id}")
    else:
        submission_id = reusable_sub_id
        print(f"[Review] Reusing READY_FOR_REVIEW reviewSubmission {submission_id}")

    # Check if version_id is already an item in this submission.
    items, _ = client.paginate(
        f"reviewSubmissions/{submission_id}/items",
        params={"include": "appStoreVersion", "limit": 50},
    )
    already_attached = any(
        (((item.get("relationships") or {}).get("appStoreVersion") or {}).get("data") or {}).get("id")
        == version_id
        for item in items
    )

    if not already_attached:
        client.request(
            "POST",
            "reviewSubmissionItems",
            body={
                "data": {
                    "type": "reviewSubmissionItems",
                    "relationships": {
                        "reviewSubmission": {
                            "data": {"type": "reviewSubmissions", "id": submission_id}
                        },
                        "appStoreVersion": {
                            "data": {"type": "appStoreVersions", "id": version_id}
                        },
                    },
                }
            },
        )
        print(f"[Review] Attached appStoreVersion {version_id} to reviewSubmission {submission_id}")
    else:
        print(f"[Review] appStoreVersion {version_id} already attached to reviewSubmission {submission_id}")

    client.request(
        "PATCH",
        f"reviewSubmissions/{submission_id}",
        body={
            "data": {
                "type": "reviewSubmissions",
                "id": submission_id,
                "attributes": {"submitted": True},
            }
        },
    )
    print(f"[Review] Submitted reviewSubmission {submission_id} for App Store review!")


# ---------------------------------------------------------------------------
# CLI entrypoint
# ---------------------------------------------------------------------------


def write_github_outputs(path: str | None, outputs: dict[str, str]) -> None:
    if not path:
        return
    with open(path, "a", encoding="utf-8") as fh:
        for k, v in outputs.items():
            fh.write(f"{k}={v}\n")


def build_parser() -> argparse.ArgumentParser:
    parser = argparse.ArgumentParser(description="App Store Connect automation for MoonCode")
    sub = parser.add_subparsers(dest="command", required=True)

    p_prof = sub.add_parser("fetch-profile", help="Fetch or create IOS_APP_STORE provisioning profile")
    p_prof.add_argument("--bundle-id", default="com.qinkun.kimicode")
    p_prof.add_argument("--cert-serial", required=True, help="Hex serial number of the imported distribution cert")
    p_prof.add_argument("--profile-name", default="KimiCode CI AppStore")
    p_prof.add_argument(
        "--install-dir",
        default=str(pathlib.Path.home() / "Library/MobileDevice/Provisioning Profiles"),
    )
    p_prof.add_argument("--github-output", default=os.environ.get("GITHUB_OUTPUT"))
    p_prof.add_argument("--dry-run", action="store_true")

    p_sub = sub.add_parser("submit", help="Wait for build, update release notes, and submit for review")
    p_sub.add_argument("--bundle-id", default="com.qinkun.kimicode")
    p_sub.add_argument("--version", required=True, help="MARKETING_VERSION, e.g. 1.9")
    p_sub.add_argument("--build-number", required=True, help="CURRENT_PROJECT_VERSION, e.g. 42")
    p_sub.add_argument("--locale", default="zh-Hans")
    p_sub.add_argument("--whats-new", default="", help="Inline release notes text")
    p_sub.add_argument("--whats-new-file", default="", help="File containing release notes text")
    p_sub.add_argument(
        "--release-type",
        default="AFTER_APPROVAL",
        choices=["AFTER_APPROVAL", "MANUAL"],
    )
    p_sub.add_argument("--wait-timeout", type=int, default=2400)
    p_sub.add_argument("--poll-interval", type=int, default=20)
    p_sub.add_argument("--skip-submit", action="store_true", help="Prepare version & attach build without submitting")
    p_sub.add_argument("--dry-run", action="store_true")

    return parser


def main(argv: list[str] | None = None) -> int:
    parser = build_parser()
    args = parser.parse_args(argv)
    client = ASCClient.from_env()

    if args.command == "fetch-profile":
        uuid, name, out_path = fetch_or_create_profile(
            client,
            bundle_id=args.bundle_id,
            cert_serial=args.cert_serial,
            profile_name=args.profile_name,
            install_dir=pathlib.Path(args.install_dir),
            dry_run=args.dry_run,
        )
        write_github_outputs(
            args.github_output,
            {
                "profile_uuid": uuid,
                "profile_name": name,
                "profile_path": str(out_path),
            },
        )
        return 0

    if args.command == "submit":
        if args.whats_new_file:
            whats_new = pathlib.Path(args.whats_new_file).read_text(encoding="utf-8")
        else:
            whats_new = args.whats_new

        if not whats_new.strip():
            raise SystemExit(
                "Release notes are empty. Please pass a non-empty annotated Git tag message "
                "(e.g. `git tag -a v1.9 -m '...'`) or --whats-new / --whats-new-file."
            )

        app = find_app(client, args.bundle_id)
        app_id = app["id"]
        print(f"[App] Found {args.bundle_id} (id={app_id})")

        build = wait_for_build(
            client,
            app_id=app_id,
            version=args.version,
            build_number=args.build_number,
            timeout_seconds=args.wait_timeout,
            poll_interval=args.poll_interval,
        )
        build_id = build["id"]

        version_res = ensure_app_store_version(
            client,
            app_id=app_id,
            version=args.version,
            release_type=args.release_type,
            dry_run=args.dry_run,
        )
        version_id = version_res["id"]

        update_whats_new(
            client,
            version_id=version_id,
            locale=args.locale,
            whats_new=whats_new,
            dry_run=args.dry_run,
        )

        attach_build(
            client,
            version_id=version_id,
            build_id=build_id,
            dry_run=args.dry_run,
        )

        if args.skip_submit:
            print("[Review] --skip-submit enabled: stopped before submitting for review.")
            return 0

        submit_version_for_review(
            client,
            app_id=app_id,
            version_id=version_id,
            dry_run=args.dry_run,
        )
        return 0

    return 1


if __name__ == "__main__":
    try:
        raise SystemExit(main())
    except ASCError as exc:
        print(str(exc), file=sys.stderr)
        raise SystemExit(1)
