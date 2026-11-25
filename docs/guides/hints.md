# Hints

A `.sql` file can start with comment lines that tell dream_model what the generated function returns, which errors it gives, and which values are `Option`. These lines are hints. This guide shows each hint with a real file of the end-to-end app and the function that dream_model writes for it.

## Table of Contents

- [How a hint looks](#how-a-hint-looks)
- [returns](#returns)
- [not found](#not-found)
- [unique](#unique)
- [not null](#not-null)
- [nullable](#nullable)
- [params](#params)
- [Common pitfalls](#common-pitfalls)
- [Where to go next](#where-to-go-next)

## How a hint looks

A hint is a comment line at the top of the file, before the statement: `-- key: value`. The keys do not depend on case. A comment line with another key is a plain comment. dream_model refuses a second `returns` or `not found` hint, with a message that names the file and the line. A later `params` line replaces an earlier one.

| Hint | Effect |
| --- | --- |
| `-- returns: one User` | One row as `User`, or `NotFound` (404) when there is no row |
| `-- returns: maybe User` | `Option(User)` |
| `-- returns: many User` | `List(User)` |
| `-- returns: none` | `Nil`, for a statement with no result columns |
| `-- returns: one` | With no type name and one result column: the value of that column |
| `-- returns: many app/models/user.User` | A type of another model |
| `-- not found: User not found` | The text of the 404 of `returns: one` |
| `-- unique users_email_key: Email already taken` | A violation of that unique constraint gives `Conflict` (409) with the text |
| `-- not null: total` | A computed column is not `Option`. The decoder checks each row |
| `-- nullable: title` | The column is `Option` |
| `-- params: pattern, nickname?` | The names of the parameters, in order. `?` makes a parameter `Option` |

## returns

`returns` sets how many rows the function gives, and their type. The forms are `one`, `maybe`, `many` and `none`.

### One row

`one` gives the row, or `NotFound` (404) when there is no row. More than one row gives `InternalServerError` (500).

#### find.sql <a href="https://github.com/TrustBound/dream_model/blob/1.0.0/e2e/model_app/src/app/models/user/find.sql"><img align="right" alt="Tested snippet" src="https://img.shields.io/badge/%F0%9F%A7%AA_tested-snippet-lightgreen.svg?style=flat-square"></a>

```sql
-- returns: one User
-- not found: User not found
select id, email, nickname from users where id = $1
```

#### The function of find.sql <a href="https://github.com/TrustBound/dream_model/blob/1.0.0/e2e/model_app/src/app/models/user.gleam#L80-L88"><img align="right" alt="Tested snippet" src="https://img.shields.io/badge/%F0%9F%A7%AA_tested-snippet-lightgreen.svg?style=flat-square"></a>

```gleam
/// Generated from find.sql.
pub fn find(db: client.Connection, id: Int) -> Result(User, Error) {
  "select id, email, nickname from users where id = $1"
  |> client.query
  |> client.parameter(client.int(id))
  |> client.returning(user_decoder())
  |> client.execute(db)
  |> one_row("user.find", "User not found", [])
}
```

### No row or one row

`maybe` gives `Option`: `None` when there is no row.

#### find_by_email.sql <a href="https://github.com/TrustBound/dream_model/blob/1.0.0/e2e/model_app/src/app/models/user/find_by_email.sql"><img align="right" alt="Tested snippet" src="https://img.shields.io/badge/%F0%9F%A7%AA_tested-snippet-lightgreen.svg?style=flat-square"></a>

```sql
-- returns: maybe User
select id, email, nickname from users where email = $1
```

#### The function of find_by_email.sql <a href="https://github.com/TrustBound/dream_model/blob/1.0.0/e2e/model_app/src/app/models/user.gleam#L90-L101"><img align="right" alt="Tested snippet" src="https://img.shields.io/badge/%F0%9F%A7%AA_tested-snippet-lightgreen.svg?style=flat-square"></a>

```gleam
/// Generated from find_by_email.sql.
pub fn find_by_email(
  db: client.Connection,
  email: String,
) -> Result(Option(User), Error) {
  "select id, email, nickname from users where email = $1"
  |> client.query
  |> client.parameter(client.text(email))
  |> client.returning(user_decoder())
  |> client.execute(db)
  |> maybe_row("user.find_by_email", [])
}
```

### Every row

`many` gives a `List` of the rows.

#### by_user.sql <a href="https://github.com/TrustBound/dream_model/blob/1.0.0/e2e/model_app/src/app/models/post/by_user.sql"><img align="right" alt="Tested snippet" src="https://img.shields.io/badge/%F0%9F%A7%AA_tested-snippet-lightgreen.svg?style=flat-square"></a>

```sql
-- returns: many Post
select id, user_id, title, body, published from posts
where user_id = $1 order by id
```

#### The function of by_user.sql <a href="https://github.com/TrustBound/dream_model/blob/1.0.0/e2e/model_app/src/app/models/post.gleam#L48-L60"><img align="right" alt="Tested snippet" src="https://img.shields.io/badge/%F0%9F%A7%AA_tested-snippet-lightgreen.svg?style=flat-square"></a>

```gleam
/// Generated from by_user.sql.
pub fn by_user(
  db: client.Connection,
  user_id: Int,
) -> Result(List(Post), Error) {
  "select id, user_id, title, body, published from posts
where user_id = $1 order by id"
  |> client.query
  |> client.parameter(client.int(user_id))
  |> client.returning(post_decoder())
  |> client.execute(db)
  |> many_rows("post.by_user", [])
}
```

### No hint

A file with no `returns` hint and with result columns gives `many`, with the type of the model folder: `User` for the folder `user`.

#### list.sql <a href="https://github.com/TrustBound/dream_model/blob/1.0.0/e2e/model_app/src/app/models/user/list.sql"><img align="right" alt="Tested snippet" src="https://img.shields.io/badge/%F0%9F%A7%AA_tested-snippet-lightgreen.svg?style=flat-square"></a>

```sql
select id, email, nickname from users order by id
```

#### The function of list.sql <a href="https://github.com/TrustBound/dream_model/blob/1.0.0/e2e/model_app/src/app/models/user.gleam#L103-L110"><img align="right" alt="Tested snippet" src="https://img.shields.io/badge/%F0%9F%A7%AA_tested-snippet-lightgreen.svg?style=flat-square"></a>

```gleam
/// Generated from list.sql.
pub fn list(db: client.Connection) -> Result(List(User), Error) {
  "select id, email, nickname from users order by id"
  |> client.query
  |> client.returning(user_decoder())
  |> client.execute(db)
  |> many_rows("user.list", [])
}
```

A file with no `returns` hint and no result columns gives `Nil`:

#### delete.sql <a href="https://github.com/TrustBound/dream_model/blob/1.0.0/e2e/model_app/src/app/models/user/delete.sql"><img align="right" alt="Tested snippet" src="https://img.shields.io/badge/%F0%9F%A7%AA_tested-snippet-lightgreen.svg?style=flat-square"></a>

```sql
delete from users where id = $1
```

#### The function of delete.sql <a href="https://github.com/TrustBound/dream_model/blob/1.0.0/e2e/model_app/src/app/models/user.gleam#L71-L78"><img align="right" alt="Tested snippet" src="https://img.shields.io/badge/%F0%9F%A7%AA_tested-snippet-lightgreen.svg?style=flat-square"></a>

```gleam
/// Generated from delete.sql.
pub fn delete(db: client.Connection, id: Int) -> Result(Nil, Error) {
  "delete from users where id = $1"
  |> client.query
  |> client.parameter(client.int(id))
  |> client.execute(db)
  |> no_rows("user.delete", [])
}
```

### Nothing

`none` gives `Nil`. dream_model refuses `none` for a statement with result columns.

#### rename.sql <a href="https://github.com/TrustBound/dream_model/blob/1.0.0/e2e/model_app/src/app/models/user/rename.sql"><img align="right" alt="Tested snippet" src="https://img.shields.io/badge/%F0%9F%A7%AA_tested-snippet-lightgreen.svg?style=flat-square"></a>

```sql
-- returns: none
update users set nickname = $2 where id = $1
```

#### The function of rename.sql <a href="https://github.com/TrustBound/dream_model/blob/1.0.0/e2e/model_app/src/app/models/user.gleam#L112-L124"><img align="right" alt="Tested snippet" src="https://img.shields.io/badge/%F0%9F%A7%AA_tested-snippet-lightgreen.svg?style=flat-square"></a>

```gleam
/// Generated from rename.sql.
pub fn rename(
  db: client.Connection,
  id: Int,
  nickname: Option(String),
) -> Result(Nil, Error) {
  "update users set nickname = $2 where id = $1"
  |> client.query
  |> client.parameter(client.int(id))
  |> client.parameter(client.nullable(client.text, nickname))
  |> client.execute(db)
  |> no_rows("user.rename", [])
}
```

### One value

With no type name and one result column, `one`, `maybe` and `many` give the value of that column, not a record. With more columns, they give the type of the model folder.

#### count.sql <a href="https://github.com/TrustBound/dream_model/blob/1.0.0/e2e/model_app/src/app/models/user/count.sql"><img align="right" alt="Tested snippet" src="https://img.shields.io/badge/%F0%9F%A7%AA_tested-snippet-lightgreen.svg?style=flat-square"></a>

```sql
-- returns: one
select count(*) as total from users
```

#### The function of count.sql <a href="https://github.com/TrustBound/dream_model/blob/1.0.0/e2e/model_app/src/app/models/user.gleam#L25-L32"><img align="right" alt="Tested snippet" src="https://img.shields.io/badge/%F0%9F%A7%AA_tested-snippet-lightgreen.svg?style=flat-square"></a>

```gleam
/// Generated from count.sql.
pub fn count(db: client.Connection) -> Result(Int, Error) {
  "select count(*) as total from users"
  |> client.query
  |> client.returning(decode.at([0], decode.int))
  |> client.execute(db)
  |> one_row("user.count", "User not found", [])
}
```

#### publish.sql <a href="https://github.com/TrustBound/dream_model/blob/1.0.0/e2e/model_app/src/app/models/post/publish.sql"><img align="right" alt="Tested snippet" src="https://img.shields.io/badge/%F0%9F%A7%AA_tested-snippet-lightgreen.svg?style=flat-square"></a>

```sql
-- returns: maybe
update posts set published = true where id = $1 returning published
```

#### The function of publish.sql <a href="https://github.com/TrustBound/dream_model/blob/1.0.0/e2e/model_app/src/app/models/post.gleam#L80-L88"><img align="right" alt="Tested snippet" src="https://img.shields.io/badge/%F0%9F%A7%AA_tested-snippet-lightgreen.svg?style=flat-square"></a>

```gleam
/// Generated from publish.sql.
pub fn publish(db: client.Connection, id: Int) -> Result(Option(Bool), Error) {
  "update posts set published = true where id = $1 returning published"
  |> client.query
  |> client.parameter(client.int(id))
  |> client.returning(decode.at([0], decode.bool))
  |> client.execute(db)
  |> maybe_row("post.publish", [])
}
```

### A type of another model

Name a type of another model by its module and its name. The generated module imports that module and decodes the rows into its type. A `.sql` file of that model must return the type, with the same fields.

#### authors.sql <a href="https://github.com/TrustBound/dream_model/blob/1.0.0/e2e/model_app/src/app/models/post/authors.sql"><img align="right" alt="Tested snippet" src="https://img.shields.io/badge/%F0%9F%A7%AA_tested-snippet-lightgreen.svg?style=flat-square"></a>

```sql
-- returns: many app/models/user.User
select distinct users.id, users.email, users.nickname
from users join posts on posts.user_id = users.id
where posts.published = $1
order by users.id
```

#### The function of authors.sql <a href="https://github.com/TrustBound/dream_model/blob/1.0.0/e2e/model_app/src/app/models/post.gleam#L32-L46"><img align="right" alt="Tested snippet" src="https://img.shields.io/badge/%F0%9F%A7%AA_tested-snippet-lightgreen.svg?style=flat-square"></a>

```gleam
/// Generated from authors.sql.
pub fn authors(
  db: client.Connection,
  published: Bool,
) -> Result(List(user.User), Error) {
  "select distinct users.id, users.email, users.nickname
from users join posts on posts.user_id = users.id
where posts.published = $1
order by users.id"
  |> client.query
  |> client.parameter(client.bool(published))
  |> client.returning(user_user_decoder())
  |> client.execute(db)
  |> many_rows("post.authors", [])
}
```

## not found

`not found` sets the text of the 404 of `returns: one`. The default text is `<Type> not found`, for example `User not found`. dream_model refuses `not found` with another form of `returns`.

### find.sql with its 404 text <a href="https://github.com/TrustBound/dream_model/blob/1.0.0/e2e/model_app/src/app/models/user/find.sql"><img align="right" alt="Tested snippet" src="https://img.shields.io/badge/%F0%9F%A7%AA_tested-snippet-lightgreen.svg?style=flat-square"></a>

```sql
-- returns: one User
-- not found: User not found
select id, email, nickname from users where id = $1
```

The text is an argument of `one_row` in the generated function: `one_row("user.find", "User not found", [])`.

## unique

`unique <constraint>: <text>` turns a violation of that unique constraint, primary key or unique index into `Conflict` (409) with the text. A file can have more than one `unique` hint.

### create.sql <a href="https://github.com/TrustBound/dream_model/blob/1.0.0/e2e/model_app/src/app/models/user/create.sql"><img align="right" alt="Tested snippet" src="https://img.shields.io/badge/%F0%9F%A7%AA_tested-snippet-lightgreen.svg?style=flat-square"></a>

```sql
-- returns: one User
-- unique users_email_key: Email already taken
insert into users (email, nickname) values ($1, $2)
returning id, email, nickname
```

### The function of create.sql <a href="https://github.com/TrustBound/dream_model/blob/1.0.0/e2e/model_app/src/app/models/user.gleam#L34-L50"><img align="right" alt="Tested snippet" src="https://img.shields.io/badge/%F0%9F%A7%AA_tested-snippet-lightgreen.svg?style=flat-square"></a>

```gleam
/// Generated from create.sql.
pub fn create(
  db: client.Connection,
  email: String,
  nickname: Option(String),
) -> Result(User, Error) {
  "insert into users (email, nickname) values ($1, $2)
returning id, email, nickname"
  |> client.query
  |> client.parameter(client.text(email))
  |> client.parameter(client.nullable(client.text, nickname))
  |> client.returning(user_decoder())
  |> client.execute(db)
  |> one_row("user.create", "User not found", [
    #("users_email_key", "Email already taken"),
  ])
}
```

dream_model checks each `unique` hint at generation time:

- The statement must write a table. Otherwise the message is `the statement writes no table, so no unique constraint can fail; remove the hint`.
- The name must be a unique constraint, a primary key or a unique index of a table that the statement writes. The unique indexes of the partitions of that table count too.
- No other index or constraint in the database can have the same name, in any schema. PostgreSQL names a violation only by the name of its constraint, and a constraint name is unique only for one table. A check constraint or a foreign key with the same name on another table, reached through a trigger, a cascade or a CTE, would give this `Conflict`. The message names both objects and says to rename one of them.

## not null

PostgreSQL cannot tell if most computed values can be NULL. `not null: <column>` promises that a computed result column is never NULL. The column is then not `Option`, and the decoder checks the promise on each row.

### total.sql <a href="https://github.com/TrustBound/dream_model/blob/1.0.0/e2e/model_app/src/app/models/post/total.sql"><img align="right" alt="Tested snippet" src="https://img.shields.io/badge/%F0%9F%A7%AA_tested-snippet-lightgreen.svg?style=flat-square"></a>

```sql
-- returns: one
-- not null: total
select sum(id)::int as total from posts where user_id = $1
```

### The function of total.sql <a href="https://github.com/TrustBound/dream_model/blob/1.0.0/e2e/model_app/src/app/models/post.gleam#L99-L114"><img align="right" alt="Tested snippet" src="https://img.shields.io/badge/%F0%9F%A7%AA_tested-snippet-lightgreen.svg?style=flat-square"></a>

```gleam
/// Generated from total.sql.
pub fn total(db: client.Connection, user_id: Int) -> Result(Int, Error) {
  "select sum(id)::int as total from posts where user_id = $1"
  |> client.query
  |> client.parameter(client.int(user_id))
  |> client.returning(decode.at(
    [0],
    client.promised_not_null(
      decode.int,
      "src/app/models/post/total.sql",
      "total",
    ),
  ))
  |> client.execute(db)
  |> one_row("post.total", "Post not found", [])
}
```

A NULL breaks the promise. The function then gives `InternalServerError` (500) with the text `the SQL file src/app/models/post/total.sql promised the column total is never NULL, and PostgreSQL returned NULL`.

dream_model refuses `not null` on a table column, because the schema decides it, and on a computed column that is never NULL by rule, for example `count(*)`.

## nullable

`nullable: <column>` makes a result column `Option`, also when the schema says that it is never NULL.

### titles.sql <a href="https://github.com/TrustBound/dream_model/blob/1.0.0/e2e/model_app/src/app/models/post/titles.sql"><img align="right" alt="Tested snippet" src="https://img.shields.io/badge/%F0%9F%A7%AA_tested-snippet-lightgreen.svg?style=flat-square"></a>

```sql
-- returns: many
-- nullable: title
select title from posts order by id
```

### The function of titles.sql <a href="https://github.com/TrustBound/dream_model/blob/1.0.0/e2e/model_app/src/app/models/post.gleam#L90-L97"><img align="right" alt="Tested snippet" src="https://img.shields.io/badge/%F0%9F%A7%AA_tested-snippet-lightgreen.svg?style=flat-square"></a>

```gleam
/// Generated from titles.sql.
pub fn titles(db: client.Connection) -> Result(List(Option(String)), Error) {
  "select title from posts order by id"
  |> client.query
  |> client.returning(decode.at([0], decode.optional(decode.string)))
  |> client.execute(db)
  |> many_rows("post.titles", [])
}
```

## params

Without `params`, a parameter gets the name of the column that it is stored into or compared with, for example `id` for `where id = $1`. `params` names every parameter, in order. A name that ends with `?` makes that parameter `Option`.

### search.sql <a href="https://github.com/TrustBound/dream_model/blob/1.0.0/e2e/model_app/src/app/models/user/search.sql"><img align="right" alt="Tested snippet" src="https://img.shields.io/badge/%F0%9F%A7%AA_tested-snippet-lightgreen.svg?style=flat-square"></a>

```sql
-- returns: many User
-- params: pattern, nickname?
select id, email, nickname from users
where email like $1 and ($2::text is null or nickname = $2)
order by id
```

### The function of search.sql <a href="https://github.com/TrustBound/dream_model/blob/1.0.0/e2e/model_app/src/app/models/user.gleam#L126-L141"><img align="right" alt="Tested snippet" src="https://img.shields.io/badge/%F0%9F%A7%AA_tested-snippet-lightgreen.svg?style=flat-square"></a>

```gleam
/// Generated from search.sql.
pub fn search(
  db: client.Connection,
  pattern: String,
  nickname: Option(String),
) -> Result(List(User), Error) {
  "select id, email, nickname from users
where email like $1 and ($2::text is null or nickname = $2)
order by id"
  |> client.query
  |> client.parameter(client.text(pattern))
  |> client.parameter(client.nullable(client.text, nickname))
  |> client.returning(user_decoder())
  |> client.execute(db)
  |> many_rows("user.search", [])
}
```

Give a name with `params` when dream_model cannot find one, for example when a parameter is compared with two columns, or with no column.

## Common pitfalls

- **A hint after the statement.** dream_model reads only the comment lines before the statement.
- **A `unique` hint on a SELECT.** A SELECT writes no table, so no unique constraint can fail.
- **`not null` on a table column.** The schema decides a table column. Add a NOT NULL constraint to the column.
- **`params` with too few names.** `params` names every parameter, in order.

## Where to go next

- [Why is this column Option?](why-option.md): what the generator decides without hints
- [Errors](errors.md): the errors of the hints at run time
- [Command reference](command-reference.md): every message of a refused hint
