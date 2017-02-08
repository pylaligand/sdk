// Copyright (c) 2017, the Dart project authors.  Please see the AUTHORS file
// for details. All rights reserved. Use of this source code is governed by a
// BSD-style license that can be found in the LICENSE file.

import 'package:analyzer/context/declared_variables.dart';
import 'package:analyzer/dart/ast/ast.dart';
import 'package:analyzer/dart/ast/token.dart';
import 'package:analyzer/dart/element/element.dart';
import 'package:analyzer/error/error.dart';
import 'package:analyzer/error/listener.dart';
import 'package:analyzer/src/context/context.dart';
import 'package:analyzer/src/dart/analysis/file_state.dart';
import 'package:analyzer/src/dart/ast/ast.dart';
import 'package:analyzer/src/dart/constant/evaluation.dart';
import 'package:analyzer/src/dart/constant/utilities.dart';
import 'package:analyzer/src/dart/element/element.dart';
import 'package:analyzer/src/dart/scanner/scanner.dart';
import 'package:analyzer/src/error/codes.dart';
import 'package:analyzer/src/error/pending_error.dart';
import 'package:analyzer/src/generated/declaration_resolver.dart';
import 'package:analyzer/src/generated/engine.dart';
import 'package:analyzer/src/generated/error_verifier.dart';
import 'package:analyzer/src/generated/parser.dart';
import 'package:analyzer/src/generated/resolver.dart';
import 'package:analyzer/src/generated/source.dart';
import 'package:analyzer/src/summary/package_bundle_reader.dart';
import 'package:analyzer/src/task/dart.dart';
import 'package:analyzer/src/task/strong/checker.dart';
import 'package:front_end/src/dependency_walker.dart';
import 'package:front_end/src/scanner/reader.dart';

/**
 * Analyzer of Dart files.
 *
 * Work in progress, not ready to be used.
 */
class AnalyzerImpl {
  final AnalysisOptions _analysisOptions;
  final DeclaredVariables _declaredVariables;
  final SourceFactory _sourceFactory;
  final FileSystemState _fsState;
  final SummaryDataStore _store;
  final FileState _library;

  TypeProvider _typeProvider;
  AnalysisContextImpl _context;
  StoreBasedSummaryResynthesizer _resynthesizer;

  final Map<FileState, RecordingErrorListener> _errorListeners = {};
  final Map<FileState, ErrorReporter> _errorReporters = {};
  final List<UsedImportedElements> _usedImportedElementsList = [];
  final List<UsedLocalElements> _usedLocalElementsList = [];
  final List<ConstantEvaluationTarget> _constants = [];

  AnalyzerImpl(this._analysisOptions, this._declaredVariables,
      this._sourceFactory, this._fsState, this._store, this._library);

  /**
   * Compute analysis results for all units of the library.
   */
  Map<FileState, UnitAnalysisResult> analyze() {
    Map<FileState, CompilationUnit> units = {};

    // Parse all files.
    units[_library] = _parse(_library);
    for (FileState part in _library.partedFiles) {
      units[part] = _parse(part);
    }

    // Resolve directives.
    units.forEach((file, unit) {
      _resolveUriBasedDirectives(file, unit);
    });

    _createAnalysisContext();

    try {
      _resynthesizer = new StoreBasedSummaryResynthesizer(
          _context, _sourceFactory, _analysisOptions.strongMode, _store);
      _typeProvider = _resynthesizer.typeProvider;
      _context.typeProvider = _typeProvider;

      units.forEach((file, unit) {
        _resolveFile(file, unit);
      });

      _computeConstants();

      units.forEach((file, unit) {
        LibraryElement libraryElement = unit.element.library;
        {
          var visitor = new GatherUsedLocalElementsVisitor(libraryElement);
          unit.accept(visitor);
          _usedLocalElementsList.add(visitor.usedElements);
        }
        {
          var visitor = new GatherUsedImportedElementsVisitor(libraryElement);
          unit.accept(visitor);
          _usedImportedElementsList.add(visitor.usedElements);
        }
      });

      units.forEach((file, unit) {
        _computeVerifyErrorsAndHints(file, unit);
      });
    } finally {
      _context.dispose();
    }

    // Return full results.
    Map<FileState, UnitAnalysisResult> results = {};
    units.forEach((file, unit) {
      List<AnalysisError> errors = _getErrorListener(file).errors;
      results[file] = new UnitAnalysisResult(file, unit, errors);
    });
    return results;
  }

