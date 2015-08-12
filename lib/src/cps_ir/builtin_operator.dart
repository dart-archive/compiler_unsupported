// Copyright (c) 2015, the Dart project authors.  Please see the AUTHORS file
// for details. All rights reserved. Use of this source code is governed by a
// BSD-style license that can be found in the LICENSE file.
library builtin_operator;
// This is shared by the CPS and Tree IRs.
// Both cps_ir_nodes and tree_ir_nodes import and re-export this file.

/// An operator supported natively in the CPS and Tree IRs using the
/// `ApplyBuiltinOperator` instructions.
///
/// These operators are pure in the sense that they cannot throw, diverge,
/// have observable side-effects, return new objects, nor depend on any
/// mutable state.
///
/// Most operators place restrictions on the values that may be given as
/// argument; their behaviour is unspecified if those requirements are violated.
///
/// In all cases, the word "null" refers to the Dart null object, corresponding
/// to both JS null and JS undefined.
///
/// Some operators, notably [IsFloor] and [IsNumberAndFloor], take "repeated"
/// arguments to reflect the number of times the given value is referenced
/// by the generated code. The tree IR needs to know the number of references
/// to safely propagate assignments.
enum BuiltinOperator {
  /// The numeric binary operators must take two numbers as argument.
  /// The bitwise operators coerce the result to an unsigned integer, but
  /// otherwise these all behave like the corresponding JS operator.
  NumAdd,
  NumSubtract,
  NumMultiply,
  NumAnd,
  NumOr,
  NumXor,
  NumLt,
  NumLe,
  NumGt,
  NumGe,

  /// Concatenates any number of strings.
  ///
  /// Takes any number of arguments, and each argument must be a string.
  ///
  /// Returns the empty string if no arguments are given.
  StringConcatenate,

  /// Returns true if the two arguments are the same value, and that value is
  /// not NaN, or if one argument is +0 and the other is -0.
  ///
  /// Compiled as a static method call.
  Identical,

  /// Like [Identical], except at most one argument may be null.
  ///
  /// Compiles to `===`.
  StrictEq,

  /// Negated version of [StrictEq]. Introduced by [LogicalRewriter] in Tree IR.
  StrictNeq,

  /// Returns true if the two arguments are both null or are the same string,
  /// boolean, or number, and that number is not NaN, or one argument is +0
  /// and the other is -0.
  ///
  /// One of the following must hold:
  /// - At least one argument is null.
  /// - Arguments are both strings, or both booleans, or both numbers.
  ///
  /// Compiles to `==`.
  LooseEq,

  /// Negated version of [LooseEq]. Introduced by [LogicalRewriter] in Tree IR.
  LooseNeq,

  /// Returns true if the argument is false, +0. -0, NaN, the empty string,
  /// or null.
  ///
  /// Compiles to `!`.
  IsFalsy,

  /// Returns true if the argument is a number.
  ///
  /// Compiles to `typeof x === 'number'`
  IsNumber,

  /// Returns true if the argument is not a number.
  ///
  /// Compiles to `typeof x !== 'number'`.
  IsNotNumber,

  /// Returns true if the argument is an integer, false if it is a double or
  /// null, and unspecified if it is anything else.
  ///
  /// The argument must be repeated 2 times.
  ///
  /// Compiles to `Math.floor(x) === x`
  IsFloor,

  /// Returns true if the argument is an integer.
  ///
  /// The argument must be repeated 3 times.
  ///
  /// Compiles to `typeof x === 'number' && Math.floor(x) === x`
  IsNumberAndFloor,
}
