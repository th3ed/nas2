"""news-ui: FastAPI + Jinja2 ops dashboard / article browser for the
news service. Mounted from a ConfigMap into a python:3.12-slim
container (mem0 library-mode pattern). No JS framework — plain HTML
forms drive everything; the kube python client triggers ad-hoc
ingest Jobs from the CronJob template."""
from __future__ import annotations

import logging
import os
from contextlib import contextmanager
from datetime import datetime, timezone
from pathlib import Path
from typing import Any

import psycopg2
import psycopg2.extras
from fastapi import FastAPI, HTTPException, Request, status
from fastapi.responses import HTMLResponse, RedirectResponse, PlainTextResponse
from jinja2 import Environment, FileSystemLoader, select_autoescape
from kubernetes import client, config

logging.basicConfig(
    level=logging.INFO,
    format="%(asctime)s %(levelname)s %(name)s %(message)s",
)
log = logging.getLogger("news-ui")

PG = dict(
    host=os.environ["PG_HOST"],
    port=int(os.environ.get("PG_PORT", "5432")),
    dbname=os.environ.get("PG_DB", "postgres"),
    user=os.environ.get("PG_USER", "postgres"),
    password=os.environ["POSTGRES_PASSWORD"],
)
NAMESPACE = os.environ.get("NEWS_NAMESPACE", "news")
CRONJOB_NAME = os.environ.get("INGEST_CRONJOB", "news-ingest")
FORCE_RESYNC_ENABLED = os.environ.get("FORCE_RESYNC_ENABLED", "true").lower() == "true"
PAGE_SIZE = 25

TEMPLATE_DIR = Path(__file__).resolve().parent
env = Environment(
    loader=FileSystemLoader(str(TEMPLATE_DIR)),
    autoescape=select_autoescape(["html"]),
    trim_blocks=True,
    lstrip_blocks=True,
)
env.filters["isoshort"] = lambda dt: dt.strftime("%Y-%m-%d %H:%M") if dt else "—"


@contextmanager
def pg_conn():
    conn = psycopg2.connect(**PG)
    try:
        yield conn
    finally:
        conn.close()


app = FastAPI(title="news-ui", docs_url=None, redoc_url=None)


@app.get("/healthz", response_class=PlainTextResponse)
def healthz() -> str:
    with pg_conn() as conn:
        with conn.cursor() as cur:
            cur.execute("SELECT 1")
            cur.fetchone()
    return "ok"


@app.get("/", response_class=HTMLResponse)
def dashboard(request: Request) -> HTMLResponse:
    with pg_conn() as conn:
        with conn.cursor(cursor_factory=psycopg2.extras.DictCursor) as cur:
            cur.execute(
                "SELECT id, started_at, finished_at, status, items_fetched, "
                "       items_inserted, chunks_inserted, chunks_dedup, trigger, "
                "       metrics, errors "
                "FROM ingest_runs ORDER BY started_at DESC LIMIT 20"
            )
            runs = [dict(r) for r in cur.fetchall()]
            cur.execute(
                "SELECT count(*) AS total, "
                "       count(*) FILTER (WHERE extraction_status='ok') AS ok, "
                "       count(*) FILTER (WHERE summary IS NOT NULL) AS summarized "
                "FROM articles"
            )
            a_stats = dict(cur.fetchone())
            cur.execute(
                "SELECT count(*) AS chunks, "
                "       count(*) FILTER (WHERE citation_ct>1) AS multi_cite "
                "FROM chunks"
            )
            c_stats = dict(cur.fetchone())
            cur.execute(
                "SELECT last_successful_run_at, last_article_published_at, "
                "       backfill_completed FROM ingest_state WHERE id=1"
            )
            state = dict(cur.fetchone())
    html = env.get_template("index.html").render(
        runs=runs,
        article_stats=a_stats,
        chunk_stats=c_stats,
        ingest_state=state,
        force_resync_enabled=FORCE_RESYNC_ENABLED,
        now=datetime.now(timezone.utc),
    )
    return HTMLResponse(html)


