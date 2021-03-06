// Copyright (c) 2015, the Dart project authors.  Please see the AUTHORS file
// for details. All rights reserved. Use of this source code is governed by a
// BSD-style license that can be found in the LICENSE file.

/// Implementation of the element model used for deserialiation.
///
/// These classes are created by [ElementDeserializer] triggered by the
/// [Deserializer].

library dart2js.serialization.modelz;

import '../common.dart';
import '../common/resolution.dart' show
    Resolution;
import '../constants/constructors.dart';
import '../constants/expressions.dart';
import '../core_types.dart';
import '../dart_types.dart';
import '../elements/elements.dart';
import '../elements/modelx.dart' show
    FunctionSignatureX;
import '../elements/common.dart';
import '../elements/visitor.dart';
import '../io/source_file.dart';
import '../ordered_typeset.dart';
import '../resolution/class_members.dart' as class_members;
import '../resolution/tree_elements.dart' show
    TreeElements;
import '../resolution/scope.dart' show
    Scope;
import '../script.dart';
import '../serialization/constant_serialization.dart';
import '../tokens/token.dart' show
    Token;
import '../tree/tree.dart';
import '../util/util.dart' show
    Link,
    LinkBuilder;

import 'keys.dart';
import 'serialization.dart';

/// Compute a [Link] from an [Iterable].
Link toLink(Iterable iterable) {
  LinkBuilder builder = new LinkBuilder();
  for (var element in iterable) {
    builder.addLast(element);
  }
  return builder.toLink();
}

abstract class ElementZ extends Element with ElementCommon {
  String toString() {
    if (enclosingElement == null || isTopLevel) return 'Z$kind($name)';
    return 'Z$kind(${enclosingElement.name}#$name)';
  }

  _unsupported(text) => throw new UnsupportedError('${this}.$text');

  @override
  AnalyzableElement get analyzableElement {
    Element element = this;
    if (element is AnalyzableElement) {
      return element;
    } else if (enclosingElement != null) {
      return enclosingElement.analyzableElement;
    }
    return null;
  }

  @override
  FunctionElement asFunctionElement() => null;

  @override
  Scope buildScope() => _unsupported('analyzableElement');

  @override
  ClassElement get enclosingClass => null;

  @override
  Element get enclosingClassOrCompilationUnit {
    return _unsupported('enclosingClassOrCompilationUnit');
  }

  @override
  LibraryElement get implementationLibrary => library;

  @override
  bool get isAbstract => false;

  @override
  bool get isAssignable => _unsupported('isAssignable');

  @override
  bool get isClassMember => false;

  @override
  bool get isClosure => _unsupported('isClosure');

  @override
  bool get isConst => _unsupported('isConst');

  @override
  bool get isDeferredLoaderGetter => false;

  @override
  bool get isFinal => _unsupported('isFinal');

  @override
  bool get isInstanceMember => false;

  @override
  bool get isLocal => false;

  @override
  bool get isMixinApplication => false;

  @override
  bool get isOperator => false;

  @override
  bool get isStatic => false;

  // TODO(johnniwinther): Find a more precise semantics for this.
  @override
  bool get isSynthesized => true;

  @override
  bool get isTopLevel => false;

  // TODO(johnniwinther): Support metadata.
  @override
  Iterable<MetadataAnnotation> get metadata => const <MetadataAnnotation>[];

  @override
  Element get outermostEnclosingMemberOrTopLevel {
    return _unsupported('outermostEnclosingMemberOrTopLevel');
  }

  @override
  Token get position => _unsupported('position');
}

abstract class DeserializedElementZ extends ElementZ {
  ObjectDecoder _decoder;

  DeserializedElementZ(this._decoder);

  @override
  String get name => _decoder.getString(Key.NAME);

  @override
  SourceSpan get sourcePosition {
    // TODO(johnniwinther): Should this be cached?
    int offset = _decoder.getInt(Key.OFFSET, isOptional: true);
    if (offset == null) return null;
    Uri uri = _decoder.getUri(Key.URI, isOptional: true);
    if (uri == null) {
      uri = compilationUnit.script.readableUri;
    }
    int length = _decoder.getInt(Key.LENGTH, isOptional: true);
    if (length == null) {
      length = name.length;
    }
    return new SourceSpan(uri, offset, offset + length);
  }
}

/// Deserializer for a collection of member elements serialized as a map from
/// names to element declarations.
///
/// The serialized data contains the declared getters and setters but lookup
/// into the map returns an [AbstractFieldElement] for pairs of corresponding
/// getters and setters.
///
/// The underlying map encoding allows for lazy computation of the members upon
/// query.
class MappedContainer {
  Map<String, Element> _lookupCache = {};

  Element lookup(String name, MapDecoder members) {
    if (_lookupCache.containsKey(name)) {
      Element element = _lookupCache[name];
      if (element != null) {
        return element;
      }
    }
    if (members == null) {
      return null;
    }
    bool hasId = members.containsKey(name);
    String setterName = '$name,=';
    bool hasSetterId = members.containsKey(setterName);
    Element element;
    Element setterElement;
    if (!hasId && !hasSetterId) {
      _lookupCache[name] = null;
      return null;
    }
    bool isAccessor = false;
    if (hasId) {
      element = members.getElement(name);
      isAccessor = element.isGetter;
    }
    if (hasSetterId) {
      setterElement = members.getElement(setterName);
      isAccessor = true;
    }
    if (isAccessor) {
      element = new AbstractFieldElementZ(name, element, setterElement);
    }
    _lookupCache[name] = element;
    return element;
  }
}

/// Deserializer for a collection of member elements serialized as a list of
/// element declarations.
///
/// The serialized data contains the declared getters and setters but lookup
/// into the map returns an [AbstractFieldElement] for pairs of corresponding
/// getters and setters.
///
/// The underlying list encoding requires the complete lookup map to be computed
/// before query.
class ListedContainer {
  final Map<String, Element> _lookupMap = <String, Element>{};

