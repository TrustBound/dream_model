//// dream_model writes a typed Gleam module for each folder of `.sql` files
//// in an app, with Dream errors.
////
//// Run it in the app folder:
////
//// ### Write the modules <a href="https://github.com/TrustBound/dream_model/blob/1.0.0/e2e/model_app/scripts/generate-models.sh#L6"><img align="right" alt="Tested snippet" src="https://img.shields.io/badge/%F0%9F%A7%AA_tested-snippet-lightgreen.svg?style=flat-square"></a>
////
//// ```sh
//// gleam run -m dream_model
//// ```
////
//// It reads every folder under `src` that holds `.sql` files, for example
//// `src/app/models/user/find.sql`, analyzes each statement against the
//// database in the environment variable `DATABASE_URL`, and writes
//// `src/app/models/user.gleam`. `gleam run -m dream_model -- --check` writes
//// nothing, and exits with status 1 when a module is missing or differs.

import dream_model/command

@external(erlang, "dream_model_ffi", "arguments")
fn arguments() -> List(String)

@external(erlang, "dream_model_ffi", "get_env")
fn get_env(name: String) -> Result(String, Nil)

@external(erlang, "erlang", "halt")
fn halt(status: Int) -> Nil

/// Runs the command with the arguments after `--`, in the current folder,
/// and exits with status 1 when it fails.
pub fn main() -> Nil {
  command.main(arguments(), ".", get_env, halt)
}
