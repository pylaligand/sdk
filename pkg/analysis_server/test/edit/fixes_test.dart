// Copyright (c) 2014, the Dart project authors.  Please see the AUTHORS file
// for details. All rights reserved. Use of this source code is governed by a
// BSD-style license that can be found in the LICENSE file.

library test.edit.fixes;

import 'dart:async';

import 'package:analysis_server/plugin/protocol/protocol.dart';
import 'package:analysis_server/src/edit/edit_domain.dart';
import 'package:plugin/manager.dart';
import 'package:test_reflective_loader/test_reflective_loader.dart';
import 'package:unittest/unittest.dart' hide ERROR;

import '../analysis_abstract.dart';
import '../utils.dart';

main() {
  initializeTestEnvironment();
  defineReflectiveTests(FixesTest);
}

@reflectiveTest
class FixesTest extends AbstractAnalysisTest {
  @override
  void setUp() {
    super.setUp();
    ExtensionManager manager = new ExtensionManager();
    manager.processPlugins([server.serverPlugin]);
    handler = new EditDomainHandler(server);
  }

  test_fixUndefinedClass() async {
    createProject();
    addTestFile('''
main() {
  Future<String> x = null;
}
''');
    await waitForTasksFinished();
    List<AnalysisErrorFixes> errorFixes = await _getFixesAt('Future<String>');
    expect(errorFixes, hasLength(1));
    AnalysisError error = errorFixes[0].error;
    expect(error.severity, AnalysisErrorSeverity.WARNING);
    expect(error.type, AnalysisErrorType.STATIC_WARNING);
    List<SourceChange> fixes = errorFixes[0].fixes;
    expect(fixes, hasLength(2));
    expect(fixes[0].message, matches('Import library'));
    expect(fixes[1].message, matches('Create class'));
  }

  test_hasFixes() async {
    createProject();
    addTestFile('''
foo() {
  print(1)
}
bar() {
  print(10) print(20)
}
''');
    await waitForTasksFinished();
    // print(1)
    {
      List<AnalysisErrorFixes> errorFixes = await _getFixesAt('print(1)');
      expect(errorFixes, hasLength(1));
      _isSyntacticErrorWithSingleFix(errorFixes[0]);
    }
    // print(10)
    {
      List<AnalysisErrorFixes> errorFixes = await _getFixesAt('print(10)');
      expect(errorFixes, hasLength(2));
      _isSyntacticErrorWithSingleFix(errorFixes[0]);
      _isSyntacticErrorWithSingleFix(errorFixes[1]);
    }
  }

  test_overlayOnlyFile() async {
    createProject();
    testCode = '''
main() {
print(1)
}
''';
    _addOverlay(testFile, testCode);
    // ask for fixes
    await waitForTasksFinished();
    List<AnalysisErrorFixes> errorFixes = await _getFixesAt('print(1)');
    expect(errorFixes, hasLength(1));
    _isSyntacticErrorWithSingleFix(errorFixes[0]);
  }

  test_suggestImportFromDifferentAnalysisRoot() async {
    // Set up two projects.
    resourceProvider..newFolder("/project1")..newFolder("/project2");
    handleSuccessfulRequest(
        new AnalysisSetAnalysisRootsParams(["/project1", "/project2"], [])
            .toRequest('0'),
        handler: analysisHandler);

    // Set up files.
    testFile = "/project1/main.dart";
    testCode = "main() { print(new Foo()); }";
    _addOverlay(testFile, testCode);
    // Add another file in the same project that imports the target file.
    // This ensures it will be analyzed as an implicit Source.
    _addOverlay("/project1/another.dart", 'import "../project2/target.dart";');
    _addOverlay("/project2/target.dart", "class Foo() {}");

    await waitForTasksFinished();

    List<String> fixes = (await _getFixesAt('Foo()'))
        .single
        .fixes
        .map((f) => f.message)
        .toList();
    expect(fixes, contains("Import library '../project2/target.dart'"));
  }

  void _addOverlay(String name, String contents) {
    Request request =
        new AnalysisUpdateContentParams({name: new AddContentOverlay(contents)})
            .toRequest('0');
    handleSuccessfulRequest(request, handler: analysisHandler);
  }

  Future<List<AnalysisErrorFixes>> _getFixes(int offset) async {
    Request request = new EditGetFixesParams(testFile, offset).toRequest('0');
    Response response = await waitResponse(request);
    var result = new EditGetFixesResult.fromResponse(response);
    return result.fixes;
  }

  Future<List<AnalysisErrorFixes>> _getFixesAt(String search) async {
    int offset = findOffset(search);
    return await _getFixes(offset);
  }

  void _isSyntacticErrorWithSingleFix(AnalysisErrorFixes fixes) {
    AnalysisError error = fixes.error;
    expect(error.severity, AnalysisErrorSeverity.ERROR);
    expect(error.type, AnalysisErrorType.SYNTACTIC_ERROR);
    expect(fixes.fixes, hasLength(1));
  }
}
