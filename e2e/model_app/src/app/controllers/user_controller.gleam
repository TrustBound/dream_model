//// The controller of the README: it gives the result of a generated model
//// function to the client. The model returns data, and the controller
//// picks the status and the text of each error. The message of an error is
//// for developers and logs, so no response shows it.

import app/models/user
import dream/http/response.{type Response, text_response}
import dream_errors
import dream_postgres/client
import gleam/option.{None}

/// Answers with the email of the user, or with the status and the text of
/// the error.
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

/// The status and the text of each model error. The cause of a `Conflict`
/// is the error of the database, and `client.violated_constraint` gives
/// the name of its constraint.
fn error_response(error: dream_errors.Error(client.QueryError)) -> Response {
  case error {
    dream_errors.NotFound(..) -> text_response(404, "User not found")
    dream_errors.Conflict(cause:, ..) ->
      case client.violated_constraint(cause) {
        Ok("users_email_key") -> text_response(409, "Email already taken")
        _ -> text_response(409, "Conflict")
      }
    dream_errors.Unavailable(..) -> text_response(503, "Service unavailable")
    dream_errors.Timeout(..) -> text_response(504, "Timed out")
    dream_errors.Invalid(..) | dream_errors.Failed(..) ->
      text_response(500, "Internal server error")
  }
}
