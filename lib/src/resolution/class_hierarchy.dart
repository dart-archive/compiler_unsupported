// Copyright (c) 2015, the Dart project authors.  Please see the AUTHORS file
// for details. All rights reserved. Use of this source code is governed by a
// BSD-style license that can be found in the LICENSE file.

part of resolution;

class TypeDefinitionVisitor extends MappingVisitor<DartType> {
  Scope scope;
  final TypeDeclarationElement enclosingElement;
  TypeDeclarationElement get element => enclosingElement;

  TypeDefinitionVisitor(Compiler compiler,
                        TypeDeclarationElement element,
                        ResolutionRegistry registry)
      : this.enclosingElement = element,
        scope = Scope.buildEnclosingScope(element),
        super(compiler, registry);

  DartType get objectType => compiler.objectClass.rawType;

  void resolveTypeVariableBounds(NodeList node) {
    if (node == null) return;

    Setlet<String> nameSet = new Setlet<String>();
    // Resolve the bounds of type variables.
    Iterator<DartType> types = element.typeVariables.iterator;
    Link<Node> nodeLink = node.nodes;
    while (!nodeLink.isEmpty) {
      types.moveNext();
      TypeVariableType typeVariable = types.current;
      String typeName = typeVariable.name;
      TypeVariable typeNode = nodeLink.head;
      registry.useType(typeNode, typeVariable);
      if (nameSet.contains(typeName)) {
        error(typeNode, MessageKind.DUPLICATE_TYPE_VARIABLE_NAME,
              {'typeVariableName': typeName});
      }
      nameSet.add(typeName);

      TypeVariableElementX variableElement = typeVariable.element;
      if (typeNode.bound != null) {
        DartType boundType = typeResolver.resolveTypeAnnotation(
            this, typeNode.bound);
        variableElement.boundCache = boundType;

        void checkTypeVariableBound() {
          Link<TypeVariableElement> seenTypeVariables =
              const Link<TypeVariableElement>();
          seenTypeVariables = seenTypeVariables.prepend(variableElement);
          DartType bound = boundType;
          while (bound.isTypeVariable) {
            TypeVariableElement element = bound.element;
            if (seenTypeVariables.contains(element)) {
              if (identical(element, variableElement)) {
                // Only report an error on the checked type variable to avoid
                // generating multiple errors for the same cyclicity.
                warning(typeNode.name, MessageKind.CYCLIC_TYPE_VARIABLE,
                    {'typeVariableName': variableElement.name});
              }
              break;
            }
            seenTypeVariables = seenTypeVariables.prepend(element);
            bound = element.bound;
          }
        }
        addDeferredAction(element, checkTypeVariableBound);
      } else {
        variableElement.boundCache = objectType;
      }
      nodeLink = nodeLink.tail;
    }
    assert(!types.moveNext());
  }
}

/**
 * The implementation of [ResolverTask.resolveClass].
 *
 * This visitor has to be extra careful as it is building the basic
 * element information, and cannot safely look at other elements as
 * this may lead to cycles.
 *
 * This visitor can assume that the supertypes have already been
 * resolved, but it cannot call [ResolverTask.resolveClass] directly
 * or indirectly (through [ClassElement.ensureResolved]) for any other
 * types.
 */
class ClassResolverVisitor extends TypeDefinitionVisitor {
  BaseClassElementX get element => enclosingElement;

  ClassResolverVisitor(Compiler compiler,
                       ClassElement classElement,
                       ResolutionRegistry registry)
    : super(compiler, classElement, registry);