  /**
   * Compute [_constants] in all units.
   */
  void _computeConstants() {
    ConstantEvaluationEngine evaluationEngine = new ConstantEvaluationEngine(
        _typeProvider, _declaredVariables,
        typeSystem: _context.typeSystem);

    List<_ConstantNode> nodes = [];
    Map<ConstantEvaluationTarget, _ConstantNode> nodeMap = {};
    for (ConstantEvaluationTarget constant in _constants) {
      var node = new _ConstantNode(evaluationEngine, nodeMap, constant);
      nodes.add(node);
      nodeMap[constant] = node;
    }

    for (_ConstantNode node in nodes) {
      if (!node.isEvaluated) {
        new _ConstantWalker(evaluationEngine).walk(node);
      }
    }
  }

  void _computeVerifyErrorsAndHints(FileState file, CompilationUnit unit) {
    RecordingErrorListener errorListener = _getErrorListener(file);
    CompilationUnitElement unitElement = unit.element;
    LibraryElement libraryElement = unitElement.library;

    //
    // Use the ErrorVerifier to compute errors.
    //
    List<PendingError> pendingErrors;
    {
      RequiredConstantsComputer computer =
          new RequiredConstantsComputer(file.source);
      unit.accept(computer);
      pendingErrors = computer.pendingErrors;
      List<ConstantEvaluationTarget> requiredConstants =
          computer.requiredConstants;
    }

    if (_analysisOptions.strongMode) {
      AnalysisOptionsImpl options = _analysisOptions as AnalysisOptionsImpl;
      CodeChecker checker = new CodeChecker(
          _typeProvider,
          new StrongTypeSystemImpl(_typeProvider,
              implicitCasts: options.implicitCasts,
              nonnullableTypes: options.nonnullableTypes),
          errorListener,
          options);
      checker.visitCompilationUnit(unit);
    }

    var errorReporter = _getErrorReporter(file);

    //
    // Validate the directives.
    //
    _validateUriBasedDirectives(file, unit);

    //
    // Use the ConstantVerifier to compute errors.
    //
    ConstantVerifier constantVerifier = new ConstantVerifier(
        errorReporter, libraryElement, _typeProvider, _declaredVariables);
    unit.accept(constantVerifier);

    //
    // Use the ErrorVerifier to compute errors.
    //
    ErrorVerifier errorVerifier = new ErrorVerifier(
        errorReporter,
        libraryElement,
        _typeProvider,
        new InheritanceManager(libraryElement),
        _analysisOptions.enableSuperMixins);
    unit.accept(errorVerifier);

    //
    // Convert the pending errors into actual errors.
    //
    for (PendingError pendingError in pendingErrors) {
      errorListener.onError(pendingError.toAnalysisError());
    }

    //
    // Find dead code.
    //
    unit.accept(
        new DeadCodeVerifier(errorReporter, typeSystem: _context.typeSystem));

    // Dart2js analysis.
    if (_analysisOptions.dart2jsHint) {
      unit.accept(new Dart2JSVerifier(errorReporter));
    }

    InheritanceManager inheritanceManager = new InheritanceManager(
        libraryElement,
        includeAbstractFromSuperclasses: true);

    unit.accept(new BestPracticesVerifier(
        errorReporter, _typeProvider, libraryElement, inheritanceManager,
        typeSystem: _context.typeSystem));

    unit.accept(new OverrideVerifier(errorReporter, inheritanceManager));

    new ToDoFinder(errorReporter).findIn(unit);

    // Verify imports.
    {
      ImportsVerifier verifier = new ImportsVerifier();
      verifier.addImports(unit);
      _usedImportedElementsList.forEach(verifier.removeUsedElements);
      ErrorReporter errorReporter = _getErrorReporter(file);
      verifier.generateDuplicateImportHints(errorReporter);
      verifier.generateUnusedImportHints(errorReporter);
      verifier.generateUnusedShownNameHints(errorReporter);
    }

    {
      GatherUsedLocalElementsVisitor visitor =
          new GatherUsedLocalElementsVisitor(libraryElement);
      unit.accept(visitor);
    }

    // Unused local elements.
    {
      UsedLocalElements usedElements =
          new UsedLocalElements.merge(_usedLocalElementsList);
      UnusedLocalElementsVerifier visitor =
          new UnusedLocalElementsVerifier(errorListener, usedElements);
      unitElement.accept(visitor);
    }
  }

  void _createAnalysisContext() {
    AnalysisContextImpl analysisContext =
        AnalysisEngine.instance.createAnalysisContext();
    analysisContext.analysisOptions = _analysisOptions;
    analysisContext.declaredVariables.addAll(_declaredVariables);
    analysisContext.sourceFactory = _sourceFactory.clone();
    analysisContext.contentCache = new _ContentCacheWrapper(_fsState);
    this._context = analysisContext;
  }

  RecordingErrorListener _getErrorListener(FileState file) =>
      _errorListeners.putIfAbsent(file, () => new RecordingErrorListener());

