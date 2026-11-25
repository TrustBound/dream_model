//// Tests for `dream_model/command` and `dream_model.main`, with small
//// projects that each test writes under build/command_tests.

import dream_model
import dream_model/command.{Check, Config, Generate, Outcome}
import dream_test/matchers.{be_equal, or_fail_with, should}
import dream_test/suite.{type TestSuite}
import dream_test/unit.{describe, group, it}
import fixtures/model_database
import fixtures/servers
import gleam/erlang/process
import gleam/list
import gleam/option.{None, Some}
import gleam/result
import gleam/string
import simplifile

const root = "build/command_tests"

const plain_toml = "name = \"app\"\nversion = \"1.0.0\"\n"

const count_sql = "-- returns: one\nselect count(*) as total from users\n"

pub fn tests(version: Int) -> TestSuite {
  describe("dream_model/command", [
    arguments_tests(),
    config_tests(),
    folder_tests(),
    run_failure_tests(version),
    run_tests(version),
    main_tests(),
  ])
}

/// Writes a project with a gleam.toml and files, each as `#(path, text)`,
/// and returns its folder.
fn make_project(
  name: String,
  toml: String,
  files: List(#(String, String)),
) -> String {
  let directory = root <> "/" <> name
  let _ = simplifile.delete(directory)
  let assert Ok(Nil) = simplifile.create_directory_all(directory)
  let assert Ok(Nil) = simplifile.write(directory <> "/gleam.toml", toml)
  list.each(files, fn(file) {
    let path = directory <> "/" <> file.0
    let assert Ok(Nil) =
      simplifile.create_directory_all(
        string.split(path, "/")
        |> list.reverse
        |> list.drop(1)
        |> list.reverse
        |> string.join("/"),
      )
    let assert Ok(Nil) = simplifile.write(path, file.1)
  })
  directory
}

fn environment(url: String) -> fn(String) -> Result(String, Nil) {
  fn(name) {
    case name {
      "DATABASE_URL" -> Ok(url)
      _ -> Error(Nil)
    }
  }
}

fn no_environment(_name: String) -> Result(String, Nil) {
  Error(Nil)
}

fn arguments_tests() {
  group("parse_arguments", [
    it("generates with no arguments", fn() {
      // Act
      let mode = command.parse_arguments([])

      // Assert
      mode
      |> should
      |> be_equal(Ok(Generate))
      |> or_fail_with("Expected Generate")
    }),
    it("checks with --check", fn() {
      // Act
      let mode = command.parse_arguments(["--check"])

      // Assert
      mode
      |> should
      |> be_equal(Ok(Check))
      |> or_fail_with("Expected Check")
    }),
    it("refuses other arguments", fn() {
      // Act
      let mode = command.parse_arguments(["--write", "now"])

      // Assert
      mode
      |> should
      |> be_equal(Error(
        "dream_model does not know the arguments '--write now'. Run `gleam run -m dream_model` to write the modules, or `gleam run -m dream_model -- --check` to check them.\n",
      ))
      |> or_fail_with("Expected the refusal")
    }),
  ])
}

fn config_tests() {
  let cases = [
    #(
      "uses the defaults without a table",
      plain_toml,
      Ok(Config(database_url_variable: "DATABASE_URL", models: None)),
    ),
    #(
      "reads both settings",
      plain_toml
        <> "[tools.dream_model]\ndatabase_url_variable = \"APP_DB\"\nmodels = [\"src/app/models/user\"]\n",
      Ok(Config(
        database_url_variable: "APP_DB",
        models: Some(["src/app/models/user"]),
      )),
    ),
    #(
      "refuses an unknown setting",
      plain_toml <> "[tools.dream_model]\nmodel = [] \nurl = \"x\"\n",
      Error(
        "dream_model does not know the settings model, url in [tools.dream_model] of gleam.toml; the settings are database_url_variable and models\n",
      ),
    ),
    #(
      "refuses a variable name that is not a string",
      plain_toml <> "[tools.dream_model]\ndatabase_url_variable = 1\n",
      Error(
        "the setting database_url_variable in [tools.dream_model] of gleam.toml must be a string\n",
      ),
    ),
    #(
      "refuses models that are not a list",
      plain_toml <> "[tools.dream_model]\nmodels = \"src\"\n",
      Error(
        "the setting models in [tools.dream_model] of gleam.toml must be a list of folders\n",
      ),
    ),
    #(
      "refuses models that are not strings",
      plain_toml <> "[tools.dream_model]\nmodels = [1]\n",
      Error(
        "the setting models in [tools.dream_model] of gleam.toml must be a list of folders\n",
      ),
    ),
    #(
      "refuses a gleam.toml that is not TOML",
      "name = ",
      Error("dream_model cannot parse gleam.toml\n"),
    ),
  ]
  group(
    "read_config",
    list.index_map(cases, fn(example, index) {
      let #(title, toml, expected) = example
      it(title, fn() {
        // Arrange
        let directory =
          make_project("config_" <> string.inspect(index), toml, [])

        // Act
        let config = command.read_config(directory)

        // Assert
        config
        |> should
        |> be_equal(expected)
        |> or_fail_with("Expected " <> string.inspect(expected))
      })
    })
      |> list.append([
        it("refuses a folder without gleam.toml", fn() {
          // Act
          let config = command.read_config(root <> "/no_such_project")

          // Assert
          config
          |> should
          |> be_equal(Error(
            "dream_model cannot read gleam.toml: No such file or directory\n",
          ))
          |> or_fail_with("Expected the read error")
        }),
      ]),
  )
}

