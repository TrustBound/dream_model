//// A random number generator with a seed, so that a fuzz run can be
//// replayed: the same seed gives the same schemas, data and queries.
////
//// It is SplitMix64. Each function returns the value and the generator to
//// use next.

import gleam/int.{
  bitwise_and, bitwise_exclusive_or, bitwise_shift_right, compare, max, multiply,
  to_float,
}
import gleam/list.{drop, fold, index_map, length, map, repeat, sort, take}

const mask = 0xFFFFFFFFFFFFFFFF

/// The state of the generator.
pub opaque type Random {
  Random(state: Int)
}

/// Starts a generator from a seed.
pub fn new(seed: Int) -> Random {
  Random(bitwise_and(seed, mask))
}

/// Returns 64 random bits.
pub fn next(random: Random) -> #(Int, Random) {
  let state = bitwise_and(random.state + 0x9E3779B97F4A7C15, mask)
  let mixed =
    mix(state, 30, 0xBF58476D1CE4E5B9)
    |> mix(27, 0x94D049BB133111EB)
  let value = bitwise_exclusive_or(mixed, bitwise_shift_right(mixed, 31))
  #(value, Random(state))
}

fn mix(value: Int, shift: Int, multiplier: Int) -> Int {
  bitwise_exclusive_or(value, bitwise_shift_right(value, shift))
  |> multiply(multiplier)
  |> bitwise_and(mask)
}

/// Returns an integer from `low` to `high`, both included.
pub fn between(random: Random, low: Int, high: Int) -> #(Int, Random) {
  let #(bits, random) = next(random)
  let size = max(high - low + 1, 1)
  #(low + bits % size, random)
}

/// Returns True with the probability `probability` (from 0.0 to 1.0).
pub fn chance(random: Random, probability: Float) -> #(Bool, Random) {
  let #(value, random) = fraction(random)
  #(value <. probability, random)
}

/// Returns a float from 0.0 (included) to 1.0 (not included).
pub fn fraction(random: Random) -> #(Float, Random) {
  let #(bits, random) = next(random)
  let top = bitwise_shift_right(bits, 11)
  #(to_float(top) /. 9_007_199_254_740_992.0, random)
}

/// Returns one item of a list, or `fallback` when the list is empty.
pub fn choose(random: Random, items: List(a), fallback: a) -> #(a, Random) {
  let #(index, random) = between(random, 0, length(items) - 1)
  let chosen = case drop(items, index) {
    [item, ..] -> item
    [] -> fallback
  }
  #(chosen, random)
}

/// Returns one item of a list of weighted items: an item with weight 2 is
/// chosen twice as often as one with weight 1. An item with weight 0 is
/// never chosen. Returns `fallback` when every weight is 0.
pub fn weighted(
  random: Random,
  items: List(#(Float, a)),
  fallback: a,
) -> #(a, Random) {
  let total = fold(items, 0.0, fn(sum, item) { sum +. item.0 })
  let #(value, random) = fraction(random)
  #(pick_weighted(items, value *. total, fallback), random)
}

fn pick_weighted(items: List(#(Float, a)), left: Float, fallback: a) -> a {
  case items {
    [] -> fallback
    [#(weight, item), ..] if weight >. 0.0 && left <. weight -> item
    [#(weight, _), ..rest] -> pick_weighted(rest, left -. weight, fallback)
  }
}

/// Returns `count` different items of a list, in a random order, or every
/// item when the list is shorter.
pub fn sample(
  random: Random,
  items: List(a),
  count: Int,
) -> #(List(a), Random) {
  let #(shuffled, random) = shuffle(random, items)
  #(take(shuffled, count), random)
}

/// Returns the items of a list in a random order.
pub fn shuffle(random: Random, items: List(a)) -> #(List(a), Random) {
  let #(keyed, random) =
    fold(items, #([], random), fn(state, item) {
      let #(keyed, random) = state
      let #(key, random) = next(random)
      #([#(key, item), ..keyed], random)
    })
  let shuffled =
    sort(keyed, fn(left, right) { compare(left.0, right.0) })
    |> map(fn(pair) { pair.1 })
  #(shuffled, random)
}

/// Returns the integers from `low` to `high`, both included, or an empty
/// list when `high` is lower than `low`.
pub fn numbers(low: Int, high: Int) -> List(Int) {
  repeat(Nil, max(high - low + 1, 0))
  |> index_map(fn(_, index) { low + index })
}
