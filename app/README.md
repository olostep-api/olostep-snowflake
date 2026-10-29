# Olostep for Snowflake

[Olostep](https://www.olostep.com) is web data infrastructure for AI. It provides live web search, scraping and crawling API to extract and structure data.

This app lets you search the web, scrape pages into clean markdown, map websites and get answers with sources, directly from Snowflake SQL or as tools for Cortex Agents.

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

## Support

- Documentation: https://docs.olostep.com
- Email: info@olostep.com
