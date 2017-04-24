// Copyright (c) 2012, the Dart project authors.  Please see the AUTHORS file
// for details. All rights reserved. Use of this source code is governed by a
// BSD-style license that can be found in the LICENSE file.

library dart2js.js_emitter.code_emitter_task;

import 'package:compiler_unsupported/_internal/js_runtime/shared/embedded_names.dart' show JsBuiltin;

import '../common.dart';
import '../common/tasks.dart' show CompilerTask;
import '../compiler.dart' show Compiler;
import '../constants/values.dart';
import '../deferred_load.dart' show OutputUnit;
import '../elements/entities.dart';
import '../js/js.dart' as jsAst;
import '../js_backend/js_backend.dart' show JavaScriptBackend, Namer;
import '../world.dart' show ClosedWorld;
import 'full_emitter/emitter.dart' as full_js_emitter;
import 'lazy_emitter/emitter.dart' as lazy_js_emitter;
import 'program_builder/program_builder.dart';
import 'startup_emitter/emitter.dart' as startup_js_emitter;

import 'metadata_collector.dart' show MetadataCollector;
import 'native_emitter.dart' show NativeEmitter;
import 'type_test_registry.dart' show TypeTestRegistry;

const USE_LAZY_EMITTER = const bool.fromEnvironment("dart2js.use.lazy.emitter");

/**
 * Generates the code for all used classes in the program. Static fields (even
 * in classes) are ignored, since they can be treated as non-class elements.
 *
 * The code for the containing (used) methods must exist in the `universe`.
 */
class CodeEmitterTask extends CompilerTask {
  TypeTestRegistry typeTestRegistry;
  NativeEmitter nativeEmitter;
  MetadataCollector metadataCollector;
  EmitterFactory _emitterFactory;
  Emitter _emitter;
  final Compiler compiler;

  JavaScriptBackend get backend => compiler.backend;

  @deprecated
  // This field should be removed. It's currently only needed for dump-info and
  // tests.
  // The field is set after the program has been emitted.
  /// Contains a list of all classes that are emitted.
  Set<ClassEntity> neededClasses;

  CodeEmitterTask(
      Compiler compiler, bool generateSourceMap, bool useStartupEmitter)
      : compiler = compiler,
        super(compiler.measurer) {
    nativeEmitter = new NativeEmitter(this);
    if (USE_LAZY_EMITTER) {
      _emitterFactory = new lazy_js_emitter.EmitterFactory();
    } else if (useStartupEmitter) {
      _emitterFactory = new startup_js_emitter.EmitterFactory(
          generateSourceMap: generateSourceMap);
    } else {
      _emitterFactory = new full_js_emitter.EmitterFactory(
          generateSourceMap: generateSourceMap);
    }
  }

  Emitter get emitter {
    assert(invariant(NO_LOCATION_SPANNABLE, _emitter != null,
        message: "Emitter has not been created yet."));
    return _emitter;
  }

  String get name => 'Code emitter';

  /// Returns the string that is used to find library patches that are
  /// specialized for the emitter.
  String get patchVersion => _emitterFactory.patchVersion;

  /// Returns true, if the emitter supports reflection.
  bool get supportsReflection => _emitterFactory.supportsReflection;

  /// Returns the closure expression of a static function.
  jsAst.Expression isolateStaticClosureAccess(FunctionEntity element) {
    return emitter.isolateStaticClosureAccess(element);
  }

  /// Returns the JS function that must be invoked to get the value of the
  /// lazily initialized static.
  jsAst.Expression isolateLazyInitializerAccess(FieldEntity element) {
    return emitter.isolateLazyInitializerAccess(element);
  }

  /// Returns the JS code for accessing the embedded [global].
  jsAst.Expression generateEmbeddedGlobalAccess(String global) {
    return emitter.generateEmbeddedGlobalAccess(global);
  }

  /// Returns the JS code for accessing the given [constant].
  jsAst.Expression constantReference(ConstantValue constant) {
    return emitter.constantReference(constant);
  }

  jsAst.Expression staticFieldAccess(FieldEntity e) {
    return emitter.staticFieldAccess(e);
  }

  /// Returns the JS function representing the given function.
  ///
  /// The function must be invoked and can not be used as closure.
  jsAst.Expression staticFunctionAccess(FunctionEntity e) {
    return emitter.staticFunctionAccess(e);
  }

  /// Returns the JS constructor of the given element.
  ///
  /// The returned expression must only be used in a JS `new` expression.
  jsAst.Expression constructorAccess(ClassEntity e) {
    return emitter.constructorAccess(e);
  }