  DartType visitClassNode(ClassNode node) {
    if (element == null) {
      throw compiler.internalError(node, 'element is null');
    }
    if (element.resolutionState != STATE_STARTED) {
      throw compiler.internalError(element,
          'cyclic resolution of class $element');
    }

    element.computeType(compiler);
    scope = new TypeDeclarationScope(scope, element);
    // TODO(ahe): It is not safe to call resolveTypeVariableBounds yet.
    // As a side-effect, this may get us back here trying to
    // resolve this class again.
    resolveTypeVariableBounds(node.typeParameters);

    // Setup the supertype for the element (if there is a cycle in the
    // class hierarchy, it has already been set to Object).
    if (element.supertype == null && node.superclass != null) {
      MixinApplication superMixin = node.superclass.asMixinApplication();
      if (superMixin != null) {
        DartType supertype = resolveSupertype(element, superMixin.superclass);
        Link<Node> link = superMixin.mixins.nodes;
        while (!link.isEmpty) {
          supertype = applyMixin(supertype,
                                 checkMixinType(link.head), link.head);
          link = link.tail;
        }
        element.supertype = supertype;
      } else {
        element.supertype = resolveSupertype(element, node.superclass);
      }
    }
    // If the super type isn't specified, we provide a default.  The language
    // specifies [Object] but the backend can pick a specific 'implementation'
    // of Object - the JavaScript backend chooses between Object and
    // Interceptor.
    if (element.supertype == null) {
      ClassElement superElement = registry.defaultSuperclass(element);
      // Avoid making the superclass (usually Object) extend itself.
      if (element != superElement) {
        if (superElement == null) {
          compiler.internalError(node,
              "Cannot resolve default superclass for $element.");
        } else {
          superElement.ensureResolved(compiler);
        }
        element.supertype = superElement.computeType(compiler);
      }
    }

    if (element.interfaces == null) {
      element.interfaces = resolveInterfaces(node.interfaces, node.superclass);
    } else {
      assert(invariant(element, element.hasIncompleteHierarchy));
    }
    calculateAllSupertypes(element);

    if (!element.hasConstructor) {
      Element superMember = element.superclass.localLookup('');
      if (superMember == null || !superMember.isGenerativeConstructor) {
        MessageKind kind = MessageKind.CANNOT_FIND_CONSTRUCTOR;
        Map arguments = {'constructorName': ''};
        // TODO(ahe): Why is this a compile-time error? Or if it is an error,
        // why do we bother to registerThrowNoSuchMethod below?
        compiler.reportError(node, kind, arguments);
        superMember = new ErroneousElementX(
            kind, arguments, '', element);
        registry.registerThrowNoSuchMethod();
      } else {
        ConstructorElement superConstructor = superMember;
        Selector callToMatch = new Selector.call("", element.library, 0);
        superConstructor.computeType(compiler);
        if (!callToMatch.applies(superConstructor, compiler.world)) {
          MessageKind kind = MessageKind.NO_MATCHING_CONSTRUCTOR_FOR_IMPLICIT;
          compiler.reportError(node, kind);
          superMember = new ErroneousElementX(kind, {}, '', element);
        }
      }
      FunctionElement constructor =
          new SynthesizedConstructorElementX.forDefault(superMember, element);
      if (superMember.isErroneous) {
        compiler.elementsWithCompileTimeErrors.add(constructor);
      }
      element.setDefaultConstructor(constructor, compiler);
    }
    return element.computeType(compiler);
  }

  @override
  DartType visitEnum(Enum node) {
    if (element == null) {
      throw compiler.internalError(node, 'element is null');
    }
    if (element.resolutionState != STATE_STARTED) {
      throw compiler.internalError(element,
          'cyclic resolution of class $element');
    }

    InterfaceType enumType = element.computeType(compiler);
    element.supertype = compiler.objectClass.computeType(compiler);
    element.interfaces = const Link<DartType>();
    calculateAllSupertypes(element);

    if (node.names.nodes.isEmpty) {
      compiler.reportError(node,
                           MessageKind.EMPTY_ENUM_DECLARATION,
                           {'enumName': element.name});
    }

    EnumCreator creator = new EnumCreator(compiler, element);
    creator.createMembers();
    return enumType;
  }

