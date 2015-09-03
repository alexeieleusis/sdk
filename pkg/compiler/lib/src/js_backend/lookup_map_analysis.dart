// Copyright (c) 2015, the Dart project authors.  Please see the AUTHORS file
// for details. All rights reserved. Use of this source code is governed by a
// BSD-style license that can be found in the LICENSE file.

/// Analysis to determine how to generate code for `LookupMap`s.
library compiler.src.js_backend.lookup_map_analysis;

import '../common/registry.dart' show Registry;
import '../compiler.dart' show Compiler;
import '../constants/values.dart' show
     ConstantValue,
     ConstructedConstantValue,
     ListConstantValue,
     NullConstantValue,
     TypeConstantValue;
import '../dart_types.dart' show DartType;
import '../elements/elements.dart' show Elements, Element, ClassElement,
     FieldElement, FunctionElement, FunctionSignature;
import '../enqueue.dart' show Enqueuer;
import 'js_backend.dart' show JavaScriptBackend;
import '../dart_types.dart' show DynamicType, InterfaceType;

/// An analysis and optimization to remove unused entries from a `LookupMap`.
///
/// `LookupMaps` are defined in `package:lookup_map/lookup_map.dart`. They are
/// simple maps that contain constant expressions as keys, and that only support
/// the lookup operation.
///
/// This analysis and optimization will tree-shake the contents of the maps by
/// looking at the program and finding which keys are clearly unused. Not all
/// constants can be approximated statically, so this optimization is limited to
/// the following keys:
///
///   * Const expressions that can only be created via const constructors. This
///   excludes primitives, strings, and any const type that overrides the ==
///   operator.
///
///   * Type literals.
///
/// Type literals are more complex than const expressions because they can be
/// created in multiple ways. We can approximate the possible set of keys if we
/// follow these rules:
///
///   * Include all type-literals used explicitly in the code (excluding
///   obviously the uses that can be removed from LookupMaps)
///
///   * Include every reflectable type-literal if a mirror API is used to create
///   types (e.g.  ClassMirror.reflectedType).
///
///   * Include all allocated types if the program contains `e.runtimeType`
///   expressions.
///
///   * Include all generic-type arguments, if the program uses type
///   variables in expressions such as `class A<T> { Type get extract => T }`.
///
// TODO(sigmund): add support for const expressions, currently this
// implementation only supports Type literals. To support const expressions we
// need to change some of the invariants below (e.g. we can no longer use the
// ClassElement of a type to refer to keys we need to discover).
// TODO(sigmund): detect uses of mirrors
class LookupMapAnalysis {
  /// Reference to [JavaScriptBackend] to be able to enqueue work when we
  /// discover that a key in a map is potentially used.
  final JavaScriptBackend backend;

  /// The resolved [ClassElement] associated with `LookupMap`.
  ClassElement typeLookupMapClass;

  /// The resolved [FieldElement] for `LookupMap._entries`.
  FieldElement entriesField;

  /// The resolved [FieldElement] for `LookupMap._key`.
  FieldElement keyField;

  /// The resolved [FieldElement] for `LookupMap._value`.
  FieldElement valueField;

  /// Constant instances of `LookupMap` and information about them tracked by
  /// this analysis.
  final Map<ConstantValue, _LookupMapInfo> _lookupMaps = {};

  /// Types that we have discovered to be in use in the program.
  final _inUse = new Set<ClassElement>();

  /// Pending work to do if we discover that a new type is in use. For each type
  /// that we haven't seen, we record the list of lookup-maps that use such type
  /// as a key.
  final _pending = <ClassElement, List<_LookupMapInfo>>{};

  /// Whether the backend is currently processing the codegen queue.
  // TODO(sigmund): is there a better way to do this. Do we need to plumb the
  // enqueuer on each callback?
  bool get _inCodegen => backend.compiler.phase == Compiler.PHASE_COMPILING;

  LookupMapAnalysis(this.backend);

  /// Whether this analysis and optimization is enabled.
  bool get _isEnabled {
    // `lookupMap==off` kept here to make it easy to test disabling this feature
    if (const String.fromEnvironment('lookupMap') == 'off') return false;
    return typeLookupMapClass != null;
  }

