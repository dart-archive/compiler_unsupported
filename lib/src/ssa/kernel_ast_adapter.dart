// Copyright (c) 2016, the Dart project authors.  Please see the AUTHORS file
// for details. All rights reserved. Use of this source code is governed by a
// BSD-style license that can be found in the LICENSE file.

import 'package:compiler_unsupported/_internal/js_runtime/shared/embedded_names.dart';
import 'package:compiler_unsupported/_internal/kernel/ast.dart' as ir;

import '../closure.dart';
import '../common.dart';
import '../compiler.dart';
import '../constants/expressions.dart';
import '../constants/values.dart';
import '../common_elements.dart';
import '../elements/resolution_types.dart';
import '../elements/elements.dart';
import '../elements/entities.dart';
import '../elements/modelx.dart';
import '../elements/types.dart';
import '../js/js.dart' as js;
import '../js_backend/js_backend.dart';
import '../kernel/element_adapter.dart';
import '../kernel/kernel.dart';
import '../kernel/kernel_debug.dart';
import '../native/native.dart' as native;
import '../resolution/tree_elements.dart';
import '../tree/tree.dart' as ast;
import '../types/masks.dart';
import '../types/types.dart';
import '../universe/selector.dart';
import '../universe/side_effects.dart';
import '../world.dart';
import 'graph_builder.dart';
import 'jump_handler.dart' show SwitchCaseJumpHandler;
import 'locals_handler.dart';
import 'types.dart';

/// A helper class that abstracts all accesses of the AST from Kernel nodes.
///
/// The goal is to remove all need for the AST from the Kernel SSA builder.
class KernelAstAdapter extends KernelElementAdapterMixin {
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

  final native.BehaviorBuilder nativeBehaviorBuilder;

