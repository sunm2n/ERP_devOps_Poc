using System.Collections.Concurrent;

namespace ErpCore.Orders;

/// <summary>
/// 주문 저장소. **PoC 스캐폴딩 단계에서는 인메모리다.**
/// </summary>
/// <remarks>
/// 실제 저장은 마이그레이션(이슈 #11)이 스키마를 만든 뒤에 붙는다. 지금 DB 쓰기를 넣으면
/// 스키마가 두 곳(코드와 마이그레이션)에서 정의되고, H4·H5 가 대조할 기준이 흐려진다.
///
/// plan.md 2장의 12-factor 규칙("로컬 디스크 저장 없음")은 이슈 #8 에서 형식화한다.
/// 인메모리는 프로세스가 죽으면 사라지므로 그 규칙과 충돌하지 않는다 — 다만
/// **여러 인스턴스에서 상태가 갈리므로 PoC 는 단일 인스턴스를 전제한다.**
/// </remarks>
public sealed class OrderStore
{
    private readonly ConcurrentDictionary<Guid, Order> _orders = new();

    public Order Add(CreateOrderRequest request, TimeProvider clock)
    {
        var order = new Order(
            Guid.NewGuid(),
            request.CustomerCode,
            request.Quantity,
            request.UnitPrice,
            clock.GetUtcNow());

        _orders[order.Id] = order;
        return order;
    }

    public Order? Find(Guid id) => _orders.TryGetValue(id, out var order) ? order : null;

    public IReadOnlyCollection<Order> All() => _orders.Values.ToArray();
}
