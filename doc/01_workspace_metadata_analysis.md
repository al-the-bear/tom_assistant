# Tom Brain Workspace Management System: Comprehensive Analysis

## 1. Workspace Metadata Summary

| Property | Value |
|----------|-------|
| **Workspace Name** | tom_agent_container |
| **Operating Systems Supported** | macOS, Linux, Windows |
| **Mobile Platforms** | Android, iOS |
| **Binaries Directory** | bin/ |
| **Generated Timestamp** | 2026-06-08T21:50:05.402700 |

---

## 2. Project Groups Inventory

The workspace is organized into **20 project groups** containing **130 total projects** (110 named projects plus test projects).

### Complete Project Groups List

| Group | Project Count | Description |
|-------|---------------|-------------|
| **ai_build** | 10 | AI-powered build tooling, spec generation, and flow engine |
| **app_deepwork** | 2 | Deepwork application (personal productivity) |
| **app_webwork** | 5 | Webwork application suite |
| **basics** | 8 | Basic framework utilities (crypto, console, tools, network, build base) |
| **cloud** | 2 | Cloud provisioning server and client |
| **core** | 8 | Core framework — kernel, server, flutter, d4rt, bridge, UI |
| **d4rt** | 10 | D4rt interpreter, generator, AST, and DCli ecosystem |
| **devops** | 11 | Build, deploy, test, issue-tracking, and documentation tooling |
| **distributed** | 7 | Distributed ledger, orchestration, and process monitoring |
| **reflection** | 5 | Runtime reflection — reflector, generator, and model |
| **test-projects** | 0 | Test projects (zom_ prefix) for testing build tools |
| **tom_assistant** | 4 | Tom Assistant — flagship AI personal assistant |
| **tom_claw** | 3 | OpenClaw, Raspberry Pi tooling, and TS-to-Dart transpiler |
| **tom_forge** | 14 | Tom Forge — composable visual development tooling (editors) |
| **tom_sqm** | 4 | Subscription and Quota Management |
| **tom_uam** | 3 | User and Authorization Management |
| **tom_worktracker** | 4 | Work tracker and project management |
| **vscode** | 7 | VS Code integration — extension, bridge, scripting API, workflow |
| **xternal** | 3 | External forks and native integrations (ceval, native_semaphores, tom_flutter_inappwebview) |
| **opensource** | 1 | External open-source projects integrated as submodules |

---

## 3. Cross-Compilation Targets

### All Available Targets (7 total)
```
darwin-x64, darwin-arm64, linux-x64, linux-arm64, linux-arm, linux-riscv64, win32-x64
```

### Build-On Configurations (Multi-Platform Cross-Compilation)

| Build On Platform | Can Target |
|-------------------|-----------|
| **darwin-arm64** | darwin-arm64, linux-x64, linux-arm64 |
| **darwin-x64** | darwin-x64, linux-x64, linux-arm64 |
| **linux-arm64** | linux-arm64, linux-x64 |
| **linux-x64** | linux-x64, linux-arm64 |
| **win32-x64** | win32-x64, linux-x64, linux-arm64 |

---

## 4. Build Order Overview

**Total Projects in Build Order: 130**

### First 20 Projects (Foundation & Infrastructure)
1. bench
2. ceval
3. deepwork_core
4. deepwork_ui
5. installed-extension-prev
6. native_semaphores
7. tom_ai
8. tom_ai_build
9. tom_analyzer_shared
10. tom_assistant_core
11. tom_assistant_messaging
12. tom_assistant_server
13. tom_assistant_ui
14. tom_ast_model
15. tom_basics
16. tom_basics_console
17. tom_basics_network
18. tom_build_base (KEY: Foundation for all CLI tools)
19. tom_build_common
20. tom_build_kit

