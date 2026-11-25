//// Runs the generated models against the database in
//// MODEL_APP_DATABASE_URL and prints one line for each check, each line
//// starting with `| `. The tests of dream_model compare the lines with
//// expected_output.txt.

import app/controllers/user_controller
import app/models/post
import app/models/sample
import app/models/user
import app/startup
import dream/http/error.{type Error}
import dream/http/response
import dream_postgres/client
import gleam/int
import gleam/io
import gleam/list
import gleam/option.{None, Some}
import gleam/result
import gleam/string
import gleam/time/calendar
import gleam/time/timestamp

@external(erlang, "model_app_ffi", "get_env")
fn get_env(name: String) -> Result(String, Nil)

pub fn main() -> Nil {
  let assert Ok(url) = get_env("MODEL_APP_DATABASE_URL")
  let assert Ok(db) = client.from_url(url)
  show("startup.check_models", startup.check_models(db))
  check_users(db)
  show_response("user_controller.show", user_controller.show(db, 1))
  show_response(
    "user_controller.show of a missing user",
    user_controller.show(db, 99),
  )
  check_posts(db)
  check_samples(db)
  show_error("user.delete of a user with posts", user.delete(db, 1))
  run(db, "alter table users add column age int")
  show(
    "startup.check_models after a new column",
    startup.check_models(db) |> result.map_error(first_line),
  )
}

/// The first line of a message. The other lines hold fingerprints, which
/// are different on each PostgreSQL version.
fn first_line(message: String) -> String {
  string.split(message, "\n") |> list.first |> result.unwrap(message)
}

fn show(label: String, value: a) -> Nil {
  io.println("| " <> label <> ": " <> string.inspect(value))
}

fn show_response(label: String, found: response.Response) -> Nil {
  io.println(
    "| "
    <> label
    <> ": "
    <> int.to_string(found.status)
    <> " "
    <> string.inspect(found.body),
  )
}

fn show_error(label: String, value: Result(a, Error)) -> Nil {
  let text = case value {
    Ok(found) -> "Ok " <> string.inspect(found)
    Error(found) ->
      int.to_string(error.to_status_code(found)) <> " " <> error.message(found)
  }
  io.println("| " <> label <> ": " <> text)
}

fn check_users(db: client.Connection) -> Nil {
  show("user.create", user.create(db, "ann@example.com", Some("Ann")))
  show_error(
    "user.create of a taken email",
    user.create(db, "ANN@example.com", None),
  )
  show(
    "user.create without a nickname",
    user.create(db, "bob@example.com", None),
  )
  show("user.find", user.find(db, 1))
  show_error("user.find of a missing user", user.find(db, 99))
  show("user.count", user.count(db))
  show("user.find_by_email", user.find_by_email(db, "BOB@example.com"))
  show("user.find_by_email of no user", user.find_by_email(db, "nobody"))
  show("user.list", user.list(db))
  show("user.search", user.search(db, "%example.com", None))
  show("user.search with a nickname", user.search(db, "%", Some("Ann")))
  show("user.rename", user.rename(db, 3, Some("Bobby")))
  show("user.find after rename", user.find(db, 3))
  show("user.rename to NULL", user.rename(db, 3, None))
  show("user.find after rename to NULL", user.find(db, 3))
  show(
    "user.created_at is a time after 2020",
    user.created_at(db, 1)
      |> result.map(fn(created) {
        timestamp.compare(created, timestamp.from_unix_seconds(1_577_836_800))
      }),
  )
  show("user.delete", user.delete(db, 3))
  show_error("user.find after delete", user.find(db, 3))
}

fn check_posts(db: client.Connection) -> Nil {
  show("post.create", post.create(db, 1, "Hello", None))
  show("post.publish", post.publish(db, 1))
  show("post.publish of a missing post", post.publish(db, 99))
  show("post.authors", post.authors(db, True))
  show("post.by_user", post.by_user(db, 1))
  show("post.titles", post.titles(db))
  show("post.total", post.total(db, 1))
  show_error("post.total of a user with no posts", post.total(db, 2))
}