  ListedContainer(List<Element> elements) {
    Set<String> accessorNames = new Set<String>();
    Map<String, Element> getters = <String, Element>{};
    Map<String, Element> setters = <String, Element>{};
    for (Element element in elements) {
      String name = element.name;
      if (element.isGetter) {
        accessorNames.add(name);
        getters[name] = element;
        // Inserting [element] here to ensure insert order of [name].
        _lookupMap[name] = element;
      } else if (element.isSetter) {
        accessorNames.add(name);
        setters[name] = element;
        // Inserting [element] here to ensure insert order of [name].
        _lookupMap[name] = element;
      } else {
        _lookupMap[name] = element;
      }
    }
    for (String name in accessorNames) {
      _lookupMap[name] =
          new AbstractFieldElementZ(name, getters[name], setters[name]);
    }
  }

  Element lookup(String name) => _lookupMap[name];

  void forEach(f(Element element)) => _lookupMap.values.forEach(f);

  Iterable<Element> get values => _lookupMap.values;
}


abstract class AnalyzableElementMixin implements AnalyzableElement, ElementZ {
  @override
  bool get hasTreeElements => _unsupported('hasTreeElements');

  @override
  TreeElements get treeElements => _unsupported('treeElements');
}


abstract class AstElementMixin implements AstElement, ElementZ {
  @override
  bool get hasNode => _unsupported('hasNode');

  @override
  bool get hasResolvedAst => _unsupported('hasResolvedAst');

  @override
  get node => _unsupported('node');

  @override
  ResolvedAst get resolvedAst => _unsupported('resolvedAst');
}

abstract class ContainerMixin
    implements DeserializedElementZ, ScopeContainerElement {
  MappedContainer _membersMap = new MappedContainer();

  @override
  Element localLookup(String name) {
    return _membersMap.lookup(
        name, _decoder.getMap(Key.MEMBERS, isOptional: true));
  }

  @override
  void forEachLocalMember(f(Element element)) {
    MapDecoder members =
        _decoder.getMap(Key.MEMBERS, isOptional: true);
    if (members == null) return;
    members.forEachKey((String key) {
      Element member = members.getElement(key);
      if (member != null) {
        f(member);
      }
    });
  }
}

class AbstractFieldElementZ extends ElementZ implements AbstractFieldElement {
  final String name;
  final FunctionElement getter;
  final FunctionElement setter;

  AbstractFieldElementZ(this.name, this.getter, this.setter);

  FunctionElement get _canonicalElement => getter != null ? getter : setter;

  @override
  ElementKind get kind => ElementKind.ABSTRACT_FIELD;

  @override
  accept(ElementVisitor visitor, arg) {
    return visitor.visitAbstractFieldElement(this, arg);
  }

  @override
  LibraryElement get library => _canonicalElement.library;

  @override
  CompilationUnitElement get compilationUnit {
    return _canonicalElement.compilationUnit;
  }

  @override
  Element get enclosingElement => _canonicalElement.enclosingElement;

  @override
  SourceSpan get sourcePosition => _canonicalElement.sourcePosition;

  @override
  ClassElement get enclosingClass => _canonicalElement.enclosingClass;
}

class LibraryElementZ extends DeserializedElementZ
    with AnalyzableElementMixin,
         ContainerMixin,
         LibraryElementCommon
    implements LibraryElement {
  Uri _canonicalUri;
  CompilationUnitElement _entryCompilationUnit;
  Link<CompilationUnitElement> _compilationUnits;
  List<ImportElement> _imports;
  List<ExportElement> _exports;
  ListedContainer _exportsMap;
  ListedContainer _importsMap;

  LibraryElementZ(ObjectDecoder decoder)
      : super(decoder);

  @override
  ElementKind get kind => ElementKind.LIBRARY;

  @override
  Element get enclosingElement => null;

  @override
  String get name => entryCompilationUnit.name;

  @override
  accept(ElementVisitor visitor, arg) {
    return visitor.visitLibraryElement(this, arg);
  }

  @override
  LibraryElement get library => this;

  @override
  CompilationUnitElement get compilationUnit => entryCompilationUnit;

  @override
  Uri get canonicalUri {
    if (_canonicalUri == null) {
      _canonicalUri = _decoder.getUri(Key.CANONICAL_URI);
    }
    return _canonicalUri;
  }

  @override
  CompilationUnitElement get entryCompilationUnit {
    if (_entryCompilationUnit == null) {
      _entryCompilationUnit = _decoder.getElement(Key.COMPILATION_UNIT);
    }
    return _entryCompilationUnit;
  }

  @override
  Link<CompilationUnitElement> get compilationUnits {
    if (_compilationUnits == null) {
      _compilationUnits =
          toLink(_decoder.getElements(Key.COMPILATION_UNITS));
    }
    return _compilationUnits;
  }

  @override
  bool get hasLibraryName {
    return libraryName != '';
  }

  @override
  String get libraryName {
    return _decoder.getString(Key.LIBRARY_NAME);
  }

  @override
  bool get exportsHandled => true;

  void _ensureExports() {
    if (_exportsMap == null) {
      _exportsMap = new ListedContainer(_decoder.getElements(Key.EXPORT_SCOPE));
    }
  }

  @override
  void forEachExport(f(Element element)) {
    _ensureExports();
    _exportsMap.forEach(f);
  }

  @override
  Element find(String elementName) {
    Element element = localLookup(elementName);
    if (element == null) {
      _ensureImports();
      element = _importsMap.lookup(elementName);
    }
    return element;
  }

  @override
  Element findLocal(String elementName) {
    return localLookup(elementName);
  }

  @override
  Element findExported(String elementName) => _unsupported('findExported');

  void _ensureImports() {
    if (_importsMap == null) {
      _importsMap = new ListedContainer(_decoder.getElements(Key.IMPORT_SCOPE));
    }
  }

  @override
  void forEachImport(f(Element element)) {
    _ensureImports();
    _importsMap.forEach(f);
  }

  @override
  Iterable<ImportElement> getImportsFor(Element element) {
    return _unsupported('getImportsFor');
  }

  String toString() {
    return 'Zlibrary(${canonicalUri})';
  }

  @override
  Iterable<ExportElement> get exports {
    if (_exports == null) {
      _exports = _decoder.getElements(Key.EXPORTS, isOptional: true);
    }
    return _exports;
  }

  @override
  Iterable<ImportElement> get imports {
    if (_imports == null) {
      _imports = _decoder.getElements(Key.IMPORTS, isOptional: true);
    }
    return _imports;
  }
}

class ScriptZ implements Script {
  final Uri resourceUri;

  ScriptZ(this.resourceUri);

