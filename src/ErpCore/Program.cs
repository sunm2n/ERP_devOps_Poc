using ErpCore.Health;
using ErpCore.Orders;
using Microsoft.AspNetCore.Diagnostics.HealthChecks;
using Microsoft.Extensions.Diagnostics.HealthChecks;
using System.Reflection;
using System.Text.Json;

var builder = WebApplication.CreateBuilder(args);

// 설정은 환경변수에서 온다. 기본값은 **개발 편의용이 아니라 폐쇄망 기본값**이다 —
// 실제 값은 배포 시 주입된다. 12-factor 전반은 이슈 #8 에서 형식화한다.
const string DefaultConnectionString = "Host=localhost;Port=5432;Database=erp;Username=erp;Timeout=3";

var configuredConnection = builder.Configuration["ERP_DB_CONNECTION"];
var connectionString = string.IsNullOrWhiteSpace(configuredConnection)
    ? DefaultConnectionString
    : configuredConnection;

// **설정이 어디서 왔는지를 남긴다.** 이게 없으면 "환경변수를 안 넣었다" 와 "DB 가 죽었다" 가
// 같은 화면으로 나온다 — 둘 다 SocketException 이다. 고객사 수만큼 손으로 채우는 값인데
// 그 지점의 실패가 무증상이면 원인 특정에 통화 30분이 든다.
var connectionSource = string.IsNullOrWhiteSpace(configuredConnection) ? "default" : "env";

// 설정값이 잘못되면 스택트레이스만 남기고 죽는다 — `_SECONDS` 라는 이름 때문에 `3s` 로
// 쓰는 실수가 흔하다. 폐쇄망에서는 "컨테이너가 바로 꺼져요" 로 보이고 원인은 우리가
// 접속할 수 없는 곳의 로그 안에 있다. 기본값으로 떨어지되 경고를 남긴다.
var rawTimeout = builder.Configuration["ERP_HEALTH_TIMEOUT_SECONDS"];
var timeoutSeconds = 3.0;
string? timeoutWarning = null;
if (!string.IsNullOrWhiteSpace(rawTimeout))
{
    if (double.TryParse(rawTimeout, System.Globalization.NumberStyles.Float,
            System.Globalization.CultureInfo.InvariantCulture, out var parsed)
        && parsed is > 0 and <= 300)
    {
        timeoutSeconds = parsed;
    }
    else
    {
        timeoutWarning =
            $"ERP_HEALTH_TIMEOUT_SECONDS 값을 해석할 수 없어 기본값 {timeoutSeconds}초를 씁니다 " +
            "(0 초과 300 이하의 숫자여야 합니다. 예: 3 또는 2.5)";
    }
}
var healthTimeout = TimeSpan.FromSeconds(timeoutSeconds);

// 배포된 것이 정말 새 버전인지 확인할 수단. 이게 없으면 "새 버전이 건강함" 과
// "옛 컨테이너가 그대로 떠서 건강함" 이 구분되지 않고, 7번 ⑥ 멱등 2회차와 H4 가
// 정확히 그 위험 구간이다.
var buildId = Assembly.GetEntryAssembly()
    ?.GetCustomAttribute<AssemblyInformationalVersionAttribute>()
    ?.InformationalVersion ?? "unknown";

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
    ResponseWriter = (context, report) =>
        WriteHealthResponse(context, report, buildId, connectionSource),
});

app.Logger.LogInformation(
    "ErpCore {BuildId} 기동. DB 연결 설정 출처={ConnectionSource}, 헬스 타임아웃={TimeoutSeconds}초",
    buildId, connectionSource, timeoutSeconds);
if (timeoutWarning is not null)
    app.Logger.LogWarning("{Warning}", timeoutWarning);

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

    // 합계 오버플로를 **저장 전에** 막는다. Total 은 직렬화 시점에 계산되는데 저장이 먼저
    // 일어나므로, 오버플로를 일으킨 주문이 저장소에 남아 그 뒤 모든 목록 조회를 500 으로
    // 만든다 — 인메모리라 프로세스 재시작 외에 복구 수단이 없다. 그런데 그동안 /health 는
    // 계속 200 이라 배포 스크립트는 '적용 완료' 로 기록한다.
    // 이건 업무 규칙이 아니라 크래시 방지이므로 #9 의 IOrderValidator 를 선점하지 않는다.
    // 이슈 #10 의 경계값 시드가 이 두 컬럼에 int.MaxValue/decimal.MaxValue 를 넣는다.
    try
    {
        _ = checked(request.Quantity * request.UnitPrice);
    }
    catch (OverflowException)
    {
        return Results.BadRequest(new { error = "Quantity × UnitPrice overflows decimal range" });
    }

    var order = store.Add(request, clock);
    return Results.Created($"/orders/{order.Id}", order);
});

orders.MapGet("/{id:guid}", (Guid id, OrderStore store) =>
    store.Find(id) is { } order ? Results.Ok(order) : Results.NotFound());

orders.MapGet("/", (OrderStore store) => Results.Ok(store.All()));

app.Run();

static Task WriteHealthResponse(
    HttpContext context, HealthReport report, string buildId, string connectionSource)
{
    context.Response.ContentType = "application/json; charset=utf-8";

    var payload = new
    {
        status = report.Status.ToString(),
        // 배포 스크립트(#20)가 이 값을 기대값과 대조하면 '적용 완료' 판정이 근거를 갖는다.
        build = buildId,
        connectionSource,
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
