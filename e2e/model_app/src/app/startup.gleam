//// The start-up check of the app: it stops the app with a clear message
//// when the schema changed after dream_model generated the models.

import app/models/post
import app/models/sample
import app/models/user
import dream_postgres/client.{type Connection, check_schema, format_schema_check_error}
import gleam/result.{map_error}

/// Compares the schema fingerprint of each model with the database.
pub fn check_models(db: Connection) -> Result(Nil, String) {
  check_schema(db, [
    user.schema_fingerprint,
    post.schema_fingerprint,
    sample.schema_fingerprint,
  ])
  |> map_error(format_schema_check_error)
}