  /// Initializes this analysis by providing the resolver information of
  /// `LookupMap`.
  void initRuntimeClass(ClassElement cls) {
    cls.computeType(backend.compiler);
    entriesField = cls.lookupMember('_entries');
    keyField = cls.lookupMember('_key');
    valueField = cls.lookupMember('_value');
    // TODO(sigmund): Maybe inline nested maps make the output code smaller?
    typeLookupMapClass = cls;
  }

  /// Whether [constant] is an instance of a `LookupMap`.
  bool isLookupMap(ConstantValue constant) =>
      _isEnabled &&
      constant is ConstructedConstantValue &&
      constant.type.asRaw().element.isSubclassOf(typeLookupMapClass);

  /// Registers an instance of a lookup-map with the analysis.
  void registerLookupMapReference(ConstantValue lookupMap) {
    if (!_isEnabled || !_inCodegen) return;
    assert(isLookupMap(lookupMap));
    _lookupMaps.putIfAbsent(lookupMap,
        () => new _LookupMapInfo(lookupMap, this).._updateUsed());
  }

  /// Records that [type] is used in the program, and updates every map that
  /// has it as a key.
  void _addUse(ClassElement type) {
    if (_inUse.add(type)) {
      _pending[type]?.forEach((info) => info._markUsed(type));
      _pending.remove(type);
    }
  }

  /// Callback from the enqueuer, invoked when [element] is instantiated.
  void registerInstantiatedClass(ClassElement element) {
    if (!_isEnabled || !_inCodegen) return;
    // TODO(sigmund): only add if .runtimeType is ever used
    _addUse(element);
  }

  /// Callback from the enqueuer, invoked when [type] is instantiated.
  void registerInstantiatedType(InterfaceType type, Registry registry) {
    if (!_isEnabled || !_inCodegen) return;
    // TODO(sigmund): only add if .runtimeType is ever used
    _addUse(type.element);
    // TODO(sigmund): only do this when type-argument expressions are used?
    _addGenerics(type, registry);
  }

  /// Records generic type arguments in [type], in case they are retrieved and
  /// returned using a type-argument expression.
  void _addGenerics(InterfaceType type, Registry registry) {
    if (!type.isGeneric) return;
    for (var arg in type.typeArguments) {
      if (arg is InterfaceType) {
        _addUse(arg.element);
        // Note: this call was needed to generate correct code for
        // type_lookup_map/generic_type_test
        // TODO(sigmund): can we get rid of this?
        backend.registerInstantiatedConstantType(
            backend.typeImplementation.rawType, registry);
        _addGenerics(arg, registry);
      }
    }
  }

  /// Callback from the codegen enqueuer, invoked when a type constant
  /// corresponding to the [element] is used in the program.
  void registerTypeConstant(Element element) {
    if (!_isEnabled || !_inCodegen) return;
    assert(element.isClass);
    _addUse(element);
  }

  /// Callback from the backend, invoked when reaching the end of the enqueuing
  /// process, but before emitting the code. At this moment we have discovered
  /// all types used in the program and we can tree-shake anything that is
  /// unused.
  void onQueueClosed() {
    if (!_isEnabled || !_inCodegen) return;

    _lookupMaps.values.forEach((info) {
      assert (!info.emitted);
      info.emitted = true;
      info._prepareForEmission();
    });

    // When --verbose is passed, we show the total number and set of keys that
    // were tree-shaken from lookup maps.
    Compiler compiler = backend.compiler;
    if (compiler.verbose) {
      var sb = new StringBuffer();
      int count = 0;
      for (var info in _lookupMaps.values) {
        for (var key in info.unusedEntries.keys) {
          if (count != 0) sb.write(',');
          sb.write(key.unparse());
          count++;
        }
      }
      compiler.log(count == 0
          ? 'lookup-map: nothing was tree-shaken'
          : 'lookup-map: found $count unused keys ($sb)');
    }
  }
}

/// Internal information about the entries on a lookup-map.
class _LookupMapInfo {
  /// The original reference to the constant value.
  ///
  /// This reference will be mutated in place to remove it's entries when the
  /// map is first seen during codegen, and to restore them (or a subset of
  /// them) when we have finished discovering which entries are used. This has
  /// the side-effect that `orignal.getDependencies()` will be empty during
  /// most of codegen until we are ready to emit the constants. However,
  /// restoring the entries before emitting code lets us keep the emitter logic
  /// agnostic of this optimization.
  final ConstructedConstantValue original;

