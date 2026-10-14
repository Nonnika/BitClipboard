"""Local, persistent JSON-lines worker. Clipboard text is never sent to a server."""
import argparse
import contextlib
import json
import os
from pathlib import Path
import sys

MODEL_ID = "google/embeddinggemma-2"
REVISION = "914f7f89142e33e77833254d9c9b90c3cef7303b"
DIMENSIONS = 256


def load_model(runtime, prepare=False):
    # All diagnostics go to stderr; stdout is exclusively the JSON protocol.
    with contextlib.redirect_stdout(sys.stderr):
        import torch
        from sentence_transformers import SentenceTransformer

        torch.set_num_threads(max(1, min(4, os.cpu_count() or 1)))
        model = SentenceTransformer(
            MODEL_ID,
            revision=REVISION,
            cache_folder=str(runtime / "models"),
            local_files_only=not prepare,
            device="cpu",
            config_kwargs={"vision_config": None, "audio_config": None},
            model_kwargs={"torch_dtype": torch.float32},
            trust_remote_code=False,
        )
        # Bound latency and memory; Swift splits long records into overlapping chunks.
        model.max_seq_length = 2048
        return model


def encode(model, texts, is_query):
    if not isinstance(texts, list) or not 1 <= len(texts) <= 8:
        raise ValueError("Invalid batch")
    # Swift chunks by grapheme; emoji can contain several Unicode code points.
    if any(not isinstance(text, str) or len(text) > 32768 for text in texts):
        raise ValueError("Invalid input")
    with contextlib.redirect_stdout(sys.stderr):
        output = model.encode(
            texts,
            prompt_name="SearchQuery" if is_query else None,
            # Documents already contain the title/text prefix.
            prompt="" if not is_query else None,
            batch_size=4,
            truncate_dim=DIMENSIONS,
            normalize_embeddings=True,
            show_progress_bar=False,
            convert_to_numpy=True,
        )
    vectors = output.tolist()
    # Reject NaNs rather than emitting plausible-looking invalid search results.
    json.dumps(vectors, allow_nan=False)
    return vectors


def serve(model, input_stream, output_stream):
    for line in input_stream:
        try:
            request = json.loads(line)
            vectors = encode(model, request["texts"], request["isQuery"])
            reply = {"vectors": vectors}
        except Exception:
            # Do not include clipboard text, exceptions or request bodies in logs.
            reply = {"error": "embedding_failed"}
        output_stream.write(json.dumps(reply, allow_nan=False) + "\n")
        output_stream.flush()


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument("--runtime", type=Path, required=True)
    parser.add_argument("--prepare", action="store_true")
    args = parser.parse_args()
    if not args.prepare:
        os.environ["HF_HUB_OFFLINE"] = "1"
        os.environ["TRANSFORMERS_OFFLINE"] = "1"
    os.environ["HF_HUB_DISABLE_TELEMETRY"] = "1"
    model = load_model(args.runtime, args.prepare)
    if args.prepare:
        encode(model, ["semantic search"], True)
        marker = args.runtime / "ready"
        marker.write_text(f"{MODEL_ID}@{REVISION}/{DIMENSIONS}\n")
        marker.chmod(0o600)
    else:
        serve(model, sys.stdin, sys.stdout)


if __name__ == "__main__":
    main()