  @override
  Script copyWithFile(SourceFile file) {
    throw new UnsupportedError('ScriptZ.copyWithFile');
  }

  @override
  SourceFile get file => throw new UnsupportedError('ScriptZ.file');

  @override
  bool get isSynthesized => throw new UnsupportedError('ScriptZ.isSynthesized');

  @override
  String get name => resourceUri.toString();

  // TODO(johnniwinther): Support the distinction between [readableUri] and
  // [resourceUri]; needed for platform libraries.
  @override
  Uri get readableUri => resourceUri;

  @override
  String get text => throw new UnsupportedError('ScriptZ.text');
}

class CompilationUnitElementZ extends DeserializedElementZ
    with LibraryMemberMixin,
         CompilationUnitElementCommon
    implements CompilationUnitElement {
  List<Element> _members;
  Script _script;

  CompilationUnitElementZ(ObjectDecoder decoder)
      : super(decoder);

  @override
  ElementKind get kind => ElementKind.COMPILATION_UNIT;

  @override
  CompilationUnitElement get compilationUnit => this;

  @override
  Element get enclosingElement => library;

  @override
  accept(ElementVisitor visitor, arg) {
    return visitor.visitCompilationUnitElement(this, arg);
  }

  @override
  void forEachLocalMember(f(Element element)) {
    if (_members == null) {
      _members =
          _decoder.getElements(Key.ELEMENTS, isOptional: true);
    }
    _members.forEach(f);
  }

  @override
  Script get script {
    if (_script == null) {
      Uri resolvedUri = _decoder.getUri(Key.URI);
      _script = new ScriptZ(resolvedUri);
    }
    return _script;
  }

  @override
  String get name => script.name;
}


abstract class LibraryMemberMixin implements DeserializedElementZ {
  LibraryElement _library;
  CompilationUnitElement _compilationUnit;

  @override
  LibraryElement get library {
    if (_library == null) {
      _library = _decoder.getElement(Key.LIBRARY);
    }
    return _library;
  }

  @override
  CompilationUnitElement get compilationUnit {
    if (_compilationUnit == null) {
      _compilationUnit = _decoder.getElement(Key.COMPILATION_UNIT);
    }
    return _compilationUnit;
  }

  @override
  Element get enclosingElement => compilationUnit;

  @override
  ClassElement get enclosingClass => null;

  @override
  bool get isTopLevel => true;

  @override
  bool get isStatic => false;
}

abstract class ClassMemberMixin implements DeserializedElementZ {
  ClassElement _class;

  @override
  Element get enclosingElement => enclosingClass;

  @override
  ClassElement get enclosingClass {
    if (_class == null) {
      _class = _decoder.getElement(Key.CLASS);
    }
    return _class;
  }

  @override
  bool get isClassMember => true;

  @override
  LibraryElement get library => enclosingClass.library;

  @override
  CompilationUnitElement get compilationUnit => enclosingClass.compilationUnit;
}

abstract class InstanceMemberMixin implements DeserializedElementZ {
  @override
  bool get isTopLevel => false;

  @override
  bool get isStatic => false;

  @override
  bool get isInstanceMember => true;
}

abstract class StaticMemberMixin implements DeserializedElementZ {
  @override
  bool get isTopLevel => false;

  @override
  bool get isStatic => true;
}

abstract class TypedElementMixin
    implements DeserializedElementZ, TypedElement {
  DartType _type;

  @override
  DartType get type {
    if (_type == null) {
      _type = _decoder.getType(Key.TYPE);
    }
    return _type;
  }

  @override
  DartType computeType(Resolution resolution) => type;
}

abstract class ParametersMixin
    implements DeserializedElementZ, FunctionTypedElement {
  FunctionSignature _functionSignature;
  List<ParameterElement> _parameters;

  bool get hasFunctionSignature => true;

  @override
  FunctionSignature get functionSignature {
    if (_functionSignature == null) {
      List<Element> requiredParameters = [];
      List<Element> optionalParameters = [];
      List orderedOptionalParameters = [];
      int requiredParameterCount = 0;
      int optionalParameterCount = 0;
      bool optionalParametersAreNamed = false;
      List<DartType> parameterTypes = <DartType>[];
      List<DartType> optionalParameterTypes = <DartType>[];
      List<String> namedParameters = <String>[];
      List<DartType> namedParameterTypes = <DartType>[];
      for (ParameterElement parameter in parameters) {
        if (parameter.isOptional) {
          optionalParameterCount++;
          requiredParameters.add(parameter);
          orderedOptionalParameters.add(parameter);
          if (parameter.isNamed) {
            optionalParametersAreNamed = true;
            namedParameters.add(parameter.name);
            namedParameterTypes.add(parameter.type);
          } else {
            optionalParameterTypes.add(parameter.type);
          }
        } else {
          requiredParameterCount++;
          optionalParameters.add(parameter);
          parameterTypes.add(parameter.type);
        }
      }
      if (optionalParametersAreNamed) {
        orderedOptionalParameters.sort((Element a, Element b) {
            return a.name.compareTo(b.name);
        });
      }

      FunctionType type = new FunctionType(
          this,
          _decoder.getType(Key.RETURN_TYPE),
          parameterTypes,
          optionalParameterTypes,
          namedParameters,
          namedParameterTypes);
      _functionSignature = new FunctionSignatureX(
          requiredParameters: requiredParameters,
          requiredParameterCount: requiredParameterCount,
          optionalParameters: optionalParameters,
          optionalParameterCount: optionalParameterCount,
          optionalParametersAreNamed: optionalParametersAreNamed,
          orderedOptionalParameters: orderedOptionalParameters,
          type: type);
    }
    return _functionSignature;
  }

  List<ParameterElement> get parameters {
    if (_parameters == null) {
      _parameters = _decoder.getElements(Key.PARAMETERS, isOptional: true);
    }
    return _parameters;
  }
}

abstract class FunctionTypedElementMixin
    implements FunctionElement, DeserializedElementZ {
  @override
  AsyncMarker get asyncMarker => _unsupported('asyncMarker');

  @override
  FunctionElement asFunctionElement() => this;

  @override
  bool get isExternal {
    return _decoder.getBool(
        Key.IS_EXTERNAL, isOptional: true, defaultValue: false);
  }
}

abstract class ClassElementMixin implements ElementZ, ClassElement {

