//// Tests for the SQL files that the guides show: each file of
//// `test/snippets/why_option` gives the NULL decisions and reasons that
//// docs/guides/why-option.md tells, on the attack database, and each file
//// of `test/snippets/types` gives the fields that docs/guides/types.md
//// tells, on the generator database.

import dream_model/generator/gleam_type.{
  type GleamType, IntType, StringType, TimestampType,
}
import dream_model/generator/query.{Model, RecordOutput}
import dream_model/nullability
import dream_model/nullability/reason.{type ColumnReason, type ParameterReason}
import dream_test/matchers.{be_equal, or_fail_with, should}
import dream_test/suite.{type TestSuite}
import dream_test/unit.{describe, group, it}
import fixtures/attack_database
import fixtures/model_database
import fixtures/servers
import gleam/int
import gleam/list
import gleam/result
import simplifile

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
  describe(
    "the SQL files of the guides on PostgreSQL " <> int.to_string(version),
    [
      group(
        "why-option.md",
        why_option_cases(version)
          |> list.filter(fn(example) { version >= example.1 })
          |> list.map(why_option_test(version, _)),
      ),
      group("types.md", list.map(type_cases(), type_test(version, _))),
    ],
  )
}

fn why_option_test(
  version: Int,
  example: #(String, Int, Decisions),
) -> unit.UnitNode {
  let #(file, _minimum_version, expected) = example
  it(file <> " gives the reasons of the guide", fn() {
    // Arrange
    let assert Ok(sql) = simplifile.read(why_option_folder <> file)
    let assert Ok(analyzer) =
      nullability.connect(servers.url(version, attack_database.database))

    // Act
    let decisions =
      nullability.analyze(analyzer, sql)
      |> result.map(fn(found) {
        let _ = nullability.close(found.1)
        summarize(found.0)
      })

    // Assert
    decisions
    |> should
    |> be_equal(Ok(expected))
    |> or_fail_with("Expected the reasons of " <> file)
  })
}

