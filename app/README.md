# Olostep for Snowflake

[Olostep](https://www.olostep.com) is web data infrastructure for AI. It provides live web search, scraping and crawling API to extract and structure data.

This app lets you search the web, scrape pages into clean markdown, map websites and get answers with sources, directly from Snowflake SQL or as tools for Cortex Agents. Batch scrapes and website crawls are saved as tables you can query, join and load into Cortex Search.

## Setup

1. Get an Olostep API key at https://www.olostep.com.
2. Store it in a secret and allow access to the Olostep API (replace `<APP_NAME>` with the name you installed the app under):

```sql
CREATE DATABASE IF NOT EXISTS olostep_config;

CREATE OR REPLACE SECRET olostep_config.public.olostep_api_key
  TYPE = GENERIC_STRING
  SECRET_STRING = '<YOUR_OLOSTEP_API_KEY>';

CREATE OR REPLACE NETWORK RULE olostep_config.public.olostep_api_rule
  MODE = EGRESS TYPE = HOST_PORT VALUE_LIST = ('api.olostep.com');

CREATE OR REPLACE EXTERNAL ACCESS INTEGRATION olostep_external_access
  ALLOWED_NETWORK_RULES = (olostep_config.public.olostep_api_rule)
  ALLOWED_AUTHENTICATION_SECRETS = (olostep_config.public.olostep_api_key)
  ENABLED = TRUE;

CALL <APP_NAME>.core.register_reference('OLOSTEP_API_KEY', 'ADD',
  SYSTEM$REFERENCE('SECRET', 'olostep_config.public.olostep_api_key', 'PERSISTENT', 'READ'));

CALL <APP_NAME>.core.register_reference('OLOSTEP_EXTERNAL_ACCESS', 'ADD',
  SYSTEM$REFERENCE('EXTERNAL ACCESS INTEGRATION', 'olostep_external_access', 'PERSISTENT', 'USAGE'));
```

## Usage

```sql
-- Scrape a page into markdown
CALL <APP_NAME>.core.scrape('https://docs.olostep.com');

-- Search the web
CALL <APP_NAME>.core.search('latest AI agent frameworks', 5);

-- Answer a question with sources
CALL <APP_NAME>.core.answer('What is the latest stable version of Next.js?');

-- List the URLs on a website
CALL <APP_NAME>.core.map('https://docs.olostep.com', 50);
```

Every procedure returns a `VARIANT`. On failure it returns an object with `status` set to `error`.

## Save pages as tables

`batch_scrape` and `crawl` save one row per page to `<APP_NAME>.results.<table_name>`, with the columns `URL`, `MARKDOWN`, `ERROR` and `RETRIEVED_AT`. Using an existing table name replaces that table.

```sql
-- Scrape every URL in one of your tables
CALL <APP_NAME>.core.batch_scrape(
  (SELECT ARRAY_AGG(url) FROM my_db.my_schema.companies),
  'company_pages');

-- Crawl a website (up to 25 pages)
CALL <APP_NAME>.core.crawl('https://docs.olostep.com', 'olostep_docs', 25);

-- Query the results, or copy them into your own database
SELECT url, markdown FROM <APP_NAME>.results.company_pages;
CREATE TABLE my_db.my_schema.company_pages AS SELECT * FROM <APP_NAME>.results.company_pages;
```

Batches and crawls usually finish in a few minutes. If one is still running after 20 minutes, the procedure returns its `id` with `status` set to `in_progress`. Save its pages later with:

```sql
CALL <APP_NAME>.core.save_results('<id>', 'company_pages');
```

Tables in `results` are removed if you uninstall the app, so copy anything you want to keep into your own database.

## Support

- Documentation: https://docs.olostep.com
- Email: info@olostep.com
