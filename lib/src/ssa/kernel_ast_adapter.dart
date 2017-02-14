// Copyright (c) 2016, the Dart project authors.  Please see the AUTHORS file
// for details. All rights reserved. Use of this source code is governed by a
// BSD-style license that can be found in the LICENSE file.

import 'package:compiler_unsupported/_internal/js_runtime/shared/embedded_names.dart';
import 'package:compiler_unsupported/_internal/kernel/ast.dart' as ir;

import '../common.dart';
import '../common/names.dart';
import '../compiler.dart';
import '../constants/expressions.dart';
import '../constants/values.dart';
import '../elements/resolution_types.dart';
import '../elements/elements.dart';
import '../elements/entities.dart';
import '../elements/modelx.dart';
import '../elements/types.dart';
import '../js/js.dart' as js;
import '../js_backend/backend_helpers.dart';
import '../js_backend/js_backend.dart';
import '../kernel/kernel.dart';
import '../kernel/kernel_debug.dart';
import '../native/native.dart' as native;
import '../resolution/tree_elements.dart';
import '../tree/tree.dart' as ast;
import '../types/masks.dart';
import '../types/types.dart';
import '../universe/call_structure.dart';
import '../universe/selector.dart';
import '../universe/side_effects.dart';
import '../world.dart';
import 'graph_builder.dart';
import 'jump_handler.dart' show SwitchCaseJumpHandler;
import 'locals_handler.dart';
import 'types.dart';

/// Interface that translates between Kernel IR nodes and entities.
abstract class KernelWorldBuilder {
  /// Returns the [DartType] corresponding to [type].
  DartType getDartType(ir.DartType type);

  /// Returns the list of [DartType]s corresponding to [types].
  List<DartType> getDartTypes(List<ir.DartType> types);

  /// Returns the [InterfaceType] corresponding to [type].
  InterfaceType getInterfaceType(ir.InterfaceType type);

  /// Return the [InterfaceType] corresponding to the [cls] with the given
  /// [typeArguments].
  InterfaceType createInterfaceType(
      ir.Class cls, List<ir.DartType> typeArguments);

  /// Returns the [CallStructure] corresponding to the [arguments].
  CallStructure getCallStructure(ir.Arguments arguments);

  /// Returns the [Selector] corresponding to the invocation or getter/setter
  /// access of [node].
  Selector getSelector(ir.Expression node);

  /// Returns the [FunctionEntity] corresponding to the generative or factory
  /// constructor [node].
  FunctionEntity getConstructor(ir.Member node);

  /// Returns the [MemberEntity] corresponding to the member [node].
  MemberEntity getMember(ir.Member node);

  /// Returns the [FunctionEntity] corresponding to the procedure [node].
  FunctionEntity getMethod(ir.Procedure node);

  /// Returns the [FieldEntity] corresponding to the field [node].
  FieldEntity getField(ir.Field node);

  /// Returns the [ClassEntity] corresponding to the class [node].
  ClassEntity getClass(ir.Class node);

  /// Returns the [Local] corresponding to the [node]. The node must be either
  /// a [ir.FunctionDeclaration] or [ir.FunctionExpression].
  Local getLocalFunction(ir.Node node);

  /// Returns the [Name] corresponding to [name].
  Name getName(ir.Name name);

  /// Returns `true` is [node] has a `@Native(...)` annotation.
  bool isNativeClass(ir.Class node);

  /// Return `true` if [node] is the `dart:_foreign_helper` library.
  bool isForeignLibrary(ir.Library node);

  /// Computes the native behavior for reading the native [field].
  native.NativeBehavior getNativeBehaviorForFieldLoad(ir.Field field);

  /// Computes the native behavior for writing to the native [field].
  native.NativeBehavior getNativeBehaviorForFieldStore(ir.Field field);

  /// Computes the native behavior for calling [procedure].
  native.NativeBehavior getNativeBehaviorForMethod(ir.Procedure procedure);

  /// Computes the [native.NativeBehavior] for a call to the [JS] function.
  native.NativeBehavior getNativeBehaviorForJsCall(ir.StaticInvocation node);

  /// Computes the [native.NativeBehavior] for a call to the [JS_BUILTIN]
  /// function.
  native.NativeBehavior getNativeBehaviorForJsBuiltinCall(
      ir.StaticInvocation node);

  /// Computes the [native.NativeBehavior] for a call to the
  /// [JS_EMBEDDED_GLOBAL] function.
  native.NativeBehavior getNativeBehaviorForJsEmbeddedGlobalCall(
      ir.StaticInvocation node);

  /// Compute the kind of foreign helper function called by [node], if any.
  ForeignKind getForeignKind(ir.StaticInvocation node);

  /// Computes the [InterfaceType] referenced by a call to the
  /// [JS_INTERCEPTOR_CONSTANT] function, if any.
  InterfaceType getInterfaceTypeForJsInterceptorCall(ir.StaticInvocation node);
}

/// A helper class that abstracts all accesses of the AST from Kernel nodes.
///
/// The goal is to remove all need for the AST from the Kernel SSA builder.
class KernelAstAdapter implements KernelWorldBuilder {
  final Kernel kernel;
  final JavaScriptBackend _backend;
  final Map<ir.Node, ast.Node> _nodeToAst;
  final Map<ir.Node, Element> _nodeToElement;
  final Map<ir.VariableDeclaration, SyntheticLocal> _syntheticLocals =
      <ir.VariableDeclaration, SyntheticLocal>{};
  // TODO(efortuna): In an ideal world the TreeNodes should be some common
  // interface we create for both ir.Statements and ir.SwitchCase (the
  // ContinueSwitchStatement's target is a SwitchCase) rather than general
  // TreeNode. Talking to Asger about this.
  final Map<ir.TreeNode, KernelJumpTarget> _jumpTargets =
      <ir.TreeNode, KernelJumpTarget>{};
  DartTypeConverter _typeConverter;
  ResolvedAst _resolvedAst;

