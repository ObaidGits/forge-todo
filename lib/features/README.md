# Feature modules

Forge uses feature-first modules. A feature owns four inward-pointing layers:

- `domain/`: immutable entities, values, policies, and repository interfaces;
- `application/`: commands, queries, projections, events, and exported contracts;
- `infrastructure/`: Drift repositories and platform/remote adapters;
- `presentation/`: routes, controllers, views, and feature widgets.

Create a layer only when it has production code. Cross-feature access is limited
to exported `application/` contracts or typed `domain/events/`; infrastructure
and DAO imports never cross a feature boundary. `tool/architecture_fitness.py`
enforces these rules and the approved module names.