  InterfaceType _createType(List<DartType> typeArguments) {
    return new InterfaceType(this, typeArguments);
  }

  @override
  ElementKind get kind => ElementKind.CLASS;

  @override
  void addBackendMember(Element element) => _unsupported('addBackendMember');

  @override
  void forEachBackendMember(void f(Element member)) {
    _unsupported('forEachBackendMember');
  }

  @override
  bool get hasBackendMembers => _unsupported('hasBackendMembers');

  @override
  bool get hasConstructor => _unsupported('hasConstructor');

  @override
  bool hasFieldShadowedBy(Element fieldMember) => _unsupported('');

  @override
  bool get hasIncompleteHierarchy => _unsupported('hasIncompleteHierarchy');

  @override
  bool get hasLocalScopeMembers => _unsupported('hasLocalScopeMembers');

  @override
  bool implementsFunction(CoreClasses coreClasses) {
    return _unsupported('implementsFunction');
  }

  @override
  bool get isEnumClass => false;

  @override
  Element lookupBackendMember(String memberName) {
    return _unsupported('lookupBackendMember');
  }

  @override
  ConstructorElement lookupDefaultConstructor() {
    ConstructorElement constructor = lookupConstructor("");
    if (constructor != null && constructor.parameters.isEmpty) {
      return constructor;
    }
    return null;
  }

  @override
  void reverseBackendMembers() => _unsupported('reverseBackendMembers');

  @override
  ClassElement get superclass => supertype != null ? supertype.element : null;

  @override
  void ensureResolved(Resolution resolution) {
    resolution.registerClass(this);
  }

}

class ClassElementZ extends DeserializedElementZ
    with AnalyzableElementMixin,
         AstElementMixin,
         ClassElementCommon,
         class_members.ClassMemberMixin,
         ContainerMixin,
         LibraryMemberMixin,
         TypeDeclarationMixin<InterfaceType>,
         ClassElementMixin
    implements ClassElement {
  bool _isObject;
  DartType _supertype;
  OrderedTypeSet _allSupertypesAndSelf;
  Link<DartType> _interfaces;

  ClassElementZ(ObjectDecoder decoder)
      : super(decoder);

  @override
  List<DartType> _getTypeVariables() {
    return _decoder.getTypes(Key.TYPE_VARIABLES, isOptional: true);
  }

  void _ensureSuperHierarchy() {
    if (_interfaces == null) {
      InterfaceType supertype =
          _decoder.getType(Key.SUPERTYPE, isOptional: true);
      if (supertype == null) {
        _isObject = true;
        _allSupertypesAndSelf = new OrderedTypeSet.singleton(thisType);
        _interfaces = const Link<DartType>();
      } else {
        _isObject = false;
        _interfaces = toLink(
            _decoder.getTypes(Key.INTERFACES, isOptional: true));
        List<InterfaceType> mixins =
            _decoder.getTypes(Key.MIXINS, isOptional: true);
        for (InterfaceType mixin in mixins) {
          MixinApplicationElement mixinElement =
              new UnnamedMixinApplicationElementZ(this, supertype, mixin);
          supertype = mixinElement.thisType.subst(
              typeVariables, mixinElement.typeVariables);
        }
        _supertype = supertype;
        _allSupertypesAndSelf =
            new OrderedTypeSetBuilder(this)
              .createOrderedTypeSet(_supertype, _interfaces);
      }
    }
  }

  @override
  accept(ElementVisitor visitor, arg) {
    return visitor.visitClassElement(this, arg);
  }

  @override
  DartType get supertype {
    _ensureSuperHierarchy();
    return _supertype;
  }

  @override
  bool get isAbstract => _decoder.getBool(Key.IS_ABSTRACT);

  @override
  bool get isObject {
    _ensureSuperHierarchy();
    return _isObject;
  }

  @override
  OrderedTypeSet get allSupertypesAndSelf {
    _ensureSuperHierarchy();
    return _allSupertypesAndSelf;
  }

  @override
  Link<DartType> get interfaces {
    _ensureSuperHierarchy();
    return _interfaces;
  }

  @override
  bool get isProxy => _decoder.getBool(Key.IS_PROXY);

  @override
  bool get isUnnamedMixinApplication => false;
}

abstract class MixinApplicationElementMixin
    implements ElementZ, MixinApplicationElement {
  Link<ConstructorElement> _constructors;

  @override
  bool get isMixinApplication => false;

  @override
  ClassElement get mixin => mixinType.element;

  Link<ConstructorElement> get constructors {
    if (_constructors == null) {
      LinkBuilder<ConstructorElement> builder =
          new LinkBuilder<ConstructorElement>();
      for (ConstructorElement definingConstructor in superclass.constructors) {
        if (definingConstructor.isGenerativeConstructor &&
            definingConstructor.memberName.isAccessibleFrom(library)) {
          builder.addLast(
              new ForwardingConstructorElementZ(this, definingConstructor));
        }
      }
      _constructors = builder.toLink();
    }
    return _constructors;
  }
}


class NamedMixinApplicationElementZ extends ClassElementZ
    with MixinApplicationElementCommon,
         MixinApplicationElementMixin {
  InterfaceType _mixinType;

  NamedMixinApplicationElementZ(ObjectDecoder decoder)
      : super(decoder);

  @override
  InterfaceType get mixinType =>_mixinType ??= _decoder.getType(Key.MIXIN);
}