fn folder_tests() {
  group("find_folders", [
    it("finds every folder with a .sql file, sorted", fn() {
      // Arrange
      let directory =
        make_project("folders_found", plain_toml, [
          #("src/app/models/user/find.sql", "select 1"),
          #("src/app/models/user/list.sql", "select 1"),
          #("src/app/models/post/list.sql", "select 1"),
          #("src/app/web.gleam", "pub fn main() { Nil }"),
        ])

      // Act
      let folders =
        command.find_folders(directory, Config("DATABASE_URL", None))

      // Assert
      folders
      |> should
      |> be_equal(Ok(["src/app/models/post", "src/app/models/user"]))
      |> or_fail_with("Expected the two model folders")
    }),
    it("refuses a folder that is not a module path", fn() {
      // Arrange
      let directory =
        make_project("folders_refused", plain_toml, [
          #("src/App/find.sql", "select 1"),
          #("src/top.sql", "select 1"),
        ])

      // Act
      let folders =
        command.find_folders(directory, Config("DATABASE_URL", None))

      // Assert
      folders
      |> should
      |> be_equal(Error(
        "these model folders are not Gleam module paths under src: src, src/App; each folder name must be in snake case, for example src/app/models/user\n",
      ))
      |> or_fail_with("Expected the refused folders")
    }),
    it("uses the models of the config", fn() {
      // Arrange
      let directory =
        make_project("folders_config", plain_toml, [
          #("src/app/models/user/find.sql", "select 1"),
          #("src/app/models/post/list.sql", "select 1"),
        ])

      // Act
      let folders =
        command.find_folders(
          directory,
          Config("DATABASE_URL", Some(["src/app/models/user"])),
        )

      // Assert
      folders
      |> should
      |> be_equal(Ok(["src/app/models/user"]))
      |> or_fail_with("Expected the configured folder")
    }),
    it("refuses a configured folder without .sql files", fn() {
      // Arrange
      let directory =
        make_project("folders_missing", plain_toml, [
          #("src/app/models/user/find.sql", "select 1"),
        ])

      // Act
      let folders =
        command.find_folders(
          directory,
          Config("DATABASE_URL", Some(["src/app/models/post"])),
        )

      // Assert
      folders
      |> should
      |> be_equal(Error(
        "these folders of models in gleam.toml hold no .sql file: src/app/models/post\n",
      ))
      |> or_fail_with("Expected the empty folder")
    }),
    it("refuses a project without src", fn() {
      // Arrange
      let directory = make_project("folders_no_src", plain_toml, [])

      // Act
      let folders =
        command.find_folders(directory, Config("DATABASE_URL", None))

      // Assert
      folders
      |> should
      |> be_equal(Error(
        "dream_model cannot read the src folder: No such file or directory\n",
      ))
      |> or_fail_with("Expected the read error")
    }),
    it("module_of_folder refuses a folder outside src", fn() {
      // Act
      let module = command.module_of_folder("lib/app/models/user")

      // Assert
      module
      |> should
      |> be_equal(Error(Nil))
      |> or_fail_with("Expected Error(Nil)")
    }),
  ])
}