  ErrorReporter _getErrorReporter(FileState file) {
    return _errorReporters.putIfAbsent(file, () {
      RecordingErrorListener listener = _getErrorListener(file);
      return new ErrorReporter(listener, file.source);
    });
  }

  /**
   * Return a new parsed unresolved [CompilationUnit].
   */
  CompilationUnit _parse(FileState file) {
    RecordingErrorListener errorListener = _getErrorListener(file);

    CharSequenceReader reader = new CharSequenceReader(file.content);
    Scanner scanner = new Scanner(file.source, reader, errorListener);
    scanner.scanGenericMethodComments = _analysisOptions.strongMode;
    Token token = scanner.tokenize();
    LineInfo lineInfo = new LineInfo(scanner.lineStarts);

    Parser parser = new Parser(file.source, errorListener);
    parser.parseGenericMethodComments = _analysisOptions.strongMode;
    CompilationUnit unit = parser.parseCompilationUnit(token);
    unit.lineInfo = lineInfo;
    return unit;
  }

  void _resolveFile(FileState file, CompilationUnit unit) {
    RecordingErrorListener errorListener = _getErrorListener(file);

    String libraryUri = _library.uri.toString();
    String unitUri = file.uri.toString();
    CompilationUnitElement unitElement = _resynthesizer.getElement(
        new ElementLocationImpl.con3(<String>[libraryUri, unitUri]));
    LibraryElement libraryElement = unitElement.library;

    // TODO(scheglov) Hack: set types for top-level variables
    // Otherwise TypeResolverVisitor will set declared types, and because we
    // don't run InferStaticVariableTypeTask, we will stuck with these declared
    // types. And we don't need to run this task - resynthesized elements have
    // inferred types.
    for (var e in unitElement.topLevelVariables) {
      if (!e.isSynthetic) {
        e.type;
      }
    }

    new DeclarationResolver().resolve(unit, unitElement);

    if (file == _library) {
      // TODO(scheglov) fill these maps?
      DirectiveResolver resolver = new DirectiveResolver({}, {}, {});
      unit.accept(resolver);
    }

    // TODO(scheglov) remove EnumMemberBuilder class

    new TypeParameterBoundsResolver(
            _typeProvider, libraryElement, unitElement.source, errorListener)
        .resolveTypeBounds(unit);

    unit.accept(new TypeResolverVisitor(
        libraryElement, unitElement.source, _typeProvider, errorListener));

    LibraryScope libraryScope = new LibraryScope(libraryElement);
    unit.accept(new VariableResolverVisitor(
        libraryElement, unitElement.source, _typeProvider, errorListener,
        nameScope: libraryScope));

    unit.accept(new PartialResolverVisitor(libraryElement, unitElement.source,
        _typeProvider, AnalysisErrorListener.NULL_LISTENER));

    // Nothing for RESOLVED_UNIT8?
    // Nothing for RESOLVED_UNIT9?
    // Nothing for RESOLVED_UNIT10?

    unit.accept(new ResolverVisitor(
        libraryElement, unitElement.source, _typeProvider, errorListener));

    //
    // Find constants to compute.
    //
    {
      ConstantFinder constantFinder = new ConstantFinder();
      unit.accept(constantFinder);
      _constants.addAll(constantFinder.constantsToCompute);
    }
  }

  /**
   * Return the result of resolve the given [uriContent], reporting errors
   * against the [uriLiteral].
   */
  Source _resolveUri(FileState file, bool isImport, StringLiteral uriLiteral,
      String uriContent) {
    UriValidationCode code =
        UriBasedDirectiveImpl.validateUri(isImport, uriLiteral, uriContent);
    if (code == null) {
      try {
        Uri.parse(uriContent);
      } on FormatException {
        return null;
      }
      return _sourceFactory.resolveUri(file.source, uriContent);
    } else if (code == UriValidationCode.URI_WITH_DART_EXT_SCHEME) {
      return null;
    } else if (code == UriValidationCode.URI_WITH_INTERPOLATION) {
      _getErrorReporter(file).reportErrorForNode(
          CompileTimeErrorCode.URI_WITH_INTERPOLATION, uriLiteral);
      return null;
    } else if (code == UriValidationCode.INVALID_URI) {
      _getErrorReporter(file).reportErrorForNode(
          CompileTimeErrorCode.INVALID_URI, uriLiteral, [uriContent]);
      return null;
    }
    return null;
  }

  void _resolveUriBasedDirectives(FileState file, CompilationUnit unit) {
    for (Directive directive in unit.directives) {
      if (directive is UriBasedDirective) {
        StringLiteral uriLiteral = directive.uri;
        String uriContent = uriLiteral.stringValue?.trim();
        directive.uriContent = uriContent;
        Source defaultSource = _resolveUri(
            file, directive is ImportDirective, uriLiteral, uriContent);
        directive.uriSource = defaultSource;
      }
    }
  }