  /// Sometimes for resolution the resolved AST element needs to change (for
  /// example, if we're inlining, or if we're in a constructor, but then also
  /// constructing the field values). We keep track of this with a stack.
  final List<ResolvedAst> _resolvedAstStack = <ResolvedAst>[];

  KernelAstAdapter(this.kernel, this._backend, this._resolvedAst,
      this._nodeToAst, this._nodeToElement) {
    KernelJumpTarget.index = 0;
    // TODO(het): Maybe just use all of the kernel maps directly?
    for (FieldElement fieldElement in kernel.fields.keys) {
      _nodeToElement[kernel.fields[fieldElement]] = fieldElement;
    }
    for (FunctionElement functionElement in kernel.functions.keys) {
      _nodeToElement[kernel.functions[functionElement]] = functionElement;
    }
    for (ClassElement classElement in kernel.classes.keys) {
      _nodeToElement[kernel.classes[classElement]] = classElement;
    }
    for (LibraryElement libraryElement in kernel.libraries.keys) {
      _nodeToElement[kernel.libraries[libraryElement]] = libraryElement;
    }
    for (LocalFunctionElement localFunction in kernel.localFunctions.keys) {
      _nodeToElement[kernel.localFunctions[localFunction]] = localFunction;
    }
    for (TypeVariableElement typeVariable in kernel.typeParameters.keys) {
      _nodeToElement[kernel.typeParameters[typeVariable]] = typeVariable;
    }
    _typeConverter = new DartTypeConverter(this);
  }

  /// Push the existing resolved AST on the stack and shift the current resolved
  /// AST to the AST that this kernel node points to.
  void pushResolvedAst(ir.Node node) {
    _resolvedAstStack.add(_resolvedAst);
    _resolvedAst = (getElement(node) as AstElement).resolvedAst;
  }

  /// Pop the resolved AST stack to reset it to the previous resolved AST node.
  void popResolvedAstStack() {
    assert(_resolvedAstStack.isNotEmpty);
    _resolvedAst = _resolvedAstStack.removeLast();
  }

  Compiler get _compiler => _backend.compiler;
  TreeElements get elements => _resolvedAst.elements;
  DiagnosticReporter get reporter => _compiler.reporter;
  Element get _target => _resolvedAst.element;

  GlobalTypeInferenceResults get _globalInferenceResults =>
      _compiler.globalInference.results;

  GlobalTypeInferenceElementResult _resultOf(Element e) =>
      _globalInferenceResults
          .resultOf(e is ConstructorBodyElementX ? e.constructor : e);

  ConstantValue getConstantForSymbol(ir.SymbolLiteral node) {
    if (kernel.syntheticNodes.contains(node)) {
      return _backend.constantSystem.createSymbol(_compiler, node.value);
    }
    ast.Node astNode = getNode(node);
    ConstantValue constantValue = _backend.constants
        .getConstantValueForNode(astNode, _resolvedAst.elements);
    assert(invariant(astNode, constantValue != null,
        message: 'No constant computed for $node'));
    return constantValue;
  }

  // TODO(johnniwinther): Use the more precise functions below.
  Element getElement(ir.Node node) {
    Element result = _nodeToElement[node];
    assert(invariant(CURRENT_ELEMENT_SPANNABLE, result != null,
        message: "No element found for $node."));
    return result;
  }

  ConstructorElement getConstructor(ir.Member node) =>
      getElement(node).declaration;

  MemberElement getMember(ir.Member node) => getElement(node).declaration;

  MethodElement getMethod(ir.Procedure node) => getElement(node).declaration;

  FieldElement getField(ir.Field node) => getElement(node).declaration;

  ClassElement getClass(ir.Class node) => getElement(node).declaration;

  LocalFunctionElement getLocalFunction(ir.Node node) => getElement(node);

  ast.Node getNode(ir.Node node) {
    ast.Node result = _nodeToAst[node];
    assert(invariant(CURRENT_ELEMENT_SPANNABLE, result != null,
        message: "No node found for $node"));
    return result;
  }

  ast.Node getNodeOrNull(ir.Node node) {
    return _nodeToAst[node];
  }

  void assertNodeIsSynthetic(ir.Node node) {
    assert(invariant(
        CURRENT_ELEMENT_SPANNABLE, kernel.syntheticNodes.contains(node),
        message: "No synthetic marker found for $node"));
  }

  Local getLocal(ir.VariableDeclaration variable) {
    // If this is a synthetic local, return the synthetic local
    if (variable.name == null) {
      return _syntheticLocals.putIfAbsent(
          variable, () => new SyntheticLocal("x", null));
    }
    return getElement(variable) as LocalElement;
  }

  bool getCanThrow(ir.Node procedure, ClosedWorld closedWorld) {
    FunctionElement function = getElement(procedure);
    return !closedWorld.getCannotThrow(function);
  }

  TypeMask returnTypeOf(ir.Member node) {
    return TypeMaskFactory.inferredReturnTypeForElement(
        getElement(node), _globalInferenceResults);
  }

  SideEffects getSideEffects(ir.Node node, ClosedWorld closedWorld) {
    return closedWorld.getSideEffectsOfElement(getElement(node));
  }

  CallStructure getCallStructure(ir.Arguments arguments) {
    int argumentCount = arguments.positional.length + arguments.named.length;
    List<String> namedArguments = arguments.named.map((e) => e.name).toList();
    return new CallStructure(argumentCount, namedArguments);
  }

  FunctionSignature getFunctionSignature(ir.FunctionNode function) {
    return getElement(function).asFunctionElement().functionSignature;
  }

  Name getName(ir.Name name) {
    return new Name(
        name.name, name.isPrivate ? getElement(name.library) : null);
  }

  ir.Field getFieldFromElement(FieldElement field) {
    return kernel.fields[field];
  }

