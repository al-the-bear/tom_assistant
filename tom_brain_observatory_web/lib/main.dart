// Entry point for the Tom Brain Observatory web front-end (Module 1 — Prompt
// Tracing). Served by the tom_brain_observatory Trail Read API process at its
// static root, so the live brain and its observatory are one origin: the
// production client resolves `/api` against the document origin (`Uri.base`),
// with no base-URL config and no CORS (`prompt_tracing_plan.md` PT-2.0).

import 'package:flutter/material.dart';

import 'src/api/trace_api_client.dart';
import 'src/app.dart';

void main() {
  runApp(ObservatoryApp(client: HttpTraceApiClient()));
}
