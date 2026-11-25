//// The end-to-end tests: the app in e2e/model_app, copied to
//// build/e2e/<version>/model_app, gets its models generated against PostgreSQL, the
//// modules are compared with the ones in e2e/model_app/src/app/models
//// (with the fingerprint hash left out, because it differs between
//// versions), and the app's test/model_app_test.gleam runs the generated
//// code against the database and prints one line per check, which must
//// equal e2e/model_app/expected_output.txt.
////
//// The copy needs the packages of the app in build/e2e/model_app/build:
//// `sh scripts/stand-ins.sh` puts them there until dream_postgres 2.1.0
//// and Dream 3.0.0 are on Hex. Each version has its own copy, so the
//// versions can run at the same time. A copy gets the build folder of
//// build/e2e/model_app once, and again when its packages.toml is not the
//// same. The tests of one version run one at a time.

import dream_model/command.{Outcome}
import dream_test/matchers.{be_equal, or_fail_with, should}
import dream_test/suite.{type TestSuite}
import dream_test/unit.{before_all, describe, it}
import fixtures/model_database
import fixtures/servers
import gleam/int
import gleam/list
import gleam/result
import gleam/string
import simplifile

const source = "e2e/model_app"

/// The build folder with the packages of the app.
const packages_build = "build/e2e/model_app/build"

/// The copy of the app for a version.
fn copy_of(version: Int) -> String {
  "build/e2e/" <> int.to_string(version) <> "/model_app"
}

const url_variable = "MODEL_APP_DATABASE_URL"

const modules = ["post", "sample", "user"]

