using System.Net.Sockets;
using Microsoft.Extensions.Diagnostics.HealthChecks;
using Npgsql;

namespace ErpCore.Health;

/// <summary>
/// DB 도달성 확인. <c>/health</c> 가 의존성 상태를 반영해야 한다는 요구(이슈 #7)의 구현이다.
/// </summary>
/// <remarks>
/// **폐쇄망에서 이 검사는 조용히 실패하면 안 된다.** 번들 적용 시간은 "스크립트 실행 시작 →
/// 헬스체크 통과" 로 측정되므로(plan.md 5장), 헬스체크가 DB 를 안 보고 통과하면 그 측정값이
/// 거짓이 된다 — 서비스는 떴는데 DB 가 없는 상태를 "적용 완료" 로 기록하게 된다.
///
/// **예외 타입 이름은 진단이 아니다.** <c>SocketException</c> 하나에 (a) DB 프로세스가 안 떴다
/// (b) 라우팅이 없다 (c) 호스트명이 안 풀린다 (d) 방화벽이 막았다 가 전부 들어가는데
/// **넷은 조치가 전부 다르다.** 현장에서 우리가 접속할 수 없으므로, 담당자가 전화로 읽어줄
/// 한 줄에 원인이 갈려 있어야 한다. 그래서 <c>SqlState</c>(5자, 고정 집합, 비밀 아님)와
/// <c>SocketErrorCode</c>, 그리고 <c>Host:Port/Database</c> 를 함께 남긴다.
/// **자격증명(Username·Password)은 절대 담지 않는다.**
/// </remarks>
public sealed class DatabaseHealthCheck : IHealthCheck
{
    private readonly string _connectionString;
    private readonly string _endpoint;
    private readonly TimeSpan _timeout;
    private readonly int _connectTimeoutSeconds;

    public DatabaseHealthCheck(string connectionString, TimeSpan timeout)
    {
        _timeout = timeout;

        // 연결 타임아웃을 코드에서 강제한다. 고객사가 자기 연결 문자열을 주입하는 순간
        // — 즉 실제 운영의 100% — 기본값 문자열의 `Timeout=3` 은 사라지고 Npgsql 기본
        // 15초로 돌아간다. 그러면 아래 헬스 타임아웃이 항상 먼저 걸려 **모든 실패가
        // "timed out" 하나로 붕괴하고** 위에서 살린 진단이 다시 죽는다.
        try
        {
            var builder = new NpgsqlConnectionStringBuilder(connectionString);

            // Npgsql 에서 Timeout=0 은 **무한대**다. `builder.Timeout > connectTimeout` 만
            // 보면 0 이 통과해(0 > 2 는 거짓) 막으려던 붕괴가 그대로 일어난다.
            _connectTimeoutSeconds = Math.Max(1, (int)Math.Floor(timeout.TotalSeconds) - 1);
            if (builder.Timeout == 0 || builder.Timeout > _connectTimeoutSeconds)
                builder.Timeout = _connectTimeoutSeconds;

            _connectionString = builder.ConnectionString;
            _endpoint = $"{builder.Host}:{builder.Port}/{builder.Database}";
        }
        catch (ArgumentException ex)
        {
            // 파싱 실패도 검사 시점에 보고한다. 여기서 던지면 앱이 기동조차 못 하고
            // 폐쇄망에서는 그 이유가 화면에 안 나온다.
            // **ParamName 에 어느 키가 틀렸는지가 들어 있고 값은 안 들어 있다** —
            // 없으면 담당자에게 연결 문자열을 통째로 불러달라고 해야 하는데
            // 그 안에 비밀번호가 있어 전화로 못 읽는다.
            _connectionString = connectionString;
            _connectTimeoutSeconds = Math.Max(1, (int)Math.Floor(timeout.TotalSeconds) - 1);
            // 키 이름은 Describe 가 낸다. 여기서 또 붙이면 한 줄에 두 번 나온다.
            _endpoint = "<연결 문자열 파손>";
        }
        catch (Exception ex)
        {
            _connectionString = connectionString;
            _connectTimeoutSeconds = Math.Max(1, (int)Math.Floor(timeout.TotalSeconds) - 1);
            _endpoint = $"<연결 문자열 파손: {ex.GetType().Name}>";
        }
    }

    public async Task<HealthCheckResult> CheckHealthAsync(
        HealthCheckContext context,
        CancellationToken cancellationToken = default)
    {
        using var timeoutCts = CancellationTokenSource.CreateLinkedTokenSource(cancellationToken);
        timeoutCts.CancelAfter(_timeout);

        try
        {
            await using var connection = new NpgsqlConnection(_connectionString);
            await connection.OpenAsync(timeoutCts.Token);

            await using var command = new NpgsqlCommand("SELECT 1", connection);
            await command.ExecuteScalarAsync(timeoutCts.Token);

            return HealthCheckResult.Healthy($"database reachable at {_endpoint}");
        }
        catch (OperationCanceledException) when (!cancellationToken.IsCancellationRequested)
        {
            return HealthCheckResult.Unhealthy(
                $"database check timed out after {_timeout.TotalSeconds:0.#}s at {_endpoint}");
        }
        catch (Exception ex)
        {
            return HealthCheckResult.Unhealthy($"database unreachable at {_endpoint}: {Describe(ex)}");
        }
    }

    /// <summary>조치가 갈리는 지점까지만 노출한다. 자격증명·예외 메시지 원문은 담지 않는다.</summary>
    private string Describe(Exception ex) => ex switch
    {
        // SqlState 는 5자 고정 집합이다. 28P01=비밀번호 틀림, 3D000=DB 없음, 53300=커넥션 한도.
        PostgresException pg => $"PostgresException SqlState={pg.SqlState}",
        // ConnectionRefused / HostNotFound / TimedOut / NetworkUnreachable 이 갈린다.
        SocketException se => $"SocketException {se.SocketErrorCode}",
        NpgsqlException { InnerException: SocketException inner }
            => $"NpgsqlException SocketException {inner.SocketErrorCode}",
        // **방화벽 DROP·라우팅 없음이 여기로 온다** — 폐쇄망 최초 설치에서 가장 흔한 원인이고,
        // 유일하게 고객사 망 담당자가 우리 없이 고칠 수 있는 칸이다. 이 arm 이 없으면
        // 'NpgsqlException' 한 단어로 붕괴해 ConnectionRefused(DB 미기동)와 구분되지 않는다.
        // 연결 타임아웃을 코드에서 강제한 결과 Npgsql 이 먼저 던지므로,
        // 아래 OperationCanceledException 분기에는 도달하지 않는다.
        NpgsqlException { InnerException: TimeoutException }
            => $"ConnectTimeout after {_connectTimeoutSeconds}s (방화벽·라우팅 확인)",
        ArgumentException ae when ae.ParamName is { Length: > 0 } key
            => $"ArgumentException '{key}' 키",
        _ => ex.GetType().Name,
    };
}
