using ErpCore.Health;
using ErpCore.Orders;
using Microsoft.AspNetCore.Diagnostics.HealthChecks;
using Microsoft.Extensions.Diagnostics.HealthChecks;
using System.Text.Json;

var builder = WebApplication.CreateBuilder(args);

// 설정은 환경변수에서 온다. 기본값은 **개발 편의용이 아니라 폐쇄망 기본값**이다 —
// 실제 값은 배포 시 주입된다. 12-factor 전반은 이슈 #8 에서 형식화한다.
var connectionString = builder.Configuration["ERP_DB_CONNECTION"]
    ?? "Host=localhost;Port=5432;Database=erp;Username=erp;Timeout=3";
var healthTimeout = TimeSpan.FromSeconds(
    builder.Configuration.GetValue("ERP_HEALTH_TIMEOUT_SECONDS", 3.0));

builder.Services.AddSingleton(TimeProvider.System);
builder.Services.AddSingleton<OrderStore>();
builder.Services.AddHealthChecks()
    .AddCheck("database", new DatabaseHealthCheck(connectionString, healthTimeout), tags: ["ready"]);

var app = builder.Build();

// --- 헬스체크 -----------------------------------------------------------
// liveness 와 readiness 를 나눈다. 하나로 합치면 DB 가 잠깐 끊겼을 때 오케스트레이터가
// 멀쩡한 프로세스를 죽인다. PoC 는 K8s 를 쓰지 않지만(plan.md 2장 제외), 배포 스크립트가
// 무엇을 기다려야 하는지는 여기서 갈린다 — 번들 적용 시간 측정의 종료 지점이다.
app.MapHealthChecks("/health/live", new HealthCheckOptions
{
    Predicate = _ => false,   // 프로세스가 응답하면 살아 있다
});

app.MapHealthChecks("/health", new HealthCheckOptions
{
    Predicate = check => check.Tags.Contains("ready"),
    ResponseWriter = WriteHealthResponse,
});

// --- 업무 엔드포인트 ----------------------------------------------------
// plan.md 2장: "실제 ERP 비즈니스 로직" 은 범위 밖이다. 배포 파이프라인이 실어 나를
// **무언가**가 있으면 되고, 그 무언가가 DB·설정·확장 지점을 건드리면 충분하다.
var orders = app.MapGroup("/orders");

orders.MapPost("/", (CreateOrderRequest request, OrderStore store, TimeProvider clock) =>
{
    // 검증 지점. 이슈 #9 의 IOrderValidator 가 여기 꽂힌다 —
    // **코어 수정 없이** 교체 가능해야 하는 것이 H2 의 판정 기준이다.
    if (string.IsNullOrWhiteSpace(request.CustomerCode))
        return Results.BadRequest(new { error = "CustomerCode is required" });
    if (request.Quantity <= 0)
        return Results.BadRequest(new { error = "Quantity must be positive" });
    if (request.UnitPrice < 0)
        return Results.BadRequest(new { error = "UnitPrice must not be negative" });

    var order = store.Add(request, clock);
    return Results.Created($"/orders/{order.Id}", order);
});

orders.MapGet("/{id:guid}", (Guid id, OrderStore store) =>
    store.Find(id) is { } order ? Results.Ok(order) : Results.NotFound());

orders.MapGet("/", (OrderStore store) => Results.Ok(store.All()));

app.Run();

static Task WriteHealthResponse(HttpContext context, HealthReport report)
{
    context.Response.ContentType = "application/json; charset=utf-8";

    var payload = new
    {
        status = report.Status.ToString(),
        durationMs = report.TotalDuration.TotalMilliseconds,
        checks = report.Entries.ToDictionary(
            entry => entry.Key,
            entry => new
            {
                status = entry.Value.Status.ToString(),
                // 실패 원인을 응답에 남긴다. 현장에서 우리가 접속할 수 없다.
                description = entry.Value.Description,
            }),
    };

    return context.Response.WriteAsync(JsonSerializer.Serialize(payload));
}

/// <summary>통합 테스트에서 참조하기 위한 진입점 표식.</summary>
public partial class Program;