  Selector getSelector(ir.Expression node) {
    if (node is ir.PropertyGet) return getGetterSelector(node);
    if (node is ir.PropertySet) return getSetterSelector(node);
    if (node is ir.InvocationExpression) return getInvocationSelector(node);
    _compiler.reporter.internalError(getNode(node),
        "Can only get the selector for a property get or an invocation.");
    return null;
  }

  Selector getInvocationSelector(ir.InvocationExpression invocation) {
    Name name = getName(invocation.name);
    SelectorKind kind;
    if (Elements.isOperatorName(invocation.name.name)) {
      if (name == Names.INDEX_NAME || name == Names.INDEX_SET_NAME) {
        kind = SelectorKind.INDEX;
      } else {
        kind = SelectorKind.OPERATOR;
      }
    } else {
      kind = SelectorKind.CALL;
    }

    CallStructure callStructure = getCallStructure(invocation.arguments);
    return new Selector(kind, name, callStructure);
  }

  Selector getGetterSelector(ir.PropertyGet getter) {
    ir.Name irName = getter.name;
    Name name = new Name(
        irName.name, irName.isPrivate ? getElement(irName.library) : null);
    return new Selector.getter(name);
  }

  Selector getSetterSelector(ir.PropertySet setter) {
    ir.Name irName = setter.name;
    Name name = new Name(
        irName.name, irName.isPrivate ? getElement(irName.library) : null);
    return new Selector.setter(name);
  }

  TypeMask typeOfInvocation(ir.MethodInvocation send, ClosedWorld closedWorld) {
    ast.Node operatorNode = kernel.nodeToAstOperator[send];
    if (operatorNode != null) {
      return _resultOf(_target).typeOfOperator(operatorNode);
    }
    if (send.name.name == '[]=') {
      return closedWorld.commonMasks.dynamicType;
    }
    return _resultOf(_target).typeOfSend(getNode(send));
  }

  TypeMask typeOfGet(ir.PropertyGet getter) {
    return _resultOf(_target).typeOfSend(getNode(getter));
  }

  TypeMask typeOfSet(ir.PropertySet setter, ClosedWorld closedWorld) {
    return closedWorld.commonMasks.dynamicType;
  }

  TypeMask typeOfSend(ir.Expression send) {
    assert(send is ir.InvocationExpression || send is ir.PropertyGet);
    return _resultOf(_target).typeOfSend(getNode(send));
  }

  TypeMask typeOfListLiteral(
      Element owner, ir.ListLiteral listLiteral, ClosedWorld closedWorld) {
    ast.Node node = getNodeOrNull(listLiteral);
    if (node == null) {
      assertNodeIsSynthetic(listLiteral);
      return closedWorld.commonMasks.growableListType;
    }
    return _resultOf(owner).typeOfListLiteral(getNode(listLiteral)) ??
        closedWorld.commonMasks.dynamicType;
  }

  TypeMask typeOfIterator(ir.ForInStatement forInStatement) {
    return _resultOf(_target).typeOfIterator(getNode(forInStatement));
  }

  TypeMask typeOfIteratorCurrent(ir.ForInStatement forInStatement) {
    return _resultOf(_target).typeOfIteratorCurrent(getNode(forInStatement));
  }

  TypeMask typeOfIteratorMoveNext(ir.ForInStatement forInStatement) {
    return _resultOf(_target).typeOfIteratorMoveNext(getNode(forInStatement));
  }

  bool isJsIndexableIterator(
      ir.ForInStatement forInStatement, ClosedWorld closedWorld) {
    TypeMask mask = typeOfIterator(forInStatement);
    return mask != null &&
        mask.satisfies(_backend.helpers.jsIndexableClass, closedWorld) &&
        // String is indexable but not iterable.
        !mask.satisfies(_backend.helpers.jsStringClass, closedWorld);
  }

  bool isFixedLength(TypeMask mask, ClosedWorld closedWorld) {
    if (mask.isContainer && (mask as ContainerTypeMask).length != null) {
      // A container on which we have inferred the length.
      return true;
    }
    // TODO(sra): Recognize any combination of fixed length indexables.
    if (mask.containsOnly(closedWorld.backendClasses.fixedListImplementation) ||
        mask.containsOnly(closedWorld.backendClasses.constListImplementation) ||
        mask.containsOnlyString(closedWorld) ||
        closedWorld.commonMasks.isTypedArray(mask)) {
      return true;
    }
    return false;
  }

  TypeMask inferredIndexType(ir.ForInStatement forInStatement) {
    return TypeMaskFactory.inferredTypeForSelector(new Selector.index(),
        typeOfIterator(forInStatement), _globalInferenceResults);
  }

  TypeMask inferredTypeOf(ir.Member node) {
    return TypeMaskFactory.inferredTypeForElement(
        getElement(node), _globalInferenceResults);
  }

  TypeMask selectorTypeOf(Selector selector, TypeMask mask) {
    return TypeMaskFactory.inferredTypeForSelector(
        selector, mask, _globalInferenceResults);
  }

  TypeMask typeFromNativeBehavior(
      native.NativeBehavior nativeBehavior, ClosedWorld closedWorld) {
    return TypeMaskFactory.fromNativeBehavior(nativeBehavior, closedWorld);
  }

  ConstantValue getConstantFor(ir.Node node) {
    // Some `null`s are not mapped when they correspond to errors, e.g. missing
    // `const` initializers.
    if (node is ir.NullLiteral) return new NullConstantValue();

    ConstantValue constantValue =
        _backend.constants.getConstantValueForNode(getNode(node), elements);
    assert(invariant(getNode(node), constantValue != null,
        message: 'No constant computed for $node'));
    return constantValue;
  }

  ConstantValue getConstantForParameterDefaultValue(ir.Node defaultExpression) {
    // TODO(27394): Evaluate constant expressions in ir.Node domain.
    // In the interim, expand the Constantifier and do this:
    //
    //     ConstantExpression constantExpression =
    //         defaultExpression.accept(new Constantifier(this));
    //     assert(constantExpression != null);
    ConstantExpression constantExpression =
        kernel.parameterInitializerNodeToConstant[defaultExpression];
    if (constantExpression == null) return null;
    return _backend.constants.getConstantValue(constantExpression);
  }

