"""Stage verified distributables in a separate draft; never publish source/evidence."""
import hashlib
import json
import os
from pathlib import Path
import re
import subprocess
import tempfile
import zipfile

REPO = "penguiin1/focoach-downloads"
QA = "qa-desktop-release-0.4.20-20261028"
TARGET = "v0.4.20"
SOURCE = "9473a581a072b57558b2973d19ca148636d6bfbf"
BASE = "v0.4.13"
BASE_FEED_HASH = "0d93be2daf6bd1be04ed85d5239f95806d9659d9a6277a39394ad8ce865ae4a9"
METADATA = {"installer-build.json", "source-inputs.json", "releases.win-x64.json", "assets.win-x64.json", "RELEASES-win-x64"}
BINARIES = {"Focoach.Desktop-win-x64-Setup.exe", "Focoach.Desktop-win-x64-Portable.zip"}


def allowed(name):
    return name in METADATA | BINARIES or bool(re.fullmatch(r"Focoach\.Desktop-\d+\.\d+\.\d+-win-x64-(?:full|delta)\.nupkg", name))


def gh(*args):
    return subprocess.check_output(["gh", *args], stderr=subprocess.DEVNULL)


def release(tag):
    return json.loads(gh("release", "view", tag, "--repo", REPO, "--json", "isDraft,tagName,assets"))


def guards():
    assert os.environ.get("GITHUB_REPOSITORY") == REPO
    assert release(QA)["isDraft"] is True
    candidate = release(TARGET)
    assert candidate["isDraft"] is True and candidate["tagName"] == TARGET


def download(tag, name, folder):
    folder.mkdir(parents=True, exist_ok=True)
    gh("release", "download", tag, "--repo", REPO, "--pattern", name, "--dir", str(folder))
    return folder / name


def digest(path):
    h = hashlib.sha256()
    with path.open("rb") as f:
        for chunk in iter(lambda: f.read(1024 * 1024), b""):
            h.update(chunk)
    return h.hexdigest()


def same(path, size, sha):
    assert type(size) is int and size > 0
    assert isinstance(sha, str) and re.fullmatch("[0-9a-f]{64}", sha)
    assert path.stat().st_size == size and digest(path) == sha


def publish_to_draft(path, size, sha):
    assert allowed(path.name)
    same(path, size, sha)
    guards()
    gh("release", "upload", TARGET, "--repo", REPO, str(path), "--clobber")
    result = next(x for x in release(TARGET)["assets"] if x["name"] == path.name)
    assert result["state"] == "uploaded" and result["size"] == size
    assert result["digest"] == "sha256:" + sha


def main():
    guards()
    run_id = os.environ["CANDIDATE_RUN_ID"]
    assert re.fullmatch("[1-9][0-9]*", run_id)
    run = json.loads(gh("api", f"repos/{REPO}/actions/runs/{run_id}"))
    assert run["status"] == "completed" and run["conclusion"] == "success"
    assert run["head_branch"] == "codex/desktop-release-0.4.20-native"
    evidence_name = f"windows-desktop-0.4.20-native-{run_id}-{run['run_attempt']}.zip"
    with tempfile.TemporaryDirectory(prefix="focoach-reviewed-stage-") as temporary:
        root = Path(temporary)
        evidence_path = download(QA, evidence_name, root / "private-proof")
        with zipfile.ZipFile(evidence_path) as z:
            proof = json.loads(z.read("evidence/native-release-success.json"))
            frozen = json.loads(z.read("evidence/source-input.json"))
        assert proof["status"] == "PASS" and proof["sourceCommit"] == SOURCE
        assert proof["version"] == "0.4.20" and proof["actualPublishedBase"] == "0.4.13"
        assert proof["nativeWindowsBuild"] is True and proof["fullPythonAndCSharpChecks"] == "PASS"
        assert proof["wpfAndAccountSmoke"] == proof["packagedAgentSmoke"] == proof["freshSetup"] == "PASS"
        assert proof["upgradeLoginAndHistoryPreserved"] is True and proof["publicPublication"] is False
        assert frozen["sourceCommit"] == SOURCE and frozen["trackedTreeClean"] is True
        assert frozen["sourceSHA256"] == "8a1824856dda831b571c5d6d34aaf98a5478173c1e5f450f0cc1f2f5539ecc09"
        assert frozen["baseArchiveCommit"] == "87219763024d3f3649fd71cfb77b4fc10cc52790"
        assert frozen["sourceRevisionSHA256"] == "5e15ce1b7c254e674912dfa31f1a118da8f762065e894f644c988b07c0564813"

        manifest_path = download(QA, "installer-build.json", root / "metadata")
        manifest = json.loads(manifest_path.read_text(encoding="utf-8-sig"))
        assert manifest["appVersion"] == "0.4.20" and manifest["sourceCommit"] == SOURCE
        assert manifest["sourceTreeDirty"] is False and manifest["sourceInputsVerifiedAcrossBuild"] is True
        assert manifest["sourceInputsSha256"] == "0aaefbe1d9b7e944364bd584c76ee6b5147097d79bf0dce124006567fb4f37dd"
        assert manifest["payloadUnchanged"] is True and manifest["installerFile"] == "Focoach.Desktop-win-x64-Setup.exe"
        feed_path = download(QA, "releases.win-x64.json", root / "metadata")
        feed = json.loads(feed_path.read_text(encoding="utf-8-sig"))
        base_path = download(BASE, "releases.win-x64.json", root / "base-metadata")
        assert digest(base_path) == BASE_FEED_HASH
        old = {x["FileName"]: x for x in json.loads(base_path.read_text(encoding="utf-8-sig"))["Assets"]}
        current = {x["FileName"]: x for x in feed["Assets"]}
        assert len(current) == len(feed["Assets"])
        for name, item in old.items():
            assert name in current and current[name]["Size"] == item["Size"]
            assert current[name]["SHA256"].lower() == item["SHA256"].lower()

        plans = []
        for name, item in current.items():
            assert allowed(name) and name.endswith(".nupkg")
            origin = QA if item["Version"] == "0.4.20" else BASE
            assert origin == QA or name in old
            plans.append((origin, name, item["Size"], item["SHA256"].lower()))
        assert any(name == "Focoach.Desktop-0.4.20-win-x64-full.nupkg" for _, name, _, _ in plans)
        artifacts = {x["file"]: x for x in manifest["artifacts"]}
        for name in BINARIES | (METADATA - {"installer-build.json"}):
            if name == "assets.win-x64.json" and name not in artifacts:
                continue
            item = artifacts[name]
            plans.append((QA, name, item["sizeBytes"], item["sha256"]))
        assert len({x[1] for x in plans}) == len(plans)
        for tag, name, size, sha in plans:
            assert allowed(name)
            folder = root / "one-artifact"
            path = download(tag, name, folder)
            publish_to_draft(path, size, sha)
            path.unlink()
        publish_to_draft(manifest_path, manifest_path.stat().st_size, digest(manifest_path))
        print(json.dumps({"status": "staged-unpublished", "distributables": len(plans) + 1, "source_or_evidence_published": False}))


if __name__ == "__main__":
    try:
        main()
    except Exception:
        raise SystemExit("Candidate staging failed; the separate QA source and evidence remain unpublished.")
