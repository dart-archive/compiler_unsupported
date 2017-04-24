// Copyright (c) 2013, the Dart project authors.  Please see the AUTHORS file
// for details. All rights reserved. Use of this source code is governed by a
// BSD-style license that can be found in the LICENSE file.

import '../common.dart';
import '../common_elements.dart';
import '../constants/expressions.dart';
import '../constants/values.dart';
import '../elements/resolution_types.dart';
import '../elements/elements.dart';
import '../js/js.dart' as jsAst;
import '../js_emitter/js_emitter.dart'
    show CodeEmitterTask, MetadataCollector, Placeholder;
import '../universe/call_structure.dart' show CallStructure;
import '../universe/use.dart' show ConstantUse;
import '../universe/world_impact.dart';
import 'backend.dart';
import 'backend_usage.dart' show BackendUsageBuilder;
import 'backend_helpers.dart';
import 'backend_impact.dart';
import 'mirrors_data.dart';

/// Resolution analysis that prepares for the construction of TypeVariable
/// constants needed at runtime.
class TypeVariableResolutionAnalysis {
  final ElementEnvironment _elementEnvironment;
  final BackendImpacts _impacts;
  final BackendUsageBuilder _backendUsageBuilder;

  /**
   * Set to 'true' on first encounter of a class with type variables.
   */
  bool _seenClassesWithTypeVariables = false;

  /// Impact builder used for the resolution world computation.
  final StagedWorldImpactBuilder impactBuilder = new StagedWorldImpactBuilder();

  TypeVariableResolutionAnalysis(
      this._elementEnvironment, this._impacts, this._backendUsageBuilder);

  /// Compute the [WorldImpact] for the type variables registered since last
  /// flush.
  WorldImpact flush() {
    return impactBuilder.flush();
  }

  void registerClassWithTypeVariables(ClassElement cls) {
    // On first encounter, we have to ensure that the support classes get
    // resolved.
    if (!_seenClassesWithTypeVariables) {
      _impacts.typeVariableMirror
          .registerImpact(impactBuilder, _elementEnvironment);
      _backendUsageBuilder.processBackendImpact(_impacts.typeVariableMirror);
      _seenClassesWithTypeVariables = true;
    }
  }
}

/// Codegen handler that creates TypeVariable constants needed at runtime.
class TypeVariableCodegenAnalysis {
  final JavaScriptBackend _backend;
  final BackendHelpers _helpers;
  final MirrorsData _mirrorsData;

  /**
   *  Maps a class element to a list with indices that point to type variables
   *  constants for each of the class' type variables.
   */
  Map<ClassElement, List<jsAst.Expression>> _typeVariables =
      new Map<ClassElement, List<jsAst.Expression>>();

  /**
   *  Maps a TypeVariableType to the index pointing to the constant representing
   *  the corresponding type variable at runtime.
   */
  Map<TypeVariableElement, jsAst.Expression> _typeVariableConstants =
      new Map<TypeVariableElement, jsAst.Expression>();

  /// Impact builder used for the codegen world computation.
  final StagedWorldImpactBuilder _impactBuilder =
      new StagedWorldImpactBuilder();

  TypeVariableCodegenAnalysis(this._backend, this._helpers, this._mirrorsData);

  CodeEmitterTask get _task => _backend.emitter;
  MetadataCollector get _metadataCollector => _task.metadataCollector;

  /// Compute the [WorldImpact] for the type variables registered since last
  /// flush.
  WorldImpact flush() {
    return _impactBuilder.flush();
  }

  void registerClassWithTypeVariables(ClassElement cls) {
    if (_mirrorsData.isAccessibleByReflection(cls)) {
      processTypeVariablesOf(cls);
    }
  }

  void processTypeVariablesOf(ClassElement cls) {
    // Do not process classes twice.
    if (_typeVariables.containsKey(cls)) return;

    List<jsAst.Expression> constants = <jsAst.Expression>[];

    for (ResolutionTypeVariableType currentTypeVariable in cls.typeVariables) {
      TypeVariableElement typeVariableElement = currentTypeVariable.element;

      jsAst.Expression boundIndex =
          _metadataCollector.reifyType(typeVariableElement.bound);
      ConstantValue boundValue = new SyntheticConstantValue(
          SyntheticConstantKind.TYPEVARIABLE_REFERENCE, boundIndex);
      ClassElement typeVariableClass = _helpers.typeVariableClass;
      ConstantExpression constant = new ConstructedConstantExpression(
          typeVariableClass.thisType,
          _helpers.typeVariableConstructor,
          const CallStructure.unnamed(3), [
        new TypeConstantExpression(cls.rawType, cls.name),
        new StringConstantExpression(currentTypeVariable.name),
        new SyntheticConstantExpression(boundValue)
      ]);

      _backend.constants.evaluate(constant);
      ConstantValue value = _backend.constants.getConstantValue(constant);
      _impactBuilder
          .registerConstantUse(new ConstantUse.typeVariableMirror(value));
      constants
          .add(_reifyTypeVariableConstant(value, currentTypeVariable.element));
    }
    _typeVariables[cls] = constants;
  }

  /**
   * Adds [c] to [emitter.metadataCollector] and returns the index pointing to
   * the entry.
   *
   * If the corresponding type variable has already been encountered an
   * entry in the list has already been reserved and the constant is added
   * there, otherwise a new entry for [c] is created.
   */
  jsAst.Expression _reifyTypeVariableConstant(
      ConstantValue c, TypeVariableElement variable) {
    jsAst.Expression name = _task.constantReference(c);
    jsAst.Expression result = _metadataCollector.reifyExpression(name);
    if (_typeVariableConstants.containsKey(variable)) {
      Placeholder placeholder = _typeVariableConstants[variable];
      placeholder.bind(result);
    }
    _typeVariableConstants[variable] = result;
    return result;
  }

  /**
   * Returns the index pointing to the constant in [emitter.metadataCollector]
   * representing this type variable.
   *
   * If the constant has not yet been constructed, an entry is  allocated in
   * the global metadata list and the index pointing to this entry is returned.
   * When the corresponding constant is constructed later,
   * [reifyTypeVariableConstant] will be called and the constant will be added
   * on the allocated entry.
   */
  jsAst.Expression reifyTypeVariable(TypeVariableElement variable) {
    if (_typeVariableConstants.containsKey(variable)) {
      return _typeVariableConstants[variable];
    }

    Placeholder placeholder =
        _metadataCollector.getMetadataPlaceholder(variable);
    return _typeVariableConstants[variable] = placeholder;
  }

  List<jsAst.Expression> typeVariablesOf(ClassElement classElement) {
    List<jsAst.Expression> result = _typeVariables[classElement];
    if (result == null) {
      result = const <jsAst.Expression>[];
    }
    return result;
  }
}
