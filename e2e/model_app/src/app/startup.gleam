//// The start-up check of the app: it stops the app with a clear message
//// when the schema changed after dream_model generated the models.

import app/models/post
import app/models/sample
import app/models/user
import dream_postgres/client
import gleam/result

/// Compares the schema fingerprint of each model with the database.
pub fn check_models(db: client.Connection) -> Result(Nil, String) {
  client.check_schema(db, [
    user.schema_fingerprint,
    post.schema_fingerprint,
    sample.schema_fingerprint,
  ])
  |> result.map_error(client.format_schema_check_error)
}
