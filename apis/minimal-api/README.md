# Minimal API

A simple ASP.NET Core minimal API that exposes a basic endpoint returning HTTP 200.

## Project Structure

```
minimal-api/
└── MinimalApi/          # Main API project
    ├── Program.cs       # Application entry point with endpoint definitions
    ├── MinimalApi.csproj # Project file
    └── appsettings.json # Configuration settings
```

## Getting Started

### Prerequisites

- .NET 8.0 SDK or later

### Running the API

```bash
cd src/apis/minimal-api/MinimalApi
dotnet run
```

The API will start and listen on `http://localhost:5152` (or the port specified in launchSettings.json).

### Building the API

```bash
cd src/apis/minimal-api/MinimalApi
dotnet build
```

## Endpoints

### GET /
Returns a simple status message with HTTP 200.

**Response:**
```json
{
  "status": "ok",
  "message": "Minimal API is running"
}
```

## Testing

You can test the endpoint using curl:

```bash
curl http://localhost:5152/
```

Or visit the Swagger UI in your browser (in development mode):
```
http://localhost:5152/swagger
```

## Technology Stack

- ASP.NET Core 8.0
- Minimal APIs
- Swagger/OpenAPI for API documentation
