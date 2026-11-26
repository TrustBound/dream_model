//// The database of the attack tests: the schema, the data sets and the
//// statement that clears the data between runs. They are the ones of the
//// proof of concept, with a few objects added for the computed values that
//// are never NULL.
////
//// `create` drops and creates the database on a server, so each test run
//// starts from the same state.

import dream_model/postgres/wire.{close, error_to_string, simple_query}
import fixtures/servers.{connect, database_name, default_database}
import gleam/list.{append}
import gleam/result.{map_error, replace, try}

/// The name of the attack database on each server, with the prefix of
/// `servers.database_name`.
pub fn database() -> String {
  database_name("dream_model_attack")
}

/// The schema on every version.
pub const schema =
  "
create table users (id int primary key, email text not null, nickname text, created_at timestamp not null default now());
create table posts (id int primary key, user_id int not null, title text not null, body text);
create table tags (post_id int not null, tag text not null);
create domain strict_text as text not null;
create table contacts (id int primary key, email strict_text, note text);
create table checked (id int primary key, code text check (code is not null), other text check (other <> ''));
create table animals (id int not null, name text not null);
create table dogs (bark text) inherits (animals);
create table events (id int not null, kind text not null, payload text) partition by list (kind);
create table events_a partition of events for values in ('a');
create table events_b partition of events (payload not null) for values in ('b');
create table \"Weird Table\" (\"Weird Name\" text not null, \"with\"\"quote\" int not null, \"a(b)\" text not null, \"x:y{z}\" text not null, \"ñame\" text, \"select\" int not null);
create view v_user_posts as select u.id, u.email, p.title from users u left join posts p on p.user_id = u.id;
create view v_inner as select u.id, u.email, p.title from users u join posts p on p.user_id = u.id;
create view v_of_view as select * from v_user_posts;
create view v_union as select email as v from users union all select title from posts;
create view v_computed as select id, lower(email) as low from users;
create view v_secure with (security_barrier) as select id, email from users;
create view v_updatable as select id, email, nickname from users;
create materialized view mv_users as select id, email from users;
create table generated_t (id int primary key, a text not null, b text generated always as (upper(a)) stored not null);
create or replace function reject_null_nick() returns trigger language plpgsql as $$
begin if new.nickname is null and new.email = 'trigger@example.com' then raise exception 'nickname required'; end if; return new; end $$;
create trigger t_reject before insert on users for each row execute function reject_null_nick();
"

/// More schema for the computed values that are never NULL: an enum with
/// an equality operator that returns NULL, and an aggregate named `count`
/// outside `pg_catalog` that returns NULL. Also, for parameters: domains
/// with a CHECK and without rules, a table with row-level security, a
/// partition with a CHECK, and the `sized` tables, whose columns have a
/// length or a precision, so that a stored parameter is inside a length
/// coercion.
pub const schema_computed =
  "
create type mood as enum ('happy', 'sad');
create function mood_equal(mood, mood) returns boolean language sql immutable as 'select null::boolean';
create operator = (leftarg = mood, rightarg = mood, function = mood_equal);
create function keep_null(bigint, text) returns bigint language sql immutable as 'select null::bigint';
create aggregate count(text) (sfunc = keep_null, stype = bigint);
create domain checked_text as text check (value <> '');
create domain plain_text as text;
create table domain_targets (id int primary key, checked checked_text, plain plain_text);
create table secured (id int primary key, note text);
alter table secured enable row level security;
create table measures (id int not null, kind text not null, value text) partition by list (kind);
create table measures_a partition of measures (constraint value_check check (value <> '')) for values in ('a');
create table sized (id int primary key, label varchar(10), code char(3), flags bit(4), more_flags varbit(8), amount numeric(8, 2), happened timestamp(0), happened_zone timestamptz(0), clock time(0), span interval day to second(0));
create table sized_checked (id int primary key, label varchar(10) check (label <> ''));
create domain short_text as varchar(10) check (value <> '');
create domain short_required as varchar(10) not null;
create table sized_domains (id int primary key, checked short_text, required short_required);
create table sized_triggered (id int primary key, label varchar(10));
create function keep_label() returns trigger language plpgsql as $$ begin return new; end $$;
create trigger t_keep before insert or update on sized_triggered for each row execute function keep_label();
create table sized_secured (id int primary key, label varchar(10));
alter table sized_secured enable row level security;
create table sized_events (id int not null, kind text not null, label varchar(10)) partition by list (kind);
create table sized_events_a partition of sized_events for values in ('a');
create table sized_events_b partition of sized_events (label not null) for values in ('b');
"

/// The schema of the review attacks: a DO ALSO rule, a table for domain
/// casts of a parameter, a generated column, a partition key, a view WITH
/// CHECK OPTION, a view with an INSTEAD OF trigger, whole-row and
/// column-free CHECK constraints, and foreign tables of postgres_fdw over
/// the same database: a foreign table, a foreign table with a NOT NULL
/// column and a CHECK (which PostgreSQL does not enforce on a foreign
/// table), a foreign child table and a foreign partition. The foreign rows are committed, so a rolled-back run sees
/// them.
pub const schema_review =
  "