/// Stores infinity in a row, and shows the error of sample.get for each
/// time column that holds it.
fn check_infinity(db: client.Connection) -> Nil {
  run(db, "update samples set happened_at = 'infinity' where id = 1")
  show_error("sample.get of an infinite timestamp", sample.get(db, 1))
  run(
    db,
    "update samples set happened_at = null, happened_at_zone = '-infinity' where id = 1",
  )
  show_error("sample.get of an infinite timestamptz", sample.get(db, 1))
  run(
    db,
    "update samples set happened_at_zone = null, day = 'infinity' where id = 1",
  )
  show_error("sample.get of an infinite date", sample.get(db, 1))
  run(db, "update samples set day = null where id = 1")
}

/// Sends each numeric text to PostgreSQL and reads it back: the text must
/// come back exactly, with its scale and its trailing zeros.
fn check_numeric(db: client.Connection) -> Nil {
  [
    "1.50", "123456789012345678901234567890.123456789012345678901234567890",
    "0.000000000000000000000000000000000000000000000000001", "-42.10", "NaN",
    "Infinity", "-Infinity",
  ]
  |> list.each(fn(text) {
    show(
      "sample.echo_amount of " <> text,
      sample.echo_amount(db, text)
        |> result.map(fn(exact) { #(exact, exact == text) }),
    )
  })
  show_error(
    "sample.echo_amount of text that is not a number",
    sample.echo_amount(db, "12,50"),
  )
  show(
    "sample.amounts of a text array",
    sample.amounts(db, [Some("1.50"), None, Some("-0.001")]),
  )
  run(db, "update samples set amount = 99999999999999999999.99 where id = 1")
  show(
    "sample.get of a large amount",
    sample.get(db, 1) |> result.map(fn(found) { found.amount }),
  )
}

/// Reads the tags of row 1 with the promise that no element is NULL: first
/// with a NULL element, then with none, then with no array.
fn check_element_promise(db: client.Connection) -> Nil {
  show_error("sample.tags with a NULL element", sample.tags(db, 1))
  run(db, "update samples set tags = '{a,b}' where id = 1")
  show("sample.tags with no NULL element", sample.tags(db, 1))
  run(db, "update samples set tags = null where id = 1")
  show("sample.tags of a NULL array", sample.tags(db, 1))
}

fn run(db: client.Connection, sql: String) -> Nil {
  let assert Ok(_) =
    sql
    |> client.query
    |> client.execute(db)
  Nil
}

fn check_samples(db: client.Connection) -> Nil {
  let happened_at =
    timestamp.from_calendar(
      calendar.Date(2024, calendar.February, 29),
      calendar.TimeOfDay(13, 14, 15, 0),
      calendar.utc_offset,
    )
  let inserted =
    sample.insert(
      db,
      Some(7),
      Some(9_000_000_000),
      Some(42),
      Some(1.5),
      Some(2.25),
      Some("12.50"),
      Some("first"),
      Some("abc"),
      Some("short"),
      Some("Mixed"),
      Some("{\"a\": 1}"),
      Some("{\"b\": [1, 2]}"),
      Some("happy"),
      Some(True),
      Some(<<1, 2, 3>>),
      Some(<<0:size(120), 1>>),
      Some(happened_at),
      Some(happened_at),
      Some(calendar.Date(2024, calendar.February, 29)),
      Some(calendar.TimeOfDay(13, 14, 15, 0)),
      Some([Some("a"), None]),
      Some([Some(1), Some(2)]),
      5,
    )
  show("sample.insert", inserted)
  show("sample.get", sample.get(db, 1))
  show(
    "timestamp round trip",
    sample.get(db, 1)
      |> result.map(fn(found) { found.happened_at == Some(happened_at) }),
  )
  show(
    "array with a NULL element round trip",
    sample.get(db, 1)
      |> result.map(fn(found) { found.tags == Some([Some("a"), None]) }),
  )
  check_infinity(db)
  check_numeric(db)
  check_element_promise(db)
  show_error(
    "sample.insert of a taken label",
    sample.insert(
      db,
      None,
      None,
      None,
      None,
      None,
      None,
      Some("first"),
      Some("xyz"),
      None,
      None,
      None,
      None,
      None,
      None,
      None,
      None,
      None,
      None,
      None,
      None,
      None,
      None,
      1,
    ),
  )
}
