//// The databases of the generator tests: `dream_model_generator` holds the
//// schema of the end-to-end app (e2e/model_app/schema.sql) and a few more
//// objects for the refusals, and `dream_model_e2e` holds only the schema
//// of the end-to-end app.
////
//// `create` drops and creates both databases on a server, so each test
//// run starts from the same state.

import dream_model/postgres/wire.{close, error_to_string, simple_query}
import fixtures/servers.{connect, database_name, default_database}
import gleam/result.{map_error, replace, try}
import simplifile.{describe_error, read}

/// The database of the generator tests on each server, with the prefix of
/// `servers.database_name`.
pub fn database() -> String {
  database_name("dream_model_generator")
}

/// The database of the end-to-end app on each server, with the prefix of
/// `servers.database_name`.
pub fn e2e_database() -> String {
  database_name("dream_model_e2e")
}

/// The schema file of the end-to-end app.
pub const e2e_schema_path = "e2e/model_app/schema.sql"

/// The objects of the generator tests that the end-to-end app does not
/// have.
pub const extra_schema =
  "
create view user_emails as select id, email from users;
create view post_authors as select u.id, p.title from users u join posts p on p.user_id = u.id;
create table events (id int, kind text, note text, primary key (id, kind))
  partition by list (kind);
create table events_a partition of events for values in ('a');
create table logged (id int primary key, note text);
create table log (note text);
create rule log_insert as on insert to logged do also insert into log values (new.note);
create table spans (id int primary key, span interval, label text unique);
create table \"Odd Names\" (\"Mixed Case\" int primary key, \"type\" text);
create table reserved_names (db int primary key, \"9lives\" int, decode int);
create table accounts (id int primary key, handle text constraint accounts_handle_key unique);
create table audits (id int primary key, handle text constraint accounts_handle_key check (handle <> ''));
create table badges (id int primary key, code text);
create unique index badges_code_index on badges (code);
create schema archive;
create table archive.badges (code text);
create index badges_code_index on archive.badges (code);
create table teams (id int constraint teams_id_key unique);
create table members (team_id int constraint teams_id_key references teams (id));
create domain team_code as text constraint teams_id_key check (value <> '');
create domain money_amount as numeric(12, 2);
create table prices (
  id int primary key,
  amount numeric(10, 2) not null,
  cost money_amount,
  history numeric[],
  tags text[] not null,
  labels text[]
);
"

/// Drops and creates both databases on the server of a version.
pub fn create(version: Int) -> Result(Nil, String) {
  use schema <- try(
    read(e2e_schema_path)
    |> map_error(describe_error),
  )
  use Nil <- try(recreate(version, database(), schema <> extra_schema))
  recreate(version, e2e_database(), schema)
}

/// Drops and creates one database and runs the schema in it.
pub fn recreate(
  version: Int,
  name: String,
  schema: String,
) -> Result(Nil, String) {
  let admin = connect(version, default_database)
  let created = {
    use _ <- try(simple_query(
      admin,
      "drop database if exists " <> name <> " with (force)",
    ))
    simple_query(admin, "create database " <> name)
  }
  let _ = close(admin)
  use _ <- try(created |> map_error(error_to_string))
  let connection = connect(version, name)
  let filled = simple_query(connection, schema)
  let _ = close(connection)
  filled
  |> replace(Nil)
  |> map_error(error_to_string)
}

/// Returns the URL of the generator database on the server of a version.
pub fn url(version: Int) -> String {
  servers.url(version, database())
}