create table logged (id int primary key, note text);
create table log (note text not null);
create rule log_note as on insert to logged do also insert into log values (new.note);
create table notes (id int primary key, plain_text text);
create table gen_from (id int primary key, a text, b text generated always as (upper(a)) stored not null);
create table keyed (id int not null, kind text) partition by list (kind);
create table keyed_a partition of keyed for values in ('a');
create table keyed_expression (id int not null, kind text) partition by list (lower(kind));
create function noop_statement() returns trigger language plpgsql as $$ begin return null; end $$;
create table statement_triggered (id int primary key, note text);
create trigger t_statement before insert on statement_triggered for each statement execute function noop_statement();
create table after_triggered (id int primary key, note text);
create trigger t_after after insert on after_triggered for each row execute function noop_statement();
create table wco_base (id int primary key, note text);
create view wco_view as select id, note from wco_base where note is not null with check option;
create table iot_base (id int primary key, note text);
create view iot_view as select id, note from iot_base;
create function iot_insert() returns trigger language plpgsql as $$
begin if new.note is null then raise exception 'note required'; end if; insert into iot_base values (new.id, new.note); return new; end $$;
create trigger t_iot instead of insert on iot_view for each row execute function iot_insert();
create table whole_checked (id int primary key, note text, constraint whole_row check (whole_checked is not null));
create table free_checked (id int primary key, note text, constraint no_column check (pg_catalog.now() is not null));
create extension if not exists postgres_fdw;
do $$ begin execute format('create server loopback foreign data wrapper postgres_fdw options (host %L, port %L, dbname %L)', 'localhost', '5432', pg_catalog.current_database()); end $$;
create user mapping for current_user server loopback options (user 'dream', password 'dream');
create table remote_source (id int, note text);
insert into remote_source values (null, null);
create table remote_parts (id int, kind text, note text not null);
create foreign table remote_notes (id int, note text) server loopback options (table_name 'remote_source');
create foreign table remote_checked (id int not null, note text check (note <> '')) server loopback options (table_name 'remote_source');
create table fparent (id int not null, note text);
create foreign table fchild () inherits (fparent) server loopback options (table_name 'remote_source');
create table fpart (id int not null, kind text not null, note text) partition by list (kind);
create table fpart_a partition of fpart for values in ('a');
create foreign table fpart_r partition of fpart for values in ('r') server loopback options (table_name 'remote_parts');
"

/// The schema for PostgreSQL 18 and newer.
pub const schema_18 =
  "
create table things (id int not null, label text not null no inherit);
create table child_things () inherits (things);
alter table child_things alter column label drop not null;
create table legacy (id int primary key, code text);
insert into legacy values (1, null);
alter table legacy add constraint legacy_code_nn not null code not valid;
create table virt (id int primary key, a text not null, b text generated always as (lower(a)) virtual not null);
"

/// Clears the data of the tables that the data sets fill.
pub const reset =
  "truncate users, posts, tags, contacts, checked, animals, dogs, events, \"Weird Table\", generated_t"

/// The data sets on every version: a label and the SQL that fills the
/// tables.
pub const data_sets = [
  #("empty", ""),
  #(
    "users only",
    "insert into users (id, email, nickname) values (1, 'a@x', null), (2, 'b@x', 'bee');insert into animals values (1, 'cat'); insert into dogs values (2, 'rex', 'woof');insert into contacts values (1, 'c@x', null); insert into events values (1, 'a', null), (2, 'b', 'p');insert into \"Weird Table\" values ('w', 1, 'ab', 'xy', null, 3); insert into generated_t (id, a) values (1, 'q');",
  ),
  #(
    "orphans",
    "insert into users (id, email, nickname) values (1, 'a@x', null), (2, 'b@x', 'bee');insert into posts values (1, 1, 'hello', null), (2, 99, 'orphan', 'b');insert into tags values (1, 't'), (77, 'lost');",
  ),
  #(
    "dense",
    "insert into users (id, email, nickname) values (1, 'a@x', 'aa'), (2, 'b@x', null), (3, 'c@x', 'cc');insert into posts values (1, 1, 'p1', 'b1'), (2, 1, 'p2', null), (3, 2, 'p3', 'b3'), (4, 3, 'p4', null);insert into tags values (1, 'x'), (2, 'y'), (3, 'z');",
  ),
]

/// The data set added on PostgreSQL 18 and newer.
pub const data_sets_18 = [
  #(
    "legacy rows",
    "insert into child_things values (5, null); insert into things values (6, 'ok');",
  ),
]

/// Returns the data sets of a version.
pub fn data_sets_for(version: Int) -> List(#(String, String)) {
  case version >= 18 {
    True -> append(data_sets, data_sets_18)
    False -> data_sets
  }
}

/// Drops and creates the attack database on the server of a version, and
/// creates the schema in it.
pub fn create(version: Int) -> Result(Nil, String) {
  let database = database()
  let admin = connect(version, default_database)
  let created = {
    use _ <- try(simple_query(
      admin,
      "drop database if exists " <> database <> " with (force)",
    ))
    simple_query(admin, "create database " <> database)
  }
  let _ = close(admin)
  use _ <- try(created |> map_error(error_to_string))
  let connection = connect(version, database)
  let filled = {
    use _ <- try(simple_query(connection, schema))
    use _ <- try(simple_query(connection, schema_computed))
    use _ <- try(simple_query(connection, schema_review))
    case version >= 18 {
      True -> simple_query(connection, schema_18)
      False -> Ok([])
    }
  }
  let _ = close(connection)
  filled
  |> replace(Nil)
  |> map_error(error_to_string)
}
