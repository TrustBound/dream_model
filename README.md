# dream_model

dream_model writes typed Gleam model modules from PostgreSQL `.sql` files. Each generated function returns Dream errors, so a controller can give the result straight to `result_to_response`.

You write one `.sql` file for each query, in a folder that has the name of the model. dream_model analyzes each statement against your database, and writes one Gleam module next to the folder. The module decides `Option` from the schema: a column or a parameter is `Option` only when it can be NULL.

## Guides

- [Getting started](https://github.com/TrustBound/dream_model/blob/main/docs/guides/getting-started.md): write the SQL files of a model, generate its module, the hints, the settings and the supported types

## Contributing

See [CONTRIBUTING.md](CONTRIBUTING.md).
