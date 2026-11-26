//// Why a result column or a parameter can or cannot be NULL.
////
//// The reasons are data, so the code generator and the tests can match on
//// them. `column_reason_to_string` and `parameter_reason_to_string` give
//// the text for messages.

import gleam/int.{to_string}

/// Where the value of a result column comes from.
pub type Origin {
  /// A stored table column, maybe through views, subqueries, CTEs, joins
  /// and set operations.
  Table
  /// Anything else: a constant, a function, an aggregate, an expression.
  Computed
}

/// Why a result column is never NULL, or can be NULL.
pub type ColumnReason {
  // --- never NULL ---
  /// The table column is NOT NULL, in the table and in every child table
  /// and partition that a scan reads.
  NotNullInSchema
  /// A system column, such as `ctid`.
  SystemColumn
  /// Every branch of the set operation is never NULL.
  NotNullInEveryBranch
  /// A literal constant that is not NULL.
  NonNullConstant
  /// `count(*)` or `count(x)`: an aggregate that returns 0, not NULL, for
  /// no rows.
  CountAggregate
  /// `coalesce(...)` whose last argument is never NULL.
  CoalesceWithNonNullLastArgument
  /// `EXISTS (...)` is true or false.
  ExistsSubquery
  /// `x IS NULL` and `x IS NOT NULL` are true or false.
  NullTest
  /// `a IS DISTINCT FROM b` with a built-in equality operator is true or
  /// false.
  DistinctFrom
  /// A `-- not null:` hint names the column. The generated code checks it
  /// on every row.
  NotNullHint
  // --- can be NULL ---
  /// The table column allows NULL.
  ColumnAllowsNull
  /// The catalog has no such column.
  ColumnNotFound
  /// A child table or partition that the scan reads allows NULL in the
  /// column.
  ChildTableAllowsNull
  /// The NOT NULL constraint is NOT VALID, so old rows can hold NULL.
  NotNullNotValid
  /// The column comes from the nullable side of an outer join, or a
  /// grouping set can make it NULL (PostgreSQL marks both the same way).
  OuterJoinOrGroupingSet
  /// The query has grouping sets, which make the grouping columns NULL in
  /// the rows of the higher grouping levels.
  GroupingSet
  /// `RETURNING old.x` or `new.x`, where the old or new row does not exist
  /// for some rows.
  ReturningOldNew
  /// A source column of a MERGE with `WHEN NOT MATCHED BY SOURCE`, where no
  /// source row exists.
  MergeNotMatchedBySource
  /// A value that the rules do not prove: a function, an operator, a
  /// subquery and so on. The text is the node name, for example
  /// `funcexpr`.
  ComputedValue(node: String)
  /// A whole-row value, `select u from users u`.
  WholeRow
  /// The relation is not a table, so it does not enforce NOT NULL: for
  /// example `m`, a materialized view.
  RelationKindWithoutNotNull(kind: String)
  /// A join column that the join does not hold.
  JoinColumnUntraceable
  /// A column of a subquery that the subquery does not hold.
  ColumnUntraceable
  /// The CTE of a column cannot be found.
  CteNotFound
  /// A column of a recursive CTE.
  RecursiveCte
  /// A column of a range that the rules do not look into: `function`,
  /// `tablefunc`, `values`, `tuplestore`, `result` or `unknown`.
  RangeResult(kind: String)
  /// A `-- nullable:` hint names the column.
  NullableHint
}

/// Why a parameter is required or can be NULL.
pub type ParameterReason {
  /// The parameter is stored straight into a column that accepts NULL.
  StoredIntoNullableColumn
  /// A `-- params:` hint marks the parameter with `?`.
  ParamsHint
  /// The parameter is not stored straight into a column.
  Required
  /// The parameter is stored into a column, and is also used elsewhere.
  AlsoUsedOutsideStore
  /// The catalog has no such column.
  StoreColumnNotFound
  /// The column is NOT NULL.
  ColumnIsNotNull
  /// The column's domain type, or one of its base domains, is NOT NULL.
  DomainNotNull
  /// The column's domain type, or one of its base domains, has a CHECK.
  DomainCheck
  /// A CHECK constraint names the column.
  CheckConstraint
  /// A partition or child table makes the column NOT NULL.
  PartitionNotNull
  /// A CHECK constraint of a partition or child table names the column.
  PartitionCheck
  /// A BEFORE trigger can reject any value.
  BeforeTrigger
  /// A row-level security policy can reject the row.
  RowLevelSecurity
  /// A rule rewrites the statement into more than one query. The other
  /// queries can use the parameter anywhere, so every parameter is
  /// required.
  RuleAddsQueries(queries: Int)
  /// The value goes into a domain type that is NOT NULL: a cast of the
  /// parameter to the domain, or the parameter's own type.
  CastToNotNullDomain
  /// The value goes into a domain type that has a CHECK.
  CastToDomainWithCheck
  /// A generated column is computed from the column, and its NOT NULL or
  /// its CHECK can reject the row.
  GeneratedColumnUsesIt
  /// The column is part of a partition key: a NULL can find no partition.
  PartitionKey
  /// The statement writes through a view WITH CHECK OPTION, which can
  /// reject the row.
  ViewCheckOption
  /// The statement writes into a relation that is not a table, or one of
  /// its partitions or child tables is not a table: a view with an INSTEAD
  /// OF trigger (`v`) or a foreign table (`f`). dream_model cannot read
  /// what the trigger or the remote server accepts.
  RelationNotTable(kind: String)
}

