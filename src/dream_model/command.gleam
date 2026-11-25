//// The command `gleam run -m dream_model`: finds the model folders, reads
//// their SQL files, analyzes them against the database and writes one
//// Gleam module next to each folder. With `--check` it writes nothing and
//// lists every module that is missing or differs.
////
//// The settings are in the `[tools.dream_model]` table of the app's
//// `gleam.toml`:
////
//// - `database_url_variable`: the environment variable that holds the
////   database URL. The default is `DATABASE_URL`.
//// - `models`: the model folders, for example `["src/app/models/user"]`.
////   The default is every folder under `src` that holds a `.sql` file.

import dream_model/generator/fingerprint
import dream_model/generator/model.{type Unit, Unit}
import dream_model/generator/name
import dream_model/generator/query.{type Problem}
import dream_model/generator/query_hint
import dream_model/nullability.{type Analyzer}
import filepath
import gleam/bool
import gleam/dict
import gleam/int
import gleam/io
import gleam/list
import gleam/option.{type Option, None, Some}
import gleam/result
import gleam/string
import simplifile
import tom

/// What the command prints, and its exit status.
pub type Outcome {
  Outcome(status: Int, output: String)
}

/// The settings of `[tools.dream_model]`.
pub type Config {
  Config(database_url_variable: String, models: Option(List(String)))
}

/// What the command does.
pub type Mode {
  /// Write the modules.
  Generate
  /// Write nothing, and fail when a module is missing or differs.
  Check
}

/// A module that generation gives.
pub type Generated {
  Generated(
    /// The path of the Gleam file, for example `src/app/models/user.gleam`.
    path: String,
    text: String,
  )
}

/// The environment variable of the database URL when `gleam.toml` names
/// none.
pub const default_database_url_variable = "DATABASE_URL"

/// The program that formats the generated modules.
pub const gleam_program = "gleam"

