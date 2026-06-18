# SysON Backend & REST API — Structure Analysis Notes

Reference notes from a live investigation of the SysON REST/GraphQL API behavior,
the `syson-sysml-rest-api-services` module, and the MCP server tooling built on
top of it. Intended to be handed to a future Claude session to avoid
re-deriving these findings from scratch.

Context: SysON running locally via Docker (`docker-compose up`, app at
`http://localhost:8080`), CoffeeMachineProject test project
(`c9d6a53d-8e33-4fe1-bb54-7305a29bb361`), MCP servers from
`F:\Repositories\Github\SysML_V2_MCP_server`.

---

## 1. Architecture summary

- SysON's `syson-sysml-rest-api-services` module (backend/services/syson-sysml-rest-api-services)
  implements the OMG SysML v2 REST API **only partially**. It mostly delegates
  to Sirius Web's framework-level services rather than containing its own
  persistence logic.
- Key class: `SysONProjectDataVersioningRestService.java`
  (`backend/services/syson-sysml-rest-api-services/src/main/java/org/eclipse/syson/sysml/rest/api/`)
  — implements `IProjectDataVersioningRestServiceDelegate` and wraps
  `IDefaultProjectDataVersioningRestService` (an external Sirius Web interface,
  not present in this repo — Sirius Web 2026.1.6 per root `CLAUDE.md`).
- There is **no REST controller for branches/projects/commits inside the SysON
  repo at all** — the `@PostMapping`/`@GetMapping` routing lives entirely
  inside Sirius Web. Grepping this repo for `BranchRestController` or
  `@PostMapping.*branch` only finds the one delegate file above.
- Most of `SysONProjectDataVersioningRestService`'s methods are pure
  pass-throughs to `defaultProjectDataVersioningRestService`. SysON only adds
  custom logic for `getCommitChange` / `getCommitChangeById` (computing
  synthetic change IDs from element hashes).

## 2. Confirmed REST/GraphQL API limitations