### Last 10 Projects (High-Level Consumer Applications)
121. tom_reflection_generator
122. tom_uam_codespec
123. tom_uam_client
124. tom_uam_server
125. **tom_brain_procedure** (Tom Brain core procedure engine)
126. **tom_brain_smoke_prototype** (Tom Brain end-to-end test harness)
127. **tom_brain_access** (Tom Brain inbound surface)
128. **tom_brain_substrate** (Tom Brain LLM abstraction layer)
129. **tom_brain_memory** (Tom Brain knowledge graph)
130. **tom_brain_run** (Tom Brain production assembly)

---

## 5. Project Types Distribution

The workspace supports **8 project types**:

| Project Type | Count | Description |
|--------------|-------|-------------|
| **dart_package** | 70 | Publishable Dart libraries |
| **dart_console** | 35 | Dart command-line applications |
| **flutter_app** | 12 | Flutter mobile/web applications |
| **typescript_node** | 5 | TypeScript Node.js projects |
| **vscode_extension** | 4 | VS Code extensions |
| **javascript** | 2 | JavaScript projects |
| **node_cli** | 1 | Node.js CLI tool |
| **python** | 1 | Python project |

---

## 6. Workspace Modes (5 Types, 14 Total Modes)

### Mode Categories

#### Environment Modes (3)
- **local** (default): Local development environment
- **int**: Integration/staging environment
- **prod**: Production environment

#### Execution Modes (3)
- **local** (default): Run directly on local machine
- **docker**: Run in Docker container
- **cloud**: Run in cloud environment

#### Cloud Provider Modes (4)
- **aws** (default): Amazon Web Services
- **gcp**: Google Cloud Platform
- **azure**: Microsoft Azure
- **firebase**: Firebase (Google)

#### Deployment Modes (3)
- **none** (default): No deployment
- **docker-compose**: Docker Compose deployment
- **kubernetes**: Kubernetes deployment

#### Publishing Modes (2)
- **development** (default): Development/preview release (implies: development, relative_build)
- **release**: Official release (implies: production)

### Named Workspace Modes (4)
1. **relative_build**: Use relative paths for package dependencies
2. **development**: Development mode with relative builds (implies relative_build)
3. **production**: Production mode with versioned dependencies
4. **default**: Default mode (no special configuration)

---

## 7. Available Actions

The workspace supports **5 primary actions**:

| Action | Description | Command(s) |
|--------|-------------|-----------|
| **pubget** | Run dart pub get | `dart pub get` (Dart/Flutter aware) |
| **test** | Run tests | `dart test` / `flutter test` (type-aware) |
| **builder_runner** | Run build_runner code generation | `dart run build_runner build --delete-conflicting-outputs` |
| **echo** | Verify placeholders and D4rt execution | Dart inline scripts with tom context access |
| **bin_release** | Build release binaries | Dart compile exe with platform-specific output (bin/{os}/{name}) |

---

## 8. SDK Versions

The workspace uses **Dart SDK ^3.x** across 13 different version constraints:

```
^3.0.0, ^3.5.0, ^3.9.0, ^3.9.2, ^3.10.0, ^3.10.4, ^3.10.8, 
^3.11.0, ^3.11.1, ^3.11.4, ^3.11.5, >=3.0.0, >=3.3.0 <4.0.0
```

**Most Common:** ^3.10.x and ^3.11.x (supporting modern Dart features)

---

## 9. Copilot Guidelines Inventory

The workspace includes **58 structured documentation files** organized in `_agent_guidelines/`:

### Global Guidelines (Top-Level)
- **index.md**: Master index of all guidelines
- **documentation_guidelines.md**: Package/module documentation format
- **project_guidelines.md**: Template for project-specific guidelines
- **project_structure.md**: Project and workspace structure patterns
- **projects_and_repos.md**: Project IDs and repository IDs
- **tool_dependencies.md**: CLI tools, source projects, rebuild instructions
- **test_driven_development.md**: TDD principles and red-green-refactor workflow
- **issue_implementation.md**: Bug and feature workflow
- **user_clarification_guidelines.md**: Clarification file structure
- **spec_workflow.md**: Specification to implementation workflow
- **spec_writing_guide.md**: Writing AI-friendly specifications
- **prompt_patterns.md**: !prompt, $prompt, $!prompt patterns
- **document_schemas.md**: YAML/markdown schema validation
- **console_markdown.md**: Console markdown formatting conventions
- **global_actions_coordination.md**: Cross-action coordination patterns
- **.analysis_options.yaml**: Dart analyzer configuration reference