class UnnamedMixinApplicationElementZ extends ElementZ
    with ClassElementCommon,
         ClassElementMixin,
         class_members.ClassMemberMixin,
         TypeDeclarationMixin<InterfaceType>,
         AnalyzableElementMixin,
         AstElementMixin,
         MixinApplicationElementCommon,
         MixinApplicationElementMixin {
  final String name;
  final ClassElement _subclass;
  final InterfaceType supertype;
  final Link<DartType> interfaces;
  OrderedTypeSet _allSupertypesAndSelf;

  UnnamedMixinApplicationElementZ(
      ClassElement subclass,
      InterfaceType supertype, InterfaceType mixin)
      : this._subclass = subclass,
        this.supertype = supertype,
        this.interfaces = const Link<DartType>().prepend(mixin),
        this.name = "${supertype.name}+${mixin.name}";

  @override
  CompilationUnitElement get compilationUnit => _subclass.compilationUnit;

  @override
  bool get isUnnamedMixinApplication => true;

  @override
  List<DartType> _getTypeVariables() {
    // Create synthetic type variables for the mixin application.
    List<DartType> typeVariables = <DartType>[];
    int index = 0;
    for (TypeVariableType type in _subclass.typeVariables) {
      SyntheticTypeVariableElementZ typeVariableElement =
          new SyntheticTypeVariableElementZ(this, index, type.name);
      TypeVariableType typeVariable = new TypeVariableType(typeVariableElement);
      typeVariables.add(typeVariable);
      index++;
    }
    // Setup bounds on the synthetic type variables.
    for (TypeVariableType type in _subclass.typeVariables) {
      TypeVariableType typeVariable = typeVariables[type.element.index];
      SyntheticTypeVariableElementZ typeVariableElement = typeVariable.element;
      typeVariableElement._type = typeVariable;
      typeVariableElement._bound =
          type.element.bound.subst(typeVariables, _subclass.typeVariables);
    }
    return typeVariables;
  }

  @override
  accept(ElementVisitor visitor, arg) {
    return visitor.visitMixinApplicationElement(this, arg);
  }

  @override
  OrderedTypeSet get allSupertypesAndSelf {
    if (_allSupertypesAndSelf == null) {
      _allSupertypesAndSelf =
          new OrderedTypeSetBuilder(this)
            .createOrderedTypeSet(supertype, interfaces);
    }
    return _allSupertypesAndSelf;
  }

  @override
  Element get enclosingElement => _subclass.enclosingElement;

  @override
  bool get isObject => false;

  @override
  bool get isProxy => false;

  @override
  LibraryElement get library => enclosingElement.library;

  @override
  InterfaceType get mixinType => interfaces.head;

  @override
  SourceSpan get sourcePosition => _subclass.sourcePosition;
}


class EnumClassElementZ extends ClassElementZ implements EnumClassElement {
  List<FieldElement> _enumValues;

  EnumClassElementZ(ObjectDecoder decoder)
      : super(decoder);

  @override
  bool get isEnumClass => true;

  @override
  List<FieldElement> get enumValues {
    if (_enumValues == null) {
      _enumValues = _decoder.getElements(Key.FIELDS);
    }
    return _enumValues;
  }
}

abstract class ConstructorElementZ extends DeserializedElementZ
    with AnalyzableElementMixin,
         AstElementMixin,
         ClassMemberMixin,
         FunctionTypedElementMixin,
         ParametersMixin,
         TypedElementMixin,
         MemberElementMixin
    implements ConstructorElement {
  ConstantConstructor _constantConstructor;

  ConstructorElementZ(ObjectDecoder decoder)
      : super(decoder);

  accept(ElementVisitor visitor, arg) {
    return visitor.visitConstructorElement(this, arg);
  }

  @override
  bool get isConst => _decoder.getBool(Key.IS_CONST);

  @override
  bool get isExternal => _decoder.getBool(Key.IS_EXTERNAL);

  bool get isFromEnvironmentConstructor {
    return name == 'fromEnvironment' &&
           library.isDartCore &&
           (enclosingClass.name == 'bool' ||
            enclosingClass.name == 'int' ||
            enclosingClass.name == 'String');
  }

  ConstantConstructor get constantConstructor {
    if (isConst && _constantConstructor == null) {
      ObjectDecoder data =
          _decoder.getObject(Key.CONSTRUCTOR, isOptional: true);
      if (data == null) {
        assert(isFromEnvironmentConstructor || isExternal);
        return null;
      }
      _constantConstructor = ConstantConstructorDeserializer.deserialize(data);
    }
    return _constantConstructor;
  }

  @override
  AsyncMarker get asyncMarker => _unsupported('asyncMarker');

  @override
  InterfaceType computeEffectiveTargetType(InterfaceType newType) {
    return _unsupported('computeEffectiveTargetType');
  }

  @override
  ConstructorElement get definingConstructor  {
    return _unsupported('definingConstructor');
  }

  @override
  ConstructorElement get effectiveTarget  {
    return _unsupported('effectiveTarget');
  }

  @override
  ConstructorElement get immediateRedirectionTarget  {
    return _unsupported('immediateRedirectionTarget');
  }

  @override
  bool get isEffectiveTargetMalformed {
    return _unsupported('isEffectiveTargetMalformed');
  }

  @override
  bool get isRedirectingFactory => _unsupported('isRedirectingFactory');

  @override
  bool get isRedirectingGenerative => _unsupported('isRedirectingGenerative');

  @override
  bool get isCyclicRedirection => _unsupported('isCyclicRedirection');

  @override
  PrefixElement get redirectionDeferredPrefix  {
    return _unsupported('redirectionDeferredPrefix');
  }
}

class GenerativeConstructorElementZ extends ConstructorElementZ {
  GenerativeConstructorElementZ(ObjectDecoder decoder)
      : super(decoder);

  @override
  ElementKind get kind => ElementKind.GENERATIVE_CONSTRUCTOR;

  @override
  bool get isEffectiveTargetMalformed =>
      _unsupported('isEffectiveTargetMalformed');
}

class FactoryConstructorElementZ extends ConstructorElementZ {

  FactoryConstructorElementZ(ObjectDecoder decoder)
      : super(decoder);

  @override
  ElementKind get kind => ElementKind.FACTORY_CONSTRUCTOR;

  @override
  bool get isEffectiveTargetMalformed =>
      _unsupported('isEffectiveTargetMalformed');
}