  /// Resolves the mixed type for [mixinNode] and checks that the the mixin type
  /// is a valid, non-blacklisted interface type. The mixin type is returned.
  DartType checkMixinType(TypeAnnotation mixinNode) {
    DartType mixinType = resolveType(mixinNode);
    if (isBlackListed(mixinType)) {
      compiler.reportError(mixinNode,
          MessageKind.CANNOT_MIXIN, {'type': mixinType});
    } else if (mixinType.isTypeVariable) {
      compiler.reportError(mixinNode, MessageKind.CLASS_NAME_EXPECTED);
    } else if (mixinType.isMalformed) {
      compiler.reportError(mixinNode, MessageKind.CANNOT_MIXIN_MALFORMED,
          {'className': element.name, 'malformedType': mixinType});
    } else if (mixinType.isEnumType) {
      compiler.reportError(mixinNode, MessageKind.CANNOT_MIXIN_ENUM,
          {'className': element.name, 'enumType': mixinType});
    }
    return mixinType;
  }

  DartType visitNamedMixinApplication(NamedMixinApplication node) {
    if (element == null) {
      throw compiler.internalError(node, 'element is null');
    }
    if (element.resolutionState != STATE_STARTED) {
      throw compiler.internalError(element,
          'cyclic resolution of class $element');
    }

    if (identical(node.classKeyword.stringValue, 'typedef')) {
      // TODO(aprelev@gmail.com): Remove this deprecation diagnostic
      // together with corresponding TODO in parser.dart.
      compiler.reportWarning(node.classKeyword,
          MessageKind.DEPRECATED_TYPEDEF_MIXIN_SYNTAX);
    }

    element.computeType(compiler);
    scope = new TypeDeclarationScope(scope, element);
    resolveTypeVariableBounds(node.typeParameters);

    // Generate anonymous mixin application elements for the
    // intermediate mixin applications (excluding the last).
    DartType supertype = resolveSupertype(element, node.superclass);
    Link<Node> link = node.mixins.nodes;
    while (!link.tail.isEmpty) {
      supertype = applyMixin(supertype, checkMixinType(link.head), link.head);
      link = link.tail;
    }
    doApplyMixinTo(element, supertype, checkMixinType(link.head));
    return element.computeType(compiler);
  }

  DartType applyMixin(DartType supertype, DartType mixinType, Node node) {
    String superName = supertype.name;
    String mixinName = mixinType.name;
    MixinApplicationElementX mixinApplication = new MixinApplicationElementX(
        "${superName}+${mixinName}",
        element.compilationUnit,
        compiler.getNextFreeClassId(),
        node,
        new Modifiers.withFlags(new NodeList.empty(), Modifiers.FLAG_ABSTRACT));
    // Create synthetic type variables for the mixin application.
    List<DartType> typeVariables = <DartType>[];
    int index = 0;
    for (TypeVariableType type in element.typeVariables) {
      TypeVariableElementX typeVariableElement = new TypeVariableElementX(
          type.name, mixinApplication, index, type.element.node);
      TypeVariableType typeVariable = new TypeVariableType(typeVariableElement);
      typeVariables.add(typeVariable);
      index++;
    }
    // Setup bounds on the synthetic type variables.
    for (TypeVariableType type in element.typeVariables) {
      TypeVariableType typeVariable = typeVariables[type.element.index];
      TypeVariableElementX typeVariableElement = typeVariable.element;
      typeVariableElement.typeCache = typeVariable;
      typeVariableElement.boundCache =
          type.element.bound.subst(typeVariables, element.typeVariables);
    }
    // Setup this and raw type for the mixin application.
    mixinApplication.computeThisAndRawType(compiler, typeVariables);
    // Substitute in synthetic type variables in super and mixin types.
    supertype = supertype.subst(typeVariables, element.typeVariables);
    mixinType = mixinType.subst(typeVariables, element.typeVariables);

    doApplyMixinTo(mixinApplication, supertype, mixinType);
    mixinApplication.resolutionState = STATE_DONE;
    mixinApplication.supertypeLoadState = STATE_DONE;
    // Replace the synthetic type variables by the original type variables in
    // the returned type (which should be the type actually extended).
    InterfaceType mixinThisType = mixinApplication.thisType;
    return mixinThisType.subst(element.typeVariables,
                               mixinThisType.typeArguments);
  }

  bool isDefaultConstructor(FunctionElement constructor) {
    if (constructor.name != '') return false;
    constructor.computeType(compiler);
    return constructor.functionSignature.parameterCount == 0;
  }

