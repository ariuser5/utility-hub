# utility-hub

Utility Hub is a general-purpose collection of APIs, tools, and helper modules designed to support a wide range of projects. It serves as a central place for experimenting, prototyping, and building reusable components, with the flexibility to split coherent features into dedicated repositories as they grow.

## Repository Structure

The repository is organized into deep, domain-specific directories to accommodate multiple projects of various technologies:

```
utility-hub/
├── src/                    # Source code
│   ├── apis/              # API projects
│   │   └── minimal-api/   # .NET Minimal API project
│   ├── tools/             # Command-line tools and utilities (future)
│   └── libraries/         # Shared libraries and modules (future)
├── docs/                   # Documentation (future)
└── tests/                  # Test projects (future)
```

## Projects

### APIs

#### Minimal API (`src/apis/minimal-api`)
A simple ASP.NET Core minimal API that exposes a basic endpoint returning HTTP 200.

**Quick Start:**
```bash
cd src/apis/minimal-api/MinimalApi
dotnet run
```

Then visit: `http://localhost:5152/` or `http://localhost:5152/swagger`

See the [Minimal API README](src/apis/minimal-api/README.md) for more details.

## Adding New Projects

The structure is designed to accommodate diverse technologies:

- **APIs**: Place in `src/apis/<project-name>/`
- **Tools**: Place in `src/tools/<tool-name>/`
- **Libraries**: Place in `src/libraries/<library-name>/`

Each project should be self-contained within its directory and include its own README with setup and usage instructions.
