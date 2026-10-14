"""Offline model comparison on public snippets; not a production accuracy estimate."""
import argparse
import json
import math
import os
from pathlib import Path
import sys
import time

ROOT = Path(__file__).resolve().parents[1]
sys.path.insert(0, str(ROOT / "Sources/BitClipboard/SemanticRuntime"))


def evaluate(documents, queries, score_rows):
    if len(score_rows) != len(queries):
        raise ValueError("Expected one score row per query")
    ids = {document["id"] for document in documents}
    if len(ids) != len(documents):
        raise ValueError("Document IDs must be unique")
    results = []
    for query, scores in zip(queries, score_rows):
        relevant = set(query["relevant"])
        if not relevant.issubset(ids) or len(scores) != len(documents) or not all(math.isfinite(float(s)) for s in scores):
            raise ValueError("Invalid labels or model scores")
        ranked = sorted(zip(documents, scores), key=lambda pair: -float(pair[1]))
        k = len(relevant)
        selected = {document["id"] for document, _ in ranked[:k]} if k else set()
        results.append({
            "query": query["text"],
            "precision_at_expected_count": len(selected & relevant) / k if k else None,
            "missing_from_top_k": sorted(relevant - selected),
            "unexpected_in_top_k": sorted(selected - relevant),
            "ranking": [{"id": document["id"], "score": float(score)} for document, score in ranked],
        })
    return results


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--model", choices=["current", "google-full", "qwen", "e5", "reranker"], default="current")
    parser.add_argument("--runtime", type=Path, default=Path.home() / "Library/Application Support/BitClipboard/SemanticSearch")
    parser.add_argument("--cache-dir", type=Path, help="HF cache containing the alternative model's pinned snapshot")
    parser.add_argument("--cases", type=Path, default=ROOT / "Tests/SemanticRuntimeTests/search_cases.json")
    parser.add_argument("--output", type=Path, required=True)
    parser.add_argument("--require-perfect-recall", action="store_true", help="Fail if a labeled relevant snippet falls outside top-k")
    args = parser.parse_args()
    os.environ.update(HF_HUB_OFFLINE="1", TRANSFORMERS_OFFLINE="1", HF_HUB_DISABLE_TELEMETRY="1")
    import numpy as np
    import torch
    from sentence_transformers import CrossEncoder, SentenceTransformer
    from embedding_worker import DIMENSIONS, MODEL_ID, REVISION, encode, load_model

    torch.set_num_threads(4)
    fixture = json.loads(args.cases.read_text())
    documents, queries = fixture["documents"], fixture["queries"]
    texts, search_terms = [x["text"] for x in documents], [x["text"] for x in queries]
    started = time.monotonic()
    if args.model in {"current", "google-full"}:
        model_id, revision = MODEL_ID, REVISION
        model = load_model(args.runtime)
        if args.model == "current":
            # Exercise the actual shipped prompts, truncation and worker encoder.
            def batches(values, is_query):
                return np.array([row for start in range(0, len(values), 8)
                                 for row in encode(model, values[start:start + 8], is_query)])
            d = batches(["title: none | text: " + text for text in texts], False)
            q = batches(search_terms, True)
        else:
            d = model.encode_document(texts, normalize_embeddings=True, show_progress_bar=False)
            q = model.encode_query(search_terms, normalize_embeddings=True, show_progress_bar=False)
        # Re-normalize after truncation, as Swift's index does.
        d = d / np.linalg.norm(d, axis=1, keepdims=True)
        q = q / np.linalg.norm(q, axis=1, keepdims=True)
        scores = q @ d.T
    else:
        if args.cache_dir is None:
            parser.error("Alternative models require --cache-dir (download the pinned revision first).")
        model_id, revision = {
            "qwen": ("Qwen/Qwen3-Embedding-0.6B", "97b0c614be4d77ee51c0cef4e5f07c00f9eb65b3"),
            "e5": ("intfloat/multilingual-e5-small", "614241f622f53c4eeff9890bdc4f31cfecc418b3"),
            "reranker": ("Qwen/Qwen3-Reranker-0.6B", "e61197ed45024b0ed8a2d74b80b4d909f1255473"),
        }[args.model]
        snapshot = args.cache_dir / ("models--" + model_id.replace("/", "--")) / "snapshots" / revision
        if args.model == "reranker":
            model = CrossEncoder(str(snapshot), local_files_only=True, device="cpu", max_length=2048,
                                 model_kwargs={"torch_dtype": torch.float32}, trust_remote_code=False)
            scores = [model.predict([(query, text) for text in texts], batch_size=4,
                                    activation_fn=torch.nn.Sigmoid(), show_progress_bar=False) for query in search_terms]
        else:
            model = SentenceTransformer(str(snapshot), local_files_only=True, device="cpu",
                                        model_kwargs={"torch_dtype": torch.float32}, trust_remote_code=False)
            model.max_seq_length = 512 if args.model == "e5" else 2048
            if args.model == "qwen":
                model.tokenizer.padding_side = "left"
            d = model.encode(texts, prompt="passage: " if args.model == "e5" else "",
                             batch_size=4, normalize_embeddings=True, show_progress_bar=False)
            q = model.encode(search_terms, prompt="query: " if args.model == "e5" else model.prompts["query"],
                             batch_size=4, normalize_embeddings=True, show_progress_bar=False)
            scores = q @ d.T
    results = evaluate(documents, queries, scores)
    report = {"model": model_id, "revision": revision, "variant": args.model,
              "dimensions": DIMENSIONS if args.model == "current" else len(d[0]) if args.model != "reranker" else None,
              "elapsed_seconds": time.monotonic() - started, "queries": results}
    args.output.parent.mkdir(parents=True, exist_ok=True)
    args.output.write_text(json.dumps(report, ensure_ascii=False, indent=2) + "\n")
    for row in results:
        print(row["query"], "P@k:", row["precision_at_expected_count"], "missing:", row["missing_from_top_k"])
    if args.require_perfect_recall and any(row["missing_from_top_k"] for row in results):
        raise SystemExit(1)


if __name__ == "__main__":
    main()