@external(erlang, "dream_model_test_ffi", "run")
fn run_program(
  program: String,
  arguments: List(String),
  directory: String,
  environment: List(#(String, String)),
) -> #(Int, String)

pub fn tests(version: Int) -> TestSuite {
  let copy = copy_of(version)
  let url = servers.url(version, model_database.e2e_database())
  let read_environment_variable = fn(name) {
    case name == url_variable {
      True -> Ok(url)
      False -> Error(Nil)
    }
  }
  describe(
    "the end-to-end app on PostgreSQL " <> int.to_string(version),
    list.flatten([
      [
        before_all(fn() { prepare(version, copy) }),
        it("--check lists every module as missing before generation", fn() {
          // Act
          let outcome =
            command.run(["--check"], copy, read_environment_variable)

          // Assert
          outcome
          |> should
          |> be_equal(Outcome(
            1,
            "missing src/app/models/post.gleam\nmissing src/app/models/sample.gleam\nmissing src/app/models/user.gleam\nRun `gleam run -m dream_model` to write the modules again.\n",
          ))
          |> or_fail_with("Expected three missing modules")
        }),
        it("writes the three modules", fn() {
          // Act
          let outcome = command.run([], copy, read_environment_variable)

          // Assert
          outcome
          |> should
          |> be_equal(Outcome(
            0,
            "wrote src/app/models/post.gleam\nwrote src/app/models/sample.gleam\nwrote src/app/models/user.gleam\n",
          ))
          |> or_fail_with("Expected three written modules")
        }),
      ],
      list.map(modules, fn(module) {
        it("writes " <> module <> ".gleam as checked in", fn() {
          // Arrange
          let path = "/src/app/models/" <> module <> ".gleam"
          let assert Ok(expected) = simplifile.read(source <> path)

          // Act
          let written = simplifile.read(copy <> path)

          // Assert
          written
          |> result.map(without_hash)
          |> should
          |> be_equal(Ok(without_hash(expected)))
          |> or_fail_with("Expected the checked-in " <> module <> ".gleam")
        })
      }),
      [
        it("--check passes after the generation", fn() {
          // Act
          let outcome =
            command.run(["--check"], copy, read_environment_variable)

          // Assert
          outcome
          |> should
          |> be_equal(Outcome(
            0,
            "every model module matches its .sql files (3 modules)\n",
          ))
          |> or_fail_with("Expected every module to match")
        }),
        it("--check lists a changed module", fn() {
          // Arrange
          let path = copy <> "/src/app/models/post.gleam"
          let assert Ok(text) = simplifile.read(path)
          let assert Ok(Nil) = simplifile.write(path, text <> "\n// edited\n")

          // Act
          let outcome =
            command.run(["--check"], copy, read_environment_variable)
          let assert Ok(Nil) = simplifile.write(path, text)

          // Assert
          outcome
          |> should
          |> be_equal(Outcome(
            1,
            "differs src/app/models/post.gleam\nRun `gleam run -m dream_model` to write the modules again.\n",
          ))
          |> or_fail_with("Expected the changed module")
        }),
        it("the command line says that the modules are unchanged", fn() {
          // Act
          let #(status, output) =
            run_program("sh", ["scripts/generate-models.sh"], copy, [
              #(url_variable, url),
            ])

          // Assert
          #(status, last_lines(output, 3))
          |> should
          |> be_equal(#(
            0,
            "unchanged src/app/models/post.gleam\nunchanged src/app/models/sample.gleam\nunchanged src/app/models/user.gleam\n",
          ))
          |> or_fail_with(output)
        }),
        it("the command line --check exits 0 when the modules match", fn() {
          // Act
          let #(status, output) =
            run_program("sh", ["scripts/check-models.sh"], copy, [
              #(url_variable, url),
            ])

          // Assert
          #(status, last_lines(output, 1))
          |> should
          |> be_equal(#(
            0,
            "every model module matches its .sql files (3 modules)\n",
          ))
          |> or_fail_with(output)
        }),
        it("the command line --check exits 1 for a missing module", fn() {
          // Arrange
          let path = copy <> "/src/app/models/sample.gleam"
          let assert Ok(text) = simplifile.read(path)
          let assert Ok(Nil) = simplifile.delete(path)

          // Act
          let #(status, output) =
            run_program("sh", ["scripts/check-models.sh"], copy, [
              #(url_variable, url),
            ])
          let assert Ok(Nil) = simplifile.write(path, text)

          // Assert
          #(status, last_lines(output, 2))
          |> should
          |> be_equal(#(
            1,
            "missing src/app/models/sample.gleam\nRun `gleam run -m dream_model` to write the modules again.\n",
          ))
          |> or_fail_with(output)
        }),
        it("compiles the modules and runs them against the database", fn() {
          // Arrange
          let assert Ok(expected) =
            simplifile.read(source <> "/expected_output.txt")

          // Act
          let #(status, output) =
            run_program("gleam", ["test"], copy, [#(url_variable, url)])

          // Assert
          #(status, transcript(output))
          |> should
          |> be_equal(#(0, expected))
          |> or_fail_with(output)
        }),
      ],
    ]),
  )
}

/// Makes a new database and a new copy of the app with no generated
/// modules, and keeps the packages of the copy.
fn prepare(version: Int, copy: String) -> Result(Nil, String) {
  use schema <- result.try(read(source <> "/schema.sql"))
  use Nil <- result.try(model_database.recreate(
    version,
    model_database.e2e_database(),
    schema,
  ))
  use Nil <- result.try(require_packages(copy))
  use Nil <- result.try(
    ["src", "test", "scripts", "gleam.toml", "manifest.toml"]
    |> list.try_each(fn(entry) {
      let _ = simplifile.delete(copy <> "/" <> entry)
      copy_entry(copy, entry)
    }),
  )
  use Nil <- result.try(copy_dream_model(copy))
  list.try_each(modules, fn(module) {
    simplifile.delete(copy <> "/src/app/models/" <> module <> ".gleam")
    |> result.map_error(simplifile.describe_error)
  })
}

/// Copies the code under test into the packages of the app, and removes
/// its compiled copy, so `gleam run -m dream_model` in the app runs it.
fn copy_dream_model(copy: String) -> Result(Nil, String) {
  let package = copy <> "/build/packages/dream_model"
  let _ = simplifile.delete(package <> "/src")
  let _ = simplifile.delete(copy <> "/build/dev/erlang/dream_model")
  simplifile.copy_directory(at: "src", to: package <> "/src")
  |> result.try(fn(_) {
    simplifile.copy_file(at: "gleam.toml", to: package <> "/gleam.toml")
  })
  |> result.map_error(simplifile.describe_error)
}

/// Checks that the app has its packages, and copies the build folder with
/// them into the copy of a version when the copy does not have the same
/// packages.toml.
fn require_packages(copy: String) -> Result(Nil, String) {
  let list_file = "/packages/packages.toml"
  case simplifile.read(packages_build <> list_file) {
    Ok(packages) ->
      case simplifile.read(copy <> "/build" <> list_file) {
        Ok(copied) if copied == packages -> Ok(Nil)
        _ -> {
          let _ = simplifile.delete(copy <> "/build")
          let _ = simplifile.create_directory_all(copy)
          simplifile.copy_directory(at: packages_build, to: copy <> "/build")
          |> result.map_error(simplifile.describe_error)
        }
      }
    Error(_) ->
      Error(
        "the end-to-end app has no packages; run `sh scripts/stand-ins.sh` first",
      )
  }
}

fn copy_entry(copy: String, entry: String) -> Result(Nil, String) {
  let from = source <> "/" <> entry
  let to = copy <> "/" <> entry
  case simplifile.is_directory(from) {
    Ok(True) -> simplifile.copy_directory(at: from, to:)
    _ -> simplifile.copy_file(at: from, to:)
  }
  |> result.map_error(simplifile.describe_error)
}

fn read(path: String) -> Result(String, String) {
  simplifile.read(path) |> result.map_error(simplifile.describe_error)
}

/// The text without the value of the fingerprint hash.
fn without_hash(text: String) -> String {
  case string.split_once(text, "hash: \"") {
    Ok(#(before, after)) -> before <> "hash: \"" <> string.drop_start(after, 64)
    Error(Nil) -> text
  }
}

/// The last `count` lines of an output that ends with a line break.
fn last_lines(output: String, count: Int) -> String {
  string.split(output, "\n")
  |> list.reverse
  |> list.drop(1)
  |> list.take(count)
  |> list.reverse
  |> list.map(fn(line) { line <> "\n" })
  |> string.concat
}

/// The lines of the app's checks: the lines that start with `| `.
fn transcript(output: String) -> String {
  string.split(output, "\n")
  |> list.filter(string.starts_with(_, "| "))
  |> list.map(fn(line) { line <> "\n" })
  |> string.concat
}
