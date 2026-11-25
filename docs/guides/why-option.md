# Why is this column Option?

A field of a generated type is `Option` when its column can be NULL. A parameter is `Option` when NULL is a value that the statement can store. dream_model decides both from the schema and from the query tree of PostgreSQL. It never guesses: when it cannot prove that a value is never NULL, the value is `Option`. This guide gives each reason, in the words of the generator, with an example query and what to do.

The text after each heading is the name of the reason in dream_model. A refused `not null` hint shows it, for example `hint 'not null: email' names a table column; the schema decides it (NOT NULL in schema)`.

## Table of Contents

- [How the generator decides](#how-the-generator-decides)
- [Columns that are Option](#columns-that-are-option)
- [Parameters that are Option](#parameters-that-are-option)
- [Parameters that are required](#parameters-that-are-required)
- [Reasons that no query gives](#reasons-that-no-query-gives)
- [Where to go next](#where-to-go-next)

## How the generator decides

A result column is not `Option` when one of these rules proves it:

| Reason | Example |
| --- | --- |
| `NOT NULL in schema` | A NOT NULL table column, in the table and in each child table and partition that the query reads |
| `system column` | `ctid` |
| `NOT NULL in every branch of the set operation` | `select email from users union all select title from posts` |
| `a constant that is not NULL` | `select 1 as one` |
| `count(...) never returns NULL` | `select count(*) as total from users` |
| `coalesce(...) whose last argument is never NULL` | `select coalesce(nickname, '') as nickname from users` |
| `EXISTS (...) is never NULL` | `select exists (select 1 from posts) as any_posts` |
| `IS NULL and IS NOT NULL are never NULL` | `select nickname is null as anonymous from users` |
| `IS DISTINCT FROM with a built-in operator is never NULL` | `select nickname is distinct from 'x' as other from users` |
| `not null hint, checked on every row` | `-- not null: total` |

Every other column is `Option`, for one of the reasons below. A parameter is required, unless one of the rules in [Parameters that are Option](#parameters-that-are-option) makes it `Option`.

The examples use the tables of the attack tests: `users` (`email` NOT NULL, `nickname` NULL, and a BEFORE INSERT trigger), `posts` (`title` NOT NULL) and the other tables that each section names. The tests run each example on PostgreSQL 16, 17, 18 and 19, or from the version that the section names.

## Columns that are Option

### column allows NULL

The table column has no NOT NULL constraint.

#### A nullable column <a href="https://github.com/TrustBound/dream_model/blob/1.0.0/test/snippets/why_option/column_allows_null.sql"><img align="right" alt="Tested snippet" src="https://img.shields.io/badge/%F0%9F%A7%AA_tested-snippet-lightgreen.svg?style=flat-square"></a>

```sql
select id, nickname from users
```

`nickname` is `Option(String)`. To make it `String`, add NOT NULL to the column, or use `coalesce(nickname, '')` in the query.

### an outer join or grouping set can empty it

The column comes from the side of an outer join that can have no row. PostgreSQL 18 and newer marks a column of a grouping set in the same way.

#### A left join <a href="https://github.com/TrustBound/dream_model/blob/1.0.0/test/snippets/why_option/outer_join.sql"><img align="right" alt="Tested snippet" src="https://img.shields.io/badge/%F0%9F%A7%AA_tested-snippet-lightgreen.svg?style=flat-square"></a>

```sql
select u.email, p.title
from users u left join posts p on p.user_id = u.id
```

`title` is `Option`, because a user can have no post. Use an inner join when each row has a match, or `coalesce(p.title, '')`.

### a grouping set can empty it

On PostgreSQL 16 and 17, a column of `GROUPING SETS`, `ROLLUP` or `CUBE` is NULL in the rows of the higher grouping levels. PostgreSQL 18 and newer gives the reason above.

#### A rollup <a href="https://github.com/TrustBound/dream_model/blob/1.0.0/test/snippets/why_option/grouping_set.sql"><img align="right" alt="Tested snippet" src="https://img.shields.io/badge/%F0%9F%A7%AA_tested-snippet-lightgreen.svg?style=flat-square"></a>

```sql
select email, count(*) as total
from users group by rollup (email)
```

`email` is `Option`. The total row of the rollup has no email. `total` stays `Int`, because `count(*)` is never NULL.

### computed value (funcexpr)

The value is a function, an operator, a subquery or another expression that the rules do not prove. The text in parentheses is the node of the query tree, for example `funcexpr` for a function call or `opexpr` for an operator.

#### A function of a column <a href="https://github.com/TrustBound/dream_model/blob/1.0.0/test/snippets/why_option/computed_value.sql"><img align="right" alt="Tested snippet" src="https://img.shields.io/badge/%F0%9F%A7%AA_tested-snippet-lightgreen.svg?style=flat-square"></a>

```sql
select lower(email) as low from users
```

`low` is `Option`, also though `email` is NOT NULL: dream_model does not know what `lower` does with its argument. Promise the value with `-- not null: low`, or use `coalesce(lower(email), '')`.

### whole-row value

The column is a whole row, such as `u` in `select u from users u`.

#### A whole row <a href="https://github.com/TrustBound/dream_model/blob/1.0.0/test/snippets/why_option/whole_row.sql"><img align="right" alt="Tested snippet" src="https://img.shields.io/badge/%F0%9F%A7%AA_tested-snippet-lightgreen.svg?style=flat-square"></a>

```sql
select u from users u
```

Select the columns one by one.

### relation kind m does not enforce NOT NULL

The column comes from a relation that does not enforce NOT NULL, here `m`, a materialized view. The letter is the `relkind` of PostgreSQL.

#### A materialized view <a href="https://github.com/TrustBound/dream_model/blob/1.0.0/test/snippets/why_option/materialized_view.sql"><img align="right" alt="Tested snippet" src="https://img.shields.io/badge/%F0%9F%A7%AA_tested-snippet-lightgreen.svg?style=flat-square"></a>

```sql
select email from mv_users
```

Read the table of the view, or promise the column with `-- not null: email`.

### relation kind f does not enforce NOT NULL

A child table or a partition that the query reads is a foreign table (`f`). PostgreSQL does not enforce NOT NULL on a foreign table, so its rows can hold NULL in a column that the parent makes NOT NULL. Here `fparent` has `id` NOT NULL, and its child `fchild` is a foreign table of `postgres_fdw`.

#### A foreign child table <a href="https://github.com/TrustBound/dream_model/blob/1.0.0/test/snippets/why_option/foreign_child.sql"><img align="right" alt="Tested snippet" src="https://img.shields.io/badge/%F0%9F%A7%AA_tested-snippet-lightgreen.svg?style=flat-square"></a>

```sql
select id from fparent
```

Make the remote column NOT NULL and promise nothing, or read `only fparent`.

### recursive CTE

The column comes from a recursive CTE.

#### A recursive CTE <a href="https://github.com/TrustBound/dream_model/blob/1.0.0/test/snippets/why_option/recursive_cte.sql"><img align="right" alt="Tested snippet" src="https://img.shields.io/badge/%F0%9F%A7%AA_tested-snippet-lightgreen.svg?style=flat-square"></a>

```sql
with recursive r(n, e) as (
  select id, email from users
  union all
  select n + 1, e from r where n < 3
)
select e from r
```

Promise the column with `-- not null: e`.

### values result

The column comes from a range that the rules do not look into: `values`, `function`, `tablefunc`, `tuplestore`, `result` or `unknown`. The first word of the reason names the kind.

#### A VALUES list <a href="https://github.com/TrustBound/dream_model/blob/1.0.0/test/snippets/why_option/values_list.sql"><img align="right" alt="Tested snippet" src="https://img.shields.io/badge/%F0%9F%A7%AA_tested-snippet-lightgreen.svg?style=flat-square"></a>

```sql
select v.a from (values (1), (2)) as v(a)
```

Promise the column with `-- not null: a`.

### a child table allows NULL in this column

PostgreSQL 18 and newer. The parent table has `NOT NULL ... NO INHERIT`, and a child table that the query reads allows NULL.

#### A table with a nullable child <a href="https://github.com/TrustBound/dream_model/blob/1.0.0/test/snippets/why_option/child_table.sql"><img align="right" alt="Tested snippet" src="https://img.shields.io/badge/%F0%9F%A7%AA_tested-snippet-lightgreen.svg?style=flat-square"></a>

```sql
select label from things
```

Read only the parent with `from only things`, or add NOT NULL to the child.

### NOT NULL constraint is NOT VALID, old rows may be NULL

PostgreSQL 18 and newer. The NOT NULL constraint of the column is NOT VALID, so old rows can hold NULL.

#### A NOT VALID constraint <a href="https://github.com/TrustBound/dream_model/blob/1.0.0/test/snippets/why_option/not_valid.sql"><img align="right" alt="Tested snippet" src="https://img.shields.io/badge/%F0%9F%A7%AA_tested-snippet-lightgreen.svg?style=flat-square"></a>

```sql
select code from legacy
```

Run `alter table legacy validate constraint ...`, then generate again.

### RETURNING OLD/NEW is NULL for some rows

PostgreSQL 18 and newer. `RETURNING old.x` is NULL for an inserted row, and `new.x` is NULL for a deleted row.

#### RETURNING old <a href="https://github.com/TrustBound/dream_model/blob/1.0.0/test/snippets/why_option/returning_old_new.sql"><img align="right" alt="Tested snippet" src="https://img.shields.io/badge/%F0%9F%A7%AA_tested-snippet-lightgreen.svg?style=flat-square"></a>

```sql
insert into users (id, email) values ($1, $2)
returning old.email, new.email
```

The first `email` (`old.email`) is `Option`. The second one (`new.email`) is `String`.

### MERGE ... NOT MATCHED BY SOURCE leaves source columns NULL

PostgreSQL 17 and newer. In a MERGE with `WHEN NOT MATCHED BY SOURCE`, a column of the source is NULL for the target rows with no source row.

#### MERGE with NOT MATCHED BY SOURCE <a href="https://github.com/TrustBound/dream_model/blob/1.0.0/test/snippets/why_option/merge_not_matched.sql"><img align="right" alt="Tested snippet" src="https://img.shields.io/badge/%F0%9F%A7%AA_tested-snippet-lightgreen.svg?style=flat-square"></a>

```sql
merge into users u using posts p on p.user_id = u.id
when not matched by source then delete
when matched then do nothing
returning u.email, p.title
```

`title` is `Option`. `email` is `String`.

### nullable hint

A `-- nullable:` hint names the column.

#### A nullable hint <a href="https://github.com/TrustBound/dream_model/blob/1.0.0/test/snippets/why_option/nullable_hint.sql"><img align="right" alt="Tested snippet" src="https://img.shields.io/badge/%F0%9F%A7%AA_tested-snippet-lightgreen.svg?style=flat-square"></a>

```sql
-- nullable: email
select email from users
```

Remove the hint to let the schema decide.

## Parameters that are Option

### stored straight into a nullable column

The statement stores the parameter as the whole value of a column, in an INSERT, an UPDATE SET or an ON CONFLICT DO UPDATE SET, and the column accepts NULL in every case. A cast that changes nothing, a domain and a length coercion around the parameter do not change this. A length coercion is the call that PostgreSQL adds for a column such as `varchar(10)`, `char(3)`, `numeric(8, 2)` or `timestamp(0)`. It keeps NULL as NULL.

#### A store into a nullable column <a href="https://github.com/TrustBound/dream_model/blob/1.0.0/test/snippets/why_option/parameter_store.sql"><img align="right" alt="Tested snippet" src="https://img.shields.io/badge/%F0%9F%A7%AA_tested-snippet-lightgreen.svg?style=flat-square"></a>

```sql
insert into contacts (id, email, note) values ($1, $2, $3)
returning id
```

`$3` (`note`) is `Option`. `$1` (`id`) is required, because the column is NOT NULL, and `$2` (`email`) is required, because its domain `strict_text` is NOT NULL.

#### A store into a varchar(10) column <a href="https://github.com/TrustBound/dream_model/blob/1.0.0/test/snippets/why_option/parameter_length.sql"><img align="right" alt="Tested snippet" src="https://img.shields.io/badge/%F0%9F%A7%AA_tested-snippet-lightgreen.svg?style=flat-square"></a>

```sql
insert into sized (id, label) values ($1, $2)
returning id
```

`$2` (`label`, a `varchar(10)` column of the table `sized`) is `Option`.

### params hint

A `-- params:` hint ends the name with `?`.

#### A parameter that can be NULL <a href="https://github.com/TrustBound/dream_model/blob/1.0.0/test/snippets/why_option/parameter_hint.sql"><img align="right" alt="Tested snippet" src="https://img.shields.io/badge/%F0%9F%A7%AA_tested-snippet-lightgreen.svg?style=flat-square"></a>

```sql
-- params: limit?
select id from users where $1::int is null or id < $1
```

## Parameters that are required

A parameter that no rule above makes `Option` is required. The reason tells why.

### required

The statement does not store the parameter straight into a column, for example in a comparison.

#### A comparison <a href="https://github.com/TrustBound/dream_model/blob/1.0.0/test/snippets/why_option/parameter_compared.sql"><img align="right" alt="Tested snippet" src="https://img.shields.io/badge/%F0%9F%A7%AA_tested-snippet-lightgreen.svg?style=flat-square"></a>

```sql
select id from users where email = $1
```

`email = NULL` is never true. To match NULL too, write `email is not distinct from $1` and `-- params: email?`.

### also used outside a column store

The statement stores the parameter, and also uses it somewhere else.

#### A stored and compared parameter <a href="https://github.com/TrustBound/dream_model/blob/1.0.0/test/snippets/why_option/parameter_also_used.sql"><img align="right" alt="Tested snippet" src="https://img.shields.io/badge/%F0%9F%A7%AA_tested-snippet-lightgreen.svg?style=flat-square"></a>

```sql
update users set nickname = $1 where nickname = $1
returning id
```

Use two parameters, or a `-- params:` hint with `?`.

### column is NOT NULL

The column of the store is NOT NULL. See `$1` in [A store into a nullable column](#a-store-into-a-nullable-column-).

### column's domain type is NOT NULL

The type of the column is a domain that is NOT NULL, or its base domain is. See `$2` in [A store into a nullable column](#a-store-into-a-nullable-column-).

### column's domain has a CHECK constraint that may reject NULL

The domain of the column has a CHECK. A CHECK can reject NULL.

#### A domain with a CHECK <a href="https://github.com/TrustBound/dream_model/blob/1.0.0/test/snippets/why_option/parameter_domain_check.sql"><img align="right" alt="Tested snippet" src="https://img.shields.io/badge/%F0%9F%A7%AA_tested-snippet-lightgreen.svg?style=flat-square"></a>

```sql
insert into domain_targets (id, checked, plain) values ($1, $2, $3)
returning id
```

`$2` (`checked`, of the domain `checked_text`) is required. `$3` (`plain`, a domain with no rules) is `Option`.

### a CHECK constraint on this column may reject NULL

A CHECK constraint of the table names the column. A CHECK with a whole-row reference, or with no column, counts for every column.

#### A column with a CHECK <a href="https://github.com/TrustBound/dream_model/blob/1.0.0/test/snippets/why_option/parameter_check.sql"><img align="right" alt="Tested snippet" src="https://img.shields.io/badge/%F0%9F%A7%AA_tested-snippet-lightgreen.svg?style=flat-square"></a>

```sql
insert into checked (id, code) values ($1, $2)
returning id
```

#### A whole-row CHECK <a href="https://github.com/TrustBound/dream_model/blob/1.0.0/test/snippets/why_option/parameter_whole_row_check.sql"><img align="right" alt="Tested snippet" src="https://img.shields.io/badge/%F0%9F%A7%AA_tested-snippet-lightgreen.svg?style=flat-square"></a>

```sql
insert into whole_checked (id, note) values ($1, $2)
returning id
```

The table `whole_checked` has `check (whole_checked is not null)`. It names no column, and it rejects NULL in `note`.

### a partition or child table makes this column NOT NULL

A partition or a child table of the table makes the column NOT NULL.

#### A partition with NOT NULL <a href="https://github.com/TrustBound/dream_model/blob/1.0.0/test/snippets/why_option/parameter_partition.sql"><img align="right" alt="Tested snippet" src="https://img.shields.io/badge/%F0%9F%A7%AA_tested-snippet-lightgreen.svg?style=flat-square"></a>

```sql
insert into events (id, kind, payload) values ($1, $2, $3)
returning id
```

### a CHECK constraint on a partition may reject NULL

A CHECK constraint of a partition or a child table names the column.

#### A partition with a CHECK <a href="https://github.com/TrustBound/dream_model/blob/1.0.0/test/snippets/why_option/parameter_partition_check.sql"><img align="right" alt="Tested snippet" src="https://img.shields.io/badge/%F0%9F%A7%AA_tested-snippet-lightgreen.svg?style=flat-square"></a>

```sql
insert into measures (id, kind, value) values ($1, $2, $3)
returning id
```

### a BEFORE trigger on the table can reject any value

A row-level BEFORE trigger on the table, or on one of its partitions or child tables, can reject the row or change it. dream_model cannot read what the trigger does. A statement-level trigger cannot see the row, so it does not count.

#### A table with a BEFORE trigger <a href="https://github.com/TrustBound/dream_model/blob/1.0.0/test/snippets/why_option/parameter_trigger.sql"><img align="right" alt="Tested snippet" src="https://img.shields.io/badge/%F0%9F%A7%AA_tested-snippet-lightgreen.svg?style=flat-square"></a>

```sql
insert into users (id, email, nickname) values ($1, $2, $3)
returning id
```

`$3` (`nickname`) is required. If the trigger accepts NULL, mark the parameter with `-- params: id, email, nickname?`.

### a row-level security policy can reject the row

The table has row-level security, or a policy with WITH CHECK.

#### A table with row-level security <a href="https://github.com/TrustBound/dream_model/blob/1.0.0/test/snippets/why_option/parameter_row_security.sql"><img align="right" alt="Tested snippet" src="https://img.shields.io/badge/%F0%9F%A7%AA_tested-snippet-lightgreen.svg?style=flat-square"></a>

```sql
insert into secured (id, note) values ($1, $2)
returning id
```

### a rule rewrites the statement into 2 queries, so every parameter is required

A rule of the table adds queries to the statement, for example a `DO ALSO` rule. The added queries can use each parameter anywhere, and dream_model does not trace them. So each parameter is required. The number is the count of queries after the rewrite. Here the rule `log_note` copies `note` into `log.note`, which is NOT NULL.

#### A table with a DO ALSO rule <a href="https://github.com/TrustBound/dream_model/blob/1.0.0/test/snippets/why_option/parameter_rule.sql"><img align="right" alt="Tested snippet" src="https://img.shields.io/badge/%F0%9F%A7%AA_tested-snippet-lightgreen.svg?style=flat-square"></a>

```sql
insert into logged (id, note) values ($1, $2)
returning id
```

If the rule accepts NULL, mark the parameter with `-- params: id, note?`.

### the parameter is cast to a NOT NULL domain type

The parameter goes through a cast to a domain that is NOT NULL on its way to the column, or the type of the parameter is such a domain. The cast rejects NULL, also when the column accepts NULL.

#### A cast to a NOT NULL domain <a href="https://github.com/TrustBound/dream_model/blob/1.0.0/test/snippets/why_option/parameter_cast_domain.sql"><img align="right" alt="Tested snippet" src="https://img.shields.io/badge/%F0%9F%A7%AA_tested-snippet-lightgreen.svg?style=flat-square"></a>

```sql
insert into notes (id, plain_text) values ($1, $2::strict_text)
returning id
```

Remove the cast, or cast to the base type.

### the parameter is cast to a domain type with a CHECK constraint that may reject NULL

The parameter goes through a cast to a domain with a CHECK. A CHECK can reject NULL.

#### A cast to a domain with a CHECK <a href="https://github.com/TrustBound/dream_model/blob/1.0.0/test/snippets/why_option/parameter_cast_domain_check.sql"><img align="right" alt="Tested snippet" src="https://img.shields.io/badge/%F0%9F%A7%AA_tested-snippet-lightgreen.svg?style=flat-square"></a>

```sql
insert into notes (id, plain_text) values ($1, $2::text::checked_text)
returning id
```

### a generated column is computed from this column and may reject NULL

A generated column of the table uses the column. The generated column can be NOT NULL or have a CHECK, so NULL in the column can make the row fail. Here `b` is `upper(a)` and NOT NULL.

#### A column that a generated column uses <a href="https://github.com/TrustBound/dream_model/blob/1.0.0/test/snippets/why_option/parameter_generated.sql"><img align="right" alt="Tested snippet" src="https://img.shields.io/badge/%F0%9F%A7%AA_tested-snippet-lightgreen.svg?style=flat-square"></a>

```sql
insert into gen_from (id, a) values ($1, $2)
returning id
```

### the column is in a partition key, and a NULL may find no partition

The column is part of the partition key of the table or of one of its partitions. A NULL key finds no partition unless a partition takes NULL. An expression in a key counts for every column.

#### A partition key column <a href="https://github.com/TrustBound/dream_model/blob/1.0.0/test/snippets/why_option/parameter_partition_key.sql"><img align="right" alt="Tested snippet" src="https://img.shields.io/badge/%F0%9F%A7%AA_tested-snippet-lightgreen.svg?style=flat-square"></a>

```sql
insert into keyed (id, kind) values ($1, $2)
returning id
```

### a view's WITH CHECK OPTION may reject the row

The statement writes through a view with `WITH CHECK OPTION`. The condition of the view can reject a row with NULL. Here `wco_view` has `where note is not null`.

#### A view WITH CHECK OPTION <a href="https://github.com/TrustBound/dream_model/blob/1.0.0/test/snippets/why_option/parameter_check_option.sql"><img align="right" alt="Tested snippet" src="https://img.shields.io/badge/%F0%9F%A7%AA_tested-snippet-lightgreen.svg?style=flat-square"></a>

```sql
insert into wco_view (id, note) values ($1, $2)
returning id
```

### the statement writes into relation kind v (a view with an INSTEAD OF trigger or a foreign table), which may reject NULL

The statement writes into a relation that is not a table: a view with an `INSTEAD OF` trigger (`v`), or a foreign table (`f`). A partition or a child table that is a foreign table gives the same reason for its kind. dream_model cannot read what the trigger or the remote server accepts, so each stored parameter is required.

#### A view with an INSTEAD OF trigger <a href="https://github.com/TrustBound/dream_model/blob/1.0.0/test/snippets/why_option/parameter_view_trigger.sql"><img align="right" alt="Tested snippet" src="https://img.shields.io/badge/%F0%9F%A7%AA_tested-snippet-lightgreen.svg?style=flat-square"></a>

```sql
insert into iot_view (id, note) values ($1, $2)
returning id
```

If the trigger accepts NULL, mark the parameter with `-- params: id, note?`.

## Reasons that no query gives

The rules also have reasons for a tree that they cannot trace: `column not found in catalog`, `join column could not be traced`, `column could not be traced`, `CTE not found` and, for a parameter, `column not found`. No known SQL statement on PostgreSQL 16 to 19 gives them. They make a value `Option` or a parameter required when the tree has a form that the rules do not know. If you see one, report the query in an issue.

## Where to go next

- [Hints](hints.md): `not null`, `nullable` and `params`
- [Types](types.md): the Gleam type of each column