  ConstantValue getConstantForType(ir.DartType irType) {
    ResolutionDartType type = getDartType(irType);
    return _backend.constantSystem.createType(_compiler, type.asRaw());
  }

  bool isIntercepted(ir.Node node) {
    Selector selector = getSelector(node);
    return _backend.isInterceptedSelector(selector);
  }

  bool isInterceptedSelector(Selector selector) {
    return _backend.isInterceptedSelector(selector);
  }

  // Is the member a lazy initialized static or top-level member?
  bool isLazyStatic(ir.Member member) {
    if (member is ir.Field) {
      FieldElement field = _nodeToElement[member];
      return field.constant == null;
    }
    return false;
  }

  LibraryElement get jsHelperLibrary => _backend.helpers.jsHelperLibrary;

  KernelJumpTarget getJumpTarget(ir.TreeNode node,
      {bool isContinueTarget: false}) {
    return _jumpTargets.putIfAbsent(node, () {
      if (node is ir.LabeledStatement &&
          _jumpTargets.containsKey((node as ir.LabeledStatement).body)) {
        return _jumpTargets[(node as ir.LabeledStatement).body];
      }
      return new KernelJumpTarget(node, this,
          makeContinueLabel: isContinueTarget);
    });
  }

  ir.Class get mapLiteralClass =>
      kernel.classes[_backend.helpers.mapLiteralClass];

  ir.Procedure get mapLiteralConstructor =>
      kernel.functions[_backend.helpers.mapLiteralConstructor];

  ir.Procedure get mapLiteralConstructorEmpty =>
      kernel.functions[_backend.helpers.mapLiteralConstructorEmpty];

  ir.Procedure get mapLiteralUntypedEmptyMaker =>
      kernel.functions[_backend.helpers.mapLiteralUntypedEmptyMaker];

  ir.Procedure get exceptionUnwrapper =>
      kernel.functions[_backend.helpers.exceptionUnwrapper];

  TypeMask get exceptionUnwrapperType =>
      TypeMaskFactory.inferredReturnTypeForElement(
          _backend.helpers.exceptionUnwrapper, _globalInferenceResults);

  ir.Procedure get traceFromException =>
      kernel.functions[_backend.helpers.traceFromException];

  TypeMask get traceFromExceptionType =>
      TypeMaskFactory.inferredReturnTypeForElement(
          _backend.helpers.traceFromException, _globalInferenceResults);

  ir.Procedure get streamIteratorConstructor =>
      kernel.functions[_backend.helpers.streamIteratorConstructor];

  TypeMask get streamIteratorConstructorType =>
      TypeMaskFactory.inferredReturnTypeForElement(
          _backend.helpers.streamIteratorConstructor, _globalInferenceResults);

  ir.Procedure get fallThroughError =>
      kernel.functions[_backend.helpers.fallThroughError];

  TypeMask get fallThroughErrorType =>
      TypeMaskFactory.inferredReturnTypeForElement(
          _backend.helpers.fallThroughError, _globalInferenceResults);

  ir.Procedure get mapLiteralUntypedMaker =>
      kernel.functions[_backend.helpers.mapLiteralUntypedMaker];

  MemberElement get jsIndexableLength => _backend.helpers.jsIndexableLength;

  ir.Procedure get checkConcurrentModificationError =>
      kernel.functions[_backend.helpers.checkConcurrentModificationError];

  TypeMask get checkConcurrentModificationErrorReturnType =>
      TypeMaskFactory.inferredReturnTypeForElement(
          _backend.helpers.checkConcurrentModificationError,
          _globalInferenceResults);

  ir.Procedure get checkSubtype =>
      kernel.functions[_backend.helpers.checkSubtype];

  ir.Procedure get checkSubtypeOfRuntimeType =>
      kernel.functions[_backend.helpers.checkSubtypeOfRuntimeType];

  ir.Procedure get throwTypeError =>
      kernel.functions[_backend.helpers.throwTypeError];

  TypeMask get throwTypeErrorType =>
      TypeMaskFactory.inferredReturnTypeForElement(
          _backend.helpers.throwTypeError, _globalInferenceResults);

  ir.Procedure get assertHelper =>
      kernel.functions[_backend.helpers.assertHelper];

  TypeMask get assertHelperReturnType =>
      TypeMaskFactory.inferredReturnTypeForElement(
          _backend.helpers.assertHelper, _globalInferenceResults);

  ir.Procedure get assertTest => kernel.functions[_backend.helpers.assertTest];

  TypeMask get assertTestReturnType =>
      TypeMaskFactory.inferredReturnTypeForElement(
          _backend.helpers.assertTest, _globalInferenceResults);

  ir.Procedure get assertThrow =>
      kernel.functions[_backend.helpers.assertThrow];

  ir.Procedure get setRuntimeTypeInfo =>
      kernel.functions[_backend.helpers.setRuntimeTypeInfo];

  TypeMask get assertThrowReturnType =>
      TypeMaskFactory.inferredReturnTypeForElement(
          _backend.helpers.assertThrow, _globalInferenceResults);

  ir.Procedure get runtimeTypeToString =>
      kernel.functions[_backend.helpers.runtimeTypeToString];

  ir.Procedure get createRuntimeType =>
      kernel.functions[_backend.helpers.createRuntimeType];

  TypeMask get createRuntimeTypeReturnType =>
      TypeMaskFactory.inferredReturnTypeForElement(
          _backend.helpers.createRuntimeType, _globalInferenceResults);

  ir.Class get objectClass =>
      kernel.classes[_compiler.commonElements.objectClass];

  ir.Class get futureClass =>
      kernel.classes[_compiler.commonElements.futureClass];

  TypeMask makeSubtypeOfObject(ClosedWorld closedWorld) =>
      new TypeMask.subclass(_compiler.commonElements.objectClass, closedWorld);