  FunctionElement createForwardingConstructor(ConstructorElement target,
                                              ClassElement enclosing) {
    FunctionElement constructor =
        new SynthesizedConstructorElementX.notForDefault(
            target.name, target, enclosing);
    constructor.computeType(compiler);
    return constructor;
  }

  void doApplyMixinTo(MixinApplicationElementX mixinApplication,
                      DartType supertype,
                      DartType mixinType) {
    Node node = mixinApplication.parseNode(compiler);

    if (mixinApplication.supertype != null) {
      // [supertype] is not null if there was a cycle.
      assert(invariant(node, compiler.compilationFailed));
      supertype = mixinApplication.supertype;
      assert(invariant(node, supertype.element == compiler.objectClass));
    } else {
      mixinApplication.supertype = supertype;
    }

    // Named mixin application may have an 'implements' clause.
    NamedMixinApplication namedMixinApplication =
        node.asNamedMixinApplication();
    Link<DartType> interfaces = (namedMixinApplication != null)
        ? resolveInterfaces(namedMixinApplication.interfaces,
                            namedMixinApplication.superclass)
        : const Link<DartType>();

    // The class that is the result of a mixin application implements
    // the interface of the class that was mixed in so always prepend
    // that to the interface list.
    if (mixinApplication.interfaces == null) {
      if (mixinType.isInterfaceType) {
        // Avoid malformed types in the interfaces.
        interfaces = interfaces.prepend(mixinType);
      }
      mixinApplication.interfaces = interfaces;
    } else {
      assert(invariant(mixinApplication,
          mixinApplication.hasIncompleteHierarchy));
    }

    ClassElement superclass = supertype.element;
    if (mixinType.kind != TypeKind.INTERFACE) {
      mixinApplication.hasIncompleteHierarchy = true;
      mixinApplication.allSupertypesAndSelf = superclass.allSupertypesAndSelf;
      return;
    }

    assert(mixinApplication.mixinType == null);
    mixinApplication.mixinType = resolveMixinFor(mixinApplication, mixinType);

    // Create forwarding constructors for constructor defined in the superclass
    // because they are now hidden by the mixin application.
    superclass.forEachLocalMember((Element member) {
      if (!member.isGenerativeConstructor) return;
      FunctionElement forwarder =
          createForwardingConstructor(member, mixinApplication);
      if (isPrivateName(member.name) &&
          mixinApplication.library != superclass.library) {
        // Do not create a forwarder to the super constructor, because the mixin
        // application is in a different library than the constructor in the
        // super class and it is not possible to call that constructor from the
        // library using the mixin application.
        return;
      }
      mixinApplication.addConstructor(forwarder);
    });
    calculateAllSupertypes(mixinApplication);
  }

  InterfaceType resolveMixinFor(MixinApplicationElement mixinApplication,
                                DartType mixinType) {
    ClassElement mixin = mixinType.element;
    mixin.ensureResolved(compiler);

    // Check for cycles in the mixin chain.
    ClassElement previous = mixinApplication;  // For better error messages.
    ClassElement current = mixin;
    while (current != null && current.isMixinApplication) {
      MixinApplicationElement currentMixinApplication = current;
      if (currentMixinApplication == mixinApplication) {
        compiler.reportError(
            mixinApplication, MessageKind.ILLEGAL_MIXIN_CYCLE,
            {'mixinName1': current.name, 'mixinName2': previous.name});
        // We have found a cycle in the mixin chain. Return null as
        // the mixin for this application to avoid getting into
        // infinite recursion when traversing members.
        return null;
      }
      previous = current;
      current = currentMixinApplication.mixin;
    }
    registry.registerMixinUse(mixinApplication, mixin);
    return mixinType;
  }

  DartType resolveType(TypeAnnotation node) {
    return typeResolver.resolveTypeAnnotation(this, node);
  }

