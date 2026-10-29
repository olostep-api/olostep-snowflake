# Olostep for Snowflake

[Olostep](https://www.olostep.com) is web data infrastructure for AI. It provides live web search, scraping and crawling API to extract and structure data.

This repository contains the Olostep Snowflake Native App. It lets Snowflake users search the web, scrape pages into clean markdown, map websites and get answers with sources from SQL, or as tools for Cortex Agents. Batch scrapes and crawls are saved as tables. Users bring their own Olostep API key.

## Procedures

| Procedure | What it does |
|---|---|
| `core.scrape(url)` | Scrape a page and return clean markdown (JavaScript rendering included) |
| `core.search(query, max_results)` | Search the live web and return titles, URLs and descriptions |
| `core.answer(task)` | Answer a question from the live web, with source URLs |
| `core.map(url, top_n)` | List the URLs on a website |
| `core.batch_scrape(urls, table_name)` | Scrape a list of URLs in one batch and save the pages to `results.<table_name>` |
| `core.crawl(url, table_name, max_pages)` | Crawl a website and save the pages to `results.<table_name>` |
| `core.save_results(id, table_name)` | Save the pages of a batch or crawl that was still running when the call returned |

Every procedure returns a `VARIANT`. On failure it returns an object with `status` set to `error`. Rate limits, server errors and timeouts are retried automatically.

## How it works

- The consumer stores their Olostep API key in a `GENERIC_STRING` secret and creates an external access integration for `api.olostep.com`.
- They bind both to the app through the `OLOSTEP_API_KEY` and `OLOSTEP_EXTERNAL_ACCESS` references.
- Once both are bound, the app creates its internal function that calls the Olostep API. Consumers use the public procedures in the `core` schema.
- `batch_scrape` and `crawl` start an Olostep batch or crawl, wait for it to finish (up to 20 minutes), fetch each page's markdown and save it as a table in the `results` schema.

Consumer setup and usage are in [app/README.md](app/README.md).

## Development

Requires the [Snowflake CLI](https://docs.snowflake.com/en/developer-guide/snowflake-cli/index) and a Snowflake account with external access (not available on trial accounts).

```bash
# Deploy the application package and install the app
snow app run

# Bind your secret and external access integration
snow sql -q "CALL olostep_app.core.register_reference('OLOSTEP_API_KEY', 'ADD', SYSTEM\$REFERENCE('SECRET', '<DB>.<SCHEMA>.<SECRET>', 'PERSISTENT', 'READ'))"
snow sql -q "CALL olostep_app.core.register_reference('OLOSTEP_EXTERNAL_ACCESS', 'ADD', SYSTEM\$REFERENCE('EXTERNAL ACCESS INTEGRATION', '<EAI>', 'PERSISTENT', 'USAGE'))"

# Try it
snow sql -q "CALL olostep_app.core.scrape('https://docs.olostep.com')"
```

## About Olostep

- Website: https://www.olostep.com
- Documentation: https://docs.olostep.com
- Get an API key: https://www.olostep.com

## License

MIT