| Operation | Endpoint | Behavior | Notes |
|---|---|---|---|
| Create project | `POST /api/rest/projects` | HTTP 405 | Not implemented via REST. **Use `graphql_create_project` instead.** |
| Create branch | `POST /api/rest/projects/{id}/branches` | HTTP 200, empty body, **no branch persisted** | Tested with both `head` and `referencedCommit` payload shapes — same silent no-op both times. No GraphQL mutation exists for branch creation either. See §3. **Update:** also confirmed via `syson-feature-support.html` (separate doc in `SysML_V2_MCP_server/Doc/`): "Version history / branching — Not Supported — SysON uses a single-commit-per-project model; no git-style branching." So this isn't a bug at all — branching is simply out of scope for SysON's data model. Don't keep digging into this; treat it as permanently unsupported. |
| GraphQL `exposeRequirements` mutation | N/A — mutation removed from schema | `Field 'exposeRequirements' in type 'Mutation' is undefined` (confirmed via schema introspection) | Removed in a `[cleanup] Move requirement table tools declaration to the backend` change (seen in CHANGELOG.adoc merge conflict in the syson repo). **Replacement:** the generic `invokeToolMenuEntry` mutation with `menuEntryId: "import-existing-requirements-table-tool-entry"`. Discovered by introspecting `TableDescription.toolMenuEntries(tableId: ID!): [ToolMenuEntry]`, reachable via `viewer.editingContext(editingContextId).representations(representationIds: [...]).edges.node.description { ... on TableDescription { toolMenuEntries(tableId: ...) { id label } } }`. Fixed in MCP server `_invoke_import_requirements` (`SysML_V2_MCP_server` repo, commit `e510ec6`), verified end-to-end (`expose_status: "success"`, 5 `MembershipExpose` elements created under the table's `ViewUsage`). |
| `list_representations` (old MCP tool) | GraphQL `viewer.project(projectId).representations` | Always silently returned `[]`, even when representations existed | `Project` type has no `representations` field — the correct path is `viewer.editingContext(editingContextId).representations`. The tool's `result.get("data", {}).get(...)` chain swallowed the GraphQL validation error at each `.get()` step and fell through to the default `[]`, so the bug never surfaced as an error. **Fixed** (same commit `e510ec6`) — now resolves `editingContextId` first via `_fetch_editing_context_id`, queries the correct path, and uses the `kind` field (e.g. `siriusComponents://representation?type=Table`) instead of `__typename` since the query node type is `RepresentationMetadata`, not the `Table`/`Diagram` interface (interface fragments are rejected there). |
| `list_elements` (old MCP tool) | via `sysml_v2_api_client` SDK | `AttributeError: 'ElementApi' object has no attribute 'get_elements_in_commit'` | SDK method name is wrong/doesn't exist. **Fixed in MCP server** by bypassing the SDK and using `httpx` directly against `/projects/{id}/commits/{id}/elements`. |
| `get_element` (old MCP tool) | via SDK `.to_dict()` | Returns only `{id, type, identifier: null}` — no attributes, no relationship endpoints | SDK's `to_dict()` strips almost everything. **Fixed** by calling the raw REST endpoint directly, which returns full JSON-LD including relationship endpoints like `type`, `typedFeature`, `owningFeature` (essential for resolving `FeatureTyping`/`Subsetting`/`Redefinition` targets). |
| `list_relationships` (old MCP tool) | via SDK | `AttributeError: 'RelationshipApi' object has no attribute 'get_relationships_by_project_commit_element'` | Same SDK issue as `list_elements`. **Fixed** the same way. |
| `sirius-web list_representations` | GraphQL `representations` field | Returns only **opened/created graphical representations** registered in Sirius Web | Does NOT return SysML `ViewUsage` elements defined in the model's textual/structural content. A `ViewUsage` can exist in the model with zero corresponding entries here. **Added `list_view_usages` tool** to the sirius-web MCP server to cover this gap (filters `_fetch_elements` by `@type == 'ViewUsage'`). |

## 3. `deleteBranch` bug (fixed this session)

**File:** `backend/services/syson-sysml-rest-api-services/src/main/java/org/eclipse/syson/sysml/rest/api/SysONProjectDataVersioningRestService.java`

Before (copy-paste bug, line ~143):
```java
@Override
public RestBranch deleteBranch(IEditingContext editingContext, UUID branchId) {
    return this.defaultProjectDataVersioningRestService.getBranchById(editingContext, branchId);
}
```
It called `getBranchById` instead of `deleteBranch` — so calling delete would
just fetch the branch and never actually remove it.

**Fixed to:**
```java
@Override
public RestBranch deleteBranch(IEditingContext editingContext, UUID branchId) {
    return this.defaultProjectDataVersioningRestService.deleteBranch(editingContext, branchId);
}
```

This fix follows the existing pattern of every other method in the class
(`getBranches`, `createBranch`, `getBranchById` all delegate 1:1 by name to
the matching method on `defaultProjectDataVersioningRestService`), so the
interface almost certainly exposes a matching `deleteBranch(IEditingContext, UUID)`
method. **Not yet verified against Sirius Web's actual interface/jar** —
local Maven repo / Sirius Web sources were not found in this environment to
double check the exact signature. If a future build fails to compile here,
that's the first thing to check.

## 4. Branch creation — RESOLVED: not a bug, by design unsupported

**Update:** confirmed via `SysML_V2_MCP_server/Doc/syson-feature-support.html`
("Collaboration & Multi-User" section): *"Version history / branching — Not
Supported — SysON uses a single-commit-per-project model; no git-style
branching."* This is intentional, not a bug. **Stop investigating this** in
future sessions — there is nothing to fix, and no workaround via REST/GraphQL
exists or is planned.

`createBranch` (same file, ~line 132) is correctly wired:
```java
@Override
public RestBranch createBranch(IEditingContext editingContext, String branchName, UUID commitId) {
    return this.defaultProjectDataVersioningRestService.createBranch(editingContext, branchName, commitId);
}
```
i.e. this is **not a SysON bug** — it's a straight delegation to Sirius Web.
Live testing (`curl -X POST .../branches` with various payload shapes) always
returned `HTTP 200` with `Content-Length: 0` and never actually created a
branch (`GET .../branches` afterward still only shows `defaultBranch`). This
matches the documented "not supported" status above — the empty 200 is
Sirius Web's default no-op behavior for an unsupported operation, not a
malfunction.

**Practical implication (unchanged):** don't rely on creating a branch as a
safety net before risky model edits via this REST API — it will never work.
Work directly on the default branch and verify each change immediately with
`get_element`, or back up/export the project first if a real rollback point
is needed.

~~Two possible explanations, not yet distinguished~~ (kept below for history,
no longer relevant — confirmed as scenario 2, except it's not a "gap", it's
intentional product scope):
1. **Payload/contract mismatch** — Sirius Web's actual controller expects a
   different request shape than `{"@type":"Branch","name":...,"head":{...}}`
   or `{"@type":"Branch","name":...,"referencedCommit":{...}}` (both tried).
   If so, fixing this needs **no backend code change** — just the right
   request body.
2. **Genuine gap/no-op in Sirius Web's default branch persistence** for this
   deployment. If so, SysON would need to override `createBranch` with real
   custom persistence logic instead of delegating — **significant new code**,
   requires understanding Sirius Web's commit/branch/project-semantic-data
   storage model (`ProjectSemanticData`, `IProjectSemanticDataSearchService`,
   etc. — see imports in `SysONProjectDataVersioningRestService.java`).

**Practical implication:** don't rely on creating a branch as a safety net
before risky model edits via this REST API. Work directly on the default
branch and verify each change immediately with `get_element`, or back up/export
the project first if a real rollback point is needed.

**Next step if revisiting:** try to obtain Sirius Web 2026.1.6 sources/javadoc
for `IDefaultProjectDataVersioningRestService` (not found locally in this
environment — `.m2` repo location wasn't located either) to see the exact
expected request contract before assuming it's a real implementation gap.

## 5. MCP server fixes applied (in `SysML_V2_MCP_server` repo, separate from SysON)

Commit `112e954` (`[fix] Fix broken REST tools and add find_elements_by_type and list_view_usages`):

- `syson_mcp_server.py`:
  - `list_elements`, `get_element`, `list_relationships` rewritten to call
    `_rest_get(...)` directly instead of the broken `sysml_v2_api_client` SDK
    methods.
  - New tool `find_elements_by_type(project_id, commit_id, element_type)` —
    filters all elements by `@type` server-side in the tool (not a real REST
    server-side filter, just avoids manual client-side filtering every time).
    **Caveat:** for `PartDefinition` on this test project, the full result was
    58,927 characters — exceeded the MCP response token limit when called
    directly. Use a subagent or read the saved file with `jq` for large type
    filters instead of calling it directly in the main conversation.
- `sirius_web_graphql_mcp_server.py`:
  - `list_representations` docstring clarified — opened representations only.
  - New tool `list_view_usages(project_id)` — lists SysML `ViewUsage` model
    elements via `_fetch_elements` filtered by `@type`.
  - Earlier in the same session, also added `drop_elements_on_diagram` (GraphQL
    `dropOnDiagram` mutation wrapper) — unrelated to the REST fixes but same
    file.

**Important:** MCP server code changes only take effect after the MCP server
process is restarted, which in this Claude Code setup means **exiting and
restarting the whole Claude Code session** (not just re-reading the file).
New/changed tool schemas show up as deferred tools that need `ToolSearch`
(`select:<name>`) before they're callable.

## 6. CoffeeMachineProject model structure (test data reference)

Project: `CoffeeMachineProject`, id `c9d6a53d-8e33-4fe1-bb54-7305a29bb361`
(also used as `commit_id` — SysON convention: project id == initial commit id).
Single branch: `defaultBranch` (same UUID as project id).

15 `PartDefinition`s under package `Coffee Machine Parts`
(`415c2201-40b9-4c51-821b-82a3ca2fb379`):

```
CoffeeMachine (top-level)
 ├─ grinder         : GrindingSubsystem      (NO internal parts — gap)
 ├─ brewingUnit     : BrewingUnit
 │     └─ heater    : HeatingSubsystem
 │           ├─ tempSensor     : TemperatureSensor
 │           └─ pressureSensor : PressureSensor
 ├─ milkFrother     : MilkFrothingUnit       (NO internal parts — gap)
 ├─ waterTank       : WaterTank
 │     └─ waterLevelSensor : WaterLevelSensor
 ├─ beanHopper      : BeanHopper
 │     └─ beanLevelSensor  : BeanLevelSensor
 ├─ ui              : UserInterface         (NO internal parts)
 ├─ connectivity    : ConnectivityModule    (NO internal parts)
 ├─ controlUnit     : ControlUnit           (NO internal parts)
 └─ powerSupply     : PowerSupply           (NO internal parts)
```

All `FeatureTyping` targets above were verified directly via the fixed
`get_element` tool (not just inferred from naming) — confirmed accurate as of
this session.

19 `RequirementUsage` elements across 4 sub-packages of `Requirements`
(`FunctionalRequirements`, `HardwareRequirements`, `NonFunctionalRequirements`,
`InterfaceRequirements`) — see git history / prior session for full list if
needed, not repeated here.

"Coffee Machine Part Definition Diagram" `ViewUsage`
(`ca039fd0-60aa-4a02-8217-4454649f7a82`) exposes exactly these 15
`PartDefinition`s via 15 `MembershipExpose` elements — diagram content matches
model content 1:1, no missing exposes.

### Recommended model improvements (not yet implemented)

- Add internal parts to `GrindingSubsystem` (motor, grinding burrs) and
  `MilkFrothingUnit` (pump, frother wand, cleaning valve) — both currently
  empty leaf-like blocks despite being non-trivial subsystems.
- Consider whether `HeatingSubsystem` should be nested 3 levels deep inside
  `BrewingUnit` only, or also referenced directly from `CoffeeMachine`.
- Minor: add at least one internal part to `UserInterface`, `ConnectivityModule`,
  `ControlUnit`, `PowerSupply` for completeness (lower priority — these are
  plausibly leaf components).
- **Open question, discuss before implementing:** how to add new
  `PartUsage`/`PartDefinition` elements with correct containment via the REST
  API. `create_element_with_attributes` only sets flat attributes
  (`{"@type": element_type, **attributes}`) — unclear whether passing an
  `owner` field establishes proper `FeatureMembership` containment, or whether
  manual relationship-element creation is required. **Not tested yet** —
  treat as a real risk of leaving orphaned/malformed elements if attempted
  without verifying on a disposable test project first (remember: branching
  doesn't work as a safety net here, see §4).

## 7. General lessons for future sessions

- Always prefer GraphQL tools (`syson-graphql` MCP server) over REST for
  **mutations** in SysON — REST write support is inconsistent/partial.
  REST is more reliable for **reads**, especially once `get_element` /
  `list_elements` / `list_relationships` are fixed (full JSON-LD, not SDK
  `.to_dict()`).
- `graphql_insert_sysml_text` is the safe way to add **new** definitions/usages
  by writing real SysML v2 textual syntax — but re-declaring an **existing**
  named definition this way risks a name conflict/duplicate rather than
  extending it. It inserts new children into the target namespace; it does
  not patch an existing element's body.
- When checking relationship targets (e.g. `FeatureTyping.target`), don't
  trust naming-convention guesses alone if precision matters — `get_element`
  (post-fix) returns the real `type`/`typedFeature`/`target` fields directly.