class ForwardingConstructorElementZ extends ElementZ
    with AnalyzableElementMixin,
        AstElementMixin
    implements ConstructorElement {
  final MixinApplicationElement enclosingClass;
  final ConstructorElement definingConstructor;

  ForwardingConstructorElementZ(this.enclosingClass, this.definingConstructor);

  @override
  CompilationUnitElement get compilationUnit => enclosingClass.compilationUnit;

  @override
  accept(ElementVisitor visitor, arg) {
    return visitor.visitConstructorElement(this, arg);
  }

  @override
  AsyncMarker get asyncMarker => AsyncMarker.SYNC;

  @override
  InterfaceType computeEffectiveTargetType(InterfaceType newType) {
    return enclosingClass.thisType;
  }

  @override
  DartType computeType(Resolution resolution) => type;

  @override
  bool get isConst => false;

  @override
  ConstantConstructor get constantConstructor => null;

  @override
  ConstructorElement get effectiveTarget => this;

  @override
  Element get enclosingElement => enclosingClass;

  @override
  FunctionSignature get functionSignature {
    return _unsupported('functionSignature');
  }

  @override
  bool get hasFunctionSignature  {
    return _unsupported('hasFunctionSignature');
  }

  @override
  ConstructorElement get immediateRedirectionTarget => null;

  @override
  bool get isCyclicRedirection => false;

  @override
  bool get isEffectiveTargetMalformed => false;

  @override
  bool get isExternal => false;

  @override
  bool get isFromEnvironmentConstructor => false;

  @override
  bool get isRedirectingFactory => false;

  @override
  bool get isRedirectingGenerative => false;

  @override
  ElementKind get kind => ElementKind.GENERATIVE_CONSTRUCTOR;

  @override
  LibraryElement get library => enclosingClass.library;

  @override
  MemberElement get memberContext => this;

  @override
  Name get memberName => definingConstructor.memberName;

  @override
  String get name => definingConstructor.name;

  @override
  List<FunctionElement> get nestedClosures => const <FunctionElement>[];

  @override
  List<ParameterElement> get parameters {
    // TODO(johnniwinther): We need to create synthetic parameters that
    // substitute type variables.
    return definingConstructor.parameters;
  }

  // TODO: implement redirectionDeferredPrefix
  @override
  PrefixElement get redirectionDeferredPrefix => null;

  @override
  SourceSpan get sourcePosition => enclosingClass.sourcePosition;

  @override
  FunctionType get type {
    // TODO(johnniwinther): Ensure that the function type substitutes type
    // variables correctly.
    return definingConstructor.type;
  }
}

abstract class MemberElementMixin
    implements DeserializedElementZ, MemberElement {

  @override
  MemberElement get memberContext => this;

  @override
  Name get memberName => new Name(name, library);

  @override
  List<FunctionElement> get nestedClosures => const <FunctionElement>[];

}

abstract class FieldElementZ extends DeserializedElementZ
    with AnalyzableElementMixin,
         AstElementMixin,
         TypedElementMixin,
         MemberElementMixin
    implements FieldElement {
  ConstantExpression _constant;

  FieldElementZ(ObjectDecoder decoder)
      : super(decoder);

  @override
  ElementKind get kind => ElementKind.FIELD;

  @override
  accept(ElementVisitor visitor, arg) {
    return visitor.visitFieldElement(this, arg);
  }

  @override
  bool get isFinal => _decoder.getBool(Key.IS_FINAL);

  @override
  bool get isConst => _decoder.getBool(Key.IS_CONST);

  @override
  ConstantExpression get constant {
    if (isConst && _constant == null) {
      _constant = _decoder.getConstant(Key.CONSTANT);
    }
    return _constant;
  }

  @override
  Expression get initializer => _unsupported('initializer');
}


class TopLevelFieldElementZ extends FieldElementZ with LibraryMemberMixin {
  TopLevelFieldElementZ(ObjectDecoder decoder)
      : super(decoder);
}

class StaticFieldElementZ extends FieldElementZ
    with ClassMemberMixin, StaticMemberMixin {
  StaticFieldElementZ(ObjectDecoder decoder)
      : super(decoder);
}

class InstanceFieldElementZ extends FieldElementZ
    with ClassMemberMixin, InstanceMemberMixin {
  InstanceFieldElementZ(ObjectDecoder decoder)
      : super(decoder);
}

abstract class FunctionElementZ extends DeserializedElementZ
    with AnalyzableElementMixin,
         AstElementMixin,
         ParametersMixin,
         FunctionTypedElementMixin,
         TypedElementMixin,
         MemberElementMixin
    implements MethodElement {
  FunctionElementZ(ObjectDecoder decoder)
      : super(decoder);

  @override
  ElementKind get kind => ElementKind.FUNCTION;

  @override
  accept(ElementVisitor visitor, arg) {
    return visitor.visitFunctionElement(this, arg);
  }

  @override
  bool get isOperator => _decoder.getBool(Key.IS_OPERATOR);
}

class TopLevelFunctionElementZ extends FunctionElementZ
    with LibraryMemberMixin {
  TopLevelFunctionElementZ(ObjectDecoder decoder)
      : super(decoder);
}

class StaticFunctionElementZ extends FunctionElementZ
    with ClassMemberMixin, StaticMemberMixin {
  StaticFunctionElementZ(ObjectDecoder decoder)
      : super(decoder);
}

class InstanceFunctionElementZ extends FunctionElementZ
    with ClassMemberMixin, InstanceMemberMixin {
  InstanceFunctionElementZ(ObjectDecoder decoder)
      : super(decoder);
}

abstract class LocalExecutableMixin
    implements DeserializedElementZ, ExecutableElement, LocalElement {
  ExecutableElement _executableContext;

  @override
  Element get enclosingElement => executableContext;

  @override
  ExecutableElement get executableContext {
    if (_executableContext == null) {
      _executableContext = _decoder.getElement(Key.EXECUTABLE_CONTEXT);
    }
    return _executableContext;
  }

  @override
  MemberElement get memberContext => executableContext.memberContext;

  @override
  bool get isLocal => true;

  @override
  LibraryElement get library => memberContext.library;

  @override
  CompilationUnitElement get compilationUnit {
    return memberContext.compilationUnit;
  }

  @override
  bool get hasTreeElements => memberContext.hasTreeElements;

  @override
  TreeElements get treeElements => memberContext.treeElements;
}

class LocalFunctionElementZ extends DeserializedElementZ
    with LocalExecutableMixin,
         AstElementMixin,
         ParametersMixin,
         FunctionTypedElementMixin,
         TypedElementMixin
    implements LocalFunctionElement {
  LocalFunctionElementZ(ObjectDecoder decoder)
      : super(decoder);

  @override
  accept(ElementVisitor visitor, arg) {
    return visitor.visitFunctionElement(this, arg);
  }

  @override
  ElementKind get kind => ElementKind.FUNCTION;
}

abstract class GetterElementZ extends DeserializedElementZ
    with AnalyzableElementMixin,
         AstElementMixin,
         FunctionTypedElementMixin,
         ParametersMixin,
         TypedElementMixin,
         MemberElementMixin
    implements FunctionElement {

  GetterElementZ(ObjectDecoder decoder)
      : super(decoder);

  @override
  ElementKind get kind => ElementKind.GETTER;

  @override
  accept(ElementVisitor visitor, arg) {
    return visitor.visitFunctionElement(this, arg);
  }
}

