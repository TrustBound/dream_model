//// Tests for the SQL files that the guides show: each file of
//// `test/snippets/why_option` gives the NULL decisions and reasons that
//// docs/guides/why-option.md tells, on the attack database, and each file
//// of `test/snippets/types` gives the fields that docs/guides/types.md
//// tells, on the generator database.

import dream_model/generator/gleam_type.{
  type GleamType, IntType, StringType, TimestampType,
}
import dream_model/generator/model.{Unit}
import dream_model/generator/query.{Model, Problem, RecordOutput}
import dream_model/nullability.{type Analysis, close, connect}
import dream_model/nullability/reason.{
  type ColumnReason, type ParameterReason, AlsoUsedOutsideStore, BeforeTrigger,
  CastToDomainWithCheck, CastToNotNullDomain, CheckConstraint,
  ChildTableAllowsNull, ColumnAllowsNull, ColumnIsNotNull, ComputedValue,
  CountAggregate, DomainCheck, DomainNotNull, GeneratedColumnUsesIt, GroupingSet,
  MergeNotMatchedBySource, NotNullInSchema, NotNullNotValid, NullableHint,
  OuterJoinOrGroupingSet, ParamsHint, PartitionCheck, PartitionKey,
  PartitionNotNull, RangeResult, RecursiveCte, RelationKindWithoutNotNull,
  RelationNotTable, Required, ReturningOldNew, RowLevelSecurity, RuleAddsQueries,
  StoredIntoNullableColumn, ViewCheckOption, WholeRow,
}
import dream_test/matchers.{be_equal, or_fail_with, should}
import dream_test/suite.{type TestSuite}
import dream_test/unit.{type UnitNode, describe, group, it}
import fixtures/attack_database.{database}
import fixtures/model_database
import fixtures/servers
import gleam/int.{to_string}
import gleam/list.{filter}
import gleam/result.{replace, replace_error, try}
import simplifile.{read}

const why_option_folder = "test/snippets/why_option/"

const types_folder = "test/snippets/types/"