### Dart Guidelines (16 files)
Located in `_agent_guidelines/dart/`:
- coding_guidelines.md
- clean_code_principles.md
- unit_tests.md
- tests_buildtools.md (zom_ prefix for test projects)
- test_tracking.md (TestKit CLI workflow)
- using_issuekit_and_testkit.md
- examples.md (file creation rules)
- api_summary_creation.md
- api_reference_creation.md
- project_refactoring.md
- new_project_setup.md
- project_republishing.md
- tool_installation.md
- index.md (dart-specific index)

### Cloud Guidelines (4 files)
Located in `_agent_guidelines/cloud/`:
- cloud_deployment.md (AWS, Azure, GCP, Firebase)
- docker_image_creation.md (Production/dev Docker images)
- docker_local.md (Running server apps locally)
- index.md

### D4rt Guidelines (13 files)
Located in `_agent_guidelines/d4rt/`:
- d4rt.md (Overview)
- dcli_scripting_guide.md (DCli shell scripting with BuildKit)
- testing_d4rt_bridges.md (Bridge generator e2e testing)
- d4rt_interpreter_vs_d4rt_generator.md
- d4rt_bridgedclass_guidelines.md
- d4rt_bridge_generator.md
- d4rt_main_result.md
- d4rt_reusability_design.md
- d4rt_usage_guidelines.md
- d4rt_usage_guide.md
- dcli_overview.md
- generator_strategies.md
- BRIDGING_GUIDE.md
- README.md

### Pattern Prompts (13 files)
Located in `_agent_guidelines/pattern_prompts/`:
Common workflow prompts for git, builds, testing, and workspace operations

---

## 10. Key Infrastructure Projects & Dependency Chains

### Foundation Layer (Build Position 1-25)
These projects form the absolute foundation:

| Project | Type | Position | Key Dependencies |
|---------|------|----------|------------------|
| **tom_build_base** | dart_package | 18 | None (foundation for all CLI tools) |
| **tom_build_kit** | dart_console | 20 | tom_build_base |
| **tom_basics** | dart_package | 15 | Foundational utilities |
| **tom_ai_build** | dart_console | 8 | tom_ai |

### Core Framework Layer (Build Position 100+)
These depend heavily on foundation and are consumed by applications:

| Project | Type | Position | Key Dependencies |
|---------|------|----------|------------------|
| **tom_core_kernel** | dart_package | 112 | tom_reflection, tom_basics, tom_crypto, tom_build, tom_reflection_generator + 1 more |
| **tom_core_server** | dart_package | 106 | tom_core_kernel, tom_basics_console, tom_build |
| **tom_core_flutter** | dart_package | 113 | tom_reflection, tom_core_kernel, tom_d4rt, tom_d4rt_generator |
| **tom_build** | dart_console | 105 | tom_d4rt, tom_reflection, tom_core_kernel, tom_core_server, tom_dist_ledger + 3 more |

### Tom Brain (Positions 125-130)
The Tom Brain subsystem is positioned at the **end of the build order** as a complete integrated system:

