//// Runs the generated models against the database in
//// MODEL_APP_DATABASE_URL and prints one line for each check, each line
//// starting with `| `. The tests of dream_model compare the lines with
//// expected_output.txt.

import app/controllers/user_controller.{create}
import app/models/post.{authors, by_user, publish, titles, total}
import app/models/sample.{amounts, echo_amount, get, insert, tags}
import app/models/user.{count, created_at, delete, find, find_by_email, rename, search}
import app/startup.{check_models}
import dream/http/response.{type Response, Response}
import dream_errors.{type Error, kind_name}
import dream_postgres/client.{
  type Connection, type QueryError, execute, from_url, query,
  violated_constraint,
}
import gleam/int.{to_string}
import gleam/io.{println}
import gleam/list.{each, first}
import gleam/option.{type Option, None, Some}
import gleam/result.{map, map_error, unwrap}
import gleam/string.{inspect, split, split_once}
import gleam/time/calendar.{type Date, type TimeOfDay, Date, February, TimeOfDay, utc_offset}
import gleam/time/timestamp.{compare, from_calendar, from_unix_seconds}

@external(erlang, "model_app_ffi", "get_env")
fn get_env(name: String) -> Result(String, Nil)

pub fn main() -> Nil {
  let assert Ok(url) = get_env("MODEL_APP_DATABASE_URL")
  let assert Ok(db) = from_url(url)
  show("startup.check_models", check_models(db))
  check_users(db)
  show_response("user_controller.show", user_controller.show(db, 1))
  show_response(
    "user_controller.show of a missing user",
    user_controller.show(db, 99),
  )
  show_response(
    "user_controller.create of a taken email",
    create(db, "ann@example.com"),
  )
  check_posts(db)
  check_samples(db)
  show_error("user.delete of a user with posts", delete(db, 1))
  run(db, "alter table users add column age int")
  show(
    "startup.check_models after a new column",
    check_models(db) |> map_error(first_line),
  )
}

/// The first line of a message. The other lines hold fingerprints, which
/// are different on each PostgreSQL version.
fn first_line(message: String) -> String {
  split(message, "\n") |> first |> unwrap(message)
}

fn show(label: String, value: a) -> Nil {
  println("| " <> label <> ": " <> inspect(value))
}

fn show_response(label: String, found: Response) -> Nil {
  println(
    "| "
    <> label
    <> ": "
    <> to_string(found.status)
    <> " "
    <> inspect(found.body),
  )
}

/// Shows the error of a model function as data: its kind, its message and
/// the kind of its cause. The cause of a `Conflict` also shows the name of
/// its constraint, from `violated_constraint`. The details of a
/// cause can differ between PostgreSQL versions, so only its constructor
/// shows.
fn show_error(label: String, value: Result(a, Error(QueryError))) -> Nil {
  let text = case value {
    Ok(found) -> "Ok " <> inspect(found)
    Error(error) ->
      kind_name(error)
      <> " "
      <> dream_errors.message(error)
      <> cause_text(dream_errors.cause(error))
  }
  println("| " <> label <> ": " <> text)
}

fn cause_text(cause: Option(QueryError)) -> String {
  case cause {
    None -> ""
    Some(cause) ->
      case violated_constraint(cause) {
        Ok(constraint) ->
          " (cause: " <> cause_kind(cause) <> " of " <> constraint <> ")"
        Error(Nil) -> " (cause: " <> cause_kind(cause) <> ")"
      }
  }
}

