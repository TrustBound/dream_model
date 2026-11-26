//// The command `gleam run -m dream_model`: finds the model folders, reads
//// their SQL files, analyzes them against the database and writes one
//// Gleam module next to each folder. With `--check` it writes nothing and
//// lists every module that is missing or differs.
////
//// A generated module starts with a header line that names its folder. A
//// module whose folder holds no `.sql` file any more is stale: generation
//// removes it, and `--check` lists it. The command never overwrites or
//// removes a file without the header line.
////
//// The settings are in the `[tools.dream_model]` table of the app's
//// `gleam.toml`:
////
//// - `database_url_variable`: the environment variable that holds the
////   database URL. The default is `DATABASE_URL`.
//// - `models`: the model folders, for example `["src/app/models/user"]`.
////   The default is every folder under `src` that holds a `.sql` file.

import dream_model/generator/fingerprint.{compute}
import dream_model/generator/model.{type Unit, Unit}
import dream_model/generator/name.{to_type_name}
import dream_model/generator/query.{
  type Model, type Problem, type Query, Model, analyze, problem_to_string,
}
import dream_model/generator/query_hint.{is_module_segment}
import dream_model/nullability.{
  type AnalysisError, type Analyzer, close, connect, error_to_string,
}
import filepath.{directory_name}
import gleam/bool.{guard, lazy_guard}
import gleam/dict.{type Dict, keys, new}
import gleam/int.{to_string}
import gleam/io.{print}
import gleam/list.{
  all, contains, filter, filter_map, flat_map, fold, index_map, last, reverse,
  sort, try_each, try_map, unique, zip,
}
import gleam/option.{type Option, None, Some}
import gleam/result.{
  is_error, map_error, replace, replace_error, try, unwrap_error,
}
import gleam/string.{
  compare, concat, drop_end, drop_start, ends_with, split, starts_with,
}
import simplifile.{
  type FileError, Enoent, Enotdir, create_directory_all, delete, describe_error,
  get_files, is_file, read, read_directory, write,
}
import tom.{
  type GetError, type Toml, NotFound, WrongType, as_string, get_array,
  get_string, get_table, parse,
}

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
/// and ends the program with `halt` when the command failed.
/// `read_environment` reads an environment variable.
pub fn main(
  arguments: List(String),
  directory: String,
  read_environment: fn(String) -> Result(String, Nil),
  halt: fn(Int) -> Nil,
) -> Nil {
  let outcome = run(arguments, directory, read_environment)
  print(outcome.output)
  case outcome.status {
    0 -> Nil
    status -> halt(status)
  }
}

/// Runs the command in the project folder `directory`. `read_environment`
/// reads an environment variable.
pub fn run(
  arguments: List(String),
  directory: String,
  read_environment: fn(String) -> Result(String, Nil),
) -> Outcome {
  case execute(arguments, directory, read_environment) {
    Ok(output) -> Outcome(status: 0, output:)
    Error(output) -> Outcome(status: 1, output:)
  }
}

fn execute(
  arguments: List(String),
  directory: String,
  read_environment: fn(String) -> Result(String, Nil),
) -> Result(String, String) {
  use mode <- try(parse_arguments(arguments))
  use config <- try(read_config(directory))
  use folders <- try(find_folders(directory, config))
  use stale <- try(find_stale_modules(directory))
  use <- guard(
    when: folders == [] && stale == [],
    return: Ok(
      "dream_model found no folder with .sql files under src; there is nothing to generate.\n",
    ),
  )
  use <- lazy_guard(when: folders == [], return: fn() {
    finish(mode, directory, [], stale)
  })
  use url <- try(
    read_environment(config.database_url_variable)
    |> replace_error(
      "dream_model needs the URL of the database in the environment variable "
      <> config.database_url_variable
      <> ", for example postgresql://user:password@localhost:5432/app\n",
    ),
  )
  use analyzer <- try(
    connect(url)
    |> map_error(fn(error) {
      "dream_model cannot use the database: " <> error_to_string(error) <> "\n"
    }),
  )
  let generated = generate(analyzer, directory, folders)
  let closed = close(analyzer)
  use modules <- try(generated)
  use Nil <- try(check_closed(closed))
  finish(mode, directory, modules, stale)
}

