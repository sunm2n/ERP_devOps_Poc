namespace ErpCore.Orders;

/// <summary>주문. PoC 범위이므로 필드는 최소다 — 실제 ERP 스키마가 아니다.</summary>
/// <remarks>
/// <c>Quantity</c> 와 <c>UnitPrice</c> 는 3단계 마이그레이션에서 **타입 축소 대상**이다
/// (plan.md 9번, 이슈 #10 의 경계값 시드가 이 두 컬럼을 노린다).
/// 여기서 타입을 바꾸면 H5 의 가역성 표가 달라지므로 임의로 손대지 말 것.
/// </remarks>
public sealed record Order(
    Guid Id,
    string CustomerCode,
    int Quantity,
    decimal UnitPrice,
    DateTimeOffset CreatedAt)
{
    public decimal Total => Quantity * UnitPrice;
}

/// <summary>주문 생성 요청.</summary>
public sealed record CreateOrderRequest(string CustomerCode, int Quantity, decimal UnitPrice);
