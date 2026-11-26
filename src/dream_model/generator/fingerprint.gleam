//// The schema fingerprint of a generated module: the SHA-256 hash of the
//// catalog facts of its tables, the same value that
//// `dream_postgres/client.schema_fingerprint` gives for the database.
////
//// The SQL is `client.schema_fingerprint_sql` of dream_postgres, run with
//// dream_model's own connection, so both sides read the same facts.

import dream_model/nullability.{type AnalysisError, type Analyzer, execute}
import dream_postgres/client.{schema_fingerprint_sql}
import gleam/list.{flat_map}
import gleam/option.{Some, values}
import gleam/result
import gleam/string.{concat, join, replace}

@external(erlang, "dream_model_ffi", "sha256_hex")
fn sha256_hex(text: String) -> String

/// Returns the fingerprint of the tables, each written as
/// `quote_ident(schema).quote_ident(table)`, for example `public.users`.
pub fn compute(
  analyzer: Analyzer,
  tables: List(String),
) -> Result(String, AnalysisError) {
  use rows <- result.map(
    execute(analyzer, schema_fingerprint_sql, [
      Some(text_array_literal(tables)),
    ]),
  )
  // The query always gives one row with one text.
  flat_map(rows, values)
  |> concat
  |> sha256_hex
}

/// Returns a PostgreSQL array literal of texts, for a `text[]` parameter:
/// each item in double quotes, with `\` and `"` escaped.
pub fn text_array_literal(items: List(String)) -> String {
  let quoted =
    list.map(items, fn(item) {
      let escaped =
        item
        |> replace("\\", "\\\\")
        |> replace("\"", "\\\"")
      "\"" <> escaped <> "\""
    })
  "{" <> join(quoted, ",") <> "}"
}