  ir.Procedure get currentIsolate =>
      kernel.functions[_backend.helpers.currentIsolate];

  ir.Procedure get callInIsolate =>
      kernel.functions[_backend.helpers.callInIsolate];

  bool isInForeignLibrary(ir.Member member) =>
      _backend.isForeign(getElement(member));

  native.NativeBehavior getNativeBehavior(ir.Node node) {
    return elements.getNativeData(getNode(node));
  }

  js.Name getNameForJsGetName(ir.Node argument, ConstantValue constant) {
    int index = _extractEnumIndexFromConstantValue(
        constant, _backend.helpers.jsGetNameEnum);
    if (index == null) return null;
    return _backend.namer
        .getNameForJsGetName(getNode(argument), JsGetName.values[index]);
  }

  js.Template getJsBuiltinTemplate(ConstantValue constant) {
    int index = _extractEnumIndexFromConstantValue(
        constant, _backend.helpers.jsBuiltinEnum);
    if (index == null) return null;
    return _backend.emitter.builtinTemplateFor(JsBuiltin.values[index]);
  }

  int _extractEnumIndexFromConstantValue(
      ConstantValue constant, Element classElement) {
    if (constant is ConstructedConstantValue) {
      if (constant.type.element == classElement) {
        assert(constant.fields.length == 1);
        ConstantValue indexConstant = constant.fields.values.single;
        if (indexConstant is IntConstantValue) {
          return indexConstant.primitiveValue;
        }
      }
    }
    return null;
  }

  ResolutionDartType getDartType(ir.DartType type) {
    return _typeConverter.convert(type);
  }

  ResolutionDartType getDartTypeIfValid(ir.DartType type) {
    if (type is ir.InvalidType) return null;
    return _typeConverter.convert(type);
  }

  List<ResolutionDartType> getDartTypes(List<ir.DartType> types) {
    return types.map(getDartType).toList();
  }

  ResolutionInterfaceType getDartTypeOfListLiteral(ir.ListLiteral list) {
    ast.Node node = getNodeOrNull(list);
    if (node != null) return elements.getType(node);
    assertNodeIsSynthetic(list);
    return _compiler.commonElements.listType(getDartType(list.typeArgument));
  }

  ResolutionInterfaceType getDartTypeOfMapLiteral(ir.MapLiteral literal) {
    ast.Node node = getNodeOrNull(literal);
    if (node != null) return elements.getType(node);
    assertNodeIsSynthetic(literal);
    return _compiler.commonElements
        .mapType(getDartType(literal.keyType), getDartType(literal.valueType));
  }

  ResolutionDartType getFunctionReturnType(ir.FunctionNode node) {
    if (node.returnType is ir.InvalidType) return const ResolutionDynamicType();
    return getDartType(node.returnType);
  }

  /// Computes the function type corresponding the signature of [node].
  ResolutionFunctionType getFunctionType(ir.FunctionNode node) {
    ResolutionDartType returnType = getFunctionReturnType(node);
    List<ResolutionDartType> parameterTypes = <ResolutionDartType>[];
    List<ResolutionDartType> optionalParameterTypes = <ResolutionDartType>[];
    for (ir.VariableDeclaration variable in node.positionalParameters) {
      if (parameterTypes.length == node.requiredParameterCount) {
        optionalParameterTypes.add(getDartType(variable.type));
      } else {
        parameterTypes.add(getDartType(variable.type));
      }
    }
    List<String> namedParameters = <String>[];
    List<ResolutionDartType> namedParameterTypes = <ResolutionDartType>[];
    List<ir.VariableDeclaration> sortedNamedParameters =
        node.namedParameters.toList()..sort((a, b) => a.name.compareTo(b.name));
    for (ir.VariableDeclaration variable in sortedNamedParameters) {
      namedParameters.add(variable.name);
      namedParameterTypes.add(getDartType(variable.type));
    }
    return new ResolutionFunctionType.synthesized(returnType, parameterTypes,
        optionalParameterTypes, namedParameters, namedParameterTypes);
  }

  ResolutionInterfaceType getInterfaceType(ir.InterfaceType type) =>
      getDartType(type);

  ResolutionInterfaceType createInterfaceType(
      ir.Class cls, List<ir.DartType> typeArguments) {
    return new ResolutionInterfaceType(
        getClass(cls), getDartTypes(typeArguments));
  }

  /// Converts [annotations] into a list of [ConstantExpression]s.
  List<ConstantExpression> getMetadata(List<ir.Expression> annotations) {
    List<ConstantExpression> metadata = <ConstantExpression>[];
    annotations.forEach((ir.Expression node) {
      ConstantExpression constant = node.accept(new Constantifier(this));
      if (constant == null) {
        throw new UnsupportedError(
            'No constant for ${DebugPrinter.prettyPrint(node)}');
      }
      metadata.add(constant);
    });
    return metadata;
  }

  /// Compute the kind of foreign helper function called by [node], if any.
  ForeignKind getForeignKind(ir.StaticInvocation node) {
    if (isForeignLibrary(node.target.enclosingLibrary)) {
      switch (node.target.name.name) {
        case BackendHelpers.JS:
          return ForeignKind.JS;
        case BackendHelpers.JS_BUILTIN:
          return ForeignKind.JS_BUILTIN;
        case BackendHelpers.JS_EMBEDDED_GLOBAL:
          return ForeignKind.JS_EMBEDDED_GLOBAL;
        case BackendHelpers.JS_INTERCEPTOR_CONSTANT:
          return ForeignKind.JS_INTERCEPTOR_CONSTANT;
      }
    }
    return ForeignKind.NONE;
  }

  /// Return `true` if [node] is the `dart:_foreign_helper` library.
  bool isForeignLibrary(ir.Library node) {
    return node.importUri == BackendHelpers.DART_FOREIGN_HELPER;
  }

