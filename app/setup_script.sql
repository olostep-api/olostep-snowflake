-- Olostep Native App setup script.
-- Public procedures live in CORE. The function that calls the Olostep API lives in
-- INTERNAL and is created once the consumer binds the API key secret and the
-- external access integration (consumers can't call it directly).

CREATE APPLICATION ROLE IF NOT EXISTS app_public;

CREATE SCHEMA IF NOT EXISTS core;
GRANT USAGE ON SCHEMA core TO APPLICATION ROLE app_public;

CREATE SCHEMA IF NOT EXISTS internal;

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

  -- Functions created outside the setup script must be inline, so the Python
  -- handler lives here (it uses only double quotes inside the SQL string).
  CREATE OR REPLACE FUNCTION internal.olostep_request(path STRING, body VARIANT)
  RETURNS VARIANT
  LANGUAGE PYTHON
  RUNTIME_VERSION = '3.11'
  PACKAGES = ('requests')
  HANDLER = 'call'
  EXTERNAL_ACCESS_INTEGRATIONS = (reference('olostep_external_access'))
  SECRETS = ('api_key' = reference('olostep_api_key'))
  AS '
import _snowflake
import requests

API_URL = "https://api.olostep.com/v1"


def call(path, body):
    api_key = _snowflake.get_generic_secret_string("api_key")
    response = requests.post(
        f"{API_URL}/{path}",
        headers={"Authorization": f"Bearer {api_key}"},
        json=body,
        timeout=180,
    )
    try:
        data = response.json()
    except ValueError:
        data = {"message": response.text}
    if response.status_code >= 400:
        return {"status": "error", "http_status": response.status_code, "error": data}
    return data
';

  RETURN 'Olostep is ready.';
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
  res := (SELECT internal.olostep_request('scrapes', OBJECT_CONSTRUCT('url_to_scrape', :url, 'formats', ARRAY_CONSTRUCT('markdown'))));
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
  res := (SELECT internal.olostep_request('searches', OBJECT_CONSTRUCT('query', :query, 'limit', :max_results)));
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
  res := (SELECT internal.olostep_request('answers', OBJECT_CONSTRUCT('task', :task)));
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
  res := (SELECT internal.olostep_request('maps', OBJECT_CONSTRUCT('url', :url, 'top_n', :top_n)));
  IF (res:status = 'error') THEN
    RETURN res;
  END IF;
  RETURN OBJECT_CONSTRUCT('url', :url, 'urls', res:urls);
END;
$$;

GRANT USAGE ON PROCEDURE core.map(STRING, NUMBER) TO APPLICATION ROLE app_public;

-- On upgrade, recreate the internal function if the references are already bound.
CALL internal.create_functions();