class TopLevelGetterElementZ extends GetterElementZ with LibraryMemberMixin {
  TopLevelGetterElementZ(ObjectDecoder decoder)
      : super(decoder);
}

class StaticGetterElementZ extends GetterElementZ
    with ClassMemberMixin, StaticMemberMixin {
  StaticGetterElementZ(ObjectDecoder decoder)
      : super(decoder);
}

class InstanceGetterElementZ extends GetterElementZ
    with ClassMemberMixin, InstanceMemberMixin {
  InstanceGetterElementZ(ObjectDecoder decoder)
      : super(decoder);
}

abstract class SetterElementZ extends DeserializedElementZ
    with AnalyzableElementMixin,
         AstElementMixin,
         FunctionTypedElementMixin,
         ParametersMixin,
         TypedElementMixin,
         MemberElementMixin
    implements FunctionElement {

  SetterElementZ(ObjectDecoder decoder)
      : super(decoder);

  @override
  ElementKind get kind => ElementKind.SETTER;

  @override
  accept(ElementVisitor visitor, arg) {
    return visitor.visitFunctionElement(this, arg);
  }
}

class TopLevelSetterElementZ extends SetterElementZ with LibraryMemberMixin {
  TopLevelSetterElementZ(ObjectDecoder decoder)
      : super(decoder);
}

class StaticSetterElementZ extends SetterElementZ
    with ClassMemberMixin, StaticMemberMixin {
  StaticSetterElementZ(ObjectDecoder decoder)
      : super(decoder);
}

class InstanceSetterElementZ extends SetterElementZ
    with ClassMemberMixin, InstanceMemberMixin {
  InstanceSetterElementZ(ObjectDecoder decoder)
      : super(decoder);
}

abstract class TypeDeclarationMixin<T extends GenericType>
    implements ElementZ, TypeDeclarationElement {
  List<DartType> _typeVariables;
  T _rawType;
  T _thisType;
  Name _memberName;

  Name get memberName {
    if (_memberName == null) {
      _memberName = new Name(name, library);
    }
    return _memberName;
  }

  List<DartType> _getTypeVariables();

  void _ensureTypes() {
    if (_typeVariables == null) {
      _typeVariables = _getTypeVariables();
      _rawType = _createType(new List<DartType>.filled(
          _typeVariables.length, const DynamicType()));
      _thisType = _createType(_typeVariables);
    }
  }

  T _createType(List<DartType> typeArguments);

  @override
  List<DartType> get typeVariables {
    _ensureTypes();
    return _typeVariables;
  }

  @override
  T get rawType {
    _ensureTypes();
    return _rawType;
  }

  @override
  T get thisType {
    _ensureTypes();
    return _thisType;
  }

  @override
  T computeType(Resolution resolution) => thisType;

  @override
  bool get isResolved => true;
}

class TypedefElementZ extends DeserializedElementZ
    with AnalyzableElementMixin,
         AstElementMixin,
         LibraryMemberMixin,
         ParametersMixin,
         TypeDeclarationMixin<TypedefType>
    implements TypedefElement {
  DartType _alias;

  TypedefElementZ(ObjectDecoder decoder)
      : super(decoder);

  TypedefType _createType(List<DartType> typeArguments) {
    return new TypedefType(this, typeArguments);
  }

  @override
  List<DartType> _getTypeVariables() {
    return _decoder.getTypes(Key.TYPE_VARIABLES, isOptional: true);
  }

  @override
  ElementKind get kind => ElementKind.TYPEDEF;

  @override
  accept(ElementVisitor visitor, arg) {
    return visitor.visitTypedefElement(this, arg);
  }

  @override
  DartType get alias {
    if (_alias == null) {
      _alias = _decoder.getType(Key.ALIAS);
    }
    return _alias;
  }

  @override
  void ensureResolved(Resolution resolution) {}

  @override
  void checkCyclicReference(Resolution resolution) {}
}

class TypeVariableElementZ extends DeserializedElementZ
    with AnalyzableElementMixin,
         AstElementMixin,
         TypedElementMixin
    implements TypeVariableElement {
  TypeDeclarationElement _typeDeclaration;
  TypeVariableType _type;
  DartType _bound;
  Name _memberName;

  TypeVariableElementZ(ObjectDecoder decoder)
      : super(decoder);

  Name get memberName {
    if (_memberName == null) {
      _memberName = new Name(name, library);
    }
    return _memberName;
  }

  @override
  ElementKind get kind => ElementKind.TYPE_VARIABLE;

  @override
  accept(ElementVisitor visitor, arg) {
    return visitor.visitTypeVariableElement(this, arg);
  }

  @override
  CompilationUnitElement get compilationUnit {
    return typeDeclaration.compilationUnit;
  }

  @override
  Element get enclosingElement => typeDeclaration;

  @override
  Element get enclosingClass => typeDeclaration;

  @override
  int get index => _decoder.getInt(Key.INDEX);

  @override
  TypeDeclarationElement get typeDeclaration {
    if (_typeDeclaration == null) {
      _typeDeclaration =
          _decoder.getElement(Key.TYPE_DECLARATION);
    }
    return _typeDeclaration;
  }

  DartType get bound {
    if (_bound == null) {
      _bound = _decoder.getType(Key.BOUND);
    }
    return _bound;
  }

  @override
  LibraryElement get library => typeDeclaration.library;
}

class SyntheticTypeVariableElementZ extends ElementZ
    with AnalyzableElementMixin,
         AstElementMixin
    implements TypeVariableElement {
  final TypeDeclarationElement typeDeclaration;
  final int index;
  final String name;
  TypeVariableType _type;
  DartType _bound;
  Name _memberName;

  SyntheticTypeVariableElementZ(this.typeDeclaration, this.index, this.name);

  Name get memberName {
    if (_memberName == null) {
      _memberName = new Name(name, library);
    }
    return _memberName;
  }

  @override
  ElementKind get kind => ElementKind.TYPE_VARIABLE;

  @override
  accept(ElementVisitor visitor, arg) {
    return visitor.visitTypeVariableElement(this, arg);
  }

  @override
  CompilationUnitElement get compilationUnit {
    return typeDeclaration.compilationUnit;
  }

  @override
  TypeVariableType get type {
    assert(invariant(this, _type != null,
         message: "Type variable type has not been set on $this."));
    return _type;
  }

  @override
  TypeVariableType computeType(Resolution resolution) => type;

  @override
  Element get enclosingElement => typeDeclaration;

  @override
  Element get enclosingClass => typeDeclaration;

  DartType get bound {
    assert(invariant(this, _bound != null,
        message: "Type variable bound has not been set on $this."));
    return _bound;
  }

  @override
  LibraryElement get library => typeDeclaration.library;

  @override
  SourceSpan get sourcePosition => typeDeclaration.sourcePosition;
}