fn run_failure_tests(version: Int) {
  let url = model_database.url(version)
  let user_files = [#("src/app/models/user/count.sql", count_sql)]
  let cases = [
    #(
      "stops on unknown arguments",
      ["--force"],
      fn() { make_project("run_arguments", plain_toml, user_files) },
      environment(url),
      Outcome(
        1,
        "dream_model does not know the arguments '--force'. Run `gleam run -m dream_model` to write the modules, or `gleam run -m dream_model -- --check` to check them.\n",
      ),
    ),
    #(
      "says so when there is nothing to generate",
      [],
      fn() { make_project("run_nothing", plain_toml, [#("src/app.gleam", "")]) },
      environment(url),
      Outcome(
        0,
        "dream_model found no folder with .sql files under src; there is nothing to generate.\n",
      ),
    ),
    #(
      "needs the database URL variable",
      [],
      fn() { make_project("run_no_url", plain_toml, user_files) },
      no_environment,
      Outcome(
        1,
        "dream_model needs the URL of the database in the environment variable DATABASE_URL, for example postgresql://user:password@localhost:5432/app\n",
      ),
    ),
    #(
      "stops when the database is not reachable",
      [],
      fn() { make_project("run_unreachable", plain_toml, user_files) },
      environment("postgresql://dream:dream@127.0.0.1:1/dream_test"),
      Outcome(
        1,
        "dream_model cannot use the database: cannot connect to PostgreSQL at 127.0.0.1:1: econnrefused\n",
      ),
    ),
    #(
      "lists every refused file",
      [],
      fn() {
        make_project("run_refused", plain_toml, [
          #("src/app/models/user/bad.sql", "-- returns: all\nselect 1"),
          #("src/app/models/user/worse.sql", "select nope from users"),
          #("src/app/models/user/folder.sql/x", ""),
        ])
      },
      environment(url),
      Outcome(
        1,
        "src/app/models/user/bad.sql:1: 'all' is not a returns form; write one, maybe, many or none\nsrc/app/models/user/folder.sql:1: cannot read the file: Is a directory\nsrc/app/models/user/worse.sql:1: PostgreSQL refused the statement: column \"nope\" does not exist\ndream_model wrote nothing: 3 problem(s).\n",
      ),
    ),
    #(
      "stops on a type that differs between files",
      [],
      fn() {
        make_project("run_types", plain_toml, [
          #(
            "src/app/models/user/find.sql",
            "-- returns: one User\nselect id, email from users where id = $1",
          ),
          #(
            "src/app/models/user/list.sql",
            "-- returns: many User\nselect id from users",
          ),
        ])
      },
      environment(url),
      Outcome(
        1,
        "src/app/models/user/list.sql:1: the type User has no field 'email: String' here, and src/app/models/user/find.sql has it; every file that returns one type must give it the same fields, in the same order, with the same types\ndream_model wrote nothing: 1 problem(s).\n",
      ),
    ),
    #(
      "stops on a name that the module uses",
      [],
      fn() {
        make_project("run_names", plain_toml, [
          #("src/app/models/user/one_row.sql", count_sql),
        ])
      },
      environment(url),
      Outcome(
        1,
        "src/app/models/user/one_row.sql:1: the function name 'one_row' is a name that the generated module uses itself; rename the file\ndream_model wrote nothing: 1 problem(s).\n",
      ),
    ),
    #(
      "stops when build/dream_model cannot be made",
      [],
      fn() {
        make_project(
          "run_no_build",
          plain_toml,
          list.append(user_files, [#("build/dream_model", "")]),
        )
      },
      environment(url),
      Outcome(
        1,
        "dream_model cannot write to build/dream_model: Not a directory\n",
      ),
    ),
    #(
      "stops when a module cannot be written",
      [],
      fn() {
        make_project(
          "run_no_write",
          plain_toml,
          list.append(user_files, [#("src/app/models/user.gleam/x", "")]),
        )
      },
      environment(url),
      Outcome(
        1,
        "dream_model cannot write src/app/models/user.gleam: Is a directory\n",
      ),
    ),
    #(
      "stops when the gleam.toml cannot be read",
      [],
      fn() { root <> "/no_such_project" },
      environment(url),
      Outcome(
        1,
        "dream_model cannot read gleam.toml: No such file or directory\n",
      ),
    ),
  ]
  group(
    "run failures",
    list.map(cases, fn(example) {
      let #(title, arguments, make, get_env, expected) = example
      it(title, fn() {
        // Arrange
        let directory = make()

        // Act
        let outcome = command.run(arguments, directory, get_env)

        // Assert
        outcome
        |> should
        |> be_equal(expected)
        |> or_fail_with(expected.output)
      })
    })
      |> list.append([
        it("stops on a server version older than 16", fn() {
          // Arrange
          let directory = make_project("run_old", plain_toml, user_files)

          // Act
          let outcome =
            command.run(
              [],
              directory,
              environment(servers.url(15, servers.default_database)),
            )

          // Assert
          #(
            outcome.status,
            string.starts_with(
              outcome.output,
              "dream_model cannot use the database: PostgreSQL 15",
            ),
          )
          |> should
          |> be_equal(#(1, True))
          |> or_fail_with(outcome.output)
        }),
      ]),
  )
}

