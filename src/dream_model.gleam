//// dream_model writes a typed Gleam module for each folder of `.sql` files
//// in an app. Each function of the module returns a Dream error.
////
//// Put the `.sql` files of a model in one folder under `src`, for example
//// `src/app/models/user/find.sql`. The comment lines at the top of a file
//// are hints:
////
//// ### A SQL file with hints <a href="https://github.com/TrustBound/dream_model/blob/1.0.0/e2e/model_app/src/app/models/user/find.sql"><img align="right" alt="Tested snippet" src="https://img.shields.io/badge/%F0%9F%A7%AA_tested-snippet-lightgreen.svg?style=flat-square"></a>
////
//// ```sql
//// -- returns: one User
//// -- not found: User not found
//// select id, email, nickname from users where id = $1
//// ```
////
//// Run the command in the app folder. It reads every folder under `src`
//// that holds `.sql` files, analyzes each statement against the database
//// in the environment variable `DATABASE_URL`, and writes one module for
//// each folder, for example `src/app/models/user.gleam`:
////
//// ### Write the modules <a href="https://github.com/TrustBound/dream_model/blob/1.0.0/e2e/model_app/scripts/generate-models.sh#L6"><img align="right" alt="Tested snippet" src="https://img.shields.io/badge/%F0%9F%A7%AA_tested-snippet-lightgreen.svg?style=flat-square"></a>
////
//// ```sh
//// gleam run -m dream_model
//// ```
////
//// `--check` writes nothing. It exits with status 1 when a module is
//// missing or differs from its `.sql` files:
////
//// ### Check the modules <a href="https://github.com/TrustBound/dream_model/blob/1.0.0/e2e/model_app/scripts/check-models.sh#L6"><img align="right" alt="Tested snippet" src="https://img.shields.io/badge/%F0%9F%A7%AA_tested-snippet-lightgreen.svg?style=flat-square"></a>
////
//// ```sh
//// gleam run -m dream_model -- --check
//// ```
////
//// The settings are in the `[tools.dream_model]` table of the `gleam.toml`
//// of the app. `database_url_variable` names another environment variable,
//// and `models` lists the model folders:
////
//// ### The settings of an app <a href="https://github.com/TrustBound/dream_model/blob/1.0.0/e2e/model_app/gleam.toml#L19-L20"><img align="right" alt="Tested snippet" src="https://img.shields.io/badge/%F0%9F%A7%AA_tested-snippet-lightgreen.svg?style=flat-square"></a>
////
//// ```toml
//// [tools.dream_model]
//// database_url_variable = "MODEL_APP_DATABASE_URL"
//// ```
////
//// The generated function of `find.sql` reads one `User`, or gives a 404
//// with the text of the `not found` hint:
////
//// ### The generated function <a href="https://github.com/TrustBound/dream_model/blob/1.0.0/e2e/model_app/src/app/models/user.gleam#L80-L88"><img align="right" alt="Tested snippet" src="https://img.shields.io/badge/%F0%9F%A7%AA_tested-snippet-lightgreen.svg?style=flat-square"></a>
////
//// ```gleam
//// /// Generated from find.sql.
//// pub fn find(db: client.Connection, id: Int) -> Result(User, Error) {
////   "select id, email, nickname from users where id = $1"
////   |> client.query
////   |> client.parameter(client.int(id))
////   |> client.returning(user_decoder())
////   |> client.execute(db)
////   |> one_row("user.find", "User not found", [])
//// }
//// ```
////
//// The guides are on HexDocs: Getting started, Hints, Why is this column
//// Option?, Types, Errors, CI and schema drift, and Command reference.

import dream_model/command

@external(erlang, "dream_model_ffi", "arguments")
fn arguments() -> List(String)

@external(erlang, "dream_model_ffi", "get_env")
fn get_env(name: String) -> Result(String, Nil)

@external(erlang, "erlang", "halt")
fn halt(status: Int) -> Nil

/// Runs the command with the arguments after `--`, in the current folder.
///
/// With no argument, it writes the module of each model folder. With
/// `--check`, it writes nothing, and it exits with status 1 when a module
/// is missing or differs. It prints one line for each module, and it exits
/// with status 1 on any problem.
///
/// ### Run the command in the app folder <a href="https://github.com/TrustBound/dream_model/blob/1.0.0/e2e/model_app/scripts/generate-models.sh#L6"><img align="right" alt="Tested snippet" src="https://img.shields.io/badge/%F0%9F%A7%AA_tested-snippet-lightgreen.svg?style=flat-square"></a>
///
/// ```sh
/// gleam run -m dream_model
/// ```
pub fn main() -> Nil {
  command.main(arguments(), ".", get_env, halt)
}