| Project | Type | Description |
|---------|------|-------------|
| **tom_brain_access** | dart_console | Inbound surface (OpenAI HTTP/SSE + Telegram), access-object production, identity/session/persona resolution, edge security |
| **tom_brain_memory** | dart_console | Self-organizing property-graph memory; storage, retrieval, cognitive agents, sleep cycles, MCP server, multi-machine sync |
| **tom_brain_substrate** | dart_package | LLM provider abstraction, role/persona system, embedding service, web tools, MCP client |
| **tom_brain_procedure** | dart_package | Thin d4rt-hosted engine + dispatcher; runs sequences over sandboxed bridged primitive API |
| **tom_brain_smoke_prototype** | dart_console | End-to-end smoke harness; boots cognition with stub substrate + in-isolate memory |
| **tom_brain_run** | dart_console | Production assembly; boots cognition with real SqliteTomBrainMemory and real substrate (OpenAI LLM + Ollama embeddings) |

**tom_brain_shared** is shared infrastructure used across all Tom Brain components.

---

## 11. Tom AI Directory Structure

The workspace is organized into functional subdirectories under `tom_ai/`:

```
tom_ai/
├── ai_build/              (Build tools & code generation)
│   ├── tom_ai             (AI orchestration base)
│   ├── tom_ai_build       (Build system)
│   ├── tom_code_specs     (Code specification)
│   ├── tom_doc_scanner    (Documentation scanner)
│   ├── tom_doc_specs      (Documentation specs)
│   ├── tom_flow_cli       (Flow definition CLI)
│   ├── tom_flow_engine    (Flow execution engine)
│   ├── tom_specs_clitool  (Specs CLI)
│   ├── tom_specs_core     (Specs core)
│   └── tom_specs_model    (Specs data model)
│
├── basics/                (Foundational utilities)
│   ├── tom_analyzer_shared
│   ├── tom_basics
│   ├── tom_basics_console
│   ├── tom_basics_network
│   ├── tom_build_base     (Foundation for all CLI tools)
│   ├── tom_chattools
│   ├── tom_crypto
│   └── tom_tools
│
├── cloud/                 (Cloud services)
│   ├── tom_provisioning
│   └── tom_provisioning_server
│
├── core/                  (Core framework)
│   ├── tom_core_bridge
│   ├── tom_core_d4rt
│   ├── tom_core_flutter
│   ├── tom_core_kernel
│   ├── tom_core_server
│   └── UI/Test components
│
├── d4rt/                  (D4rt interpreter ecosystem)
│   ├── tom_d4rt           (Main interpreter)
│   ├── tom_d4rt_ast
│   ├── tom_d4rt_dcli
│   ├── tom_d4rt_exec
│   ├── tom_d4rt_generator
│   ├── tom_d4rt_test
│   ├── tom_dcli_exec
│   └── AST/flutter components
│
├── devops/                (Build, deploy, test infrastructure)
│   ├── tom_build          (Main build system)
│   ├── tom_build_cli
│   ├── tom_build_common
│   ├── tom_build_kit
│   ├── tom_deploy
│   ├── tom_deploy_tools
│   ├── tom_github_api
│   ├── tom_issue_kit
│   ├── tom_md2latex
│   ├── tom_md2pdf
│   └── tom_test_kit
│
├── distributed/           (Distributed systems)
│   ├── tom_dist_ledger
│   ├── tom_dist_ledger_tool
│   ├── tom_distributed_orchestration
│   ├── tom_distributed_orchestration_tool
│   ├── tom_distributed_typescript
│   ├── tom_process_monitor
│   └── tom_process_monitor_tool
│
└── reflection/            (Runtime reflection)
    ├── tom_reflection
    ├── tom_reflection_generator
    ├── tom_reflection_test
    ├── tom_reflector
    └── tom_reflector_model
```

---

## 12. Application Suites

### Tom Assistant (AI Personal Assistant)
- **tom_assistant_core**: Core functionality
- **tom_assistant_messaging**: Messaging protocol
- **tom_assistant_server**: Backend server
- **tom_assistant_ui**: Flutter UI

### Tom Forge (Visual Development Tooling)
14 projects including:
- Dart Editor + Markdown Editor + YAML Editor
- Flow Editor (visual workflows)
- UI test framework
- Webview test components
- Core editors shared infrastructure