fn run_tests(version: Int) {
  let url = model_database.url(version)
  group("run", [
    it("writes a module and says so", fn() {
      // Arrange
      let directory =
        make_project("run_write", plain_toml, [
          #("src/app/models/user/count.sql", count_sql),
        ])

      // Act
      let outcome = command.run([], directory, environment(url))

      // Assert
      outcome
      |> should
      |> be_equal(Outcome(0, "wrote src/app/models/user.gleam\n"))
      |> or_fail_with("Expected the written module")
    }),
    it("writes a module that gleam format leaves as it is", fn() {
      // Arrange
      let directory =
        make_project("run_formatted", plain_toml, [
          #("src/app/models/user/count.sql", count_sql),
        ])
      let _ = command.run([], directory, environment(url))
      let assert Ok(written) =
        simplifile.read(directory <> "/src/app/models/user.gleam")

      // Act
      let assert Ok(#(status, output)) =
        run_program("gleam", ["format", "--check", "src"], directory, [])

      // Assert
      #(status, output, string.length(written) > 0)
      |> should
      |> be_equal(#(0, "", True))
      |> or_fail_with("Expected gleam format --check to pass")
    }),
    it("says unchanged for a module that is up to date", fn() {
      // Arrange
      let directory =
        make_project("run_unchanged", plain_toml, [
          #("src/app/models/user/count.sql", count_sql),
        ])
      let _ = command.run([], directory, environment(url))

      // Act
      let outcome = command.run([], directory, environment(url))

      // Assert
      outcome
      |> should
      |> be_equal(Outcome(0, "unchanged src/app/models/user.gleam\n"))
      |> or_fail_with("Expected unchanged")
    }),
    it("--check passes when every module matches", fn() {
      // Arrange
      let directory =
        make_project("check_match", plain_toml, [
          #("src/app/models/user/count.sql", count_sql),
        ])
      let _ = command.run([], directory, environment(url))

      // Act
      let outcome = command.run(["--check"], directory, environment(url))

      // Assert
      outcome
      |> should
      |> be_equal(Outcome(
        0,
        "every model module matches its .sql files (1 modules)\n",
      ))
      |> or_fail_with("Expected the match")
    }),
    it("--check lists a missing and a changed module and writes nothing", fn() {
      // Arrange
      let directory =
        make_project("check_stale", plain_toml, [
          #("src/app/models/user/count.sql", count_sql),
          #("src/app/models/post/count.sql", count_sql),
          #("src/app/models/user.gleam", "// old\n"),
        ])

      // Act
      let outcome = command.run(["--check"], directory, environment(url))

      // Assert
      #(
        outcome,
        simplifile.read(directory <> "/src/app/models/post.gleam")
          |> result.is_error,
      )
      |> should
      |> be_equal(#(
        Outcome(
          1,
          "missing src/app/models/post.gleam\ndiffers src/app/models/user.gleam\nRun `gleam run -m dream_model` to write the modules again.\n",
        ),
        True,
      ))
      |> or_fail_with("Expected the missing and the changed module")
    }),
  ])
}