  /// Reference to the lookup map analysis to be able to refer to data shared
  /// accross infos.
  final LookupMapAnalysis analysis;

  /// Whether we have already emitted this constant.
  bool emitted = false;

  /// Whether the `LookupMap` constant was built using the `LookupMap.pair`
  /// constructor.
  bool singlePair;

  /// Entries in the lookup map whose keys have not been seen in the rest of the
  /// program.
  Map<ClassElement, ConstantValue> unusedEntries =
      <ClassElement, ConstantValue>{};

  /// Entries that have been used, and thus will be part of the generated code.
  Map<ClassElement, ConstantValue> usedEntries =
      <ClassElement, ConstantValue>{};

  /// Internal helper to memoize the mapping between map class elements and
  /// their corresponding type constants.
  Map<ClassElement, TypeConstantValue> _typeConstants =
      <ClassElement, TypeConstantValue>{};

  /// Creates and initializes the information containing all keys of the
  /// original map marked as unused.
  _LookupMapInfo(this.original, this.analysis) {
    ConstantValue key = original.fields[analysis.keyField];
    singlePair = !key.isNull;

    if (singlePair) {
      TypeConstantValue typeKey = key;
      ClassElement cls = typeKey.representedType.element;
      _typeConstants[cls] = typeKey;
      unusedEntries[cls] = original.fields[analysis.valueField];

      // Note: we modify the constant in-place, see comment in [original].
      original.fields[analysis.keyField] = new NullConstantValue();
      original.fields[analysis.valueField] = new NullConstantValue();
    } else {
      ListConstantValue list = original.fields[analysis.entriesField];
      List<ConstantValue> keyValuePairs = list.entries;
      for (int i = 0; i < keyValuePairs.length; i += 2) {
        TypeConstantValue type = keyValuePairs[i];
        ClassElement cls = type.representedType.element;
        if (cls == null || !cls.isClass) {
          // TODO(sigmund): report an error
          continue;
        }
        _typeConstants[cls] = type;
        unusedEntries[cls] = keyValuePairs[i + 1];
      }

      // Note: we modify the constant in-place, see comment in [original].
      original.fields[analysis.entriesField] =
          new ListConstantValue(list.type, []);
    }
  }

  /// Check every key in unusedEntries and mark it as used if the analysis has
  /// already discovered them. This is meant to be called once to finalize
  /// initialization after constructing an instance of this class. Afterwards,
  /// we call [_markUsed] on each individual key as it gets discovered.
  void _updateUsed() {
    // Note: we call toList because `_markUsed` modifies the map.
    for (ClassElement type in unusedEntries.keys.toList()) {
      if (analysis._inUse.contains(type)) {
        _markUsed(type);
      } else {
        analysis._pending.putIfAbsent(type, () => []).add(this);
      }
    }
  }

  /// Marks that [type] is a key that has been seen, and thus, the corresponding
  /// entry in this map should be considered reachable.
  void _markUsed(ClassElement type) {
    assert(!emitted);
    assert(unusedEntries.containsKey(type));
    assert(!usedEntries.containsKey(type));
    ConstantValue constant = unusedEntries.remove(type);
    usedEntries[type] = constant;
    analysis.backend.registerCompileTimeConstant(constant,
        analysis.backend.compiler.globalDependencies,
        addForEmission: false);
  }

  /// Restores [original] to contain all of the entries marked as possibly used.
  void _prepareForEmission() {
    ListConstantValue originalEntries = original.fields[analysis.entriesField];
    DartType listType = originalEntries.type;
    List<ConstantValue> keyValuePairs = <ConstantValue>[];
    usedEntries.forEach((key, value) {
      keyValuePairs.add(_typeConstants[key]);
      keyValuePairs.add(value);
    });

    // Note: we are restoring the entries here, see comment in [original].
    if (singlePair) {
      assert (keyValuePairs.length == 0 || keyValuePairs.length == 2);
      if (keyValuePairs.length == 2) {
        original.fields[analysis.keyField] = keyValuePairs[0];
        original.fields[analysis.valueField] = keyValuePairs[1];
      }
    } else {
      original.fields[analysis.entriesField] =
          new ListConstantValue(listType, keyValuePairs);
    }
  }
}