  /**
   * Check the given [directive] to see if the referenced source exists and
   * report an error if it does not.
   */
  void _validateUriBasedDirective(
      FileState file, UriBasedDirectiveImpl directive) {
    Source source = directive.uriSource;
    if (source != null) {
      if (_context.exists(source)) {
        return;
      }
    } else {
      // Don't report errors already reported by ParseDartTask.resolveDirective
      // TODO(scheglov) we don't use this task here
      if (directive.validate() != null) {
        return;
      }
    }
    StringLiteral uriLiteral = directive.uri;
    CompileTimeErrorCode errorCode = CompileTimeErrorCode.URI_DOES_NOT_EXIST;
    if (_isGenerated(source)) {
      errorCode = CompileTimeErrorCode.URI_HAS_NOT_BEEN_GENERATED;
    }
    _getErrorReporter(file)
        .reportErrorForNode(errorCode, uriLiteral, [directive.uriContent]);
  }

  /**
   * Check each directive in the given [unit] to see if the referenced source
   * exists and report an error if it does not.
   */
  void _validateUriBasedDirectives(FileState file, CompilationUnit unit) {
    for (Directive directive in unit.directives) {
      if (directive is UriBasedDirective) {
        _validateUriBasedDirective(file, directive);
      }
    }
  }

  /**
   * Return `true` if the given [source] refers to a file that is assumed to be
   * generated.
   */
  static bool _isGenerated(Source source) {
    if (source == null) {
      return false;
    }
    // TODO(brianwilkerson) Generalize this mechanism.
    const List<String> suffixes = const <String>[
      '.g.dart',
      '.pb.dart',
      '.pbenum.dart',
      '.pbserver.dart',
      '.pbjson.dart',
      '.template.dart'
    ];
    String fullName = source.fullName;
    for (String suffix in suffixes) {
      if (fullName.endsWith(suffix)) {
        return true;
      }
    }
    return false;
  }
}

/**
 * Analysis result for single file.
 */
class UnitAnalysisResult {
  final FileState file;
  final CompilationUnit unit;
  final List<AnalysisError> errors;

  UnitAnalysisResult(this.file, this.unit, this.errors);
}

/**
 * [Node] that is used to compute constants in dependency order.
 */
class _ConstantNode extends Node<_ConstantNode> {
  final ConstantEvaluationEngine evaluationEngine;
  final Map<ConstantEvaluationTarget, _ConstantNode> nodeMap;
  final ConstantEvaluationTarget constant;

  List<_ConstantNode> _dependencies = null;

  bool isEvaluated = false;

  _ConstantNode(this.evaluationEngine, this.nodeMap, this.constant);

  @override
  List<_ConstantNode> computeDependencies() {
    if (_dependencies == null) {
      List<ConstantEvaluationTarget> targets = [];
      evaluationEngine.computeDependencies(constant, targets.add);
      _dependencies = targets.map(_getNode).toList();
    }
    return _dependencies;
  }

  _ConstantNode _getNode(ConstantEvaluationTarget constant) {
    return nodeMap.putIfAbsent(
        constant, () => new _ConstantNode(evaluationEngine, nodeMap, constant));
  }
}

/**
 * [DependencyWalker] for computing constants and detecting cycles.
 */
class _ConstantWalker extends DependencyWalker<_ConstantNode> {
  final ConstantEvaluationEngine evaluationEngine;

  _ConstantWalker(this.evaluationEngine);

  @override
  void evaluate(_ConstantNode node) {
    evaluationEngine.computeConstantValue(node.constant);
    node.isEvaluated = true;
  }

  @override
  void evaluateScc(List<_ConstantNode> scc) {
    var constantsInCycle = scc.map((node) => node.constant);
    for (_ConstantNode node in scc) {
      evaluationEngine.generateCycleError(constantsInCycle, node.constant);
      node.isEvaluated = true;
    }
  }
}

/**
 * [ContentCache] wrapper around [FileContentOverlay].
 */
class _ContentCacheWrapper implements ContentCache {
  final FileSystemState fsState;

  _ContentCacheWrapper(this.fsState);

  @override
  void accept(ContentCacheVisitor visitor) {
    throw new UnimplementedError();
  }

  @override
  String getContents(Source source) {
    return _getFileForSource(source).content;
  }

  @override
  bool getExists(Source source) {
    return _getFileForSource(source).exists;
  }

  @override
  int getModificationStamp(Source source) {
    return _getFileForSource(source).exists ? 0 : -1;
  }

  @override
  String setContents(Source source, String contents) {
    throw new UnimplementedError();
  }

  FileState _getFileForSource(Source source) {
    String path = source.fullName;
    return fsState.getFileForPath(path);
  }
}