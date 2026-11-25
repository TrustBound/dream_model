# Security Policy

## Supported Versions

| Version | Supported          |
| ------- | ------------------ |
| 1.x     | ✅ Active support  |

## What dream_model Is

dream_model is a tool for development time. You run it on a developer machine or in CI, as `gleam run -m dream_model`. Your app does not run it, and the app does not depend on it at run time. It is a dev dependency.

The modules that it writes are part of your app. They import only `dream`, `dream_postgres/client` and the Gleam standard library.

## What dream_model Connects To

dream_model connects to one PostgreSQL database: the database in the URL of `DATABASE_URL`, or of the variable that `database_url_variable` names. It opens two connections to it, and it closes them before it exits. It connects to nothing else, and it makes no network request of its own.

On the database, dream_model:

- Sends each `.sql` file to PostgreSQL to parse and describe it. It never executes a statement of a `.sql` file, so it changes no row.
- Runs read-only queries on the system catalogs, for the facts of the tables, the types, the functions, the constraints and the indexes.
- Runs the schema fingerprint query of `dream_postgres/client`.

dream_model opens its analysis connection with `debug_print_rewritten=on` and `client_min_messages=log`. PostgreSQL then sends the analyzed query tree of each statement to dream_model in a LOG notice.

**The server log receives every analyzed query at LOG level.** With the default `log_min_messages`, PostgreSQL also writes each tree to its log. A tree holds the text of the statement and the names of the tables and columns. It holds no row data and no parameter value. Use a database for development or CI, not the production database. If you run dream_model against a shared server, its log grows with each run.

## What dream_model Is Responsible For

- **The URL**: dream_model reads the user, the password, the host, the port, the database and `sslmode` from the URL. It supports trust, cleartext, MD5 and SCRAM-SHA-256 authentication. It sends a cleartext password only over TLS, and it refuses a server that asks for more than 1,000,000 SCRAM iterations. The query string can hold only `sslmode`. `sslmode=verify-full` checks the certificate chain against the system CA certificates and the host name. `sslmode=require` uses TLS with no check of the certificate.
- **Messages**: no message of dream_model holds the password of the URL. The user name and the password end at the last `@` before the path, and dream_model refuses an `@` after the host, so no part of them can get into the host of a message. A message of PostgreSQL itself can name the user, for example when the password is wrong.
- **Generated code**: each generated function sends its arguments as parameters of the statement, never as SQL text. The error texts of a generated function hold no SQL, no parameter and no value of a row.

## What You're Responsible For

- **The SQL**: you write the statements. dream_model does not change them.
- **Credentials**: keep the database URL out of your repository and your logs.
- **TLS**: choose the `sslmode` that your network needs.
- **The database**: run dream_model against a database for development or CI.
- **The app**: authentication, authorization and input validation.

## Reporting a Vulnerability

**Do not report security vulnerabilities through public GitHub issues.**

Email: **engineering@trustbound.ai**

### What to Include

- **Type of vulnerability** (for example, a password in a message, or generated code that puts a value in the SQL text)
- **Location** in dream_model's code (file and function)
- **Steps to reproduce** with a minimal example
- **Impact**: what can an attacker do?
- **Proof of concept** if you have one

Report vulnerabilities in **dream_model's code**, not in your application code.

### What to Expect

1. **Acknowledgment** within 48 hours
2. **Assessment** within 7 days
3. **Fix** coordinated with you on timing
4. **Release** with a security advisory
5. **Credit** in the advisory, if you want it

## Known Non-Issues

These are not dream_model vulnerabilities:

- The analyzed queries in the PostgreSQL server log. This is how dream_model reads the query tree.
- A password in a log line that your code or your CI wrote.
- `sslmode=require` or no `sslmode` on a network that you do not trust.

## Dependencies

- **dream_postgres**: the client that the generated code uses, and the schema fingerprint query
- **gleam_stdlib**, **gleam_erlang**, **simplifile**, **filepath** and **tom**
- **The Erlang `crypto` and `ssl` applications**: SCRAM-SHA-256 and TLS

## Questions?

- **Security questions**: engineering@trustbound.ai
- **Other issues**: [GitHub Issues](https://github.com/TrustBound/dream_model/issues)
- **General discussion**: [GitHub Discussions](https://github.com/TrustBound/dream/discussions)
