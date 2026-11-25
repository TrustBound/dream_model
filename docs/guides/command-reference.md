# Command reference

This page lists every option, setting, exit status and message of `gleam run -m dream_model`. The guides show how to use them.

## Table of Contents

- [The command](#the-command)
- [Settings](#settings)
- [The database URL](#the-database-url)
- [Output and exit status](#output-and-exit-status)
- [Messages of the command](#messages-of-the-command)
- [Messages of a SQL file](#messages-of-a-sql-file)
- [Messages of the database connection](#messages-of-the-database-connection)

## The command

Run the command in the folder of the app, where `gleam.toml` is.

### Write the modules <a href="https://github.com/TrustBound/dream_model/blob/1.0.0/e2e/model_app/scripts/generate-models.sh#L6"><img align="right" alt="Tested snippet" src="https://img.shields.io/badge/%F0%9F%A7%AA_tested-snippet-lightgreen.svg?style=flat-square"></a>

```sh
gleam run -m dream_model
```

With no option, the command analyzes every `.sql` file of every model folder and writes one module for each folder. It writes no module when a file has a problem.

### Check the modules <a href="https://github.com/TrustBound/dream_model/blob/1.0.0/e2e/model_app/scripts/check-models.sh#L6"><img align="right" alt="Tested snippet" src="https://img.shields.io/badge/%F0%9F%A7%AA_tested-snippet-lightgreen.svg?style=flat-square"></a>

```sh
gleam run -m dream_model -- --check
```

`--check` analyzes the same files and writes nothing. It compares each module that it would write with the file on disk.

| Option | Effect |
| --- | --- |
| (none) | Write the modules |
| `--check` | Write nothing. Exit with status 1 when a module is missing or differs |

The command takes no other option.

A model folder is a folder under `src` that holds at least one `.sql` file. Its path under `src` is the module path: `src/app/models/user` gives the module `app/models/user` in the file `src/app/models/user.gleam`. Each part of the path must be in snake case. The name of the folder, in Pascal case, is the default type name: `User`. The name of each `.sql` file is the name of its function.

The command formats each module with `gleam format`, in `build/dream_model/format`, so it needs the `gleam` program on the `PATH`.

## Settings

Put the settings in the `[tools.dream_model]` table of the `gleam.toml` of the app. Both settings are optional.

### The settings of the end-to-end app <a href="https://github.com/TrustBound/dream_model/blob/1.0.0/e2e/model_app/gleam.toml#L19-L20"><img align="right" alt="Tested snippet" src="https://img.shields.io/badge/%F0%9F%A7%AA_tested-snippet-lightgreen.svg?style=flat-square"></a>

```toml
[tools.dream_model]
database_url_variable = "MODEL_APP_DATABASE_URL"
```

| Setting | Type | Default | Effect |
| --- | --- | --- | --- |
| `database_url_variable` | string | `"DATABASE_URL"` | The environment variable that holds the database URL |
| `models` | list of strings | every folder under `src` with a `.sql` file | The model folders, for example `["src/app/models/user"]` |

The command refuses any other key in the table.

## The database URL

The URL has the form `postgresql://user:password@host:port/database`. The scheme `postgres://` works too. The query string can hold `sslmode`:

| `sslmode` | Effect |
| --- | --- |
| `disable`, or no `sslmode` | No TLS |
| `require` | TLS, with no check of the server certificate |
| `verify-full` | TLS, with a check of the certificate chain against the system CA certificates and of the host name |

dream_model supports trust, cleartext, MD5 and SCRAM-SHA-256 authentication. It needs PostgreSQL 16, 17, 18 or 19.

## Output and exit status

| Exit status | When |
| --- | --- |
| 0 | The command wrote the modules, every module matches with `--check`, or there is nothing to generate |
| 1 | Any message of the tables below, a problem in a SQL file, or a module that is missing or differs with `--check` |

The command prints one line for each module:

| Line | Mode | Meaning |
| --- | --- | --- |
| `wrote <path>` | write | The module is new or changed |
| `unchanged <path>` | write | The module did not change |
| `missing <path>` | `--check` | The module file does not exist |
| `differs <path>` | `--check` | The module file is not the module that the `.sql` files give |

With `--check`, a run with no missing or different module prints `every model module matches its .sql files (<n> modules)`. Otherwise the last line is `` Run `gleam run -m dream_model` to write the modules again. ``

## Messages of the command

| Message | Cause |
| --- | --- |
| `dream_model found no folder with .sql files under src; there is nothing to generate.` | No model folder. The exit status is 0 |
| `dream_model does not know the arguments '<arguments>'. Run ...` | An option other than `--check` |
| `dream_model needs the URL of the database in the environment variable <name>, for example postgresql://user:password@localhost:5432/app` | The variable is not set |
| `dream_model cannot use the database: <reason>` | The connection failed. See [Messages of the database connection](#messages-of-the-database-connection) |
| `dream_model cannot read gleam.toml: <reason>` | No `gleam.toml` in the folder |
| `dream_model cannot parse gleam.toml` | `gleam.toml` is not TOML |
| `dream_model does not know the settings <keys> in [tools.dream_model] of gleam.toml; the settings are database_url_variable and models` | An unknown setting |
| `the setting database_url_variable in [tools.dream_model] of gleam.toml must be a string` | A value of another type |
| `the setting models in [tools.dream_model] of gleam.toml must be a list of folders` | A value of another type |
| `these folders of models in gleam.toml hold no .sql file: <folders>` | A folder of `models` with no `.sql` file |
| `these model folders are not Gleam module paths under src: <folders>; each folder name must be in snake case, for example src/app/models/user` | A folder name that is not a module path |
| `dream_model cannot read the src folder: <reason>` | No `src` folder |
| `dream_model cannot read the schema fingerprint of <module>: <reason>` | The fingerprint query failed |
| `dream_model cannot write to build/dream_model: <reason>` | The format folder cannot be written |
| `dream_model needs the gleam program on the PATH to format the modules` | No `gleam` program |
| `gleam format refused a generated module:` and the output of `gleam format` | A generated module is not valid Gleam. Report it in an issue |
| `dream_model cannot write <path>: <reason>` | The module file cannot be written |

## Messages of a SQL file

Each problem of a SQL file is one line: `<file>:<line>: <message>`. After the problems, the command prints `dream_model wrote nothing: <n> problem(s).` and writes no module.

### The file and the statement

| Message | Fix |
| --- | --- |
| `cannot read the file: <reason>` | Make the file readable |
| `the file name does not give a Gleam function name; name the file in snake case, for example find_by_email.sql` | Rename the file |
| `PostgreSQL refused the statement: <message>` | Fix the SQL. The message is the one of PostgreSQL |
| `the function name '<name>' is a name that the generated module uses itself; rename the file` | Rename the file |

### Hints

| Message | Fix |
| --- | --- |
| `a second '<key>' hint; the first one is on line <n>` | Keep one `returns` or `not found` hint |
| `'<value>' is not a returns hint; write 'returns: one', 'maybe', 'many' or 'none', with a type name after it, for example 'returns: one User'` | Fix the hint |
| `'<form>' is not a returns form; write one, maybe, many or none` | Fix the form |
| `'returns: none' takes no type name` | Remove the type name |
| `'<name>' is not a type name; a type name starts with a capital letter and has only letters and digits, for example User` | Fix the type name |
| `'<name>' is not a type name; a type of another model is its module and its type, for example app/models/user.User` | Fix the module type |
| `the 'not found' hint needs 'returns: one'; only 'one' fails when there is no row` | Use `returns: one`, or remove the hint |
| `the '<key>' hint has no message` | Write the text after the colon |
| `the 'unique' hint names no constraint; write 'unique <constraint>: <message>'` | Name the constraint |
| `'returns: none', and the statement returns the columns <columns>; remove the columns or write another returns form` | Remove the columns, or change the form |
| `'returns: <form>' needs result columns, and the statement returns none; write 'returns: none'` | Use `returns: none` |
| `hint names '<name>', which is not a result column` | Name a result column in `not null` or `nullable` |
| `hint 'not null: <name>' names a table column; the schema decides it (<reason>)` | Remove the hint, or change the schema |
| `hint 'not null: <name>' is not needed: the column is never NULL by rule (<reason>); remove the hint` | Remove the hint |

### Unique hints

| Message | Fix |
| --- | --- |
| `the statement writes no table, so no unique constraint can fail; remove the hint` | Remove the hint |
| `'<name>' is not a unique constraint, a primary key or a unique index of <tables>` | Name a unique constraint of a table that the statement writes |
| `the name '<name>' belongs to <the hinted index>, and also to <other objects>; PostgreSQL names a violation only by the name of its constraint, so a violation of the other object would give this Conflict; rename one of them` | Rename the other index or constraint, or the unique one |

### Columns and types

| Message | Fix |
| --- | --- |
| `the column '<column>' has the PostgreSQL type <type>, which dream_model does not support; cast it in the SQL to a supported type, for example <column>::text` | Cast the column. See [Types](types.md#types-that-need-a-cast) |
| `result column <n> ('<name>') has no Gleam name; name it with AS in the SQL, for example AS total` | Name the column with AS |
| `the result column '<column>' gives the field name '<name>', which the generated decoder uses itself; rename it with AS in the SQL` | Rename the column with AS |
| `two result columns give the field name '<name>'; rename one with AS in the SQL` | Rename a column with AS |
| `the type <Type> <difference>; every file that returns one type must give it the same fields, in the same order, with the same types` | Give each file of the type the same columns |
| `<module> is not a model that dream_model generates in this run; the type <module>.<Type> must come from a model folder` | Name a type of a model folder |
| `no .sql file of <module> returns the type <Type>; name a type that a file of that model returns` | Name a type that the model returns |
| `the module <module> would be imported as '<alias>', which another import of this model uses; name the type of another model whose module ends in another name` | Use a type of a module with another last name |
| `the field '<name>' has the name of the imported module <module>, which its decoder uses; rename the column with AS in the SQL` | Rename the column with AS |

### Parameters

| Message | Fix |
| --- | --- |
| `the parameter $<n> has the PostgreSQL type <type>, which dream_model does not support; cast it in the SQL from a supported type, for example $<n>::text::<type>` | Cast the parameter |
| `the 'params' hint names <n> parameters, and the statement has <m>; name every parameter, in order` | Name every parameter |
| `the parameter name '<name>' is the name that the generated function gives its connection or a module; choose another name` | Choose another name than `db`, `client` or `decode` |
| `'<name>' is not a Gleam name; write the parameter names in snake case, for example user_id` | Fix the name |
| `the parameter $<n> is not stored into or compared with a table column, so it has no name; name every parameter, in order, with a line like '-- params: ...'` | Add a `params` hint |
| `the parameter $<n> is used with the columns <columns>, so its name is not clear; ...` | Add a `params` hint |
| `the parameter $<n> would be named '<name>', which the generated function uses itself; ...` | Add a `params` hint |
| `the column '<column>' of the parameter $<n> gives no Gleam name; ...` | Add a `params` hint |
| `the parameters $<n> and $<m> would all be named '<name>'; name every parameter, in order, with a line like '-- params: ...'` | Add a `params` hint |

## Messages of the database connection

These messages come after `dream_model cannot use the database: `.

| Message | Cause |
| --- | --- |
| `PostgreSQL <version> is not supported: dream_model needs PostgreSQL 16 or newer, because older versions do not record which columns an outer join can make NULL` | PostgreSQL 15 or older |
| `PostgreSQL <version> is not supported yet: dream_model is tested on PostgreSQL 16 to 19, and it reads PostgreSQL's analyzed query, whose form can change in each major version` | PostgreSQL 20 or newer |
| `the PostgreSQL URL cannot be used: <reason>` | The URL is not valid |
| `cannot connect to PostgreSQL at <host>:<port>: <reason>` | The server does not answer |
| `PostgreSQL asks for a password, and the URL has none` | Put the password in the URL |
| `PostgreSQL asks for an authentication method that dream_model does not support: <method>` | Use trust, cleartext, MD5 or SCRAM-SHA-256 |
| `the URL asks for TLS (sslmode), and the PostgreSQL server does not offer it` | Turn on TLS on the server, or remove `sslmode` |
| `the TLS handshake with PostgreSQL failed: <reason>` | Fix the certificate or the host name |
| `the PostgreSQL connection failed: <reason>` | The connection closed |
