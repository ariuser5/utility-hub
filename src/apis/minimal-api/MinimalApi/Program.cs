var builder = WebApplication.CreateBuilder(args);

// Add services to the container.
builder.Services.AddEndpointsApiExplorer();
builder.Services.AddSwaggerGen();

var app = builder.Build();

// Configure the HTTP request pipeline.
if (app.Environment.IsDevelopment())
{
    app.UseSwagger();
    app.UseSwaggerUI();
}

app.UseHttpsRedirection();

// Simple endpoint that returns HTTP 200
app.MapGet("/", () => Results.Ok(new { status = "ok", message = "Minimal API is running" }))
    .WithName("GetStatus")
    .WithOpenApi();

app.Run();