class ParameterElementZ extends DeserializedElementZ
    with AnalyzableElementMixin,
         AstElementMixin,
         TypedElementMixin
    implements ParameterElement {
  FunctionElement _functionDeclaration;
  ConstantExpression _constant;
  DartType _type;

  ParameterElementZ(ObjectDecoder decoder) : super(decoder);

  @override
  accept(ElementVisitor visitor, arg) {
    return visitor.visitParameterElement(this, arg);
  }

  @override
  ConstantExpression get constant {
    if (isOptional) {
      if (_constant == null) {
        _constant = _decoder.getConstant(Key.CONSTANT);
      }
      return _constant;
    }
    return null;
  }

  @override
  CompilationUnitElement get compilationUnit {
    return functionDeclaration.compilationUnit;
  }

  @override
  ExecutableElement get executableContext => functionDeclaration;

  @override
  Element get enclosingElement => functionDeclaration;

  @override
  FunctionElement get functionDeclaration {
    if (_functionDeclaration == null) {
      _functionDeclaration = _decoder.getElement(Key.FUNCTION);
    }
    return _functionDeclaration;
  }

  @override
  FunctionSignature get functionSignature => _unsupported('functionSignature');

  @override
  Expression get initializer => _unsupported('initializer');

  @override
  bool get isNamed => _decoder.getBool(Key.IS_NAMED);

  @override
  bool get isOptional => _decoder.getBool(Key.IS_OPTIONAL);

  @override
  ElementKind get kind => ElementKind.PARAMETER;

  @override
  LibraryElement get library => executableContext.library;

  @override
  MemberElement get memberContext => executableContext.memberContext;
}

class InitializingFormalElementZ extends ParameterElementZ
    implements InitializingFormalElement {
  FieldElement _fieldElement;

  InitializingFormalElementZ(ObjectDecoder decoder)
      : super(decoder);

  @override
  FieldElement get fieldElement {
    if (_fieldElement == null) {
      _fieldElement = _decoder.getElement(Key.FIELD);
    }
    return _fieldElement;
  }

  @override
  accept(ElementVisitor visitor, arg) {
    return visitor.visitFieldParameterElement(this, arg);
  }

  @override
  ElementKind get kind => ElementKind.INITIALIZING_FORMAL;
}

class ImportElementZ extends DeserializedElementZ
    with LibraryMemberMixin implements ImportElement {
  bool _isDeferred;
  PrefixElement _prefix;
  LibraryElement _importedLibrary;
  Uri _uri;

  ImportElementZ(ObjectDecoder decoder)
      : super(decoder);

  @override
  String get name => '';

  @override
  accept(ElementVisitor visitor, arg) => visitor.visitImportElement(this, arg);

  @override
  ElementKind get kind => ElementKind.IMPORT;

  @override
  LibraryElement get importedLibrary {
    if (_importedLibrary == null) {
      _importedLibrary = _decoder.getElement(Key.LIBRARY_DEPENDENCY);
    }
    return _importedLibrary;
  }

  void _ensurePrefixResolved() {
    if (_isDeferred == null) {
      _isDeferred = _decoder.getBool(Key.IS_DEFERRED);
      _prefix = _decoder.getElement(Key.PREFIX, isOptional: true);
    }
  }

  @override
  bool get isDeferred {
    _ensurePrefixResolved();
    return _isDeferred;
  }

  @override
  PrefixElement get prefix {
    _ensurePrefixResolved();
    return _prefix;
  }

  @override
  Uri get uri {
    if (_uri == null) {
      _uri = _decoder.getUri(Key.URI);
    }
    return _uri;
  }

  @override
  Import get node => _unsupported('node');

  String toString() => 'Z$kind($uri)';
}

class ExportElementZ extends DeserializedElementZ
    with LibraryMemberMixin implements ExportElement {
  LibraryElement _exportedLibrary;
  Uri _uri;

  ExportElementZ(ObjectDecoder decoder)
      : super(decoder);

  @override
  String get name => '';

  @override
  accept(ElementVisitor visitor, arg) => visitor.visitExportElement(this, arg);

  @override
  ElementKind get kind => ElementKind.EXPORT;

  @override
  LibraryElement get exportedLibrary {
    if (_exportedLibrary == null) {
      _exportedLibrary = _decoder.getElement(Key.LIBRARY_DEPENDENCY);
    }
    return _exportedLibrary;
  }

  @override
  Uri get uri {
    if (_uri == null) {
      _uri = _decoder.getUri(Key.URI);
    }
    return _uri;
  }

  @override
  Export get node => _unsupported('node');

  String toString() => 'Z$kind($uri)';
}

class PrefixElementZ extends DeserializedElementZ
    with LibraryMemberMixin implements PrefixElement {
  bool _isDeferred;
  ImportElement _deferredImport;

  PrefixElementZ(ObjectDecoder decoder)
      : super(decoder);

  @override
  accept(ElementVisitor visitor, arg) => visitor.visitPrefixElement(this, arg);

  void _ensureDeferred() {
    if (_isDeferred == null) {
      _isDeferred = _decoder.getBool(Key.IS_DEFERRED);
      _deferredImport = _decoder.getElement(Key.IMPORT, isOptional: true);
    }
  }

  @override
  ImportElement get deferredImport {
    _ensureDeferred();
    return _deferredImport;
  }

  @override
  bool get isDeferred {
    _ensureDeferred();
    return _isDeferred;
  }

  @override
  ElementKind get kind => ElementKind.PREFIX;

  @override
  Element lookupLocalMember(String memberName) {
    return _unsupported('lookupLocalMember');
  }
}
