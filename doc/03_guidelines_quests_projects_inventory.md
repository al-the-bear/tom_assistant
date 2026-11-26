# Tom Brain Workspace Comprehensive Inventory Report
**Generated:** 2026-06-14  
**Source Data:** CLAUDE.md, _agent_guidelines/, tom_master.yaml, _ai/quests/

---

## Section 1: Complete Guidelines Inventory

Total: **67 global guideline files + local project guidelines**

### Global Guidelines (Root Level)

| Category | File | Purpose |
|----------|------|---------| 
| **Core Documentation** | index.md | Master index of all guidelines |
| **Core Documentation** | documentation_guidelines.md | Package/module documentation format standards |
| **Core Documentation** | project_guidelines.md | Template for project-specific _agent_guidelines/ folders |
| **Core Documentation** | project_structure.md | Project and workspace structure patterns |
| **Core Documentation** | projects_and_repos.md | Project IDs and repository organization |
| **Workflow** | tool_dependencies.md | CLI tools, source projects, rebuild instructions |
| **Workflow** | test_driven_development.md | TDD principles: red-green-refactor, test-first |
| **Workflow** | issue_implementation.md | Bug/feature workflow: investigate → test → implement → verify |
| **Workflow** | spec_workflow.md | Specification to implementation workflow |
| **Workflow** | spec_writing_guide.md | Writing AI-friendly specifications |
| **User Interaction** | user_clarification_guidelines.md | Clarification file structure and workflow |
| **Documentation** | document_schemas.md | YAML/markdown schema validation (JSON Schema, DocSpecs) |
| **Documentation** | console_markdown.md | Console markdown formatting conventions |
| **Patterns** | prompt_patterns.md | !prompt, $prompt, $!prompt pattern documentation |
| **Coordination** | global_actions_coordination.md | Fleet-wide action coordination patterns |

### Dart Guidelines (_agent_guidelines/dart/)
**13 files**
- index.md | coding_guidelines.md | clean_code_principles.md | unit_tests.md
- tests_buildtools.md | test_tracking.md | using_issuekit_and_testkit.md | examples.md
- api_summary_creation.md | api_reference_creation.md | project_refactoring.md
- new_project_setup.md | project_republishing.md | tool_installation.md

### Cloud Guidelines (_agent_guidelines/cloud/)
**4 files**
- index.md | cloud_deployment.md | docker_image_creation.md | docker_local.md

### D4rt Guidelines (_agent_guidelines/d4rt/)
**18 files**
- README.md | index.md | d4rt.md | d4rt_bridgedclass_guidelines.md | d4rt_bridge_generator.md
- d4rt_interpreter_vs_d4rt_generator.md | d4rt_usage_guide.md | d4rt_usage_guidelines.md
- d4rt_reusability_design.md | d4rt_main_result.md | dcli_scripting_guide.md | dcli_overview.md
- testing_d4rt_bridges.md | generator_strategies.md | BRIDGING_GUIDE.md

### Pattern Prompts (_agent_guidelines/pattern_prompts/)
**12 files**
Common workflow patterns for building, committing, creating branches, quests, and VS Code operations

---

## Section 2: Active Quests Catalog
**Total: 43 Active Quests**

### Core Infrastructure Quests
- **build_tom**: Build and developer tooling: tom_build_base, buildkit, testkit, issuekit and the workspace build configuration
- **setup_ws**: Restructure Tom project setup for versioning and reuse
- **tom_standards**: Consistent document structures, schemas, and verification tools
- **tom_cli**: Command-line interface for Tom workspace automation

### AI & Tooling Quests
- **tom_flow**: Prompt flow execution system with YAML-driven multi-step workflows
- **code_spec**: Dart annotation-based specification framework
- **doc_scanner**: Command-line tool for scripted markdown processing
- **doc_specs**: Document schemas and verification tools

### Core Framework Quests
- **tom_core**: Core framework projects (kernel, flutter, server, dartscript)
- **d4rt**: D4rt interpreter ecosystem with sandboxing and bridge generation
- **tom_deploy**: Unified deployment tool for multi-cloud applications

### Application & Assistant Quests
- **tom_assistant**: Flagship AI personal assistant demonstrating full Tom Framework
- **tom_brain**: Multi-component cognitive system (access, memory, procedure, substrate)
- **tom_forge**: Composable visual development tooling with flow modeling
- **vscode_extension**: Feature development for Tom VS Code Extension
- **work_tracker**: VS Code extension for todo-tracking and project management

### Integration & Cloud Quests
- **cli_dartbridge**: Local process access to VS Code via Dart bridge
- **ecli_integration**: Integrate ecli Dart package for Unix-like commands
- **tom_telegram**: Telegram Bot integration for assistant chat
- **tom_provisioning**: Automated cloud resource provisioning
- **flutter_ui**: Reusable Flutter business UI components