@app.post("/api/ingest/run")
def run_ingest_now() -> RedirectResponse:
    if not FORCE_RESYNC_ENABLED:
        raise HTTPException(403, "Manual ingest disabled via FORCE_RESYNC_ENABLED")
    config.load_incluster_config()
    batch = client.BatchV1Api()
    try:
        cj = batch.read_namespaced_cron_job(CRONJOB_NAME, NAMESPACE)
    except client.ApiException as exc:
        raise HTTPException(500, f"failed to read CronJob: {exc}") from exc
    ts = int(datetime.now(timezone.utc).timestamp())
    job_name = f"{CRONJOB_NAME}-manual-{ts}"
    job = client.V1Job(
        api_version="batch/v1",
        kind="Job",
        metadata=client.V1ObjectMeta(
            name=job_name,
            namespace=NAMESPACE,
            annotations={"news-ui/manual-trigger": "true"},
        ),
        spec=cj.spec.job_template.spec,
    )
    try:
        batch.create_namespaced_job(NAMESPACE, job)
    except client.ApiException as exc:
        raise HTTPException(500, f"failed to create Job: {exc}") from exc
    return RedirectResponse("/", status_code=status.HTTP_303_SEE_OTHER)


@app.get("/articles", response_class=HTMLResponse)
def articles_list(
    request: Request,
    q: str | None = None,
    feed: str | None = None,
    only_unread: bool = False,
    page: int = 1,
) -> HTMLResponse:
    page = max(1, page)
    offset = (page - 1) * PAGE_SIZE
    where = ["extraction_status='ok'"]
    params: list[Any] = []
    if q:
        where.append("(title ILIKE %s OR summary ILIKE %s)")
        like = f"%{q}%"
        params.extend([like, like])
    if feed:
        where.append("feed_title ILIKE %s")
        params.append(f"%{feed}%")
    if only_unread:
        where.append("read = false")
    where_sql = " AND ".join(where)
    sql_articles = (
        f"SELECT id, title, url, summary, published_at, feed_title, category, "
        f"       read, starred "
        f"FROM articles WHERE {where_sql} "
        f"ORDER BY published_at DESC LIMIT %s OFFSET %s"
    )
    sql_count = f"SELECT count(*) FROM articles WHERE {where_sql}"
    with pg_conn() as conn:
        with conn.cursor(cursor_factory=psycopg2.extras.DictCursor) as cur:
            cur.execute(sql_articles, [*params, PAGE_SIZE, offset])
            rows = [dict(r) for r in cur.fetchall()]
            cur.execute(sql_count, params)
            total = cur.fetchone()[0]
    html = env.get_template("articles.html").render(
        articles=rows,
        q=q or "",
        feed=feed or "",
        only_unread=only_unread,
        page=page,
        page_size=PAGE_SIZE,
        total=total,
        pages=(total + PAGE_SIZE - 1) // PAGE_SIZE if total else 1,
    )
    return HTMLResponse(html)


@app.get("/articles/{article_id:path}", response_class=HTMLResponse)
def article_detail(article_id: str) -> HTMLResponse:
    with pg_conn() as conn:
        with conn.cursor(cursor_factory=psycopg2.extras.DictCursor) as cur:
            cur.execute(
                "SELECT id, title, url, summary, published_at, ingested_at, "
                "       author, feed_id, feed_title, category, body_text, "
                "       body_source, extraction_status, read, starred "
                "FROM articles WHERE id = %s",
                (article_id,),
            )
            row = cur.fetchone()
            if row is None:
                raise HTTPException(404, "article not found")
            article = dict(row)
            cur.execute(
                "SELECT c.id, c.text, c.citation_ct "
                "FROM chunks c JOIN chunk_articles ca ON ca.chunk_id=c.id "
                "WHERE ca.article_id = %s "
                "ORDER BY ca.position",
                (article_id,),
            )
            chunks = [dict(r) for r in cur.fetchall()]
    html = env.get_template("article.html").render(article=article, chunks=chunks)
    return HTMLResponse(html)