  KernelAstAdapter(this.kernel, this._backend, this._resolvedAst,
      this._nodeToAst, this._nodeToElement)
      : nativeBehaviorBuilder =
            new native.ResolverBehaviorBuilder(_backend.compiler) {
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

  /// Called to find the corresponding Kernel element for a particular Element
  /// before traversing over it with a Kernel visitor.
  ir.Node getInitialKernelNode(Element originTarget) {
    ir.Node target;
    if (originTarget.isPatch) {
      originTarget = originTarget.origin;
    }
    if (originTarget is FunctionElement) {
      if (originTarget is ConstructorBodyElement) {
        ConstructorBodyElement body = originTarget;
        originTarget = body.constructor;
      }
      target = kernel.functions[originTarget];
      // Closures require a lookup one level deeper in the closure class mapper.
      if (target == null) {
        FunctionElement originTargetFunction = originTarget;
        ClosureClassMap classMap = _compiler.closureToClassMapper
            .getClosureToClassMapping(originTargetFunction.resolvedAst);
        if (classMap.closureElement != null) {
          target = kernel.localFunctions[classMap.closureElement];
        }
      }
    } else if (originTarget is FieldElement) {
      target = kernel.fields[originTarget];
    }
    assert(target != null);
    return target;
  }

  @override
  CommonElements get commonElements => _compiler.commonElements;

  @override
  ElementEnvironment get elementEnvironment => _compiler.elementEnvironment;

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
      return _backend.constantSystem.createSymbol(
          _compiler.commonElements, _backend.backendClasses, node.value);
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

  LibraryElement getLibrary(ir.Library node) => getElement(node).declaration;

  LocalFunctionElement getLocalFunction(ir.TreeNode node) => getElement(node);

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

  TypeMask returnTypeOf(ir.Procedure node) {
    return TypeMaskFactory.inferredReturnTypeForElement(
        getMethod(node), _globalInferenceResults);
  }

  SideEffects getSideEffects(ir.Node node, ClosedWorld closedWorld) {
    return closedWorld.getSideEffectsOfElement(getElement(node));
  }

  FunctionSignature getFunctionSignature(ir.FunctionNode function) {
    return getElement(function).asFunctionElement().functionSignature;
  }

  ir.Field getFieldFromElement(FieldElement field) {
    return kernel.fields[field];
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
    if (mask.containsOnly(closedWorld.backendClasses.fixedListClass) ||
        mask.containsOnly(closedWorld.backendClasses.constListClass) ||
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
    return _backend.constantSystem.createType(
        _compiler.commonElements, _backend.backendClasses, type.asRaw());
  }

  bool isIntercepted(ir.Node node) {
    Selector selector = getSelector(node);
    return _backend.interceptorData.isInterceptedSelector(selector);
  }

  bool isInterceptedSelector(Selector selector) {
    return _backend.interceptorData.isInterceptedSelector(selector);
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

  ir.Procedure get checkDeferredIsLoaded =>
      kernel.functions[_backend.helpers.checkDeferredIsLoaded];

  TypeMask get checkDeferredIsLoadedType =>
      TypeMaskFactory.inferredReturnTypeForElement(
          _backend.helpers.checkDeferredIsLoaded, _globalInferenceResults);

  ir.Procedure get createInvocationMirror =>
      kernel.functions[_backend.helpers.createInvocationMirror];

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
          _backend.helpers.streamIteratorConstructor as FunctionEntity,
          _globalInferenceResults);

  ir.Procedure get fallThroughError =>
      kernel.functions[_backend.helpers.fallThroughError];

  TypeMask get fallThroughErrorType =>
      TypeMaskFactory.inferredReturnTypeForElement(
          _backend.helpers.fallThroughError, _globalInferenceResults);

  ir.Procedure get mapLiteralUntypedMaker =>
      kernel.functions[_backend.helpers.mapLiteralUntypedMaker];

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

  ir.Procedure get functionTypeTest =>
      kernel.functions[_backend.helpers.functionTypeTest];

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
      ConstantValue constant, ClassEntity classElement) {
    if (constant is ConstructedConstantValue) {
      if (constant.type.element == classElement) {
        assert(constant.fields.length == 1 || constant.fields.length == 2);
        ConstantValue indexConstant = constant.fields.values.first;
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

  @override
  InterfaceType getThisType(ir.Class cls) {
    return getClass(cls).thisType;
  }

  MemberEntity getConstructorBodyEntity(ir.Constructor constructor) {
    AstElement element = getElement(constructor);
    MemberEntity constructorBody =
        ConstructorBodyElementX.createFromResolvedAst(element.resolvedAst);
    assert(constructorBody != null);
    return constructorBody;
  }
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
    ClassElement cls = astAdapter.getClass(node.classNode);
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

class KernelJumpTarget extends JumpTarget {
  static int index = 0;

  /// Pointer to the actual executable statements that a jump target refers to.
  /// If this jump target was not initially constructed with a LabeledStatement,
  /// this value is identical to originalStatement. This Node is actually of
  /// type either ir.Statement or ir.SwitchCase.
  ir.Node targetStatement;

  /// The original statement used to construct this jump target.
  /// If this jump target was not initially constructed with a LabeledStatement,
  /// this value is identical to targetStatement. This Node is actually of
  /// type either ir.Statement or ir.SwitchCase.
  ir.Node originalStatement;

  /// Used to provide unique numbers to labels that would otherwise be duplicate
  /// if one JumpTarget is inside another.
  int nestingLevel;

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
    var originalNode = adapter.getNode(originalStatement);
    var originalTarget = adapter.elements.getTargetDefinition(originalNode);
    if (originalTarget != null) {
      nestingLevel = originalTarget.nestingLevel;
    } else {
      nestingLevel = 0;
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
  MemberElement get memberContext => null;

  @override
  bool get isSwitch => targetStatement is ir.SwitchStatement;

  @override
  bool get isTarget => isBreakTarget || isContinueTarget;

  @override
  List<LabelDefinition> labels;

  @override
  String get name => 'target';

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
