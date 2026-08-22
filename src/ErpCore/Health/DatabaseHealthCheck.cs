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
/// 실패 원인을 <see cref="HealthCheckResult.Description"/> 에 남긴다. 현장에서 우리가
/// 접속할 수 없으므로 화면에 드러나지 않는 원인은 없는 것과 같다.
/// </remarks>
public sealed class DatabaseHealthCheck : IHealthCheck
{
    private readonly string _connectionString;
    private readonly TimeSpan _timeout;

    public DatabaseHealthCheck(string connectionString, TimeSpan timeout)
    {
        _connectionString = connectionString;
        _timeout = timeout;
    }

    public async Task<HealthCheckResult> CheckHealthAsync(
        HealthCheckContext context,
        CancellationToken cancellationToken = default)
    {
        // 타임아웃을 명시한다. 폐쇄망에서 도달 불가 호스트에 대한 기본 타임아웃은
        // 길고, 그동안 헬스체크가 매달려 있으면 배포 스크립트가 hang 으로 보인다.
        using var timeoutCts = CancellationTokenSource.CreateLinkedTokenSource(cancellationToken);
        timeoutCts.CancelAfter(_timeout);

        try
        {
            await using var connection = new NpgsqlConnection(_connectionString);
            await connection.OpenAsync(timeoutCts.Token);

            await using var command = new NpgsqlCommand("SELECT 1", connection);
            await command.ExecuteScalarAsync(timeoutCts.Token);

            return HealthCheckResult.Healthy("database reachable");
        }
        catch (OperationCanceledException) when (!cancellationToken.IsCancellationRequested)
        {
            return HealthCheckResult.Unhealthy(
                $"database check timed out after {_timeout.TotalSeconds:0.#}s");
        }
        catch (Exception ex)
        {
            // 연결 문자열은 절대 담지 않는다 — 자격증명이 헬스체크 응답으로 새어나간다.
            return HealthCheckResult.Unhealthy($"database unreachable: {ex.GetType().Name}");
        }
    }
}