fn cause_kind(cause: QueryError) -> String {
  let text = inspect(cause)
  case split_once(text, "(") {
    Ok(#(kind, _)) -> kind
    Error(Nil) -> text
  }
}

fn check_users(db: Connection) -> Nil {
  show("user.create", user.create(db, "ann@example.com", Some("Ann")))
  show_error(
    "user.create of a taken email",
    user.create(db, "ANN@example.com", None),
  )
  show(
    "user.create without a nickname",
    user.create(db, "bob@example.com", None),
  )
  show("user.find", find(db, 1))
  show_error("user.find of a missing user", find(db, 99))
  show("user.count", count(db))
  show("user.find_by_email", find_by_email(db, "BOB@example.com"))
  show("user.find_by_email of no user", find_by_email(db, "nobody"))
  show("user.list", user.list(db))
  show("user.search", search(db, "%example.com", None))
  show("user.search with a nickname", search(db, "%", Some("Ann")))
  show("user.rename", rename(db, 3, Some("Bobby")))
  show("user.find after rename", find(db, 3))
  show("user.rename to NULL", rename(db, 3, None))
  show("user.find after rename to NULL", find(db, 3))
  show(
    "user.created_at is a time after 2020",
    created_at(db, 1)
      |> map(fn(created) {
        compare(created, from_unix_seconds(1_577_836_800))
      }),
  )
  show("user.delete", delete(db, 3))
  show_error("user.find after delete", find(db, 3))
}

fn check_posts(db: Connection) -> Nil {
  show("post.create", post.create(db, 1, "Hello", None))
  show("post.publish", publish(db, 1))
  show("post.publish of a missing post", publish(db, 99))
  show("post.authors", authors(db, True))
  show("post.by_user", by_user(db, 1))
  show("post.titles", titles(db))
  show("post.total", total(db, 1))
  show_error("post.total of a user with no posts", total(db, 2))
}

/// Stores infinity in a row, and shows the error of sample.get for each
/// time column that holds it.
fn check_infinity(db: Connection) -> Nil {
  run(db, "update samples set happened_at = 'infinity' where id = 1")
  show_error("sample.get of an infinite timestamp", get(db, 1))
  run(
    db,
    "update samples set happened_at = null, happened_at_zone = '-infinity' where id = 1",
  )
  show_error("sample.get of an infinite timestamptz", get(db, 1))
  run(
    db,
    "update samples set happened_at_zone = null, day = 'infinity' where id = 1",
  )
  show_error("sample.get of an infinite date", get(db, 1))
  run(db, "update samples set day = null where id = 1")
}

/// Sends each numeric text to PostgreSQL and reads it back: the text must
/// come back exactly, with its scale and its trailing zeros.
fn check_numeric(db: Connection) -> Nil {
  [
    "1.50", "123456789012345678901234567890.123456789012345678901234567890",
    "0.000000000000000000000000000000000000000000000000001", "-42.10", "NaN",
    "Infinity", "-Infinity",
  ]
  |> each(fn(text) {
    show(
      "sample.echo_amount of " <> text,
      echo_amount(db, text)
        |> map(fn(exact) { #(exact, exact == text) }),
    )
  })
  show_error(
    "sample.echo_amount of text that is not a number",
    echo_amount(db, "12,50"),
  )
  show(
    "sample.amounts of a text array",
    amounts(db, [Some("1.50"), None, Some("-0.001")]),
  )
  run(db, "update samples set amount = 99999999999999999999.99 where id = 1")
  show(
    "sample.get of a large amount",
    get(db, 1) |> map(fn(found) { found.amount }),
  )
}

/// Reads the tags of row 1 with the promise that no element is NULL: first
/// with a NULL element, then with none, then with no array.
fn check_element_promise(db: Connection) -> Nil {
  show_error("sample.tags with a NULL element", tags(db, 1))
  run(db, "update samples set tags = '{a,b}' where id = 1")
  show("sample.tags with no NULL element", tags(db, 1))
  run(db, "update samples set tags = null where id = 1")
  show("sample.tags of a NULL array", tags(db, 1))
}

fn run(db: Connection, sql: String) -> Nil {
  let assert Ok(_) =
    sql
    |> query
    |> execute(db)
  Nil
}

fn check_samples(db: Connection) -> Nil {
  let happened_at =
    from_calendar(
      Date(2024, February, 29),
      TimeOfDay(13, 14, 15, 0),
      utc_offset,
    )
  let inserted =
    insert(
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
      Some(Date(2024, February, 29)),
      Some(TimeOfDay(13, 14, 15, 0)),
      Some([Some("a"), None]),
      Some([Some(1), Some(2)]),
      5,
    )
  show("sample.insert", inserted)
  show("sample.get", get(db, 1))
  show(
    "timestamp round trip",
    get(db, 1)
      |> map(fn(found) { found.happened_at == Some(happened_at) }),
  )
  show(
    "array with a NULL element round trip",
    get(db, 1)
      |> map(fn(found) { found.tags == Some([Some("a"), None]) }),
  )
  check_infinity(db)
  check_numeric(db)
  check_element_promise(db)
  show_error(
    "sample.insert of a taken label",
    insert(
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