  /// Looks up [typeName] for use in the spec-string of a `JS` called.
  // TODO(johnniwinther): Use this in [native.NativeBehavior] instead of calling
  // the `ForeignResolver`.
  // TODO(johnniwinther): Cache the result to avoid redundant lookups?
  native.TypeLookup _typeLookup({bool resolveAsRaw: true}) {
    return (String typeName) {
      ResolutionDartType findIn(Uri uri) {
        LibraryElement library = _compiler.libraryLoader.lookupLibrary(uri);
        if (library != null) {
          Element element = library.find(typeName);
          if (element != null && element.isClass) {
            ClassElement cls = element;
            // TODO(johnniwinther): Align semantics.
            return resolveAsRaw ? cls.rawType : cls.thisType;
          }
        }
        return null;
      }

      ResolutionDartType type = findIn(Uris.dart_core);
      type ??= findIn(BackendHelpers.DART_JS_HELPER);
      type ??= findIn(BackendHelpers.DART_INTERCEPTORS);
      type ??= findIn(BackendHelpers.DART_ISOLATE_HELPER);
      type ??= findIn(Uris.dart_collection);
      type ??= findIn(Uris.dart_html);
      type ??= findIn(Uris.dart_svg);
      type ??= findIn(Uris.dart_web_audio);
      type ??= findIn(Uris.dart_web_gl);
      return type;
    };
  }

  String _getStringArgument(ir.StaticInvocation node, int index) {
    return node.arguments.positional[index].accept(new Stringifier());
  }

  /// Computes the [native.NativeBehavior] for a call to the [JS] function.
  // TODO(johnniwinther): Cache this for later use.
  native.NativeBehavior getNativeBehaviorForJsCall(ir.StaticInvocation node) {
    if (node.arguments.positional.length < 2 ||
        node.arguments.named.isNotEmpty) {
      reporter.reportErrorMessage(
          CURRENT_ELEMENT_SPANNABLE, MessageKind.WRONG_ARGUMENT_FOR_JS);
      return new native.NativeBehavior();
    }
    String specString = _getStringArgument(node, 0);
    if (specString == null) {
      reporter.reportErrorMessage(
          CURRENT_ELEMENT_SPANNABLE, MessageKind.WRONG_ARGUMENT_FOR_JS_FIRST);
      return new native.NativeBehavior();
    }

    String codeString = _getStringArgument(node, 1);
    if (codeString == null) {
      reporter.reportErrorMessage(
          CURRENT_ELEMENT_SPANNABLE, MessageKind.WRONG_ARGUMENT_FOR_JS_SECOND);
      return new native.NativeBehavior();
    }

    return native.NativeBehavior.ofJsCall(
        specString,
        codeString,
        _typeLookup(resolveAsRaw: true),
        CURRENT_ELEMENT_SPANNABLE,
        reporter,
        _compiler.commonElements);
  }

  /// Computes the [native.NativeBehavior] for a call to the [JS_BUILTIN]
  /// function.
  // TODO(johnniwinther): Cache this for later use.
  native.NativeBehavior getNativeBehaviorForJsBuiltinCall(
      ir.StaticInvocation node) {
    if (node.arguments.positional.length < 1) {
      reporter.internalError(
          CURRENT_ELEMENT_SPANNABLE, "JS builtin expression has no type.");
      return new native.NativeBehavior();
    }
    if (node.arguments.positional.length < 2) {
      reporter.internalError(
          CURRENT_ELEMENT_SPANNABLE, "JS builtin is missing name.");
      return new native.NativeBehavior();
    }
    String specString = _getStringArgument(node, 0);
    if (specString == null) {
      reporter.internalError(
          CURRENT_ELEMENT_SPANNABLE, "Unexpected first argument.");
      return new native.NativeBehavior();
    }
    return native.NativeBehavior.ofJsBuiltinCall(
        specString,
        _typeLookup(resolveAsRaw: true),
        CURRENT_ELEMENT_SPANNABLE,
        reporter,
        _compiler.commonElements);
  }

  /// Computes the [native.NativeBehavior] for a call to the
  /// [JS_EMBEDDED_GLOBAL] function.
  // TODO(johnniwinther): Cache this for later use.
  native.NativeBehavior getNativeBehaviorForJsEmbeddedGlobalCall(
      ir.StaticInvocation node) {
    if (node.arguments.positional.length < 1) {
      reporter.internalError(CURRENT_ELEMENT_SPANNABLE,
          "JS embedded global expression has no type.");
      return new native.NativeBehavior();
    }
    if (node.arguments.positional.length < 2) {
      reporter.internalError(
          CURRENT_ELEMENT_SPANNABLE, "JS embedded global is missing name.");
      return new native.NativeBehavior();
    }
    if (node.arguments.positional.length > 2 ||
        node.arguments.named.isNotEmpty) {
      reporter.internalError(CURRENT_ELEMENT_SPANNABLE,
          "JS embedded global has more than 2 arguments.");
      return new native.NativeBehavior();
    }
    String specString = _getStringArgument(node, 0);
    if (specString == null) {
      reporter.internalError(
          CURRENT_ELEMENT_SPANNABLE, "Unexpected first argument.");
      return new native.NativeBehavior();
    }
    return native.NativeBehavior.ofJsEmbeddedGlobalCall(
        specString,
        _typeLookup(resolveAsRaw: true),
        CURRENT_ELEMENT_SPANNABLE,
        reporter,
        _compiler.commonElements);
  }

  /// Computes the [InterfaceType] referenced by a call to the
  /// [JS_INTERCEPTOR_CONSTANT] function, if any.
  InterfaceType getInterfaceTypeForJsInterceptorCall(ir.StaticInvocation node) {
    if (node.arguments.positional.length != 1 ||
        node.arguments.named.isNotEmpty) {
      reporter.reportErrorMessage(CURRENT_ELEMENT_SPANNABLE,
          MessageKind.WRONG_ARGUMENT_FOR_JS_INTERCEPTOR_CONSTANT);
    }
    ir.Node argument = node.arguments.positional.first;
    if (argument is ir.TypeLiteral && argument.type is ir.InterfaceType) {
      return getInterfaceType(argument.type);
    }
    return null;
  }

