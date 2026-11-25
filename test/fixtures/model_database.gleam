//// The databases of the generator tests: `dream_model_generator` holds the
//// schema of the end-to-end app (e2e/model_app/schema.sql) and a few more
//// objects for the refusals, and `dream_model_e2e` holds only the schema
//// of the end-to-end app.
////
//// `create` drops and creates both databases on a server, so each test
//// run starts from the same state.

import dream_model/postgres/wire
import fixtures/servers
import gleam/result
import simplifile

/// The database of the generator tests on each server.
pub const database = "dream_model_generator"

/// The database of the end-to-end app on each server.
pub const e2e_database = "dream_model_e2e"

/// The schema file of the end-to-end app.
pub const e2e_schema_path = "e2e/model_app/schema.sql"

/// The objects of the generator tests that the end-to-end app does not
/// have.
pub const extra_schema =
  "
create view user_emails as select id, email from users;
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
"

/// Drops and creates both databases on the server of a version.
pub fn create(version: Int) -> Result(Nil, String) {
  use schema <- result.try(
    simplifile.read(e2e_schema_path)
    |> result.map_error(simplifile.describe_error),
  )
  use Nil <- result.try(recreate(version, database, schema <> extra_schema))
  recreate(version, e2e_database, schema)
}

/// Drops and creates one database and runs the schema in it.
pub fn recreate(
  version: Int,
  name: String,
  schema: String,
) -> Result(Nil, String) {
  let admin = servers.connect(version, servers.default_database)
  let created = {
    use _ <- result.try(wire.simple_query(
      admin,
      "drop database if exists " <> name <> " with (force)",
    ))
    wire.simple_query(admin, "create database " <> name)
  }
  let _ = wire.close(admin)
  use _ <- result.try(created |> result.map_error(wire.error_to_string))
  let connection = servers.connect(version, name)
  let filled = wire.simple_query(connection, schema)
  let _ = wire.close(connection)
  filled
  |> result.replace(Nil)
  |> result.map_error(wire.error_to_string)
}

/// Returns the URL of the generator database on the server of a version.
pub fn url(version: Int) -> String {
  servers.url(version, database)
}
