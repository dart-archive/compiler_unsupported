// Copyright (c) 2014, the Dart project authors.  Please see the AUTHORS file
// for details. All rights reserved. Use of this source code is governed by a
// BSD-style license that can be found in the LICENSE file.

library dart2js.resolution.enum_creator;

import '../dart_types.dart';
import '../dart2jslib.dart';
import '../elements/elements.dart';
import '../elements/modelx.dart';
import '../scanner/scannerlib.dart';
import '../tree/tree.dart';
import '../util/util.dart';

// TODO(johnniwinther): Merge functionality with the `TreePrinter`.
class AstBuilder {
  final Token position;

  AstBuilder(this.position);

  int get charOffset => position.charOffset;

  Modifiers modifiers({bool isConst: false,
                       bool isFinal: false,
                       bool isStatic: false}) {
    List identifiers = [];
    int flags = 0;
    if (isConst) {
      identifiers.add(identifier('const'));
      flags |= Modifiers.FLAG_CONST;
    }
    if (isFinal) {
      identifiers.add(identifier('final'));
      flags |= Modifiers.FLAG_FINAL;
    }
    if (isStatic) {
      identifiers.add(identifier('static'));
      flags |= Modifiers.FLAG_STATIC;
    }
    return new Modifiers.withFlags(
        new NodeList(null, linkedList(identifiers), null, ''),
        flags);
  }

  Token keywordToken(String text) {
    return new KeywordToken(Keyword.keywords[text], position.charOffset);
  }

  Token stringToken(String text) {
    return new StringToken.fromString(IDENTIFIER_INFO, text, charOffset);
  }

  Token symbolToken(PrecedenceInfo info) {
    return new SymbolToken(info, charOffset);
  }

  Identifier identifier(String text) {
    Keyword keyword = Keyword.keywords[text];
    Token token;
    if (keyword != null) {
      token = new KeywordToken(Keyword.keywords[text], charOffset);
    } else {
      token = stringToken(text);
    }
    return new Identifier(token);
  }

  Link linkedList(List elements) {
    LinkBuilder builder = new LinkBuilder();
    elements.forEach((e) => builder.addLast(e));
    return builder.toLink();
  }

  NodeList argumentList(List<Node> nodes) {
    return new NodeList(symbolToken(OPEN_PAREN_INFO),
                        linkedList(nodes),
                        symbolToken(CLOSE_PAREN_INFO),
                        ',');
  }

  Return returnStatement(Expression expression) {
    return new Return(
        keywordToken('return'),
        symbolToken(SEMICOLON_INFO),
        expression);
  }

  FunctionExpression functionExpression(Modifiers modifiers,
                                        String name,
                                        NodeList argumentList,
                                        Statement body,
                                        [TypeAnnotation returnType]) {
    return new FunctionExpression(
        identifier(name),
        argumentList,
        body,
        returnType,
        modifiers,
        null, // Initializer.
        null, // get/set.
        null  // Async modifier.
        );
  }

  EmptyStatement emptyStatement() {
    return new EmptyStatement(symbolToken(COMMA_INFO));
  }

  LiteralInt literalInt(int value) {
    return new LiteralInt(stringToken('$value'), null);
  }

  LiteralString literalString(String text,
                              {String prefix: '"',
                                String suffix: '"'}) {
    return new LiteralString(stringToken('$prefix$text$suffix'),
                             new DartString.literal(text));
  }

  LiteralList listLiteral(List<Node> elements, {bool isConst: false}) {
    return new LiteralList(
        null,
        new NodeList(symbolToken(OPEN_SQUARE_BRACKET_INFO),
                     linkedList(elements),
                     symbolToken(CLOSE_SQUARE_BRACKET_INFO),
                     ','),
        isConst ? keywordToken('const') : null);
  }

  Node createDefinition(Identifier name, Expression initializer) {
    if (initializer == null) return name;
    return new SendSet(null, name, new Operator(symbolToken(EQ_INFO)),
                 new NodeList.singleton(initializer));
  }

  VariableDefinitions initializingFormal(String fieldName) {
    return new VariableDefinitions.forParameter(
        new NodeList.empty(),
        null,
        Modifiers.EMPTY,
        new NodeList.singleton(
            new Send(identifier('this'), identifier(fieldName))));
  }

  NewExpression newExpression(String typeName,
                              NodeList arguments,
                              {bool isConst: false}) {
    return new NewExpression(keywordToken(isConst ? 'const' : 'new'),
        new Send(null, identifier(typeName), arguments));
  }

  Send reference(Identifier identifier) {
    return new Send(null, identifier);
  }

  Send indexGet(Expression receiver, Expression index) {
    return new Send(receiver,
                    new Operator(symbolToken(INDEX_INFO)),
                    new NodeList.singleton(index));
  }

  LiteralMapEntry mapLiteralEntry(Expression key, Expression value) {
    return new LiteralMapEntry(key, symbolToken(COLON_INFO), value);
  }

