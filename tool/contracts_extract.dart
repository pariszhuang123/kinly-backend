import 'dart:convert';
import 'dart:io';

/// Extracts machine-readable contract blocks from `docs/contracts/*_v*.md`.
///
/// Blocks are fenced as:
/// ```contracts-json
/// { ... }
/// ```
///
/// Filenames must follow the pattern `<domain>_vN.md`.
/// Writes an aggregated registry to `docs/contracts/registry.json`.
Future<void> main(List<String> args) async {
  final root = Directory('docs/contracts');
  if (!root.existsSync()) {
    stderr.writeln('docs/contracts not found');
    exit(2);
  }

  final files =
      await root
            .list(recursive: false)
            .where((e) => e is File && e.path.endsWith('.md'))
            .cast<File>()
            .toList()
        ..sort((a, b) => a.path.compareTo(b.path));

  // domain -> { versions: { vN: {...} } }
  final domains = <String, Map<String, dynamic>>{};

  for (final file in files) {
    final name = file.uri.pathSegments.last;

    // Expect names like `<domain>_vN.md`
    final versionRx = RegExp(r'_v(\d+)\.md$');
    final versionCap = versionRx.firstMatch(name);
    if (versionCap == null) continue;

    final version = 'v${versionCap.group(1)}';

    final content = await file.readAsString();
    final block = _extractContractsJson(content);
    if (block == null) {
      stderr.writeln('No contracts-json block in ${file.path}');
      continue;
    }

    Map<String, dynamic> json;
    try {
      json = jsonDecode(block) as Map<String, dynamic>;
    } catch (e) {
      stderr.writeln('Invalid JSON in ${file.path}: $e');
      exitCode = 1;
      continue;
    }

    final domain = (json['domain'] ?? '').toString();
    if (domain.isEmpty) {
      stderr.writeln('Missing domain in ${file.path}');
      exitCode = 1;
      continue;
    }

    // --- Enforce stable registry shape ---
    final entities = _asObject(
      json['entities'],
      context: '$domain.$version entities (${file.path})',
    );

    final functions = _asFunctionsObject(
      json['functions'],
      context: '$domain.$version functions (${file.path})',
    );
    final rls = _asList(
      json['rls'],
      context: '$domain.$version rls (${file.path})',
    );

    final normalized = <String, dynamic>{
      ...json,
      'entities': entities,
      'functions': functions,
      'rls': rls,
    };

    _normalizeFunctionPaths(normalized);

    final latestForDomain = domains.putIfAbsent(
      domain,
      () => {'versions': <String, Map<String, dynamic>>{}},
    );

    (latestForDomain['versions'] as Map<String, dynamic>)[version] = {
      'docs': file.path.replaceAll('\\', '/'),
      'entities': entities,
      'functions': functions,
      'rls': rls,
      'db': json['db'],
    };
  }

  final out = <String, dynamic>{
    'generatedAt': '',
    'domains': <String, dynamic>{},
  };

  final domainNames = domains.keys.toList()..sort();
  for (final domain in domainNames) {
    final data = domains[domain]!;
    final versions = data['versions'] as Map<String, dynamic>;

    String? latest;
    for (final v in versions.keys) {
      if (latest == null) {
        latest = v;
      } else {
        final a = int.tryParse(v.substring(1)) ?? 0;
        final b = int.tryParse(latest.substring(1)) ?? 0;
        if (a > b) latest = v;
      }
    }

    if (latest == null) continue;

    final latestData = versions[latest] as Map<String, dynamic>;

    final domainObj = <String, dynamic>{
      'latest': latest,
      'docs': latestData['docs'],
      'entities': latestData['entities'],
      'functions': latestData['functions'],
      'rls': latestData['rls'],
    };

    if (latestData['db'] != null) {
      domainObj['db'] = latestData['db'];
    }

    (out['domains'] as Map<String, dynamic>)[domain] = domainObj;
  }

  final outFile = File('docs/contracts/registry.json');
  outFile.createSync(recursive: true);
  outFile.writeAsStringSync(
    '${const JsonEncoder.withIndent('  ').convert(out)}\n',
  );

  stdout.writeln('Wrote ${outFile.path}');

  if (exitCode != 0) {
    stderr.writeln('Registry extraction completed with validation issues.');
    exit(exitCode);
  }
}

String? _extractContractsJson(String content) {
  final start = RegExp(r'^```contracts-json\s*$', multiLine: true);
  final end = RegExp(r'^```\s*$', multiLine: true);

  final s = start.firstMatch(content);
  if (s == null) return null;

  final after = content.substring(s.end);
  final e = end.firstMatch(after);
  if (e == null) return null;

  return after.substring(0, e.start).trim();
}

/// Coerce a value into an object (`Map<String, dynamic>`).
/// - null → {}
/// - wrong type → {} + CI failure
Map<String, dynamic> _asObject(dynamic v, {required String context}) {
  if (v == null) return <String, dynamic>{};

  if (v is Map<String, dynamic>) return v;

  if (v is Map) {
    try {
      return Map<String, dynamic>.from(v);
    } catch (_) {}
  }

  stderr.writeln(
    'Invalid $context: expected object, got ${v.runtimeType}. '
    'Forcing empty object.',
  );
  exitCode = 1;
  return <String, dynamic>{};
}

/// Coerce a value into a list.
/// - null -> []
/// - wrong type -> [] + CI failure
List<dynamic> _asList(dynamic v, {required String context}) {
  if (v == null) return <dynamic>[];

  if (v is List) return v;

  stderr.writeln(
    'Invalid $context: expected array, got ${v.runtimeType}. '
    'Forcing empty array.',
  );
  exitCode = 1;
  return <dynamic>[];
}

/// Same as `_asObject`, but enforces that each function entry is an object.
Map<String, dynamic> _asFunctionsObject(dynamic v, {required String context}) {
  final m = _asObject(v, context: context);

  for (final entry in m.entries.toList()) {
    if (entry.value is! Map) {
      stderr.writeln(
        'Invalid $context entry "${entry.key}": '
        'expected object, got ${entry.value.runtimeType}.',
      );
      exitCode = 1;
      m[entry.key] = <String, dynamic>{};
    }
  }

  return m;
}

/// Normalize any `functions.*.path` to use forward slashes
/// to keep snapshots stable across platforms.
void _normalizeFunctionPaths(Map<String, dynamic> json) {
  final functions = json['functions'];
  if (functions is Map) {
    for (final entry in functions.entries) {
      final value = entry.value;
      if (value is Map) {
        final path = value['path'];
        if (path is String) {
          value['path'] = path.replaceAll('\\', '/');
        }
      }
    }
  }
}