/// The decisions of one SQL file: each column with its NULL decision and
/// reason, and each parameter with its decision and reason.
pub type Decisions {
  Decisions(
    columns: List(#(String, Bool, ColumnReason)),
    parameters: List(#(Int, Bool, ParameterReason)),
  )
}

pub fn tests(version: Int) -> TestSuite {
  describe("the SQL files of the guides on PostgreSQL " <> to_string(version), [
    group(
      "why-option.md",
      why_option_cases(version)
        |> filter(fn(example) { version >= example.1 })
        |> list.map(why_option_test(version, _)),
    ),
    group("types.md", list.map(type_cases(), type_test(version, _))),
    group("hints.md", hint_tests(version)),
  ])
}

fn why_option_test(
  version: Int,
  example: #(String, Int, Decisions),
) -> UnitNode {
  let #(file, _minimum_version, expected) = example
  it(file <> " gives the reasons of the guide", fn() {
    // Arrange
    let assert Ok(sql) = read(why_option_folder <> file)
    let assert Ok(analyzer) = connect(servers.url(version, database()))

    // Act
    let decisions =
      nullability.analyze(analyzer, sql)
      |> result.map(fn(found) {
        let _ = close(found.1)
        summarize(found.0)
      })

    // Assert
    decisions
    |> should
    |> be_equal(Ok(expected))
    |> or_fail_with("Expected the reasons of " <> file)
  })
}

fn summarize(analysis: Analysis) -> Decisions {
  Decisions(
    columns: list.map(analysis.columns, fn(column) {
      #(column.name, !column.not_null, column.reason)
    }),
    parameters: list.map(analysis.parameters, fn(parameter) {
      #(parameter.position, parameter.optional, parameter.reason)
    }),
  )
}

/// Each file, the first version that runs it, and its decisions. A
/// column is `True` when it is `Option`.
fn why_option_cases(version: Int) -> List(#(String, Int, Decisions)) {
  let grouping = case version >= 18 {
    True -> OuterJoinOrGroupingSet
    False -> GroupingSet
  }
  [
    #(
      "column_allows_null.sql",
      16,
      Decisions(
        columns: [
          #("id", False, NotNullInSchema),
          #("nickname", True, ColumnAllowsNull),
        ],
        parameters: [],
      ),
    ),
    #(
      "outer_join.sql",
      16,
      Decisions(
        columns: [
          #("email", False, NotNullInSchema),
          #("title", True, OuterJoinOrGroupingSet),
        ],
        parameters: [],
      ),
    ),
    #(
      "grouping_set.sql",
      16,
      Decisions(
        columns: [
          #("email", True, grouping),
          #("total", False, CountAggregate),
        ],
        parameters: [],
      ),
    ),
    #(
      "computed_value.sql",
      16,
      Decisions(
        columns: [#("low", True, ComputedValue("funcexpr"))],
        parameters: [],
      ),
    ),
    #(
      "whole_row.sql",
      16,
      Decisions(columns: [#("u", True, WholeRow)], parameters: []),
    ),
    #(
      "materialized_view.sql",
      16,
      Decisions(
        columns: [#("email", True, RelationKindWithoutNotNull("m"))],
        parameters: [],
      ),
    ),
    #(
      "recursive_cte.sql",
      16,
      Decisions(columns: [#("e", True, RecursiveCte)], parameters: []),
    ),
    #(
      "values_list.sql",
      16,
      Decisions(columns: [#("a", True, RangeResult("values"))], parameters: []),
    ),
    #(
      "child_table.sql",
      18,
      Decisions(
        columns: [#("label", True, ChildTableAllowsNull)],
        parameters: [],
      ),
    ),
    #(
      "not_valid.sql",
      18,
      Decisions(columns: [#("code", True, NotNullNotValid)], parameters: []),
    ),
    #(
      "returning_old_new.sql",
      18,
      Decisions(
        columns: [
          #("email", True, ReturningOldNew),
          #("email", False, NotNullInSchema),
        ],
        parameters: [
          #(1, False, ColumnIsNotNull),
          #(2, False, ColumnIsNotNull),
        ],
      ),
    ),
    #(
      "merge_not_matched.sql",
      17,
      Decisions(
        columns: [
          #("email", False, NotNullInSchema),
          #("title", True, MergeNotMatchedBySource),
        ],
        parameters: [],
      ),
    ),
    #(
      "nullable_hint.sql",
      16,
      Decisions(columns: [#("email", True, NullableHint)], parameters: []),
    ),
    #(
      "parameter_store.sql",
      16,
      Decisions(columns: [#("id", False, NotNullInSchema)], parameters: [
        #(1, False, ColumnIsNotNull),
        #(2, False, DomainNotNull),
        #(3, True, StoredIntoNullableColumn),
      ]),
    ),
    #(
      "parameter_length.sql",
      16,
      Decisions(columns: [#("id", False, NotNullInSchema)], parameters: [
        #(1, False, ColumnIsNotNull),
        #(2, True, StoredIntoNullableColumn),
      ]),
    ),
    #(
      "parameter_hint.sql",
      16,
      Decisions(columns: [#("id", False, NotNullInSchema)], parameters: [
        #(1, True, ParamsHint),
      ]),
    ),
    #(
      "parameter_compared.sql",
      16,
      Decisions(columns: [#("id", False, NotNullInSchema)], parameters: [
        #(1, False, Required),
      ]),
    ),
    #(
      "parameter_also_used.sql",
      16,
      Decisions(columns: [#("id", False, NotNullInSchema)], parameters: [
        #(1, False, AlsoUsedOutsideStore),
      ]),
    ),
    #(
      "parameter_domain_check.sql",
      16,
      Decisions(columns: [#("id", False, NotNullInSchema)], parameters: [
        #(1, False, ColumnIsNotNull),
        #(2, False, DomainCheck),
        #(3, True, StoredIntoNullableColumn),
      ]),
    ),
    #(
      "parameter_check.sql",
      16,
      Decisions(columns: [#("id", False, NotNullInSchema)], parameters: [
        #(1, False, ColumnIsNotNull),
        #(2, False, CheckConstraint),
      ]),
    ),
    #(
      "parameter_partition.sql",
      16,
      Decisions(columns: [#("id", False, NotNullInSchema)], parameters: [
        #(1, False, ColumnIsNotNull),
        #(2, False, ColumnIsNotNull),
        #(3, False, PartitionNotNull),
      ]),
    ),
    #(
      "parameter_partition_check.sql",
      16,
      Decisions(columns: [#("id", False, NotNullInSchema)], parameters: [
        #(1, False, ColumnIsNotNull),
        #(2, False, ColumnIsNotNull),
        #(3, False, PartitionCheck),
      ]),
    ),
    #(
      "parameter_trigger.sql",
      16,
      Decisions(columns: [#("id", False, NotNullInSchema)], parameters: [
        #(1, False, ColumnIsNotNull),
        #(2, False, ColumnIsNotNull),
        #(3, False, BeforeTrigger),
      ]),
    ),
    #(
      "parameter_row_security.sql",
      16,
      Decisions(columns: [#("id", False, NotNullInSchema)], parameters: [
        #(1, False, ColumnIsNotNull),
        #(2, False, RowLevelSecurity),
      ]),
    ),
    #(
      "parameter_rule.sql",
      16,
      Decisions(columns: [#("id", False, NotNullInSchema)], parameters: [
        #(1, False, RuleAddsQueries(2)),
        #(2, False, RuleAddsQueries(2)),
      ]),
    ),
    #(
      "parameter_cast_domain.sql",
      16,
      Decisions(columns: [#("id", False, NotNullInSchema)], parameters: [
        #(1, False, ColumnIsNotNull),
        #(2, False, CastToNotNullDomain),
      ]),
    ),
    #(
      "parameter_cast_domain_check.sql",
      16,
      Decisions(columns: [#("id", False, NotNullInSchema)], parameters: [
        #(1, False, ColumnIsNotNull),
        #(2, False, CastToDomainWithCheck),
      ]),
    ),
    #(
      "parameter_generated.sql",
      16,
      Decisions(columns: [#("id", False, NotNullInSchema)], parameters: [
        #(1, False, ColumnIsNotNull),
        #(2, False, GeneratedColumnUsesIt),
      ]),
    ),
    #(
      "parameter_partition_key.sql",
      16,
      Decisions(columns: [#("id", False, NotNullInSchema)], parameters: [
        #(1, False, ColumnIsNotNull),
        #(2, False, PartitionKey),
      ]),
    ),
    #(
      "parameter_check_option.sql",
      16,
      Decisions(columns: [#("id", False, NotNullInSchema)], parameters: [
        #(1, False, ColumnIsNotNull),
        #(2, False, ViewCheckOption),
      ]),
    ),
    #(
      "parameter_view_trigger.sql",
      16,
      Decisions(
        columns: [#("id", True, RelationKindWithoutNotNull("v"))],
        parameters: [
          #(1, False, RelationNotTable("v")),
          #(2, False, RelationNotTable("v")),
        ],
      ),
    ),
    #(
      "parameter_whole_row_check.sql",
      16,
      Decisions(columns: [#("id", False, NotNullInSchema)], parameters: [
        #(1, False, ColumnIsNotNull),
        #(2, False, CheckConstraint),
      ]),
    ),
    #(
      "foreign_child.sql",
      16,
      Decisions(
        columns: [#("id", True, RelationKindWithoutNotNull("f"))],
        parameters: [],
      ),
    ),
  ]
}