/// Returns the text of a column reason.
pub fn column_reason_to_string(reason: ColumnReason) -> String {
  case reason {
    NotNullInSchema -> "NOT NULL in schema"
    SystemColumn -> "system column"
    NotNullInEveryBranch -> "NOT NULL in every branch of the set operation"
    NonNullConstant -> "a constant that is not NULL"
    CountAggregate -> "count(...) never returns NULL"
    CoalesceWithNonNullLastArgument ->
      "coalesce(...) whose last argument is never NULL"
    ExistsSubquery -> "EXISTS (...) is never NULL"
    NullTest -> "IS NULL and IS NOT NULL are never NULL"
    DistinctFrom -> "IS DISTINCT FROM with a built-in operator is never NULL"
    NotNullHint -> "not null hint, checked on every row"
    ColumnAllowsNull -> "column allows NULL"
    ColumnNotFound -> "column not found in catalog"
    ChildTableAllowsNull -> "a child table allows NULL in this column"
    NotNullNotValid -> "NOT NULL constraint is NOT VALID, old rows may be NULL"
    OuterJoinOrGroupingSet -> "an outer join or grouping set can empty it"
    GroupingSet -> "a grouping set can empty it"
    ReturningOldNew -> "RETURNING OLD/NEW is NULL for some rows"
    MergeNotMatchedBySource ->
      "MERGE ... NOT MATCHED BY SOURCE leaves source columns NULL"
    ComputedValue(node) -> "computed value (" <> node <> ")"
    WholeRow -> "whole-row value"
    RelationKindWithoutNotNull(kind) ->
      "relation kind " <> kind <> " does not enforce NOT NULL"
    JoinColumnUntraceable -> "join column could not be traced"
    ColumnUntraceable -> "column could not be traced"
    CteNotFound -> "CTE not found"
    RecursiveCte -> "recursive CTE"
    RangeResult(kind) -> kind <> " result"
    NullableHint -> "nullable hint"
  }
}

/// Returns the text of a parameter reason.
pub fn parameter_reason_to_string(reason: ParameterReason) -> String {
  case reason {
    StoredIntoNullableColumn -> "stored straight into a nullable column"
    ParamsHint -> "params hint"
    Required -> "required"
    AlsoUsedOutsideStore -> "also used outside a column store"
    StoreColumnNotFound -> "column not found"
    ColumnIsNotNull -> "column is NOT NULL"
    DomainNotNull -> "column's domain type is NOT NULL"
    DomainCheck -> "column's domain has a CHECK constraint that may reject NULL"
    CheckConstraint -> "a CHECK constraint on this column may reject NULL"
    PartitionNotNull -> "a partition or child table makes this column NOT NULL"
    PartitionCheck -> "a CHECK constraint on a partition may reject NULL"
    BeforeTrigger -> "a BEFORE trigger on the table can reject any value"
    RowLevelSecurity -> "a row-level security policy can reject the row"
    RuleAddsQueries(queries) ->
      "a rule rewrites the statement into "
      <> to_string(queries)
      <> " queries, so every parameter is required"
    CastToNotNullDomain -> "the parameter is cast to a NOT NULL domain type"
    CastToDomainWithCheck ->
      "the parameter is cast to a domain type with a CHECK constraint that may reject NULL"
    GeneratedColumnUsesIt ->
      "a generated column is computed from this column and may reject NULL"
    PartitionKey ->
      "the column is in a partition key, and a NULL may find no partition"
    ViewCheckOption -> "a view's WITH CHECK OPTION may reject the row"
    RelationNotTable(kind) ->
      "the statement writes into relation kind "
      <> kind
      <> " (a view with an INSTEAD OF trigger or a foreign table), which may reject NULL"
  }
}
