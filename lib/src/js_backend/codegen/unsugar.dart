library dart2js.unsugar_cps;

import '../../cps_ir/cps_ir_nodes.dart';

import '../../cps_ir/optimizers.dart' show Pass;
import '../../constants/values.dart';
import '../../elements/elements.dart';
import '../../js_backend/codegen/glue.dart';
import '../../universe/selector.dart' show Selector;
import '../../cps_ir/cps_fragment.dart';
import '../../common/names.dart';

class ExplicitReceiverParameterEntity implements Local {
  String get name => 'receiver';
  final ExecutableElement executableContext;
  ExplicitReceiverParameterEntity(this.executableContext);
  toString() => 'ExplicitReceiverParameterEntity($executableContext)';
}

/// Suggested name for an interceptor.
class InterceptorEntity extends Entity {
  Entity interceptedVariable;

  InterceptorEntity(this.interceptedVariable);

  String get name => interceptedVariable.name + '_';
}

/// Rewrites the initial CPS IR to make Dart semantics explicit and inserts
/// special nodes that respect JavaScript behavior.
///
/// Performs the following rewrites:
///  - Add interceptors at call sites that use interceptor calling convention.
///  - Add explicit receiver argument for methods that are called in interceptor
///    calling convention.
///  - Convert two-parameter exception handlers to one-parameter ones.
class UnsugarVisitor extends TrampolineRecursiveVisitor implements Pass {
  Glue _glue;

  FunctionDefinition function;

  Parameter get receiverParameter => function.receiverParameter;

  /// The interceptor of the receiver.  For some methods, this is the receiver
  /// itself, for others, it is the interceptor parameter.
  Parameter receiverInterceptor;

  // In a catch block, rethrow implicitly throws the block's exception
  // parameter.  This is the exception parameter when nested in a catch
  // block and null otherwise.
  Parameter _exceptionParameter = null;

  UnsugarVisitor(this._glue);

  String get passName => 'Unsugaring';

  void rewrite(FunctionDefinition function) {
    this.function = function;
    bool inInterceptedMethod = _glue.isInterceptedMethod(function.element);

    if (function.element.name == '==' &&
        function.parameters.length == 1 &&
        !_glue.operatorEqHandlesNullArgument(function.element)) {
      // Insert the null check that the language semantics requires us to
      // perform before calling operator ==.
      insertEqNullCheck(function);
    }

    if (inInterceptedMethod) {
      function.interceptorParameter = new Parameter(null)..parent = function;
      // Since the receiver won't be compiled to "this", set a hint on it
      // so the parameter gets a meaningful name.
      function.receiverParameter.hint =
          new ExplicitReceiverParameterEntity(function.element);
      // If we need an interceptor for the receiver, use the receiver itself
      // if possible, otherwise the interceptor argument.
      receiverInterceptor = _glue.methodUsesReceiverArgument(function.element)
          ? function.interceptorParameter
          : receiverParameter;
    }

    visit(function);
  }

  Constant get trueConstant {
    return new Constant(new TrueConstantValue());
  }

  Constant get falseConstant {
    return new Constant(new FalseConstantValue());
  }

  Constant get nullConstant {
    return new Constant(new NullConstantValue());
  }

  void insertEqNullCheck(FunctionDefinition function) {
    // Replace
    //
    //     body;
    //
    // with
    //
    //     if (identical(arg, null))
    //       return false;
    //     else
    //       body;
    //
    CpsFragment cps = new CpsFragment();
    Primitive isNull = cps.applyBuiltin(BuiltinOperator.Identical,
        <Primitive>[function.parameters.single, cps.makeNull()]);
    CpsFragment trueBranch = cps.ifTruthy(isNull);
    trueBranch.invokeContinuation(
        function.returnContinuation, <Primitive>[trueBranch.makeFalse()]);
    cps.insertAbove(function.body);
  }

  /// Insert a static call to [function] immediately above [node].
  Primitive insertStaticCallAbove(
      FunctionElement function, List<Primitive> arguments, Expression node) {
    // TODO(johnniwinther): Come up with an implementation of SourceInformation
    // for calls such as this one that don't appear in the original source.
    InvokeStatic invoke = new InvokeStatic(
        function, new Selector.fromElement(function), arguments, null);
    new LetPrim(invoke).insertAbove(node);
    return invoke;
  }

