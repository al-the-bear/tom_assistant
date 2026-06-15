// The Procedures-tab door onto a procedure's d4rt script (§ 6.3, § 6.4). The
// Run Tree opens a script *in the context of a run* (`ProcedureScriptView`,
// which correlates executed lines against a `ProcedureRun`); the gear editor has
// no run — it opens a script by id alone, to author it. So this page fetches the
// verbatim source (`GET /api/procedures/<id>`) and hands it straight to the same
// validated `ProcedureEditor` the run inspector edits with (`PUT /api/procedures/
// <id>`, AUTH-1…AUTH-5). It is the script counterpart to `ConfigFileEditorView`
// for the procedures' yaml.

import 'package:flutter/material.dart';

import '../api/trace_api_client.dart';
import 'procedure_editor.dart';

/// The editable script page for the procedure [procedureId], over [client].
/// Fetches the source lazily; an absent script (no script root, or an unknown
/// id) opens as an empty buffer the first save materialises.
class ProcedureScriptConfigView extends StatefulWidget {
  final TraceApiClient client;
  final String procedureId;

  const ProcedureScriptConfigView({
    super.key,
    required this.client,
    required this.procedureId,
  });

  @override
  State<ProcedureScriptConfigView> createState() =>
      _ProcedureScriptConfigViewState();
}

class _ProcedureScriptConfigViewState extends State<ProcedureScriptConfigView> {
  late Future<String?> _source;

  @override
  void initState() {
    super.initState();
    _source = widget.client.procedureScript(widget.procedureId);
  }

  @override
  Widget build(BuildContext context) => Scaffold(
        appBar: AppBar(title: Text('script · ${widget.procedureId}')),
        body: FutureBuilder<String?>(
          future: _source,
          builder: (context, snapshot) {
            if (snapshot.connectionState != ConnectionState.done) {
              return const Center(child: CircularProgressIndicator());
            }
            if (snapshot.hasError) {
              return Center(
                  child: Text('Failed to load script: ${snapshot.error}'));
            }
            // An absent script (`null`) is offered as an empty editable buffer —
            // the first save materialises it (mirrors the absent-template path).
            return SingleChildScrollView(
              child: ProcedureEditor(
                client: widget.client,
                procedureId: widget.procedureId,
                initialSource: snapshot.data ?? '',
              ),
            );
          },
        ),
      );
}