  DartType resolveSupertype(ClassElement cls, TypeAnnotation superclass) {
    DartType supertype = resolveType(superclass);
    if (supertype != null) {
      if (supertype.isMalformed) {
        compiler.reportError(superclass, MessageKind.CANNOT_EXTEND_MALFORMED,
            {'className': element.name, 'malformedType': supertype});
        return objectType;
      } else if (supertype.isEnumType) {
        compiler.reportError(superclass, MessageKind.CANNOT_EXTEND_ENUM,
            {'className': element.name, 'enumType': supertype});
        return objectType;
      } else if (!supertype.isInterfaceType) {
        compiler.reportError(superclass.typeName,
            MessageKind.CLASS_NAME_EXPECTED);
        return objectType;
      } else if (isBlackListed(supertype)) {
        compiler.reportError(superclass, MessageKind.CANNOT_EXTEND,
            {'type': supertype});
        return objectType;
      }
    }
    return supertype;
  }

  Link<DartType> resolveInterfaces(NodeList interfaces, Node superclass) {
    Link<DartType> result = const Link<DartType>();
    if (interfaces == null) return result;
    for (Link<Node> link = interfaces.nodes; !link.isEmpty; link = link.tail) {
      DartType interfaceType = resolveType(link.head);
      if (interfaceType != null) {
        if (interfaceType.isMalformed) {
          compiler.reportError(superclass,
              MessageKind.CANNOT_IMPLEMENT_MALFORMED,
              {'className': element.name, 'malformedType': interfaceType});
        } else if (interfaceType.isEnumType) {
          compiler.reportError(superclass,
              MessageKind.CANNOT_IMPLEMENT_ENUM,
              {'className': element.name, 'enumType': interfaceType});
        } else if (!interfaceType.isInterfaceType) {
          // TODO(johnniwinther): Handle dynamic.
          TypeAnnotation typeAnnotation = link.head;
          error(typeAnnotation.typeName, MessageKind.CLASS_NAME_EXPECTED);
        } else {
          if (interfaceType == element.supertype) {
            compiler.reportError(
                superclass,
                MessageKind.DUPLICATE_EXTENDS_IMPLEMENTS,
                {'type': interfaceType});
            compiler.reportError(
                link.head,
                MessageKind.DUPLICATE_EXTENDS_IMPLEMENTS,
                {'type': interfaceType});
          }
          if (result.contains(interfaceType)) {
            compiler.reportError(
                link.head,
                MessageKind.DUPLICATE_IMPLEMENTS,
                {'type': interfaceType});
          }
          result = result.prepend(interfaceType);
          if (isBlackListed(interfaceType)) {
            error(link.head, MessageKind.CANNOT_IMPLEMENT,
                  {'type': interfaceType});
          }
        }
      }
    }
    return result;
  }

  /**
   * Compute the list of all supertypes.
   *
   * The elements of this list are ordered as follows: first the supertype that
   * the class extends, then the implemented interfaces, and then the supertypes
   * of these.  The class [Object] appears only once, at the end of the list.
   *
   * For example, for a class `class C extends S implements I1, I2`, we compute
   *   supertypes(C) = [S, I1, I2] ++ supertypes(S) ++ supertypes(I1)
   *                   ++ supertypes(I2),
   * where ++ stands for list concatenation.
   *
   * This order makes sure that if a class implements an interface twice with
   * different type arguments, the type used in the most specific class comes
   * first.
   */
  void calculateAllSupertypes(BaseClassElementX cls) {
    if (cls.allSupertypesAndSelf != null) return;
    final DartType supertype = cls.supertype;
    if (supertype != null) {
      OrderedTypeSetBuilder allSupertypes = new OrderedTypeSetBuilder(cls);
      // TODO(15296): Collapse these iterations to one when the order is not
      // needed.
      allSupertypes.add(compiler, supertype);
      for (Link<DartType> interfaces = cls.interfaces;
           !interfaces.isEmpty;
           interfaces = interfaces.tail) {
        allSupertypes.add(compiler, interfaces.head);
      }

      addAllSupertypes(allSupertypes, supertype);
      for (Link<DartType> interfaces = cls.interfaces;
           !interfaces.isEmpty;
           interfaces = interfaces.tail) {
        addAllSupertypes(allSupertypes, interfaces.head);
      }
      allSupertypes.add(compiler, cls.computeType(compiler));
      cls.allSupertypesAndSelf = allSupertypes.toTypeSet();
    } else {
      assert(identical(cls, compiler.objectClass));
      cls.allSupertypesAndSelf =
          new OrderedTypeSet.singleton(cls.computeType(compiler));
    }
  }