/// The analysis is complete, so a failed goodbye to the server changes no
/// module. It still means the connection broke, so the command fails and
/// says so, and writes nothing.
pub fn check_closed(closed: Result(Nil, AnalysisError)) -> Result(Nil, String) {
  map_error(closed, fn(error) {
    "dream_model cannot close the database connection: "
    <> error_to_string(error)
    <> "\n"
  })
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
  use text <- try(
    read(path)
    |> map_error(fn(error) {
      "dream_model cannot read gleam.toml: " <> describe_error(error) <> "\n"
    }),
  )
  use toml <- try(
    parse(text)
    |> replace_error("dream_model cannot parse gleam.toml\n"),
  )
  let table = get_table(toml, ["tools", "dream_model"]) |> result.unwrap(new())
  use Nil <- try(check_keys(table))
  use database_url_variable <- try(
    optional_setting(get_string(table, ["database_url_variable"]))
    |> result.map(option.unwrap(_, default_database_url_variable))
    |> replace_error(setting_error("database_url_variable", "a string")),
  )
  use models <- result.map(
    optional_setting(get_array(table, ["models"]))
    |> try(option_try(_, strings))
    |> replace_error(setting_error("models", "a list of folders")),
  )
  Config(database_url_variable:, models:)
}

fn check_keys(table: Dict(String, Toml)) -> Result(Nil, String) {
  let unknown =
    keys(table)
    |> filter(fn(key) { !contains(["database_url_variable", "models"], key) })
    |> sort(compare)
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
fn optional_setting(found: Result(a, GetError)) -> Result(Option(a), Nil) {
  case found {
    Ok(value) -> Ok(Some(value))
    Error(NotFound(_)) -> Ok(None)
    Error(WrongType(..)) -> Error(Nil)
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

fn strings(items: List(Toml)) -> Result(List(String), Nil) {
  try_map(items, fn(item) { as_string(item) |> replace_error(Nil) })
}

// --- Folders ---------------------------------------------------------------

/// Returns the model folders, relative to the project, sorted: the folders
/// of `models`, or every folder under `src` with a `.sql` file in it.
pub fn find_folders(
  directory: String,
  config: Config,
) -> Result(List(String), String) {
  use folders <- try(case config.models {
    Some(models) -> check_model_folders(directory, models)
    None -> discover_folders(directory)
  })
  let refused =
    filter(folders, fn(folder) { is_error(module_of_folder(folder)) })
  case refused {
    [] -> Ok(sort(folders, compare))
    _ ->
      Error(
        "these model folders are not Gleam module paths under src: "
        <> string.join(refused, ", ")
        <> "; each folder name must be in snake case, for example src/app/models/user\n",
      )
  }
}

fn discover_folders(directory: String) -> Result(List(String), String) {
  use files <- result.map(source_files(directory))
  filter(files, ends_with(_, ".sql"))
  |> list.map(fn(file) {
    let folder = directory_name(file)
    case folder {
      "src/" <> _ -> folder
      _ -> "src"
    }
  })
  |> unique
}

/// Every file under `src`, as a path relative to the project, for example
/// `src/app/models/user.gleam`.
fn source_files(directory: String) -> Result(List(String), String) {
  let source = filepath.join(directory, "src")
  use files <- result.map(
    get_files(in: source)
    |> map_error(fn(error) {
      "dream_model cannot read the src folder: "
      <> describe_error(error)
      <> "\n"
    }),
  )
  list.map(files, fn(file) {
    "src/" <> drop_start(file, string.length(source) + 1)
  })
}

/// The generated modules whose folder holds no `.sql` file: each `.gleam`
/// file under `src` that starts with the header line of its folder, the
/// path without `.gleam`.
fn find_stale_modules(directory: String) -> Result(List(String), String) {
  use files <- result.map(source_files(directory))
  filter(files, fn(file) {
    let folder = drop_end(file, string.length(".gleam"))
    ends_with(file, ".gleam")
    && starts_with_header(directory, file, folder)
    && sql_files(directory, folder) |> result.unwrap([]) == []
  })
  |> sort(compare)
}

fn starts_with_header(directory: String, path: String, folder: String) -> Bool {
  read(filepath.join(directory, path))
  |> result.map(starts_with(_, model.header_line(folder) <> "\n"))
  |> result.unwrap(False)
}

fn check_model_folders(
  directory: String,
  models: List(String),
) -> Result(List(String), String) {
  let missing =
    filter(models, fn(folder) {
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
  read_directory(filepath.join(directory, folder))
  |> replace_error(Nil)
  |> result.map(fn(entries) {
    filter(entries, ends_with(_, ".sql"))
    |> sort(compare)
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
  case all(split(module, "/"), is_module_segment) {
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
    fold(folders, #([], [], analyzer), fn(state, folder) {
      let #(units, problems, analyzer) = state
      let #(unit, found, analyzer) = analyze_folder(analyzer, directory, folder)
      #([unit, ..units], list.append(problems, found), analyzer)
    })
  let units = reverse(units)
  use Nil <- try(refuse_problems(problems))
  use Nil <- try(refuse_problems(model.check_types(units)))
  use texts <- try(render_units(analyzer, units))
  format(directory, texts)
}

fn analyze_folder(
  analyzer: Analyzer,
  directory: String,
  folder: String,
) -> #(Unit, List(Problem), Analyzer) {
  let module = module_of_folder(folder) |> result.unwrap(folder)
  let folder_name = split(module, "/") |> last |> result.unwrap("")
  let model_info = Model(module:, type_name: to_type_name(folder_name))
  let files = sql_files(directory, folder) |> result.unwrap([])
  let #(queries, problems, analyzer) =
    fold(files, #([], [], analyzer), fn(state, file) {
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
    Unit(model: model_info, folder:, queries: reverse(queries)),
    problems,
    analyzer,
  )
}

fn analyze_file(
  analyzer: Analyzer,
  model_info: Model,
  directory: String,
  path: String,
) -> #(Result(Query, List(Problem)), Analyzer) {
  case read(filepath.join(directory, path)) {
    Ok(sql) -> analyze(analyzer, model_info, path, sql)
    Error(error) -> #(
      Error([
        query.Problem(
          file: path,
          line: 1,
          message: "cannot read the file: " <> describe_error(error),
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
        list.map(problems, fn(problem) { problem_to_string(problem) <> "\n" })
        |> concat
        <> "dream_model wrote nothing: "
        <> to_string(list.length(problems))
        <> " problem(s).\n",
      )
  }
}

fn render_units(
  analyzer: Analyzer,
  units: List(Unit),
) -> Result(List(Generated), String) {
  try_map(units, fn(unit) {
    let tables =
      flat_map(unit.queries, fn(found) { found.relations })
      |> unique
      |> sort(compare)
    let prefix =
      "dream_model cannot read the schema fingerprint of "
      <> unit.folder
      <> ": "
    use hash <- try(
      compute(analyzer, tables)
      |> map_error(error_to_string)
      |> map_error(string.append(prefix, _))
      |> map_error(string.append(_, "\n")),
    )
    model.render(unit, hash)
    |> result.map(Generated(unit.folder <> ".gleam", _))
    |> map_error(fn(problems) { refuse_problems(problems) |> unwrap_error("") })
  })
}

// --- Formatting ------------------------------------------------------------

/// Formats the modules with `gleam format`, in a folder under `build`.
fn format(
  directory: String,
  modules: List(Generated),
) -> Result(List(Generated), String) {
  let work = filepath.join(directory, "build/dream_model/format")
  use Nil <- try(check_removed(delete(work)))
  let files =
    index_map(modules, fn(_, index) {
      "build/dream_model/format/module_" <> to_string(index) <> ".gleam"
    })
  use Nil <- try(
    create_directory_all(work)
    |> try(fn(_) {
      zip(files, modules)
      |> try_each(fn(pair) {
        write(filepath.join(directory, pair.0), { pair.1 }.text)
      })
    })
    |> map_error(fn(error) {
      "dream_model cannot write to build/dream_model: "
      <> describe_error(error)
      <> "\n"
    }),
  )
  use #(status, output) <- try(
    run_program(gleam_program, ["format", ..files], directory)
    |> replace_error(
      "dream_model needs the gleam program on the PATH to format the modules\n",
    ),
  )
  use <- guard(
    when: status != 0,
    return: Error("gleam format refused a generated module:\n" <> output),
  )
  zip(files, modules)
  |> try_map(fn(pair) {
    read(filepath.join(directory, pair.0))
    |> result.map(fn(text) { Generated(..pair.1, text:) })
    |> map_error(describe_error)
  })
}

/// The format folder of an earlier run is removed first. A folder that
/// does not exist is fine.
pub fn check_removed(removed: Result(Nil, FileError)) -> Result(Nil, String) {
  case removed {
    Ok(Nil) | Error(Enoent) | Error(Enotdir) -> Ok(Nil)
    Error(error) ->
      Error(
        "dream_model cannot remove build/dream_model/format: "
        <> describe_error(error)
        <> "\n",
      )
  }
}

// --- Writing and checking --------------------------------------------------

fn finish(
  mode: Mode,
  directory: String,
  modules: List(Generated),
  stale: List(String),
) -> Result(String, String) {
  case mode {
    Generate -> write_modules(directory, modules, stale)
    Check -> check_modules(directory, modules, stale)
  }
}

fn write_modules(
  directory: String,
  modules: List(Generated),
  stale: List(String),
) -> Result(String, String) {
  use Nil <- try(refuse_foreign_files(directory, modules))
  use written <- try(
    try_map(modules, write_module(directory, _))
    |> result.map(concat),
  )
  use removed <- result.map(
    try_map(stale, fn(path) {
      delete(filepath.join(directory, path))
      |> replace("removed " <> path <> "\n")
      |> map_error(fn(error) {
        "dream_model cannot remove "
        <> path
        <> ": "
        <> describe_error(error)
        <> "\n"
      })
    }),
  )
  written <> concat(removed)
}

/// Refuses to write over a file that dream_model did not write: one that
/// does not start with the header line of its folder.
fn refuse_foreign_files(
  directory: String,
  modules: List(Generated),
) -> Result(Nil, String) {
  let foreign =
    filter(modules, fn(module) {
      let folder = drop_end(module.path, string.length(".gleam"))
      is_file(filepath.join(directory, module.path)) == Ok(True)
      && !starts_with_header(directory, module.path, folder)
    })
  case foreign {
    [] -> Ok(Nil)
    _ ->
      Error(
        list.map(foreign, fn(module) {
          "dream_model will not overwrite "
          <> module.path
          <> ": the file does not start with the line '"
          <> model.header_line(drop_end(module.path, string.length(".gleam")))
          <> "', so dream_model did not write it; move the file, and run the command again\n"
        })
        |> concat
        <> "dream_model wrote nothing.\n",
      )
  }
}

fn write_module(
  directory: String,
  module: Generated,
) -> Result(String, String) {
  {
    let path = filepath.join(directory, module.path)
    let unchanged = read(path) == Ok(module.text)
    use Nil <- result.map(
      write(path, module.text)
      |> map_error(fn(error) {
        "dream_model cannot write "
        <> module.path
        <> ": "
        <> describe_error(error)
        <> "\n"
      }),
    )
    case unchanged {
      True -> "unchanged " <> module.path <> "\n"
      False -> "wrote " <> module.path <> "\n"
    }
  }
}

fn check_modules(
  directory: String,
  modules: List(Generated),
  stale: List(String),
) -> Result(String, String) {
  let differing =
    filter_map(modules, fn(module) {
      case read(filepath.join(directory, module.path)) {
        Ok(text) if text == module.text -> Error(Nil)
        Ok(_) -> Ok("differs " <> module.path <> "\n")
        Error(_) -> Ok("missing " <> module.path <> "\n")
      }
    })
    |> list.append(list.map(stale, fn(path) { "stale " <> path <> "\n" }))
  case differing {
    [] ->
      Ok(
        "every model module matches its .sql files ("
        <> to_string(list.length(modules))
        <> " modules)\n",
      )
    _ ->
      Error(
        concat(differing)
        <> "Run `gleam run -m dream_model` to write the modules again.\n",
      )
  }
}
