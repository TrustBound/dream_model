//// Tests for `dream_model/nullability/reason`: the text of every reason.

import dream_model/nullability/reason.{
  AlsoUsedOutsideStore, BeforeTrigger, CastToDomainWithCheck,
  CastToNotNullDomain, CheckConstraint, ChildTableAllowsNull,
  CoalesceWithNonNullLastArgument, ColumnAllowsNull, ColumnIsNotNull,
  ColumnNotFound, ColumnUntraceable, ComputedValue, CountAggregate, CteNotFound,
  DistinctFrom, DomainCheck, DomainNotNull, ExistsSubquery,
  GeneratedColumnUsesIt, GroupingSet, JoinColumnUntraceable,
  MergeNotMatchedBySource, NonNullConstant, NotNullHint, NotNullInEveryBranch,
  NotNullInSchema, NotNullNotValid, NullTest, NullableHint,
  OuterJoinOrGroupingSet, ParamsHint, PartitionCheck, PartitionKey,
  PartitionNotNull, RangeResult, RecursiveCte, RelationKindWithoutNotNull,
  RelationNotTable, Required, ReturningOldNew, RowLevelSecurity, RuleAddsQueries,
  StoreColumnNotFound, StoredIntoNullableColumn, SystemColumn, ViewCheckOption,
  WholeRow, column_reason_to_string, parameter_reason_to_string,
}
import dream_test/matchers.{be_equal, or_fail_with, should}
import dream_test/suite.{type TestSuite}
import dream_test/unit.{describe, it}
import gleam/list.{map}

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
  describe("dream_model/nullability/reason", map(cases(), text_test))
}

fn describe_reason(value: Reason) -> String {
  case value {
    ColumnReason(value) -> column_reason_to_string(value)
    ParameterReason(value) -> parameter_reason_to_string(value)
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
    #(column(NotNullInSchema), "NOT NULL in schema"),
    #(column(SystemColumn), "system column"),
    #(
      column(NotNullInEveryBranch),
      "NOT NULL in every branch of the set operation",
    ),
    #(column(NonNullConstant), "a constant that is not NULL"),
    #(column(CountAggregate), "count(...) never returns NULL"),
    #(
      column(CoalesceWithNonNullLastArgument),
      "coalesce(...) whose last argument is never NULL",
    ),
    #(column(ExistsSubquery), "EXISTS (...) is never NULL"),
    #(column(NullTest), "IS NULL and IS NOT NULL are never NULL"),
    #(
      column(DistinctFrom),
      "IS DISTINCT FROM with a built-in operator is never NULL",
    ),
    #(column(NotNullHint), "not null hint, checked on every row"),
    #(column(ColumnAllowsNull), "column allows NULL"),
    #(column(ColumnNotFound), "column not found in catalog"),
    #(column(ChildTableAllowsNull), "a child table allows NULL in this column"),
    #(
      column(NotNullNotValid),
      "NOT NULL constraint is NOT VALID, old rows may be NULL",
    ),
    #(
      column(OuterJoinOrGroupingSet),
      "an outer join or grouping set can empty it",
    ),
    #(column(GroupingSet), "a grouping set can empty it"),
    #(column(ReturningOldNew), "RETURNING OLD/NEW is NULL for some rows"),
    #(
      column(MergeNotMatchedBySource),
      "MERGE ... NOT MATCHED BY SOURCE leaves source columns NULL",
    ),
    #(column(ComputedValue("funcexpr")), "computed value (funcexpr)"),
    #(column(WholeRow), "whole-row value"),
    #(
      column(RelationKindWithoutNotNull("m")),
      "relation kind m does not enforce NOT NULL",
    ),
    #(column(JoinColumnUntraceable), "join column could not be traced"),
    #(column(ColumnUntraceable), "column could not be traced"),
    #(column(CteNotFound), "CTE not found"),
    #(column(RecursiveCte), "recursive CTE"),
    #(column(RangeResult("values")), "values result"),
    #(column(NullableHint), "nullable hint"),
    #(
      parameter(StoredIntoNullableColumn),
      "stored straight into a nullable column",
    ),
    #(parameter(ParamsHint), "params hint"),
    #(parameter(Required), "required"),
    #(parameter(AlsoUsedOutsideStore), "also used outside a column store"),
    #(parameter(StoreColumnNotFound), "column not found"),
    #(parameter(ColumnIsNotNull), "column is NOT NULL"),
    #(parameter(DomainNotNull), "column's domain type is NOT NULL"),
    #(
      parameter(DomainCheck),
      "column's domain has a CHECK constraint that may reject NULL",
    ),
    #(
      parameter(CheckConstraint),
      "a CHECK constraint on this column may reject NULL",
    ),
    #(
      parameter(PartitionNotNull),
      "a partition or child table makes this column NOT NULL",
    ),
    #(
      parameter(PartitionCheck),
      "a CHECK constraint on a partition may reject NULL",
    ),
    #(
      parameter(BeforeTrigger),
      "a BEFORE trigger on the table can reject any value",
    ),
    #(
      parameter(RowLevelSecurity),
      "a row-level security policy can reject the row",
    ),
    #(
      parameter(RuleAddsQueries(2)),
      "a rule rewrites the statement into 2 queries, so every parameter is required",
    ),
    #(
      parameter(CastToNotNullDomain),
      "the parameter is cast to a NOT NULL domain type",
    ),
    #(
      parameter(CastToDomainWithCheck),
      "the parameter is cast to a domain type with a CHECK constraint that may reject NULL",
    ),
    #(
      parameter(GeneratedColumnUsesIt),
      "a generated column is computed from this column and may reject NULL",
    ),
    #(
      parameter(PartitionKey),
      "the column is in a partition key, and a NULL may find no partition",
    ),
    #(
      parameter(ViewCheckOption),
      "a view's WITH CHECK OPTION may reject the row",
    ),
    #(
      parameter(RelationNotTable("f")),
      "the statement writes into relation kind f (a view with an INSTEAD OF trigger or a foreign table), which may reject NULL",
    ),
  ]
}
