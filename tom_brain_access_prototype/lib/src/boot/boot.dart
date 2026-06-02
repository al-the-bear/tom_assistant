// Boot + the running process.
//
// Owns `BrainAccessBoot` (composes substrate in-process, memory in a
// worker isolate, engine + dispatcher in the main isolate, both inbound
// adapters, identity, edge security, the classifier, and delivery),
// graceful shutdown via `tom_basics`' signal handling (stop accepting
// connections → drain in-flight foreground → close memory cleanly), and
// the `GET /healthz` endpoint. The executable itself lives in
// `bin/tom_brain_access_prototype.dart` (E.9) and is wired here. See
// `tom_brain_access_prototype_specification.md` § Boot and Plan steps
// E.41 – E.45.
//
// At E.8 this folder is intentionally empty. No exports yet.
