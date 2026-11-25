//// The controller of the README: it gives the result of a generated model
//// function to the client.

import app/models/user
import dream/http/error
import dream/http/response.{type Response, text_response}
import dream_postgres/client

/// Answers with the email of the user, or with the status and the message
/// of the error.
pub fn show(db: client.Connection, id: Int) -> Response {
  case user.find(db, id) {
    Ok(found) -> text_response(200, found.email)
    Error(problem) ->
      text_response(error.to_status_code(problem), error.message(problem))
  }
}