  /**
   * Adds [type] and all supertypes of [type] to [allSupertypes] while
   * substituting type variables.
   */
  void addAllSupertypes(OrderedTypeSetBuilder allSupertypes,
                        InterfaceType type) {
    ClassElement classElement = type.element;
    Link<DartType> supertypes = classElement.allSupertypes;
    assert(invariant(element, supertypes != null,
        message: "Supertypes not computed on $classElement "
                 "during resolution of $element"));
    while (!supertypes.isEmpty) {
      DartType supertype = supertypes.head;
      allSupertypes.add(compiler, supertype.substByContext(type));
      supertypes = supertypes.tail;
    }
  }

  isBlackListed(DartType type) {
    LibraryElement lib = element.library;
    return
      !identical(lib, compiler.coreLibrary) &&
      !compiler.backend.isBackendLibrary(lib) &&
      (type.isDynamic ||
       identical(type.element, compiler.boolClass) ||
       identical(type.element, compiler.numClass) ||
       identical(type.element, compiler.intClass) ||
       identical(type.element, compiler.doubleClass) ||
       identical(type.element, compiler.stringClass) ||
       identical(type.element, compiler.nullClass));
  }
}

class ClassSupertypeResolver extends CommonResolverVisitor {
  Scope context;
  ClassElement classElement;

  ClassSupertypeResolver(Compiler compiler, ClassElement cls)
    : context = Scope.buildEnclosingScope(cls),
      this.classElement = cls,
      super(compiler);

  void loadSupertype(ClassElement element, Node from) {
    if (!element.isResolved) {
      compiler.resolver.loadSupertypes(element, from);
      element.ensureResolved(compiler);
    }
  }

  void visitNodeList(NodeList node) {
    if (node != null) {
      for (Link<Node> link = node.nodes; !link.isEmpty; link = link.tail) {
        link.head.accept(this);
      }
    }
  }

  void visitClassNode(ClassNode node) {
    if (node.superclass == null) {
      if (!identical(classElement, compiler.objectClass)) {
        loadSupertype(compiler.objectClass, node);
      }
    } else {
      node.superclass.accept(this);
    }
    visitNodeList(node.interfaces);
  }

  void visitEnum(Enum node) {
    loadSupertype(compiler.objectClass, node);
  }

  void visitMixinApplication(MixinApplication node) {
    node.superclass.accept(this);
    visitNodeList(node.mixins);
  }

  void visitNamedMixinApplication(NamedMixinApplication node) {
    node.superclass.accept(this);
    visitNodeList(node.mixins);
    visitNodeList(node.interfaces);
  }

  void visitTypeAnnotation(TypeAnnotation node) {
    node.typeName.accept(this);
  }

  void visitIdentifier(Identifier node) {
    Element element = lookupInScope(compiler, node, context, node.source);
    if (element != null && element.isClass) {
      loadSupertype(element, node);
    }
  }

  void visitSend(Send node) {
    Identifier prefix = node.receiver.asIdentifier();
    if (prefix == null) {
      error(node.receiver, MessageKind.NOT_A_PREFIX, {'node': node.receiver});
      return;
    }
    Element element = lookupInScope(compiler, prefix, context, prefix.source);
    if (element == null || !identical(element.kind, ElementKind.PREFIX)) {
      error(node.receiver, MessageKind.NOT_A_PREFIX, {'node': node.receiver});
      return;
    }
    PrefixElement prefixElement = element;
    Identifier selector = node.selector.asIdentifier();
    var e = prefixElement.lookupLocalMember(selector.source);
    if (e == null || !e.impliesType) {
      error(node.selector, MessageKind.CANNOT_RESOLVE_TYPE,
            {'typeName': node.selector});
      return;
    }
    loadSupertype(e, node);
  }
}
