//// The controller of the README: it gives the result of a generated model
//// function to the client. The model returns data, and the controller
//// picks the status and the text of each error.

import app/models/user
import dream/http/response.{type Response, text_response}
import dream_postgres/client
import gleam/option.{None}

/// Answers with the email of the user, or with the status and the message
/// of the error.
pub fn show(db: client.Connection, id: Int) -> Response {
  case user.find(db, id) {
    Ok(found) -> text_response(200, found.email)
    Error(error) -> error_response(error)
  }
}

/// Creates a user and answers with the email, or with a 409 when the email
/// is taken.
pub fn create(db: client.Connection, email: String) -> Response {
  case user.create(db, email, None) {
    Ok(created) -> text_response(201, created.email)
    Error(error) -> error_response(error)
  }
}

/// The status and the text of each model error.
fn error_response(error: client.ModelQueryError) -> Response {
  case error {
    client.NotFound -> text_response(404, "User not found")
    client.Conflict("users_email_key") ->
      text_response(409, "Email already taken")
    client.Conflict(constraint:) ->
      text_response(409, "Conflict on " <> constraint)
    client.QueryFailed(message:, cause: _) -> text_response(500, message)
  }
}
