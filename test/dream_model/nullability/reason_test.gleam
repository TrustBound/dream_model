//// Tests for `dream_model/nullability/reason`: the text of every reason.

import dream_model/nullability/reason
import dream_test/matchers.{be_equal, or_fail_with, should}
import dream_test/suite.{type TestSuite}
import dream_test/unit.{describe, it}
import gleam/list

type Reason {
  ColumnReason(reason.ColumnReason)
  ParameterReason(reason.ParameterReason)
}

fn column(value: reason.ColumnReason) -> Reason {
  ColumnReason(value)
}

fn parameter(value: reason.ParameterReason) -> Reason {
  ParameterReason(value)
}

pub fn tests() -> TestSuite {
  describe("dream_model/nullability/reason", list.map(cases(), text_test))
}

fn describe_reason(value: Reason) -> String {
  case value {
    ColumnReason(value) -> reason.column_reason_to_string(value)
    ParameterReason(value) -> reason.parameter_reason_to_string(value)
  }
}

fn text_test(pair: #(Reason, String)) {
  let #(value, expected) = pair
  it("describes the reason as \"" <> expected <> "\"", fn() {
    // Arrange
    let described = value

    // Act
    let text = describe_reason(described)

    // Assert
    text
    |> should
    |> be_equal(expected)
    |> or_fail_with("Expected \"" <> expected <> "\"")
  })
}

fn cases() -> List(#(Reason, String)) {
  [
    #(column(reason.NotNullInSchema), "NOT NULL in schema"),
    #(column(reason.SystemColumn), "system column"),
    #(
      column(reason.NotNullInEveryBranch),
      "NOT NULL in every branch of the set operation",
    ),
    #(column(reason.NonNullConstant), "a constant that is not NULL"),
    #(column(reason.CountAggregate), "count(...) never returns NULL"),
    #(
      column(reason.CoalesceWithNonNullLastArgument),
      "coalesce(...) whose last argument is never NULL",
    ),
    #(column(reason.ExistsSubquery), "EXISTS (...) is never NULL"),
    #(column(reason.NullTest), "IS NULL and IS NOT NULL are never NULL"),
    #(
      column(reason.DistinctFrom),
      "IS DISTINCT FROM with a built-in operator is never NULL",
    ),
    #(column(reason.NotNullHint), "not null hint, checked on every row"),
    #(column(reason.ColumnAllowsNull), "column allows NULL"),
    #(column(reason.ColumnNotFound), "column not found in catalog"),
    #(
      column(reason.ChildTableAllowsNull),
      "a child table allows NULL in this column",
    ),
    #(
      column(reason.NotNullNotValid),
      "NOT NULL constraint is NOT VALID, old rows may be NULL",
    ),
    #(
      column(reason.OuterJoinOrGroupingSet),
      "an outer join or grouping set can empty it",
    ),
    #(column(reason.GroupingSet), "a grouping set can empty it"),
    #(column(reason.ReturningOldNew), "RETURNING OLD/NEW is NULL for some rows"),
    #(
      column(reason.MergeNotMatchedBySource),
      "MERGE ... NOT MATCHED BY SOURCE leaves source columns NULL",
    ),
    #(column(reason.ComputedValue("funcexpr")), "computed value (funcexpr)"),
    #(column(reason.WholeRow), "whole-row value"),
    #(
      column(reason.RelationKindWithoutNotNull("m")),
      "relation kind m does not enforce NOT NULL",
    ),
    #(column(reason.JoinColumnUntraceable), "join column could not be traced"),
    #(column(reason.ColumnUntraceable), "column could not be traced"),
    #(column(reason.CteNotFound), "CTE not found"),
    #(column(reason.RecursiveCte), "recursive CTE"),
    #(column(reason.RangeResult("values")), "values result"),
    #(column(reason.NullableHint), "nullable hint"),
    #(
      parameter(reason.StoredIntoNullableColumn),
      "stored straight into a nullable column",
    ),
    #(parameter(reason.ParamsHint), "params hint"),
    #(parameter(reason.Required), "required"),
    #(
      parameter(reason.AlsoUsedOutsideStore),
      "also used outside a column store",
    ),
    #(parameter(reason.StoreColumnNotFound), "column not found"),
    #(parameter(reason.ColumnIsNotNull), "column is NOT NULL"),
    #(parameter(reason.DomainNotNull), "column's domain type is NOT NULL"),
    #(
      parameter(reason.DomainCheck),
      "column's domain has a CHECK constraint that may reject NULL",
    ),
    #(
      parameter(reason.CheckConstraint),
      "a CHECK constraint on this column may reject NULL",
    ),
    #(
      parameter(reason.PartitionNotNull),
      "a partition or child table makes this column NOT NULL",
    ),
    #(
      parameter(reason.PartitionCheck),
      "a CHECK constraint on a partition may reject NULL",
    ),
    #(
      parameter(reason.BeforeTrigger),
      "a BEFORE trigger on the table can reject any value",
    ),
    #(
      parameter(reason.RowLevelSecurity),
      "a row-level security policy can reject the row",
    ),
  ]
}