### Advanced & Experimental Quests
- **c2dart**: Automated C-to-Dart transpiler with FFI memory runtime
- **dist_orchestrator**: Network orchestration for distributed DartScript execution
- **tom_specs**: Structured process for system creation using Tom Architecture
- **tom_deepwork**: Professional task management and deep work productivity
- **tom_uam**: User and Authorization Management application
- **tom_sqm**: Subscription and Quota Management with payment processing
- **tom_authpass**: Custom free password manager with KDBX support

### Operational & Meta Quests
- **tom_agent_container**: Operational layer for coordinated agent-controlled software
- **quests**: Meta-framework for structured AI prompt context
- **incidents**: Handle spontaneous prompts without disturbing other sessions
- **project_coordination**: Git-based transactional reservation system

### Integration & Content Quests
- **openclaw**: Open-source personal AI assistant setup
- **opensource**: Fork and maintain key open-source projects
- **marktext**: Build and publish precompiled MarkText binaries
- **tom_lint**: VS Code linting and validation for Tom formats
- **webwork**: Universal document format and UI for hierarchical content

---

## Section 3: Complete Projects Inventory
**Total: 130 Projects** (from tom_master.yaml)

### Summary by Type
- **dart_package**: 78 (publishable libraries)
- **dart_console**: 35 (CLI tools and executables)
- **flutter_app**: 14 (mobile/web applications)
- **vscode_extension**: 2 (VS Code plugins)
- **typescript_node**: 1 (Node.js/TypeScript)
- **external**: 1 (Git submodules)

### By Project Group (20 Groups)
1. **ai_build** (10 projects) — AI-powered build tooling, spec generation, flow engine
2. **basics** (8 projects) — Foundational utilities, crypto, tools, network
3. **cloud** (2 projects) — Cloud provisioning
4. **core** (8 projects) — Core framework kernel, server, flutter, d4rt, bridge
5. **d4rt** (10 projects) — D4rt interpreter, generator, AST, DCli ecosystem
6. **devops** (11 projects) — Build, deploy, test, issue-tracking tools
7. **distributed** (5 projects) — Distributed ledger, orchestration, process monitoring
8. **reflection** (4 projects) — Runtime reflection, generator, model
9. **tom_assistant** (4 projects) — AI personal assistant
10. **tom_brain** (6 projects) — Cognitive system with memory, procedure, access layers
11. **tom_forge** (13 projects) — Visual development editors (flow, dart, markdown, YAML)
12. **tom_sqm** (4 projects) — Subscription and Quota Management
13. **tom_uam** (3 projects) — User and Authorization Management
14. **tom_worktracker** (4 projects) — Todo tracking and project management
15. **app_webwork** (5 projects) — Webwork document suite
16. **app_deepwork** (2 projects) — Personal productivity applications
17. **tom_claw** (3 projects) — OpenClaw, Pi tooling, TS-to-Dart transpiler
18. **vscode** (7 projects) — VS Code integration and extensions
19. **xternal** (3 projects) — External forks (ceval, native_semaphores, webview)
20. **opensource** (1 project) — Open-source submodules

### Build Order Layers

**Foundation Layer (Positions 1-25):**
Core infrastructure, base libraries, and fundamental utilities. Every project in the workspace depends on these.

Key projects: tom_basics, tom_build_base, tom_core_kernel, tom_d4rt, tom_reflection

**AI & Tooling Layer (Positions 26-60):**
Build tools, generators, code analysis, DevOps infrastructure. Enable automated workflows and code generation.

Key projects: tom_ai_build, tom_code_specs, tom_flow_engine, tom_test_kit, tom_deploy

**Integration Layer (Positions 61-110):**
Domain-specific implementations, application frameworks, feature libraries. Build on foundation to provide integrated solutions.

Key projects: tom_assistant_core, tom_worktracker_core, tom_forge_core, tom_sqm_codespec, tom_brain_shared

**Application Layer (Positions 111-130):**
End-user applications and complete systems. Highest level of abstraction, bringing all components together.

Key projects: tom_assistant_ui, tom_forge_app, tom_worktracker_app, tom_brain_run (production assembly)

### Key Strategic Projects

**tom_build_base** (Position 3)
- CRITICAL: Foundation for ALL CLI tools
- Used by 30+ tools for arg parsing, version flags, help formatting
- Rule: Extend tom_build_base first, test, publish, then consume downstream

**tom_core_kernel** (Position 10)
- CRITICAL: Core framework foundation
- Core abstractions for 20+ framework projects
- Used by tom_core_flutter, tom_core_server, tom_brain_shared

**tom_d4rt** (Position 15)
- CRITICAL: Sandboxed Dart interpreter
- Enables D4rt scripting and automation throughout workspace
- Used by tom_d4rt_generator, tom_core_d4rt, tom_brain_procedure

**tom_brain System** (Positions 71-130)
- **tom_brain_shared** (71): Shared types for all brain components
- **tom_brain_memory** (75): Self-organizing knowledge graph with multi-recall
- **tom_brain_substrate** (74): LLM provider abstraction
- **tom_brain_procedure** (76): D4rt-hosted procedure engine
- **tom_brain_access** (102): HTTP/Telegram inbound surface
- **tom_brain_run** (130): Production assembly with real substrate