@external(erlang, "dream_model_ffi", "run")
fn run_program(
  program: String,
  arguments: List(String),
  directory: String,
) -> Result(#(Int, String), Nil)

/// Runs the command in the project folder `directory`, prints what it says
/// and ends the program with `halt` when the command failed. `get_env`
/// reads an environment variable.
pub fn main(
  arguments: List(String),
  directory: String,
  get_env: fn(String) -> Result(String, Nil),
  halt: fn(Int) -> Nil,
) -> Nil {
  let outcome = run(arguments, directory, get_env)
  io.print(outcome.output)
  case outcome.status {
    0 -> Nil
    status -> halt(status)
  }
}

/// Runs the command in the project folder `directory`. `get_env` reads an
/// environment variable.
pub fn run(
  arguments: List(String),
  directory: String,
  get_env: fn(String) -> Result(String, Nil),
) -> Outcome {
  case execute(arguments, directory, get_env) {
    Ok(output) -> Outcome(status: 0, output:)
    Error(output) -> Outcome(status: 1, output:)
  }
}

fn execute(
  arguments: List(String),
  directory: String,
  get_env: fn(String) -> Result(String, Nil),
) -> Result(String, String) {
  use mode <- result.try(parse_arguments(arguments))
  use config <- result.try(read_config(directory))
  use folders <- result.try(find_folders(directory, config))
  use <- bool.guard(
    when: folders == [],
    return: Ok(
      "dream_model found no folder with .sql files under src; there is nothing to generate.\n",
    ),
  )
  use url <- result.try(
    get_env(config.database_url_variable)
    |> result.replace_error(
      "dream_model needs the URL of the database in the environment variable "
      <> config.database_url_variable
      <> ", for example postgresql://user:password@localhost:5432/app\n",
    ),
  )
  use analyzer <- result.try(
    nullability.connect(url)
    |> result.map_error(fn(error) {
      "dream_model cannot use the database: "
      <> nullability.error_to_string(error)
      <> "\n"
    }),
  )
  let generated = generate(analyzer, directory, folders)
  let _closed = nullability.close(analyzer)
  use modules <- result.try(generated)
  finish(mode, directory, modules)
}

/// Returns the mode of the command line arguments.
pub fn parse_arguments(arguments: List(String)) -> Result(Mode, String) {
  case arguments {
    [] -> Ok(Generate)
    ["--check"] -> Ok(Check)
    _ ->
      Error(
        "dream_model does not know the arguments '"
        <> string.join(arguments, " ")
        <> "'. Run `gleam run -m dream_model` to write the modules, or `gleam run -m dream_model -- --check` to check them.\n",
      )
  }
}

// --- Configuration ---------------------------------------------------------

/// Reads `[tools.dream_model]` of the project's `gleam.toml`.
pub fn read_config(directory: String) -> Result(Config, String) {
  let path = filepath.join(directory, "gleam.toml")
  use text <- result.try(
    simplifile.read(path)
    |> result.map_error(fn(error) {
      "dream_model cannot read gleam.toml: "
      <> simplifile.describe_error(error)
      <> "\n"
    }),
  )
  use toml <- result.try(
    tom.parse(text)
    |> result.replace_error("dream_model cannot parse gleam.toml\n"),
  )
  let table =
    tom.get_table(toml, ["tools", "dream_model"]) |> result.unwrap(dict.new())
  use Nil <- result.try(check_keys(table))
  use database_url_variable <- result.try(
    optional_setting(tom.get_string(table, ["database_url_variable"]))
    |> result.map(option.unwrap(_, default_database_url_variable))
    |> result.replace_error(setting_error("database_url_variable", "a string")),
  )
  use models <- result.map(
    optional_setting(tom.get_array(table, ["models"]))
    |> result.try(option_try(_, strings))
    |> result.replace_error(setting_error("models", "a list of folders")),
  )
  Config(database_url_variable:, models:)
}

fn check_keys(table: dict.Dict(String, tom.Toml)) -> Result(Nil, String) {
  let unknown =
    dict.keys(table)
    |> list.filter(fn(key) {
      !list.contains(["database_url_variable", "models"], key)
    })
    |> list.sort(string.compare)
  case unknown {
    [] -> Ok(Nil)
    _ ->
      Error(
        "dream_model does not know the settings "
        <> string.join(unknown, ", ")
        <> " in [tools.dream_model] of gleam.toml; the settings are database_url_variable and models\n",
      )
  }
}

fn setting_error(key: String, expected: String) -> String {
  "the setting "
  <> key
  <> " in [tools.dream_model] of gleam.toml must be "
  <> expected
  <> "\n"
}

/// A missing setting is `None`; a setting of another type is an error.
fn optional_setting(found: Result(a, tom.GetError)) -> Result(Option(a), Nil) {
  case found {
    Ok(value) -> Ok(Some(value))
    Error(tom.NotFound(_)) -> Ok(None)
    Error(tom.WrongType(..)) -> Error(Nil)
  }
}

fn option_try(
  value: Option(a),
  convert: fn(a) -> Result(b, Nil),
) -> Result(Option(b), Nil) {
  case value {
    Some(value) -> convert(value) |> result.map(Some)
    None -> Ok(None)
  }
}

fn strings(items: List(tom.Toml)) -> Result(List(String), Nil) {
  list.try_map(items, fn(item) {
    tom.as_string(item) |> result.replace_error(Nil)
  })
}

// --- Folders ---------------------------------------------------------------

/// Returns the model folders, relative to the project, sorted: the folders
/// of `models`, or every folder under `src` with a `.sql` file in it.
pub fn find_folders(
  directory: String,
  config: Config,
) -> Result(List(String), String) {
  use folders <- result.try(case config.models {
    Some(models) -> check_model_folders(directory, models)
    None -> discover_folders(directory)
  })
  let refused =
    list.filter(folders, fn(folder) {
      result.is_error(module_of_folder(folder))
    })
  case refused {
    [] -> Ok(list.sort(folders, string.compare))
    _ ->
      Error(
        "these model folders are not Gleam module paths under src: "
        <> string.join(refused, ", ")
        <> "; each folder name must be in snake case, for example src/app/models/user\n",
      )
  }
}

fn discover_folders(directory: String) -> Result(List(String), String) {
  let source = filepath.join(directory, "src")
  use files <- result.map(
    simplifile.get_files(in: source)
    |> result.map_error(fn(error) {
      "dream_model cannot read the src folder: "
      <> simplifile.describe_error(error)
      <> "\n"
    }),
  )
  list.filter(files, string.ends_with(_, ".sql"))
  |> list.map(fn(file) {
    let folder = filepath.directory_name(file)
    case string.starts_with(folder, source <> "/") {
      True -> "src/" <> string.drop_start(folder, string.length(source) + 1)
      False -> "src"
    }
  })
  |> list.unique
}

fn check_model_folders(
  directory: String,
  models: List(String),
) -> Result(List(String), String) {
  let missing =
    list.filter(models, fn(folder) {
      sql_files(directory, folder) |> result.unwrap([]) == []
    })
  case missing {
    [] -> Ok(models)
    _ ->
      Error(
        "these folders of models in gleam.toml hold no .sql file: "
        <> string.join(missing, ", ")
        <> "\n",
      )
  }
}

fn sql_files(directory: String, folder: String) -> Result(List(String), Nil) {
  simplifile.read_directory(filepath.join(directory, folder))
  |> result.replace_error(Nil)
  |> result.map(fn(entries) {
    list.filter(entries, string.ends_with(_, ".sql"))
    |> list.sort(string.compare)
  })
}

/// Returns the module path of a model folder: the folder without `src/`.
pub fn module_of_folder(folder: String) -> Result(String, Nil) {
  case folder {
    "src/" <> module -> check_module_path(module)
    _ -> Error(Nil)
  }
}

fn check_module_path(module: String) -> Result(String, Nil) {
  case list.all(string.split(module, "/"), query_hint.is_module_segment) {
    True -> Ok(module)
    False -> Error(Nil)
  }
}

// --- Generation ------------------------------------------------------------

fn generate(
  analyzer: Analyzer,
  directory: String,
  folders: List(String),
) -> Result(List(Generated), String) {
  let #(units, problems, analyzer) =
    list.fold(folders, #([], [], analyzer), fn(state, folder) {
      let #(units, problems, analyzer) = state
      let #(unit, found, analyzer) = analyze_folder(analyzer, directory, folder)
      #([unit, ..units], list.append(problems, found), analyzer)
    })
  let units = list.reverse(units)
  use Nil <- result.try(refuse_problems(problems))
  use Nil <- result.try(refuse_problems(model.check_types(units)))
  use texts <- result.try(render_units(analyzer, units))
  format(directory, texts)
}

