import 'dart:convert';
import 'dart:io';

void main(List<String> args) {
  if (args.isEmpty) {
    stderr.writeln(
      'Usage: dart tool/validate_registry.dart docs/contracts/registry.json',
    );
    exit(64);
  }
  final file = File(args.first);
  if (!file.existsSync()) {
    stderr.writeln('Not found: ${file.path}');
    exit(2);
  }
  late Map<String, dynamic> json;
  try {
    json = jsonDecode(file.readAsStringSync()) as Map<String, dynamic>;
  } catch (e) {
    stderr.writeln('Invalid JSON: $e');
    exit(1);
  }

  // Validate core structure per schema (lightweight check)
  if (json['generatedAt'] is! String) {
    stderr.writeln('Invalid registry: generatedAt must be a string');
    exit(1);
  }
  final domains = json['domains'];
  if (domains is! Map<String, dynamic> || domains.isEmpty) {
    stderr.writeln('Invalid registry: missing domains');
    exit(1);
  }

  const allowedFuncTypes = {'edge', 'rpc', 'rest', 'realtime'};

  for (final entry in domains.entries) {
    final name = entry.key;
    final d = entry.value;
    if (d is! Map<String, dynamic>) {
      stderr.writeln('Domain $name must be an object');
      exit(1);
    }
    for (final req in ['latest', 'docs', 'entities', 'functions']) {
      if (!d.containsKey(req)) {
        stderr.writeln('Domain $name missing key: $req');
        exit(1);
      }
    }
    if (d['latest'] is! String) {
      stderr.writeln('Domain $name: latest must be string');
      exit(1);
    }
    if (d['docs'] is! String) {
      stderr.writeln('Domain $name: docs must be string');
      exit(1);
    }
    if (d['entities'] is! Map<String, dynamic>) {
      stderr.writeln('Domain $name: entities must be object');
      exit(1);
    }
    if (d['functions'] is! Map<String, dynamic>) {
      stderr.writeln('Domain $name: functions must be object');
      exit(1);
    }
    final funcs = d['functions'] as Map<String, dynamic>;
    for (final f in funcs.entries) {
      final fd = f.value;
      if (fd is! Map<String, dynamic>) {
        stderr.writeln('Domain $name: function ${f.key} must be object');
        exit(1);
      }
      final type = fd['type'];
      if (type is! String || !allowedFuncTypes.contains(type)) {
        stderr.writeln(
          'Domain $name: function ${f.key} has invalid type: $type',
        );
        exit(1);
      }
    }
    if (d.containsKey('rls')) {
      final rls = d['rls'];
      if (rls is! List) {
        stderr.writeln('Domain $name: rls must be array');
        exit(1);
      }
      for (final rule in rls) {
        if (rule is! Map<String, dynamic> ||
            rule['table'] is! String ||
            rule['rule'] is! String) {
          stderr.writeln('Domain $name: rls rule invalid');
          exit(1);
        }
      }
    }

    // Optional: db section for internal metadata (extensions/triggers/functions/tables)
    if (d.containsKey('db')) {
      final db = d['db'];
      if (db is! Map<String, dynamic>) {
        stderr.writeln('Domain $name: db must be object');
        exit(1);
      }
      // Light validation only; keys are optional and schema can evolve.
      if (db.containsKey('extensions') && db['extensions'] is! List) {
        stderr.writeln('Domain $name: db.extensions must be array');
        exit(1);
      }
      if (db.containsKey('triggers') && db['triggers'] is! Map) {
        stderr.writeln('Domain $name: db.triggers must be object');
        exit(1);
      }
      if (db.containsKey('functions') && db['functions'] is! Map) {
        stderr.writeln('Domain $name: db.functions must be object');
        exit(1);
      }
      if (db.containsKey('tables') && db['tables'] is! Map) {
        stderr.writeln('Domain $name: db.tables must be object');
        exit(1);
      }
    }
  }
  stdout.writeln('registry.json is valid');
}