@external(erlang, "dream_model_test_ffi", "run")
fn run_test_program(
  program: String,
  arguments: List(String),
  directory: String,
  environment: List(#(String, String)),
) -> #(Int, String)

fn run_program(
  program: String,
  arguments: List(String),
  directory: String,
  environment: List(#(String, String)),
) -> Result(#(Int, String), Nil) {
  Ok(run_test_program(program, arguments, directory, environment))
}

@external(erlang, "dream_model_ffi", "get_env")
fn ffi_get_env(name: String) -> Result(String, Nil)

@external(erlang, "dream_model_ffi", "run")
fn ffi_run(
  program: String,
  arguments: List(String),
  directory: String,
) -> Result(#(Int, String), Nil)

fn main_tests() {
  group("main", [
    it("command.main halts with status 1 when the command fails", fn() {
      // Arrange
      let halted = process.new_subject()

      // Act
      command.main(["--bad"], ".", no_environment, process.send(halted, _))

      // Assert
      process.receive(halted, 1000)
      |> should
      |> be_equal(Ok(1))
      |> or_fail_with("Expected a halt with status 1")
    }),
    it("command.main does not halt when the command succeeds", fn() {
      // Arrange
      let halted = process.new_subject()
      let directory =
        make_project("main_nothing", plain_toml, [#("src/app.gleam", "")])

      // Act
      command.main([], directory, no_environment, process.send(halted, _))

      // Assert
      process.receive(halted, 100)
      |> should
      |> be_equal(Error(Nil))
      |> or_fail_with("Expected no halt")
    }),
    it("get_env reads a variable of the environment", fn() {
      // Act
      let found = ffi_get_env("PATH") |> result.is_ok

      // Assert
      found
      |> should
      |> be_equal(True)
      |> or_fail_with("Expected PATH")
    }),
    it("get_env gives Error(Nil) for a variable that is not set", fn() {
      // Act
      let found = ffi_get_env("DREAM_MODEL_NO_SUCH_VARIABLE")

      // Assert
      found
      |> should
      |> be_equal(Error(Nil))
      |> or_fail_with("Expected Error(Nil)")
    }),
    it("run gives Error(Nil) for a program that is not on the PATH", fn() {
      // Act
      let found = ffi_run("dream-model-no-such-program", [], ".")

      // Assert
      found
      |> should
      |> be_equal(Error(Nil))
      |> or_fail_with("Expected Error(Nil)")
    }),
    it("run gives the status and the output of a program", fn() {
      // Act
      let found =
        ffi_run("gleam", ["--version"], ".")
        |> result.map(fn(ran) { #(ran.0, string.starts_with(ran.1, "gleam ")) })

      // Assert
      found
      |> should
      |> be_equal(Ok(#(0, True)))
      |> or_fail_with("Expected the version of gleam")
    }),
    it("runs the command in the current folder", fn() {
      // Act
      let returned = dream_model.main()

      // Assert
      returned
      |> should
      |> be_equal(Nil)
      |> or_fail_with("Expected main to return")
    }),
  ])
}
