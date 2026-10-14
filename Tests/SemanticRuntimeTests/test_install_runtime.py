import io
import json
from pathlib import Path
import sys
from types import SimpleNamespace
import unittest
from unittest.mock import patch

RESOURCES = Path(__file__).resolve().parents[2] / "Sources/BitClipboard/SemanticRuntime"
sys.path.insert(0, str(RESOURCES))
import install_runtime


class ModelDownloadTests(unittest.TestCase):
    def test_actual_xet_progress_backend_reports_logical_bytes(self):
        try:
            from huggingface_hub.utils._xet_progress_reporting import XetDownloadProgressReporter
            from tqdm.auto import tqdm
        except ImportError:
            self.skipTest("Requires installed huggingface_hub")
        counts = []
        progress_class = install_runtime.tracking_tqdm(tqdm, counts.append)
        with XetDownloadProgressReporter(
            reconstruction_desc="model", transfer_desc="transfer", total=1000,
            log_level=30, tqdm_class=progress_class,
        ) as progress:
            progress.update_progress(SimpleNamespace(
                total_bytes_completed=500, total_transfer_bytes_completed=200,
                total_bytes_completion_rate=100, total_transfer_bytes_completion_rate=50, total_bytes=1000,
            ))
            progress.update_progress(SimpleNamespace(
                total_bytes_completed=1000, total_transfer_bytes_completed=400,
                total_bytes_completion_rate=100, total_transfer_bytes_completion_rate=50, total_bytes=1000,
            ))
        self.assertIn(500, counts)
        self.assertEqual(counts[-1], 1000)
        self.assertLessEqual(max(counts), 1000)

    def test_dependency_progress_uses_actual_bytes(self):
        output = io.StringIO()
        reporter = install_runtime.Reporter(output)
        self.assertTrue(install_runtime.pip_progress("Progress 50 of 100\n", "component", reporter))
        self.assertFalse(install_runtime.pip_progress("Installing packages", None, reporter))
        event = json.loads(output.getvalue().split(" ", 1)[1])
        self.assertEqual((event["completed"], event["total"]), (50, 100))

    def test_model_progress_counts_cached_files_and_each_download_once(self):
        output = io.StringIO()
        reporter = install_runtime.Reporter(output)
        files = [
            SimpleNamespace(filename="config.json", file_size=100, is_cached=True),
            SimpleNamespace(filename="model.safetensors", file_size=900, is_cached=False),
        ]
        class FakeProgress:
            def __init__(self, *args, **kwargs):
                self.n = kwargs.get("initial", 0)
                self.display()
            def update(self, n):
                self.n += n
                self.display()

        def download(repo_id, filename, **kwargs):
            self.assertEqual(repo_id, install_runtime.MODEL_ID)
            self.assertEqual(filename, "model.safetensors")
            self.assertEqual(kwargs["revision"], install_runtime.REVISION)
            progress = kwargs["tqdm_class"](total=900, initial=200)
            reporter.last_time = 0
            progress.update_transfer(400)  # Transport counters must not inflate logical bytes.
            progress.update(300)
            reporter.last_time = 0
            progress.update(400)

        hub = SimpleNamespace(snapshot_download=lambda *a, **kw: files, hf_hub_download=download)
        auto = SimpleNamespace(tqdm=FakeProgress)
        with patch.dict(sys.modules, {"huggingface_hub": hub, "tqdm": SimpleNamespace(), "tqdm.auto": auto}):
            install_runtime.download_model(Path("runtime"), reporter)
        events = [json.loads(line.split(" ", 1)[1]) for line in output.getvalue().splitlines()]
        byte_events = [event for event in events if event["completed"] is not None]
        self.assertEqual(byte_events[0]["completed"], 100)
        self.assertIn(600, [event["completed"] for event in byte_events])
        self.assertEqual(byte_events[-1]["completed"], 1000)
        self.assertTrue(all(event["total"] == 1000 and event["completed"] <= 1000 for event in byte_events))

    def test_download_failure_never_reports_completion(self):
        output = io.StringIO()
        reporter = install_runtime.Reporter(output)
        hub = SimpleNamespace(
            snapshot_download=lambda *a, **kw: [SimpleNamespace(filename="model", file_size=100, is_cached=False)],
            hf_hub_download=lambda *a, **kw: (_ for _ in ()).throw(ConnectionError("offline")),
        )
        with patch.dict(sys.modules, {"huggingface_hub": hub, "tqdm": SimpleNamespace(), "tqdm.auto": SimpleNamespace(tqdm=object)}):
            with self.assertRaises(ConnectionError):
                install_runtime.download_model(Path("runtime"), reporter)
        events = [json.loads(line.split(" ", 1)[1]) for line in output.getvalue().splitlines()]
        self.assertFalse(any(event["stage"] == "complete" for event in events))
        self.assertFalse(any(event["completed"] == 100 for event in events))


if __name__ == "__main__":
    unittest.main()