  /// Returns `true` is [node] has a `@Native(...)` annotation.
  // TODO(johnniwinther): Cache this for later use.
  bool isNativeClass(ir.Class node) {
    for (ir.Expression annotation in node.annotations) {
      if (annotation is ir.ConstructorInvocation) {
        ConstructorElement target = getElement(annotation.target).declaration;
        if (target.enclosingClass ==
            _compiler.commonElements.nativeAnnotationClass) {
          return true;
        }
      }
    }
    return false;
  }

  /// Computes the native behavior for reading the native [field].
  // TODO(johnniwinther): Cache this for later use.
  native.NativeBehavior getNativeBehaviorForFieldLoad(ir.Field field) {
    ResolutionDartType type = getDartType(field.type);
    List<ConstantExpression> metadata = getMetadata(field.annotations);
    return native.NativeBehavior.ofFieldLoad(CURRENT_ELEMENT_SPANNABLE, type,
        metadata, _typeLookup(resolveAsRaw: false), _compiler,
        isJsInterop: false);
  }

  /// Computes the native behavior for writing to the native [field].
  // TODO(johnniwinther): Cache this for later use.
  native.NativeBehavior getNativeBehaviorForFieldStore(ir.Field field) {
    ResolutionDartType type = getDartType(field.type);
    return native.NativeBehavior.ofFieldStore(type, _compiler.resolution);
  }

  /// Computes the native behavior for calling [procedure].
  // TODO(johnniwinther): Cache this for later use.
  native.NativeBehavior getNativeBehaviorForMethod(ir.Procedure procedure) {
    ResolutionDartType type = getFunctionType(procedure.function);
    List<ConstantExpression> metadata = getMetadata(procedure.annotations);
    return native.NativeBehavior.ofMethod(CURRENT_ELEMENT_SPANNABLE, type,
        metadata, _typeLookup(resolveAsRaw: false), _compiler,
        isJsInterop: false);
  }

  MemberEntity getConstructorBodyEntity(ir.Constructor constructor) {
    AstElement element = getElement(constructor);
    MemberEntity constructorBody =
        ConstructorBodyElementX.createFromResolvedAst(element.resolvedAst);
    assert(constructorBody != null);
    return constructorBody;
  }
}

/// Kinds of foreign functions.
enum ForeignKind {
  JS,
  JS_BUILTIN,
  JS_EMBEDDED_GLOBAL,
  JS_INTERCEPTOR_CONSTANT,
  NONE,
}

/// Visitor that converts kernel dart types into [ResolutionDartType].
class DartTypeConverter extends ir.DartTypeVisitor<ResolutionDartType> {
  final KernelAstAdapter astAdapter;
  bool topLevel = true;

  DartTypeConverter(this.astAdapter);

  ResolutionDartType convert(ir.DartType type) {
    topLevel = true;
    return type.accept(this);
  }

  /// Visit a inner type.
  ResolutionDartType visitType(ir.DartType type) {
    topLevel = false;
    return type.accept(this);
  }

  List<ResolutionDartType> visitTypes(List<ir.DartType> types) {
    topLevel = false;
    return new List.generate(
        types.length, (int index) => types[index].accept(this));
  }

  @override
  ResolutionDartType visitTypeParameterType(ir.TypeParameterType node) {
    if (node.parameter.parent is ir.Class) {
      ir.Class cls = node.parameter.parent;
      int index = cls.typeParameters.indexOf(node.parameter);
      ClassElement classElement = astAdapter.getElement(cls);
      return classElement.typeVariables[index];
    } else if (node.parameter.parent is ir.FunctionNode) {
      ir.FunctionNode func = node.parameter.parent;
      int index = func.typeParameters.indexOf(node.parameter);
      Element element = astAdapter.getElement(func);
      if (element.isConstructor) {
        ClassElement classElement = element.enclosingClass;
        return classElement.typeVariables[index];
      } else {
        GenericElement genericElement = element;
        return genericElement.typeVariables[index];
      }
    }
    throw new UnsupportedError('Unsupported type parameter type node $node.');
  }

  @override
  ResolutionDartType visitFunctionType(ir.FunctionType node) {
    return new ResolutionFunctionType.synthesized(
        visitType(node.returnType),
        visitTypes(node.positionalParameters
            .take(node.requiredParameterCount)
            .toList()),
        visitTypes(node.positionalParameters
            .skip(node.requiredParameterCount)
            .toList()),
        node.namedParameters.map((n) => n.name).toList(),
        node.namedParameters.map((n) => visitType(n.type)).toList());
  }

  @override
  ResolutionDartType visitInterfaceType(ir.InterfaceType node) {
    ClassElement cls = astAdapter.getElement(node.classNode);
    return new ResolutionInterfaceType(cls, visitTypes(node.typeArguments));
  }

  @override
  ResolutionDartType visitVoidType(ir.VoidType node) {
    return const ResolutionVoidType();
  }

  @override
  ResolutionDartType visitDynamicType(ir.DynamicType node) {
    return const ResolutionDynamicType();
  }

  @override
  ResolutionDartType visitInvalidType(ir.InvalidType node) {
    if (topLevel) {
      throw new UnimplementedError(
          "Outermost invalid types not currently supported");
    }
    // Nested invalid types are treated as `dynamic`.
    return const ResolutionDynamicType();
  }
}

/// Visitor that converts string literals and concatenations of string literals
/// into the string value.
class Stringifier extends ir.ExpressionVisitor<String> {
  @override
  String visitStringLiteral(ir.StringLiteral node) => node.value;

  @override
  String visitStringConcatenation(ir.StringConcatenation node) {
    StringBuffer sb = new StringBuffer();
    for (ir.Expression expression in node.expressions) {
      String value = expression.accept(this);
      if (value == null) return null;
      sb.write(value);
    }
    return sb.toString();
  }
}