fn type_test(
  version: Int,
  example: #(String, List(#(String, GleamType, Bool))),
) -> UnitNode {
  let #(file, expected) = example
  it(file <> " gives the fields of the guide", fn() {
    // Arrange
    let assert Ok(sql) = read(types_folder <> file)
    let assert Ok(analyzer) = connect(model_database.url(version))

    // Act
    let #(found, analyzer) =
      query.analyze(
        analyzer,
        Model(module: "app/models/sample", type_name: "Sample"),
        "src/app/models/sample/" <> file,
        sql,
      )
    let _ = close(analyzer)
    let fields =
      found
      |> replace_error(Nil)
      |> try(fn(described) {
        case described.output {
          RecordOutput(fields:, ..) ->
            Ok(
              list.map(fields, fn(field) {
                #(field.name, field.gleam_type, field.optional)
              }),
            )
          _ -> Error(Nil)
        }
      })

    // Assert
    fields
    |> should
    |> be_equal(Ok(expected))
    |> or_fail_with("Expected the fields of " <> file)
  })
}

/// Each file and its fields: the name, the Gleam type and `True` when the
/// field is `Option`.
fn type_cases() -> List(#(String, List(#(String, GleamType, Bool)))) {
  [
    #("finite_rows.sql", [
      #("id", IntType, False),
      #("happened_at", TimestampType, True),
    ]),
    #("time_as_text.sql", [
      #("id", IntType, False),
      #("happened_at", StringType, True),
    ]),
    #("interval_as_text.sql", [
      #("id", IntType, False),
      #("span", StringType, True),
    ]),
  ]
}

const hints_folder = "test/snippets/hints/"

/// Each SQL file of hints.md that dream_model refuses, with the problems
/// of the guide.
fn hint_tests(version: Int) -> List(UnitNode) {
  [
    it("reserved_type.sql gives the refusal of the guide", fn() {
      // Arrange
      let file = "src/app/models/user/find.sql"
      let assert Ok(sql) = read(hints_folder <> "reserved_type.sql")
      let assert Ok(analyzer) = connect(model_database.url(version))
      let model_info = Model(module: "app/models/user", type_name: "User")

      // Act
      let #(found, analyzer) = query.analyze(analyzer, model_info, file, sql)
      let _ = close(analyzer)
      let assert Ok(found) = found
      let rendered =
        model.render(
          Unit(model: model_info, folder: "src/app/models/user", queries: [
            found,
          ]),
          "abc",
        )

      // Assert
      rendered
      |> should
      |> be_equal(
        Error([
          Problem(
            file,
            1,
            "the type name 'Error' is a type or a constructor of the Gleam prelude or of an import of the generated module; write another type name in the 'returns' hint, for example 'returns: one ErrorRow', or rename the model folder",
          ),
        ]),
      )
      |> or_fail_with("Expected the refusal of reserved_type.sql")
    }),
    it("reserved_parameter.sql gives the refusal of the guide", fn() {
      // Arrange
      let file = "src/app/models/user/after.sql"
      let assert Ok(sql) = read(hints_folder <> "reserved_parameter.sql")
      let assert Ok(analyzer) = connect(model_database.url(version))
      let model_info = Model(module: "app/models/user", type_name: "User")

      // Act
      let #(found, analyzer) = query.analyze(analyzer, model_info, file, sql)
      let _ = close(analyzer)

      // Assert
      found
      |> replace(Nil)
      |> should
      |> be_equal(
        Error([
          Problem(
            file,
            2,
            "the parameter name 'many_rows' is a name that the generated function uses itself: its connection, a module, a helper or a decoder; choose another name",
          ),
        ]),
      )
      |> or_fail_with("Expected the refusal of reserved_parameter.sql")
    }),
  ]
}
