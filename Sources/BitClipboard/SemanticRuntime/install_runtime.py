"""Install with real byte progress; only progress events go to stdout."""
import argparse
import json
import os
from pathlib import Path
import re
import signal
import subprocess
import sys
import threading
import time

from embedding_worker import MODEL_ID, REVISION

EVENT_PREFIX = "BITCLIPBOARD_INSTALL "


class Reporter:
    def __init__(self, stream=None):
        self.stream = stream if stream is not None else sys.stdout
        self.lock = threading.Lock()
        self.last_time = 0
        self.last_key = None

    def emit(self, stage, completed=None, total=None, filename=None, force=False):
        with self.lock:
            now = time.monotonic()
            key = (stage, filename)
            if not force and key == self.last_key and now - self.last_time < 0.2:
                return
            self.last_time, self.last_key = now, key
            event = {"stage": stage, "completed": completed, "total": total, "filename": filename}
            self.stream.write(EVENT_PREFIX + json.dumps(event, ensure_ascii=False) + "\n")
            self.stream.flush()


def pip_progress(line, filename, reporter):
    match = re.fullmatch(r"Progress (\d+) of (\d+)", line.strip())
    if match:
        completed, total = map(int, match.groups())
        reporter.emit("dependencies", completed, total, filename, force=completed == total)
        return True
    return False


def install_dependencies(reporter):
    reporter.emit("dependencies", force=True)
    requirements = Path(__file__).with_name("requirements.txt")
    child = subprocess.Popen(
        [sys.executable, "-m", "pip", "install", "--upgrade", "--progress-bar", "raw", "-r", str(requirements)],
        stdout=subprocess.PIPE, stderr=subprocess.STDOUT, text=True, bufsize=1,
    )
    def terminate(_signum, _frame):
        child.terminate()
        raise SystemExit(143)
    previous = signal.signal(signal.SIGTERM, terminate)
    try:
        filename = None
        for line in child.stdout:
            if line.lstrip().startswith(("Downloading ", "Resuming download ")):
                filename = line.strip().split(" (")[0].removeprefix("Downloading ").removeprefix("Resuming download ")
                reporter.emit("dependencies", filename=filename, force=True)
            if not pip_progress(line, filename, reporter):
                sys.stderr.write(line)
            if line.startswith("Installing collected packages:"):
                reporter.emit("dependencies", force=True)
        if child.wait() != 0:
            raise RuntimeError("Dependency installation failed")
    finally:
        signal.signal(signal.SIGTERM, previous)


def tracking_tqdm(base_class, report):
    class DownloadProgress(base_class):
        def __init__(self, *args, **kwargs):
            kwargs["disable"] = False
            kwargs["file"] = sys.stderr
            super().__init__(*args, **kwargs)

        def display(self, *args, **kwargs):
            report(getattr(self, "n", 0))

        def update(self, n=1):
            result = super().update(n)
            report(self.n)
            return result

        # Xet can report transfer and reconstruction separately. Count logical file bytes once.
        def update_transfer(self, *_args, **_kwargs):
            pass

        def set_transfer_postfix_str(self, *_args, **_kwargs):
            pass
    return DownloadProgress


def download_model(runtime, reporter):
    from huggingface_hub import hf_hub_download, snapshot_download
    from tqdm.auto import tqdm

    cache = runtime / "models"
    reporter.emit("download", force=True)
    files = snapshot_download(
        MODEL_ID, revision=REVISION, cache_dir=cache, dry_run=True,
        allow_patterns=["*.json", "*.safetensors", "*.model", "*.jinja"],
    )
    total = sum(file.file_size for file in files)
    completed = sum(file.file_size for file in files if file.is_cached)
    reporter.emit("download", completed, total, force=True)
    for file in files:
        if file.is_cached:
            continue
        # Capture each file's fixed base; callbacks must not depend on a later loop iteration.
        def report(n, base=completed, size=file.file_size, filename=file.filename):
            reporter.emit("download", base + min(size, max(0, int(n))), total, filename)
        hf_hub_download(
            MODEL_ID, file.filename, revision=REVISION, cache_dir=cache,
            tqdm_class=tracking_tqdm(tqdm, report),
        )
        completed += file.file_size
        reporter.emit("download", completed, total, file.filename, force=True)


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument("--runtime", type=Path, required=True)
    args = parser.parse_args()
    os.environ["HF_HUB_DISABLE_TELEMETRY"] = "1"
    reporter = Reporter()
    install_dependencies(reporter)
    # Even text-only inference initializes this model's multimodal processor.
    # Detect missing processor dependencies before downloading the large weights.
    subprocess.run(
        [sys.executable, "-c", "from transformers import EmbeddingGemma2Processor; from PIL import Image; from torchvision.transforms.v2 import functional"],
        stdout=sys.stderr, check=True,
    )
    download_model(args.runtime, reporter)
    reporter.emit("verifying", force=True)
    environment = dict(os.environ, HF_HUB_OFFLINE="1", TRANSFORMERS_OFFLINE="1")
    subprocess.run(
        [sys.executable, str(Path(__file__).with_name("embedding_worker.py")), "--runtime", str(args.runtime), "--prepare"],
        env=environment, stdout=sys.stderr, check=True,
    )
    reporter.emit("complete", force=True)


if __name__ == "__main__":
    main()