  /// Returns the JS prototype of the given class [e].
  jsAst.Expression prototypeAccess(ClassEntity e,
      {bool hasBeenInstantiated: false}) {
    return emitter.prototypeAccess(e, hasBeenInstantiated);
  }

  /// Returns the JS prototype of the given interceptor class [e].
  jsAst.Expression interceptorPrototypeAccess(ClassEntity e) {
    return jsAst.js('#.prototype', interceptorClassAccess(e));
  }

  /// Returns the JS constructor of the given interceptor class [e].
  jsAst.Expression interceptorClassAccess(ClassEntity e) {
    return emitter.interceptorClassAccess(e);
  }

  /// Returns the JS expression representing the type [e].
  ///
  /// The given type [e] might be a Typedef.
  jsAst.Expression typeAccess(Entity e) {
    return emitter.typeAccess(e);
  }

  /// Returns the JS template for the given [builtin].
  jsAst.Template builtinTemplateFor(JsBuiltin builtin) {
    return emitter.templateForBuiltin(builtin);
  }

  Set<ClassEntity> _finalizeRti() {
    // Compute the required type checks to know which classes need a
    // 'is$' method.
    typeTestRegistry.computeRequiredTypeChecks();
    // Compute the classes needed by RTI.
    return typeTestRegistry.computeRtiNeededClasses();
  }

  /// Creates the [Emitter] for this task.
  void createEmitter(Namer namer, ClosedWorld closedWorld) {
    measure(() {
      _emitter = _emitterFactory.createEmitter(this, namer, closedWorld);
      metadataCollector = new MetadataCollector(compiler, _emitter);
      typeTestRegistry = new TypeTestRegistry(compiler, closedWorld);
    });
  }

  int assembleProgram(Namer namer, ClosedWorld closedWorld) {
    return measure(() {
      Set<ClassEntity> rtiNeededClasses = _finalizeRti();
      ProgramBuilder programBuilder = new ProgramBuilder(
          compiler, namer, this, emitter, closedWorld, rtiNeededClasses);
      int size = emitter.emitProgram(programBuilder);
      // TODO(floitsch): we shouldn't need the `neededClasses` anymore.
      neededClasses = programBuilder.collector.neededClasses;
      return size;
    });
  }
}

abstract class EmitterFactory {
  /// Returns the string that is used to find library patches that are
  /// specialized for this emitter.
  String get patchVersion;

  /// Returns true, if the emitter supports reflection.
  bool get supportsReflection;

  /// Create the [Emitter] for the emitter [task] that uses the given [namer].
  Emitter createEmitter(
      CodeEmitterTask task, Namer namer, ClosedWorld closedWorld);
}

abstract class Emitter {
  /// Uses the [programBuilder] to generate a model of the program, emits
  /// the program, and returns the size of the generated output.
  int emitProgram(ProgramBuilder programBuilder);

  /// Returns the JS function that must be invoked to get the value of the
  /// lazily initialized static.
  jsAst.Expression isolateLazyInitializerAccess(FieldEntity element);

  /// Returns the closure expression of a static function.
  jsAst.Expression isolateStaticClosureAccess(FunctionEntity element);

  /// Returns the JS code for accessing the embedded [global].
  jsAst.Expression generateEmbeddedGlobalAccess(String global);

  /// Returns the JS function representing the given function.
  ///
  /// The function must be invoked and can not be used as closure.
  jsAst.Expression staticFunctionAccess(FunctionEntity element);

  jsAst.Expression staticFieldAccess(FieldEntity element);

  /// Returns the JS constructor of the given element.
  ///
  /// The returned expression must only be used in a JS `new` expression.
  jsAst.Expression constructorAccess(ClassEntity e);

  /// Returns the JS prototype of the given class [e].
  jsAst.Expression prototypeAccess(ClassEntity e, bool hasBeenInstantiated);

  /// Returns the JS constructor of the given interceptor class [e].
  jsAst.Expression interceptorClassAccess(ClassEntity e);

  /// Returns the JS expression representing the type [e].
  jsAst.Expression typeAccess(Entity e);

  /// Returns the JS expression representing a function that returns 'null'
  jsAst.Expression generateFunctionThatReturnsNull();

  int compareConstants(ConstantValue a, ConstantValue b);
  bool isConstantInlinedOrAlreadyEmitted(ConstantValue constant);

  /// Returns the JS code for accessing the given [constant].
  jsAst.Expression constantReference(ConstantValue constant);

  /// Returns the JS template for the given [builtin].
  jsAst.Template templateForBuiltin(JsBuiltin builtin);

  /// Returns the size of the code generated for a given output [unit].
  int generatedSize(OutputUnit unit);
}