fn analyze_folder(
  analyzer: Analyzer,
  directory: String,
  folder: String,
) -> #(Unit, List(Problem), Analyzer) {
  let module = module_of_folder(folder) |> result.unwrap(folder)
  let folder_name = string.split(module, "/") |> list.last |> result.unwrap("")
  let model_info =
    query.Model(module:, type_name: name.to_type_name(folder_name))
  let files = sql_files(directory, folder) |> result.unwrap([])
  let #(queries, problems, analyzer) =
    list.fold(files, #([], [], analyzer), fn(state, file) {
      let #(queries, problems, analyzer) = state
      let path = folder <> "/" <> file
      let #(described, analyzer) =
        analyze_file(analyzer, model_info, directory, path)
      case described {
        Ok(found) -> #([found, ..queries], problems, analyzer)
        Error(found) -> #(queries, list.append(problems, found), analyzer)
      }
    })
  #(
    Unit(model: model_info, folder:, queries: list.reverse(queries)),
    problems,
    analyzer,
  )
}

fn analyze_file(
  analyzer: Analyzer,
  model_info: query.Model,
  directory: String,
  path: String,
) -> #(Result(query.Query, List(Problem)), Analyzer) {
  case simplifile.read(filepath.join(directory, path)) {
    Ok(sql) -> query.analyze(analyzer, model_info, path, sql)
    Error(error) -> #(
      Error([
        query.Problem(
          file: path,
          line: 1,
          message: "cannot read the file: " <> simplifile.describe_error(error),
        ),
      ]),
      analyzer,
    )
  }
}

fn refuse_problems(problems: List(Problem)) -> Result(Nil, String) {
  case problems {
    [] -> Ok(Nil)
    _ ->
      Error(
        list.map(problems, fn(problem) {
          query.problem_to_string(problem) <> "\n"
        })
        |> string.concat
        <> "dream_model wrote nothing: "
        <> int.to_string(list.length(problems))
        <> " problem(s).\n",
      )
  }
}