### Tom Worktracker (Project Management)
- **tom_worktracker_core**: Core logic
- **tom_worktracker_ui**: UI components
- **tom_worktracker_mindmap**: Mind mapping
- **tom_worktracker_app**: Main application

### Tom SQM (Subscription & Quota Management)
- tom_sqm_server, tom_sqm_client (customer), tom_sqm_admin_client, tom_sqm_codespec

### Tom UAM (User & Authorization Management)
- tom_uam_server, tom_uam_client, tom_uam_codespec

### Deepwork (Personal Productivity)
- deepwork_core, deepwork_ui

### Webwork (Web Application Suite)
- webwork_core, webwork_app, webwork_deepwork, webwork_documents, webwork_integrations

---

## 13. Dependency Patterns & Architecture Principles

### Mandatory Pattern: tom_build_base Foundation
From CLAUDE.md: "All CLI tools MUST be based on `tom_build_base`. Never implement shared CLI infrastructure (arg parsing, version flags, help formatting, process execution) from scratch — it belongs in `tom_build_base`."

### Multi-Layer Architecture
1. **Foundation** (tom_build_base, tom_basics, tom_crypto)
2. **AI Infrastructure** (tom_ai, tom_ai_build)
3. **Core Framework** (tom_core_kernel, tom_core_server, tom_core_flutter)
4. **Domain Tools** (tom_build, tom_deploy, tom_d4rt, etc.)
5. **Applications** (Tom Assistant, Tom Forge, Tom Worktracker, etc.)

### D4rt Integration
D4rt bridging is a core pattern throughout:
- tom_d4rt_generator for code generation
- tom_d4rt for runtime execution
- tom_core_d4rt for framework integration
- Comprehensive guidelines in _agent_guidelines/d4rt/

---

## 14. Test & Quality Infrastructure

### Testing Framework
- **tom_test_kit**: Unified testing CLI tool
- **test_tracking.md**: TestKit CLI workflow documentation
- **tests_buildtools.md**: Guidelines for zom_ prefix test projects

### Issue Tracking
- **tom_issue_kit**: Issue management and tracking
- **using_issuekit_and_testkit.md**: Quick reference guide

### Dart Analysis
- **analysis_options.yaml**: Global linter configuration
- **tom_analyzer_shared**: Shared analyzer utilities

---

## 15. Workspace Layers (4-Layer Architecture)

From CLAUDE.md, this workspace operates across **4 interdependent layers**:

| Layer | Content | Example | Sync Command |
|-------|---------|---------|--------------|
| **L1** | Code repositories | al_the_bear submodules + sibling workspaces | `/tom_pull_code` |
| **L2** | Binaries | tom_binaries (build outputs) | `/tom_pull_binaries` |
| **L3** | AI State | tom_agent_state (_ai mounts with symlinks) | `/tom_pull_ai` |
| **L4** | Upstream | Pinned third-party dependencies | Part of `/tom_pull_code` |

All layers are managed through workspace skills:
- `/tom_pull` — sync all four layers
- `/tom_push` — commit + push all three writable layers
- `/tom_clone` — fresh checkout on new machine

---

## Summary Statistics

| Metric | Value |
|--------|-------|
| **Total Projects** | 130 |
| **Project Groups** | 20 |
| **Project Types** | 8 |
| **Build Order Steps** | 130 |
| **Workspace Modes** | 14 total (5 types) |
| **Actions Available** | 5 |
| **Cross-Compile Targets** | 7 |
| **Copilot Guidelines** | 58 files in structured folders |
| **Operating Systems** | 3 (macOS, Linux, Windows) |
| **Mobile Platforms** | 2 (Android, iOS) |
| **Dart SDK Versions** | 13 constraints |

This is a sophisticated, multi-layered enterprise system with comprehensive AI-assisted development infrastructure, specialized D4rt bridging capabilities, and a complete Tom Brain cognitive assistant implementation at the highest level of the build order.