  @override
  Expression traverseLetHandler(LetHandler node) {
    assert(node.handler.parameters.length == 2);
    Parameter previousExceptionParameter = _exceptionParameter;

    // BEFORE: Handlers have two parameters, exception and stack trace.
    // AFTER: Handlers have a single parameter, which is unwrapped to get
    // the exception and stack trace.
    _exceptionParameter = node.handler.parameters.first;
    Parameter stackTraceParameter = node.handler.parameters.last;
    Expression body = node.handler.body;
    if (_exceptionParameter.hasAtLeastOneUse ||
        stackTraceParameter.hasAtLeastOneUse) {
      InvokeStatic unwrapped = insertStaticCallAbove(
          _glue.getExceptionUnwrapper(),
          [new Parameter(null)], // Dummy argument, see below.
          body);
      _exceptionParameter.replaceUsesWith(unwrapped);

      // Replace the dummy with the exception parameter.  It must be set after
      // replacing all uses of [_exceptionParameter].
      unwrapped.argumentRefs[0].changeTo(_exceptionParameter);

      if (stackTraceParameter.hasAtLeastOneUse) {
        InvokeStatic stackTraceValue = insertStaticCallAbove(
            _glue.getTraceFromException(), [_exceptionParameter], body);
        stackTraceParameter.replaceUsesWith(stackTraceValue);
      }
    }

    assert(stackTraceParameter.hasNoUses);
    node.handler.parameters.removeLast();

    visit(node.handler);
    _exceptionParameter = previousExceptionParameter;

    return node.body;
  }

  processThrow(Throw node) {
    // The subexpression of throw is wrapped in the JavaScript output.
    Primitive wrappedException = insertStaticCallAbove(
        _glue.getWrapExceptionHelper(), [node.value], node);
    node.valueRef.changeTo(wrappedException);
  }

  processRethrow(Rethrow node) {
    // Rethrow can only appear in a catch block.  It throws that block's
    // (wrapped) caught exception.
    Throw replacement = new Throw(_exceptionParameter);
    InteriorNode parent = node.parent;
    parent.body = replacement;
    replacement.parent = parent;
    // The original rethrow does not have any references that we need to
    // worry about unlinking.
  }

  bool isNullConstant(Primitive prim) {
    return prim is Constant && prim.value.isNull;
  }

  processInvokeMethod(InvokeMethod node) {
    Selector selector = node.selector;
    if (!_glue.isInterceptedSelector(selector)) return;

    // Some platform libraries will compare non-interceptable objects against
    // null using the Dart == operator.  These must be translated directly.
    if (node.selector == Selectors.equals &&
        node.argumentRefs.length == 1 &&
        isNullConstant(node.argument(0))) {
      node.replaceWith(new ApplyBuiltinOperator(BuiltinOperator.Identical,
          [node.receiver, node.argument(0)], node.sourceInformation));
      return;
    }

    Primitive receiver = node.receiver;
    Primitive interceptor;

    if (receiver == receiverParameter && receiverInterceptor != null) {
      // TODO(asgerf): This could be done by GVN.
      // If the receiver is 'this', we are calling a method in
      // the same interceptor:
      //  Change 'receiver.foo()'  to  'this.foo(receiver)'.
      interceptor = receiverInterceptor;
    } else {
      interceptor = new Interceptor(receiver, node.sourceInformation);
      if (receiver.hint != null) {
        interceptor.hint = new InterceptorEntity(receiver.hint);
      }
      new LetPrim(interceptor).insertAbove(node.parent);
    }
    assert(node.interceptorRef == null);
    node.makeIntercepted(interceptor);
  }

  processInvokeMethodDirectly(InvokeMethodDirectly node) {
    if (!_glue.isInterceptedMethod(node.target)) return;

    Primitive receiver = node.receiver;
    Primitive interceptor;

    if (receiver == receiverParameter && receiverInterceptor != null) {
      // If the receiver is 'this', we are calling a method in
      // the same interceptor:
      //  Change 'receiver.foo()'  to  'this.foo(receiver)'.
      interceptor = receiverInterceptor;
    } else {
      interceptor = new Interceptor(receiver, node.sourceInformation);
      if (receiver.hint != null) {
        interceptor.hint = new InterceptorEntity(receiver.hint);
      }
      new LetPrim(interceptor).insertAbove(node.parent);
    }
    assert(node.interceptorRef == null);
    node.makeIntercepted(interceptor);
  }
}