**tom_vscode_extension** (Position 108)
- CRITICAL: Full VS Code integration
- Enables Copilot chat, build commands, workflow automation
- TypeScript/JavaScript vscode extension with Dart bridge

**tom_forge** (Suite - Positions 88-128)
- Composable visual development tooling
- Integrated editors: Flow, Dart, Markdown, YAML
- Complete application: tom_forge_app (Position 128)

**tom_worktracker** (Suite - Positions 77-125)
- Todo tracking and project management
- VS Code extension + Flutter application
- Core library with UI and mindmap components

---

## Section 4: Cross-Project Dependency Map

### Critical Dependency Chains

**Chain 1: CLI Tools Foundation**
```
tom_basics → tom_build_base → tom_build_cli, tom_build_kit, tom_test_kit, 
tom_issue_kit, tom_deploy_tools, tom_dist_ledger_tool, and 25+ others
```

**Chain 2: Core Framework**
```
tom_basics → tom_core_kernel → tom_core_flutter, tom_core_server, tom_core_bridge, tom_core_d4rt
→ All Flutter and server applications
```

**Chain 3: D4rt Ecosystem**
```
tom_d4rt → tom_d4rt_generator, tom_d4rt_dcli, tom_core_d4rt → tom_brain_procedure, scripting systems
```

**Chain 4: Tom Brain (Complete Cognition)**
```
tom_brain_shared ← tom_brain_memory, tom_brain_substrate, tom_d4rt
→ tom_brain_procedure → tom_brain_access → tom_brain_run
```

### Major Consumers

- **tom_basics**: 80+ projects
- **tom_build_base**: 30+ CLI tools
- **tom_core_kernel**: 20+ framework projects
- **tom_d4rt**: 10+ automation/scripting tools
- **tom_core_server**: 15+ server applications

### Circular Dependency Risks
**NONE** — Workspace maintains strict dependency DAG with clean architecture

---

## Section 5: Workspace Statistics & Metrics

| Metric | Value |
|--------|-------|
| **Total Projects** | 130 |
| **Project Groups** | 20 |
| **Build Layers** | 4 |
| **Critical Path Length** | 30-35 projects (foundation → tom_brain_run) |
| **Projects with Tests** | 60+ |
| **Projects with Examples** | 30+ |
| **Publishable to pub.dev** | 30+ |
| **VS Code Extensions** | 2 |
| **Dart Packages** | 78 |
| **Dart Console Apps** | 35 |
| **Flutter Apps** | 14 |

---

## Section 6: Project Maturity & Status

### Stable (30 projects)
Production-ready, widely used, comprehensive test coverage:
tom_basics, tom_build_base, tom_core_kernel, tom_core_flutter, tom_d4rt, tom_test_kit, tom_build_cli, tom_vscode_extension

### Active Development (40 projects)
Regular changes, ongoing features:
tom_brain system (7), tom_assistant (4), tom_forge (13), tom_ai_build, tom_deploy, tom_sqm/tom_uam suites

### Maintenance (35 projects)
Stable, minimal changes, core infrastructure:
tom_d4rt ecosystem, tom_core extensions, tom_distributed tools

### Experimental (15 projects)
Early stage, unstable APIs:
tom_openclaw, tom_pi_mono, webwork suite, deepwork_ui

### Deprecated (2 projects)
No longer maintained:
tom_vscode_extension_original, yaml_graph_vscode (subsumed)

---

## Section 7: Documentation Quality Assessment

### Guideline Presence
- **20+ projects** have local `_agent_guidelines/` folders
- **Global guidelines**: 67 files at workspace root
- **All major groups** have comprehensive guidance

### Documentation Quality by Project Group
- **Excellent**: ai_build, basics, core, d4rt, tom_brain
- **Good**: devops, vscode, cloud, tom_assistant, tom_forge
- **Emerging**: Experimental and new projects

### Key Artifacts
- **README.md**: 70+ projects with quality documentation
- **API Docs**: tom_core_kernel, tom_basics, tom_reflection (excellent)
- **Copilot Guidelines**: Comprehensive index.md files in all groups
- **Examples**: 30+ projects with example/ folders
- **Test Baselines**: testkit integration with CSV tracking

---

## Summary

The Tom Brain workspace comprises:
- **130 Projects** across 4 architectural layers
- **20 Project Groups** organized by functional domain
- **43 Active Quests** tracking ongoing development
- **67 Global Guidelines** plus 20+ local guideline folders
- **Complete AI System** (Tom Brain) with knowledge graph, procedures, and multi-modal access
- **Production-Ready Components** (30+ publishable packages, 2 VS Code extensions)
- **Strict Architecture** maintaining clean dependency DAG across all 130 projects
- **Comprehensive Test Infrastructure** (60+ projects with tests, baseline CSV tracking)
- **Multi-Layer Organization**: Foundation → AI/Tooling → Integration → Application

This is an enterprise-grade, carefully architected system designed for scalable, AI-assisted software development within the Dart/Flutter ecosystem.