  LiteralMap mapLiteral(List<LiteralMapEntry> entries, {bool isConst: false}) {
    return new LiteralMap(
        null, // Type arguments.
        new NodeList(symbolToken(OPEN_CURLY_BRACKET_INFO),
                     linkedList(entries),
                     symbolToken(CLOSE_CURLY_BRACKET_INFO),
                     ','),
        isConst ? keywordToken('const') : null);
  }
}

class EnumCreator {
  final Compiler compiler;
  final EnumClassElementX enumClass;

  EnumCreator(this.compiler, this.enumClass);

  void createMembers() {
    Enum node = enumClass.node;
    InterfaceType enumType = enumClass.thisType;
    AstBuilder builder = new AstBuilder(enumClass.position);

    InterfaceType intType = compiler.intClass.computeType(compiler);
    InterfaceType stringType = compiler.stringClass.computeType(compiler);

    EnumFieldElementX addInstanceMember(String name, InterfaceType type) {
      Identifier identifier = builder.identifier(name);
      VariableList variableList =
          new VariableList(builder.modifiers(isFinal: true));
      variableList.type = type;
      EnumFieldElementX variable = new EnumFieldElementX(
          identifier, enumClass, variableList, identifier);
      enumClass.addMember(variable, compiler);
      return variable;
    }

    EnumFieldElementX indexVariable = addInstanceMember('index', intType);

    VariableDefinitions indexDefinition = builder.initializingFormal('index');

    FunctionExpression constructorNode = builder.functionExpression(
        builder.modifiers(isConst: true),
        enumClass.name,
        builder.argumentList([indexDefinition]),
        builder.emptyStatement());

    EnumConstructorElementX constructor = new EnumConstructorElementX(
        enumClass,
        builder.modifiers(isConst: true),
        constructorNode);

    EnumFormalElementX indexFormal = new EnumFormalElementX(
        constructor,
        indexDefinition,
        builder.identifier('index'),
        indexVariable);

    FunctionSignatureX constructorSignature = new FunctionSignatureX(
        requiredParameters: builder.linkedList([indexFormal]),
        requiredParameterCount: 1,
        type: new FunctionType(constructor, const VoidType(),
            <DartType>[intType]));
    constructor.functionSignatureCache = constructorSignature;
    enumClass.addMember(constructor, compiler);

    List<FieldElement> enumValues = <FieldElement>[];
    VariableList variableList =
        new VariableList(builder.modifiers(isStatic: true, isConst: true));
    variableList.type = enumType;
    int index = 0;
    List<Node> valueReferences = <Node>[];
    List<LiteralMapEntry> mapEntries = <LiteralMapEntry>[];
    for (Link<Node> link = node.names.nodes;
         !link.isEmpty;
         link = link.tail) {
      Identifier name = link.head;
      AstBuilder valueBuilder = new AstBuilder(name.token);

      // Add reference for the `values` field.
      valueReferences.add(valueBuilder.reference(name));

      // Add map entry for `toString` implementation.
      mapEntries.add(valueBuilder.mapLiteralEntry(
            valueBuilder.literalInt(index),
            valueBuilder.literalString('${enumClass.name}.${name.source}')));

      Expression initializer = valueBuilder.newExpression(
          enumClass.name,
          valueBuilder.argumentList([valueBuilder.literalInt(index)]),
          isConst: true);
      SendSet definition = valueBuilder.createDefinition(name, initializer);

      EnumFieldElementX field = new EnumFieldElementX(
          name, enumClass, variableList, definition, initializer);
      enumValues.add(field);
      enumClass.addMember(field, compiler);
      index++;
    }

    VariableList valuesVariableList =
        new VariableList(builder.modifiers(isStatic: true, isConst: true));
    InterfaceType listType = compiler.listClass.computeType(compiler);
    valuesVariableList.type = listType.createInstantiation([enumType]);

    Identifier valuesIdentifier = builder.identifier('values');
    // TODO(johnniwinther): Add type argument.
    Expression initializer = builder.listLiteral(
        valueReferences, isConst: true);

    Node definition = builder.createDefinition(valuesIdentifier, initializer);

    EnumFieldElementX valuesVariable = new EnumFieldElementX(
        valuesIdentifier, enumClass, valuesVariableList,
        definition, initializer);

    enumClass.addMember(valuesVariable, compiler);

    // TODO(johnniwinther): Support return type. Note `String` might be prefixed
    // or not imported within the current library.
    FunctionExpression toStringNode = builder.functionExpression(
        Modifiers.EMPTY,
        'toString',
        builder.argumentList([]),
        builder.returnStatement(
              builder.indexGet(
                  builder.mapLiteral(mapEntries, isConst: true),
                  builder.reference(builder.identifier('index')))
            )
        );

    EnumMethodElementX toString = new EnumMethodElementX('toString',
        enumClass, Modifiers.EMPTY, toStringNode);
    FunctionSignatureX toStringSignature = new FunctionSignatureX(
        type: new FunctionType(toString, stringType));
    toString.functionSignatureCache = toStringSignature;
    enumClass.addMember(toString, compiler);

    enumClass.enumValues = enumValues;
  }
}