-- Olostep Native App setup script.
-- Public procedures live in CORE. The function that calls the Olostep API lives in
-- INTERNAL and is created once the consumer binds the API key secret and the
-- external access integration (consumers can't call it directly).
-- Batch and crawl results are saved as tables in RESULTS.

CREATE APPLICATION ROLE IF NOT EXISTS app_public;

CREATE SCHEMA IF NOT EXISTS core;
GRANT USAGE ON SCHEMA core TO APPLICATION ROLE app_public;

CREATE SCHEMA IF NOT EXISTS internal;

CREATE SCHEMA IF NOT EXISTS results;
GRANT USAGE ON SCHEMA results TO APPLICATION ROLE app_public;

-- Creates INTERNAL.OLOSTEP_REQUEST once both references are bound.
CREATE OR REPLACE PROCEDURE internal.create_functions()
RETURNS STRING
LANGUAGE SQL
AS
$$
BEGIN
  IF (ARRAY_SIZE(PARSE_JSON(SYSTEM$GET_ALL_REFERENCES('OLOSTEP_API_KEY'))) = 0
      OR ARRAY_SIZE(PARSE_JSON(SYSTEM$GET_ALL_REFERENCES('OLOSTEP_EXTERNAL_ACCESS'))) = 0) THEN
    RETURN 'Waiting for the API key secret and external access integration to be bound.';
  END IF;

  -- Replaced by the (method, path, body) version below.
  DROP FUNCTION IF EXISTS internal.olostep_request(STRING, VARIANT);

  -- Functions created outside the setup script must be inline, so the Python
  -- handler lives here (it uses only double quotes inside the SQL string).
  -- Rate limits, server errors and timeouts are retried with backoff.
  CREATE OR REPLACE FUNCTION internal.olostep_request(method STRING, path STRING, body VARIANT)
  RETURNS VARIANT
  LANGUAGE PYTHON
  RUNTIME_VERSION = '3.11'
  PACKAGES = ('requests')
  HANDLER = 'call'
  EXTERNAL_ACCESS_INTEGRATIONS = (reference('olostep_external_access'))
  SECRETS = ('api_key' = reference('olostep_api_key'))
  AS '
import time

import _snowflake
import requests

API_URL = "https://api.olostep.com/v1"
RETRY_STATUSES = (429, 500, 502, 503, 504)
ATTEMPTS = 3


def call(method, path, body):
    api_key = _snowflake.get_generic_secret_string("api_key")
    for attempt in range(ATTEMPTS):
        last = attempt == ATTEMPTS - 1
        try:
            response = requests.request(
                method,
                f"{API_URL}/{path}",
                headers={"Authorization": f"Bearer {api_key}"},
                json=body if isinstance(body, (dict, list)) else None,
                timeout=180,
            )
        except requests.RequestException as e:
            if last:
                return {"status": "error", "error": {"message": str(e)}}
            time.sleep(2 ** (attempt + 1))
            continue
        try:
            data = response.json()
        except ValueError:
            data = {"message": response.text}
        if response.status_code < 400:
            return data
        retryable = response.status_code in RETRY_STATUSES or "timeout" in str(data).lower()
        if retryable and not last:
            time.sleep(2 ** (attempt + 1))
            continue
        return {"status": "error", "http_status": response.status_code, "error": data}
';

  RETURN 'Olostep is ready.';
END;
$$;

CREATE OR REPLACE FUNCTION internal.is_valid_table_name(name STRING)
RETURNS BOOLEAN
AS
$$
  REGEXP_LIKE(name, '[A-Za-z_][A-Za-z0-9_]{0,254}')
$$;

-- Polls a batch or crawl until it is no longer in progress, or until max_wait_seconds pass.
CREATE OR REPLACE PROCEDURE internal.wait_for(path STRING, max_wait_seconds NUMBER)
RETURNS VARIANT
LANGUAGE SQL
AS
$$
DECLARE
  info VARIANT;
  waited NUMBER DEFAULT 0;
BEGIN
  LOOP
    info := (SELECT internal.olostep_request('GET', :path, NULL));
    IF (info:status::STRING <> 'in_progress' OR waited >= max_wait_seconds) THEN
      RETURN info;
    END IF;
    SELECT SYSTEM$WAIT(10);
    waited := waited + 10;
  END LOOP;
END;
$$;

-- Pages through a list of batch items or crawl pages, fetches each page's markdown
-- and saves it to RESULTS.<table_name>.
CREATE OR REPLACE PROCEDURE internal.save_pages(list_path STRING, items_key STRING, table_name STRING)
RETURNS VARIANT
LANGUAGE SQL
AS
$$
DECLARE
  items ARRAY DEFAULT ARRAY_CONSTRUCT();
  page VARIANT;
  page_items ARRAY;
  next_cursor STRING DEFAULT NULL;
  separator STRING;
  target STRING;
BEGIN
  separator := IFF(CONTAINS(list_path, '?'), '&', '?');
  LOOP
    page := (SELECT internal.olostep_request('GET',
      :list_path || :separator || 'limit=50' || IFF(:next_cursor IS NULL, '', '&cursor=' || :next_cursor), NULL));
    IF (page:status::STRING = 'error') THEN
      RETURN page;
    END IF;
    page_items := COALESCE(GET(page, :items_key)::ARRAY, ARRAY_CONSTRUCT());
    items := ARRAY_CAT(items, page_items);
    IF (ARRAY_SIZE(page_items) = 0 OR page:cursor IS NULL OR IS_NULL_VALUE(page:cursor)) THEN
      BREAK;
    END IF;
    next_cursor := page:cursor::STRING;
  END LOOP;

  target := 'results.' || table_name;
  CREATE OR REPLACE TABLE IDENTIFIER(:target) AS
    SELECT
      item:url::STRING AS url,
      content:markdown_content::STRING AS markdown,
      IFF(content:status::STRING = 'error', content, NULL) AS error,
      CURRENT_TIMESTAMP() AS retrieved_at
    FROM (
      SELECT
        f.value AS item,
        internal.olostep_request('GET',
          'retrieve?retrieve_id=' || f.value:retrieve_id::STRING || '&formats=markdown', NULL) AS content
      FROM TABLE(FLATTEN(input => :items)) f
    );
  GRANT SELECT ON ALL TABLES IN SCHEMA results TO APPLICATION ROLE app_public;

  RETURN OBJECT_CONSTRUCT('table', UPPER(:target), 'rows', ARRAY_SIZE(:items));
END;
$$;

-- Waits for a batch or crawl to finish and saves its pages.
-- kind is 'batches' or 'crawls'.
CREATE OR REPLACE PROCEDURE internal.finish(kind STRING, job_id STRING, table_name STRING, max_wait_seconds NUMBER)
RETURNS VARIANT
LANGUAGE SQL
AS
$$
DECLARE
  info VARIANT;
  saved VARIANT;
BEGIN
  CALL internal.wait_for(:kind || '/' || :job_id, :max_wait_seconds) INTO :info;
  IF (info:status::STRING = 'error') THEN
    RETURN info;
  END IF;
  IF (info:status::STRING = 'in_progress') THEN
    RETURN OBJECT_CONSTRUCT(
      'status', 'in_progress',
      'id', :job_id,
      'message', 'Still running. Call core.save_results(''' || :job_id || ''', ''' || :table_name || ''') in a few minutes.'
    );
  END IF;

  IF (kind = 'batches') THEN
    CALL internal.save_pages('batches/' || :job_id || '/items?status=completed', 'items', :table_name) INTO :saved;
  ELSE
    CALL internal.save_pages('crawls/' || :job_id || '/pages', 'pages', :table_name) INTO :saved;
  END IF;
  IF (saved:status::STRING = 'error') THEN
    RETURN saved;
  END IF;
  RETURN OBJECT_CONSTRUCT('status', 'completed', 'id', :job_id, 'table', saved:table, 'rows', saved:rows);
END;
$$;

-- Reference callbacks (called by Snowsight or by the consumer via SQL).
CREATE OR REPLACE PROCEDURE core.register_reference(ref_name STRING, operation STRING, ref_or_alias STRING)
RETURNS STRING
LANGUAGE SQL
AS
$$
BEGIN
  CASE (operation)
    WHEN 'ADD' THEN
      SELECT SYSTEM$SET_REFERENCE(:ref_name, :ref_or_alias);
    WHEN 'REMOVE' THEN
      SELECT SYSTEM$REMOVE_REFERENCE(:ref_name, :ref_or_alias);
    WHEN 'CLEAR' THEN
      SELECT SYSTEM$REMOVE_ALL_REFERENCES(:ref_name);
    ELSE
      RETURN 'Unknown operation: ' || operation;
  END CASE;
  CALL internal.create_functions();
  RETURN 'Operation ' || operation || ' succeeded.';
END;
$$;

GRANT USAGE ON PROCEDURE core.register_reference(STRING, STRING, STRING) TO APPLICATION ROLE app_public;

CREATE OR REPLACE PROCEDURE core.get_configuration(ref_name STRING)
RETURNS STRING
LANGUAGE SQL
AS
$$
BEGIN
  CASE (UPPER(ref_name))
    WHEN 'OLOSTEP_EXTERNAL_ACCESS' THEN
      RETURN '{"type": "CONFIGURATION", "payload": {"host_ports": ["api.olostep.com"], "allowed_secrets": "LIST", "secret_references": ["OLOSTEP_API_KEY"]}}';
    WHEN 'OLOSTEP_API_KEY' THEN
      RETURN '{"type": "CONFIGURATION", "payload": {"type": "GENERIC_STRING"}}';
    ELSE
      RETURN '';
  END CASE;
END;
$$;

GRANT USAGE ON PROCEDURE core.get_configuration(STRING) TO APPLICATION ROLE app_public;

-- Public procedures.

CREATE OR REPLACE PROCEDURE core.scrape(url STRING)
RETURNS VARIANT
LANGUAGE SQL
COMMENT = 'Scrape a web page and return its content as clean markdown (JavaScript rendering included).'
AS
$$
DECLARE
  res VARIANT;
BEGIN
  res := (SELECT internal.olostep_request('POST', 'scrapes', OBJECT_CONSTRUCT('url_to_scrape', :url, 'formats', ARRAY_CONSTRUCT('markdown'))));
  IF (res:status = 'error') THEN
    RETURN res;
  END IF;
  RETURN OBJECT_CONSTRUCT('url', :url, 'markdown', res:result:markdown_content);
END;
$$;

GRANT USAGE ON PROCEDURE core.scrape(STRING) TO APPLICATION ROLE app_public;

CREATE OR REPLACE PROCEDURE core.search(query STRING, max_results NUMBER DEFAULT 10)
RETURNS VARIANT
LANGUAGE SQL
COMMENT = 'Search the live web. Returns result titles, URLs and descriptions.'
AS
$$
DECLARE
  res VARIANT;
BEGIN
  res := (SELECT internal.olostep_request('POST', 'searches', OBJECT_CONSTRUCT('query', :query, 'limit', :max_results)));
  IF (res:status = 'error') THEN
    RETURN res;
  END IF;
  RETURN OBJECT_CONSTRUCT('query', :query, 'results', res:result:links);
END;
$$;

GRANT USAGE ON PROCEDURE core.search(STRING, NUMBER) TO APPLICATION ROLE app_public;

CREATE OR REPLACE PROCEDURE core.answer(task STRING)
RETURNS VARIANT
LANGUAGE SQL
COMMENT = 'Answer a question from the live web, with source URLs.'
AS
$$
DECLARE
  res VARIANT;
  content VARIANT;
BEGIN
  res := (SELECT internal.olostep_request('POST', 'answers', OBJECT_CONSTRUCT('task', :task)));
  IF (res:status = 'error') THEN
    RETURN res;
  END IF;
  content := TRY_PARSE_JSON(res:result:json_content::STRING);
  RETURN OBJECT_CONSTRUCT(
    'answer', COALESCE(content:result, content, res:result:json_content),
    'sources', res:result:sources
  );
END;
$$;

GRANT USAGE ON PROCEDURE core.answer(STRING) TO APPLICATION ROLE app_public;

CREATE OR REPLACE PROCEDURE core.map(url STRING, top_n NUMBER DEFAULT 100)
RETURNS VARIANT
LANGUAGE SQL
COMMENT = 'List the URLs on a website.'
AS
$$
DECLARE
  res VARIANT;
BEGIN
  res := (SELECT internal.olostep_request('POST', 'maps', OBJECT_CONSTRUCT('url', :url, 'top_n', :top_n)));
  IF (res:status = 'error') THEN
    RETURN res;
  END IF;
  RETURN OBJECT_CONSTRUCT('url', :url, 'urls', res:urls);
END;
$$;

GRANT USAGE ON PROCEDURE core.map(STRING, NUMBER) TO APPLICATION ROLE app_public;

CREATE OR REPLACE PROCEDURE core.batch_scrape(urls ARRAY, table_name STRING)
RETURNS VARIANT
LANGUAGE SQL
COMMENT = 'Scrape a list of URLs in one batch and save each page as markdown in RESULTS.<table_name>.'
AS
$$
DECLARE
  items ARRAY;
  job VARIANT;
  job_id STRING;
  done VARIANT;
BEGIN
  IF (NOT internal.is_valid_table_name(:table_name)) THEN
    RETURN OBJECT_CONSTRUCT('status', 'error', 'error', 'table_name must contain only letters, digits and underscores.');
  END IF;
  items := (SELECT ARRAY_AGG(OBJECT_CONSTRUCT('custom_id', f.index::STRING, 'url', f.value::STRING))
            FROM TABLE(FLATTEN(input => :urls)) f);
  job := (SELECT internal.olostep_request('POST', 'batches', OBJECT_CONSTRUCT('items', :items)));
  IF (job:status::STRING = 'error') THEN
    RETURN job;
  END IF;
  job_id := job:id::STRING;
  CALL internal.finish('batches', :job_id, :table_name, 1200) INTO :done;
  RETURN done;
END;
$$;

GRANT USAGE ON PROCEDURE core.batch_scrape(ARRAY, STRING) TO APPLICATION ROLE app_public;

CREATE OR REPLACE PROCEDURE core.crawl(url STRING, table_name STRING, max_pages NUMBER DEFAULT 10)
RETURNS VARIANT
LANGUAGE SQL
COMMENT = 'Crawl a website from a starting URL and save each page as markdown in RESULTS.<table_name>.'
AS
$$
DECLARE
  job VARIANT;
  job_id STRING;
  done VARIANT;
BEGIN
  IF (NOT internal.is_valid_table_name(:table_name)) THEN
    RETURN OBJECT_CONSTRUCT('status', 'error', 'error', 'table_name must contain only letters, digits and underscores.');
  END IF;
  job := (SELECT internal.olostep_request('POST', 'crawls', OBJECT_CONSTRUCT('start_url', :url, 'max_pages', :max_pages)));
  IF (job:status::STRING = 'error') THEN
    RETURN job;
  END IF;
  job_id := job:id::STRING;
  CALL internal.finish('crawls', :job_id, :table_name, 1200) INTO :done;
  RETURN done;
END;
$$;

GRANT USAGE ON PROCEDURE core.crawl(STRING, STRING, NUMBER) TO APPLICATION ROLE app_public;

CREATE OR REPLACE PROCEDURE core.save_results(job_id STRING, table_name STRING)
RETURNS VARIANT
LANGUAGE SQL
COMMENT = 'Save the pages of a batch or crawl that was still running when batch_scrape or crawl returned.'
AS
$$
DECLARE
  kind STRING DEFAULT 'batches';
  info VARIANT;
  done VARIANT;
BEGIN
  IF (NOT internal.is_valid_table_name(:table_name)) THEN
    RETURN OBJECT_CONSTRUCT('status', 'error', 'error', 'table_name must contain only letters, digits and underscores.');
  END IF;
  info := (SELECT internal.olostep_request('GET', 'batches/' || :job_id, NULL));
  IF (info:status::STRING = 'error') THEN
    kind := 'crawls';
  END IF;
  CALL internal.finish(:kind, :job_id, :table_name, 0) INTO :done;
  RETURN done;
END;
$$;

GRANT USAGE ON PROCEDURE core.save_results(STRING, STRING) TO APPLICATION ROLE app_public;

-- On upgrade, recreate the internal function if the references are already bound.
CALL internal.create_functions();