fn summarize(analysis: nullability.Analysis) -> Decisions {
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
    True -> reason.OuterJoinOrGroupingSet
    False -> reason.GroupingSet
  }
  [
    #(
      "column_allows_null.sql",
      16,
      Decisions(
        columns: [
          #("id", False, reason.NotNullInSchema),
          #("nickname", True, reason.ColumnAllowsNull),
        ],
        parameters: [],
      ),
    ),
    #(
      "outer_join.sql",
      16,
      Decisions(
        columns: [
          #("email", False, reason.NotNullInSchema),
          #("title", True, reason.OuterJoinOrGroupingSet),
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
          #("total", False, reason.CountAggregate),
        ],
        parameters: [],
      ),
    ),
    #(
      "computed_value.sql",
      16,
      Decisions(
        columns: [#("low", True, reason.ComputedValue("funcexpr"))],
        parameters: [],
      ),
    ),
    #(
      "whole_row.sql",
      16,
      Decisions(columns: [#("u", True, reason.WholeRow)], parameters: []),
    ),
    #(
      "materialized_view.sql",
      16,
      Decisions(
        columns: [#("email", True, reason.RelationKindWithoutNotNull("m"))],
        parameters: [],
      ),
    ),
    #(
      "recursive_cte.sql",
      16,
      Decisions(columns: [#("e", True, reason.RecursiveCte)], parameters: []),
    ),
    #(
      "values_list.sql",
      16,
      Decisions(
        columns: [#("a", True, reason.RangeResult("values"))],
        parameters: [],
      ),
    ),
    #(
      "child_table.sql",
      18,
      Decisions(
        columns: [#("label", True, reason.ChildTableAllowsNull)],
        parameters: [],
      ),
    ),
    #(
      "not_valid.sql",
      18,
      Decisions(
        columns: [#("code", True, reason.NotNullNotValid)],
        parameters: [],
      ),
    ),
    #(
      "returning_old_new.sql",
      18,
      Decisions(
        columns: [
          #("email", True, reason.ReturningOldNew),
          #("email", False, reason.NotNullInSchema),
        ],
        parameters: [
          #(1, False, reason.ColumnIsNotNull),
          #(2, False, reason.ColumnIsNotNull),
        ],
      ),
    ),
    #(
      "merge_not_matched.sql",
      17,
      Decisions(
        columns: [
          #("email", False, reason.NotNullInSchema),
          #("title", True, reason.MergeNotMatchedBySource),
        ],
        parameters: [],
      ),
    ),
    #(
      "nullable_hint.sql",
      16,
      Decisions(
        columns: [#("email", True, reason.NullableHint)],
        parameters: [],
      ),
    ),
    #(
      "parameter_store.sql",
      16,
      Decisions(columns: [#("id", False, reason.NotNullInSchema)], parameters: [
        #(1, False, reason.ColumnIsNotNull),
        #(2, False, reason.DomainNotNull),
        #(3, True, reason.StoredIntoNullableColumn),
      ]),
    ),
    #(
      "parameter_length.sql",
      16,
      Decisions(columns: [#("id", False, reason.NotNullInSchema)], parameters: [
        #(1, False, reason.ColumnIsNotNull),
        #(2, True, reason.StoredIntoNullableColumn),
      ]),
    ),
    #(
      "parameter_hint.sql",
      16,
      Decisions(columns: [#("id", False, reason.NotNullInSchema)], parameters: [
        #(1, True, reason.ParamsHint),
      ]),
    ),
    #(
      "parameter_compared.sql",
      16,
      Decisions(columns: [#("id", False, reason.NotNullInSchema)], parameters: [
        #(1, False, reason.Required),
      ]),
    ),
    #(
      "parameter_also_used.sql",
      16,
      Decisions(columns: [#("id", False, reason.NotNullInSchema)], parameters: [
        #(1, False, reason.AlsoUsedOutsideStore),
      ]),
    ),
    #(
      "parameter_domain_check.sql",
      16,
      Decisions(columns: [#("id", False, reason.NotNullInSchema)], parameters: [
        #(1, False, reason.ColumnIsNotNull),
        #(2, False, reason.DomainCheck),
        #(3, True, reason.StoredIntoNullableColumn),
      ]),
    ),
    #(
      "parameter_check.sql",
      16,
      Decisions(columns: [#("id", False, reason.NotNullInSchema)], parameters: [
        #(1, False, reason.ColumnIsNotNull),
        #(2, False, reason.CheckConstraint),
      ]),
    ),
    #(
      "parameter_partition.sql",
      16,
      Decisions(columns: [#("id", False, reason.NotNullInSchema)], parameters: [
        #(1, False, reason.ColumnIsNotNull),
        #(2, False, reason.ColumnIsNotNull),
        #(3, False, reason.PartitionNotNull),
      ]),
    ),
    #(
      "parameter_partition_check.sql",
      16,
      Decisions(columns: [#("id", False, reason.NotNullInSchema)], parameters: [
        #(1, False, reason.ColumnIsNotNull),
        #(2, False, reason.ColumnIsNotNull),
        #(3, False, reason.PartitionCheck),
      ]),
    ),
    #(
      "parameter_trigger.sql",
      16,
      Decisions(columns: [#("id", False, reason.NotNullInSchema)], parameters: [
        #(1, False, reason.ColumnIsNotNull),
        #(2, False, reason.ColumnIsNotNull),
        #(3, False, reason.BeforeTrigger),
      ]),
    ),
    #(
      "parameter_row_security.sql",
      16,
      Decisions(columns: [#("id", False, reason.NotNullInSchema)], parameters: [
        #(1, False, reason.ColumnIsNotNull),
        #(2, False, reason.RowLevelSecurity),
      ]),
    ),
  ]
}

fn type_test(
  version: Int,
  example: #(String, List(#(String, GleamType, Bool))),
) -> unit.UnitNode {
  let #(file, expected) = example
  it(file <> " gives the fields of the guide", fn() {
    // Arrange
    let assert Ok(sql) = simplifile.read(types_folder <> file)
    let assert Ok(analyzer) = nullability.connect(model_database.url(version))

    // Act
    let #(found, analyzer) =
      query.analyze(
        analyzer,
        Model(module: "app/models/sample", type_name: "Sample"),
        "src/app/models/sample/" <> file,
        sql,
      )
    let _ = nullability.close(analyzer)
    let fields =
      found
      |> result.replace_error(Nil)
      |> result.try(fn(described) {
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
