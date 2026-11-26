//// Tests for `dream_model/postgres/node`, the reader for PostgreSQL's node
//// text format.

import dream_model/postgres/node.{
  type Node, type ParseError, Bitmapset, Empty, IntegerList, Integers, NodeList,
  NotAnInteger, Oids, Record, Token, TransactionIds, UnexpectedEnd,
  UnexpectedToken, get_field, get_item, integer, integers, items, node_name,
  parse, remove_locations,
}
import dream_test/matchers.{be_equal, or_fail_with, should}
import dream_test/suite.{type TestSuite}
import dream_test/unit.{describe, group, it}
import gleam/dict.{from_list}
import gleam/result.{unwrap}

pub fn tests() -> TestSuite {
  describe("dream_model/postgres/node", [
    parse_tests(),
    name_tests(),
    parse_error_tests(),
    accessor_tests(),
  ])
}

fn record(name: String, fields: List(#(String, Node))) -> Node {
  Record(name:, fields: from_list(fields))
}

fn parse_case(name: String, text: String, expected: Node) {
  it(name, fn() {
    // Arrange
    let input = text

    // Act
    let parsed = parse(input)

    // Assert
    parsed
    |> should
    |> be_equal(Ok(expected))
    |> or_fail_with("Expected " <> text <> " to parse")
  })
}

fn parse_tests() {
  group("parse", [
    parse_case(
      "reads a node with its fields",
      "{VAR :varno 1 :varattno 2}",
      record("VAR", [#("varno", Token("1")), #("varattno", Token("2"))]),
    ),
    parse_case("reads <> as Empty", "<>", Empty),
    parse_case(
      "reads a list of nodes",
      "({A :x <>} {B :y 1})",
      NodeList([record("A", [#("x", Empty)]), record("B", [#("y", Token("1"))])]),
    ),
    parse_case("reads a Bitmapset", "(b 1 2)", IntegerList(Bitmapset, [1, 2])),
    parse_case("reads an empty Bitmapset", "(b)", IntegerList(Bitmapset, [])),
    parse_case("reads a list of integers", "(i 3)", IntegerList(Integers, [3])),
    parse_case("reads a list of oids", "(o 23 25)", IntegerList(Oids, [23, 25])),
    parse_case(
      "reads a list of transaction ids",
      "(x 7)",
      IntegerList(TransactionIds, [7]),
    ),
    parse_case(
      "reads a field of more than one token as a list",
      "{CONST :constvalue 4 [ 1 0 0 0 ] :location 7}",
      record("CONST", [
        #(
          "constvalue",
          NodeList([
            Token("4"),
            Token("["),
            Token("1"),
            Token("0"),
            Token("0"),
            Token("0"),
            Token("]"),
          ]),
        ),
        #("location", Token("7")),
      ]),
    ),
    parse_case(
      "reads a field without a value before the end of the node as Empty",
      "{A :b}",
      record("A", [#("b", Empty)]),
    ),
    parse_case(
      "reads line breaks as spaces",
      "{A\n:b\n1}",
      record("A", [#("b", Token("1"))]),
    ),
    parse_case(
      "reads a string without its quotes",
      "(\"a\" \"\")",
      NodeList([Token("a"), Token("")]),
    ),
    parse_case("reads a lone quote as a token", "\"", Token("\"")),
  ])
}

fn name_tests() {
  group("parse with names that need escapes", [
    parse_case(
      "takes the first token after a field name as its value, even :resno",
      "{TARGETENTRY :resname :resno :resno 1}",
      record("TARGETENTRY", [
        #("resname", Token(":resno")),
        #("resno", Token("1")),
      ]),
    ),
    parse_case(
      "reads an escaped <> as the text <>",
      "{A :resname \\<>}",
      record("A", [#("resname", Token("<>"))]),
    ),
    parse_case(
      "reads escaped braces and parentheses",
      "{A :resname \\{\\)\\(\\}}",
      record("A", [#("resname", Token("{)(}"))]),
    ),
    parse_case(
      "reads an escaped backslash",
      "{A :resname a\\\\b}",
      record("A", [#("resname", Token("a\\b"))]),
    ),
    parse_case(
      "reads an escaped newline",
      "{A :resname x\\\ny}",
      record("A", [#("resname", Token("x\ny"))]),
    ),
    parse_case(
      "reads an escaped space in a string",
      "(\"Weird\\ Name\")",
      NodeList([Token("Weird Name")]),
    ),
    parse_case(
      "reads a quote inside a string",
      "(\"with\"quote\")",
      NodeList([Token("with\"quote")]),
    ),
    parse_case("keeps a backslash at the end of the text", "a\\", Token("a\\")),
  ])
}

fn error_case(name: String, text: String, expected: ParseError) {
  it(name, fn() {
    // Arrange
    let input = text

    // Act
    let parsed = parse(input)

    // Assert
    parsed
    |> should
    |> be_equal(Error(expected))
    |> or_fail_with("Expected " <> text <> " to be refused")
  })
}

fn parse_error_tests() {
  group("parse errors", [
    error_case("refuses empty text", "", UnexpectedEnd),
    error_case("refuses a node without its end", "{A :b 1", UnexpectedEnd),
    error_case("refuses a node without its name", "{", UnexpectedToken("{")),
    error_case("refuses a list without its end", "(1 2", UnexpectedEnd),
    error_case("refuses a closing parenthesis", ")", UnexpectedToken(")")),
    error_case("refuses a closing brace", "}", UnexpectedToken("}")),
    error_case(
      "refuses a list where a field name must be",
      "{A (",
      UnexpectedToken("("),
    ),
    error_case(
      "refuses a token where a field name must be",
      "{A 1}",
      UnexpectedToken("1"),
    ),
    error_case("refuses text after the value", "1 2", UnexpectedToken("2")),
    error_case(
      "refuses a word in a list of numbers",
      "(b 1 x)",
      NotAnInteger("x"),
    ),
    error_case(
      "refuses a node in a list of numbers",
      "(b 1 {",
      NotAnInteger("{"),
    ),
    error_case(
      "refuses a list of numbers without its end",
      "(b 1",
      UnexpectedEnd,
    ),
  ])
}

fn accessor_case(name: String, read: fn() -> a, expected: a) {
  it(name, fn() {
    // Arrange
    let accessor = read

    // Act
    let read = accessor()

    // Assert
    read
    |> should
    |> be_equal(expected)
    |> or_fail_with("Expected the accessor to give the value")
  })
}

fn sample() -> Node {
  parse(
    "{QUERY :a 1 :list ({X :location 3 :inner {Y :location 4 :v 1}}) :set (b 2)}",
  )
  |> unwrap(Empty)
}

fn accessor_tests() {
  group("accessors", [
    accessor_case(
      "get_field returns a field",
      fn() { get_field(sample(), "a") },
      Token("1"),
    ),
    accessor_case(
      "get_field returns Empty for a missing field",
      fn() { get_field(sample(), "missing") },
      Empty,
    ),
    accessor_case(
      "get_field returns Empty for a value that is not a node",
      fn() { get_field(Token("1"), "a") },
      Empty,
    ),
    accessor_case(
      "get_item returns Empty after the last item",
      fn() { get_item(get_field(sample(), "list"), 1) },
      Empty,
    ),
    accessor_case("items of Empty is the empty list", fn() { items(Empty) }, []),
    accessor_case(
      "items of a list of numbers are tokens",
      fn() { items(IntegerList(Bitmapset, [2])) },
      [Token("2")],
    ),
    accessor_case("items of a token is that token", fn() { items(Token("x")) }, [
      Token("x"),
    ]),
    accessor_case("items of a node is that node", fn() { items(sample()) }, [
      sample(),
    ]),
    accessor_case(
      "integers of a list of numbers",
      fn() { integers(get_field(sample(), "set")) },
      [2],
    ),
    accessor_case(
      "integers of another value is empty",
      fn() { integers(Token("1")) },
      [],
    ),
    accessor_case("node_name of a node", fn() { node_name(sample()) }, "QUERY"),
    accessor_case(
      "node_name of a token is empty",
      fn() { node_name(Token("x")) },
      "",
    ),
    accessor_case("text of a node is empty", fn() { node.text(sample()) }, ""),
    accessor_case("integer of a number", fn() { integer(Token("12")) }, Ok(12)),
    accessor_case("integer of a word", fn() { integer(Token("x")) }, Error(Nil)),
    accessor_case(
      "remove_locations removes every location field",
      fn() { remove_locations(get_field(sample(), "list")) },
      NodeList([
        record("X", [#("inner", record("Y", [#("v", Token("1"))]))]),
      ]),
    ),
  ])
}