/// Visitor that converts a kernel constant expression into a
/// [ConstantExpression].
class Constantifier extends ir.ExpressionVisitor<ConstantExpression> {
  final KernelAstAdapter astAdapter;

  Constantifier(this.astAdapter);

  @override
  ConstantExpression visitConstructorInvocation(ir.ConstructorInvocation node) {
    ConstructorElement constructor =
        astAdapter.getElement(node.target).declaration;
    List<ResolutionDartType> typeArguments = <ResolutionDartType>[];
    for (ir.DartType type in node.arguments.types) {
      typeArguments.add(astAdapter.getDartType(type));
    }
    List<ConstantExpression> arguments = <ConstantExpression>[];
    List<String> argumentNames = <String>[];
    for (ir.Expression argument in node.arguments.positional) {
      ConstantExpression constant = argument.accept(this);
      if (constant == null) return null;
      arguments.add(constant);
    }
    for (ir.NamedExpression argument in node.arguments.named) {
      argumentNames.add(argument.name);
      ConstantExpression constant = argument.value.accept(this);
      if (constant == null) return null;
      arguments.add(constant);
    }
    return new ConstructedConstantExpression(
        constructor.enclosingClass.thisType.createInstantiation(typeArguments),
        constructor,
        new CallStructure(
            node.arguments.positional.length + argumentNames.length,
            argumentNames),
        arguments);
  }

  @override
  ConstantExpression visitStaticGet(ir.StaticGet node) {
    Element element = astAdapter.getMember(node.target);
    if (element.isField) {
      return new VariableConstantExpression(element);
    }
    astAdapter.reporter.internalError(
        CURRENT_ELEMENT_SPANNABLE, "Unexpected constant target: $element.");
    return null;
  }

  @override
  ConstantExpression visitStringLiteral(ir.StringLiteral node) {
    return new StringConstantExpression(node.value);
  }
}

class KernelJumpTarget extends JumpTarget {
  static int index = 0;

  /// Pointer to the actual executable statements that a jump target refers to.
  /// If this jump target was not initially constructed with a LabeledStatement,
  /// this value is identical to originalStatement.
  // TODO(efortuna): In an ideal world the Node should be some common
  // interface we create for both ir.Statements and ir.SwitchCase (the
  // ContinueSwitchStatement's target is a SwitchCase) rather than general
  // Node. Talking to Asger about this.
  ir.Node targetStatement;

  /// The original statement used to construct this jump target.
  /// If this jump target was not initially constructed with a LabeledStatement,
  /// this value is identical to targetStatement.
  ir.Node originalStatement;

  @override
  bool isBreakTarget = false;

  @override
  bool isContinueTarget = false;

  KernelJumpTarget(this.targetStatement, KernelAstAdapter adapter,
      {bool makeContinueLabel = false}) {
    originalStatement = targetStatement;
    this.labels = <LabelDefinition>[];
    if (targetStatement is ir.WhileStatement ||
        targetStatement is ir.DoStatement ||
        targetStatement is ir.ForStatement ||
        targetStatement is ir.ForInStatement) {
      // Currently these labels are set at resolution on the element itself.
      // Once that gets updated, this logic can change downstream.
      JumpTarget target = adapter.elements
          .getTargetDefinition(adapter.getNode(targetStatement));
      if (target != null) {
        labels.addAll(target.labels);
        isBreakTarget = target.isBreakTarget;
        isContinueTarget = target.isContinueTarget;
      }
    } else if (targetStatement is ir.LabeledStatement) {
      targetStatement = (targetStatement as ir.LabeledStatement).body;
      labels.add(
          new LabelDefinitionX(null, 'L${index++}', this)..setBreakTarget());
      isBreakTarget = true;
    }

    if (makeContinueLabel) {
      labels.add(
          new LabelDefinitionX(null, 'L${index++}', this)..setContinueTarget());
      isContinueTarget = true;
    }
  }

  @override
  LabelDefinition addLabel(ast.Label label, String labelName) {
    LabelDefinition result = new LabelDefinitionX(label, labelName, this);
    labels.add(result);
    return result;
  }

  @override
  ExecutableElement get executableContext => null;

  @override
  bool get isSwitch => targetStatement is ir.SwitchStatement;

  @override
  bool get isTarget => isBreakTarget || isContinueTarget;

  @override
  List<LabelDefinition> labels;

  @override
  String get name => 'target';

  // TODO(efortuna): In the original version, this nesting level is specified at
  // jump target construction time, by the resolver. Because these are
  // instantiated later, we don't have that information. When we move fully over
  // to the kernel model, we can pass the nesting level in KernelJumpTarget's
  // constructor.
  @override
  int get nestingLevel => 0;

  @override
  ast.Node get statement => null;

  String toString() => 'Target:$targetStatement';
}

/// Special [JumpHandler] implementation used to handle continue statements
/// targeting switch cases.
class KernelSwitchCaseJumpHandler extends SwitchCaseJumpHandler {
  KernelSwitchCaseJumpHandler(GraphBuilder builder, JumpTarget target,
      ir.SwitchStatement switchStatement, KernelAstAdapter astAdapter)
      : super(builder, target) {
    // The switch case indices must match those computed in
    // [KernelSsaBuilder.buildSwitchCaseConstants].
    // Switch indices are 1-based so we can bypass the synthetic loop when no
    // cases match simply by branching on the index (which defaults to null).
    // TODO
    int switchIndex = 1;
    for (ir.SwitchCase switchCase in switchStatement.cases) {
      JumpTarget continueTarget =
          astAdapter.getJumpTarget(switchCase, isContinueTarget: true);
      assert(continueTarget is KernelJumpTarget);
      targetIndexMap[continueTarget] = switchIndex;
      assert(builder.jumpTargets[continueTarget] == null);
      builder.jumpTargets[continueTarget] = this;
      switchIndex++;
    }
  }
}