fn render_units(
  analyzer: Analyzer,
  units: List(Unit),
) -> Result(List(Generated), String) {
  list.try_map(units, fn(unit) {
    let tables =
      list.flat_map(unit.queries, fn(found) { found.relations })
      |> list.unique
      |> list.sort(string.compare)
    let prefix =
      "dream_model cannot read the schema fingerprint of "
      <> unit.folder
      <> ": "
    use hash <- result.try(
      fingerprint.compute(analyzer, tables)
      |> result.map_error(nullability.error_to_string)
      |> result.map_error(string.append(prefix, _))
      |> result.map_error(string.append(_, "\n")),
    )
    model.render(unit, hash)
    |> result.map(Generated(unit.folder <> ".gleam", _))
    |> result.map_error(fn(problems) {
      refuse_problems(problems) |> result.unwrap_error("")
    })
  })
}

// --- Formatting ------------------------------------------------------------

/// Formats the modules with `gleam format`, in a folder under `build`.
fn format(
  directory: String,
  modules: List(Generated),
) -> Result(List(Generated), String) {
  let work = filepath.join(directory, "build/dream_model/format")
  let _removed = simplifile.delete(work)
  let files =
    list.index_map(modules, fn(_, index) {
      "build/dream_model/format/module_" <> int.to_string(index) <> ".gleam"
    })
  use Nil <- result.try(
    simplifile.create_directory_all(work)
    |> result.try(fn(_) {
      list.zip(files, modules)
      |> list.try_each(fn(pair) {
        simplifile.write(filepath.join(directory, pair.0), { pair.1 }.text)
      })
    })
    |> result.map_error(fn(error) {
      "dream_model cannot write to build/dream_model: "
      <> simplifile.describe_error(error)
      <> "\n"
    }),
  )
  use #(status, output) <- result.try(
    run_program(gleam_program, ["format", ..files], directory)
    |> result.replace_error(
      "dream_model needs the gleam program on the PATH to format the modules\n",
    ),
  )
  use <- bool.guard(
    when: status != 0,
    return: Error("gleam format refused a generated module:\n" <> output),
  )
  list.zip(files, modules)
  |> list.try_map(fn(pair) {
    simplifile.read(filepath.join(directory, pair.0))
    |> result.map(fn(text) { Generated(..pair.1, text:) })
    |> result.map_error(simplifile.describe_error)
  })
}

// --- Writing and checking --------------------------------------------------

fn finish(
  mode: Mode,
  directory: String,
  modules: List(Generated),
) -> Result(String, String) {
  case mode {
    Generate -> write_modules(directory, modules)
    Check -> check_modules(directory, modules)
  }
}

fn write_modules(
  directory: String,
  modules: List(Generated),
) -> Result(String, String) {
  list.try_map(modules, fn(module) {
    let path = filepath.join(directory, module.path)
    let unchanged = simplifile.read(path) == Ok(module.text)
    use Nil <- result.map(
      simplifile.write(path, module.text)
      |> result.map_error(fn(error) {
        "dream_model cannot write "
        <> module.path
        <> ": "
        <> simplifile.describe_error(error)
        <> "\n"
      }),
    )
    case unchanged {
      True -> "unchanged " <> module.path <> "\n"
      False -> "wrote " <> module.path <> "\n"
    }
  })
  |> result.map(string.concat)
}

fn check_modules(
  directory: String,
  modules: List(Generated),
) -> Result(String, String) {
  let stale =
    list.filter_map(modules, fn(module) {
      case simplifile.read(filepath.join(directory, module.path)) {
        Ok(text) if text == module.text -> Error(Nil)
        Ok(_) -> Ok("differs " <> module.path <> "\n")
        Error(_) -> Ok("missing " <> module.path <> "\n")
      }
    })
  case stale {
    [] ->
      Ok(
        "every model module matches its .sql files ("
        <> int.to_string(list.length(modules))
        <> " modules)\n",
      )
    _ ->
      Error(
        string.concat(stale)
        <> "Run `gleam run -m dream_model` to write the modules again.\n",
      )
  }
}
